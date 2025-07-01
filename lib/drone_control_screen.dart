import 'dart:async'; // Added for Timer
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_joystick/flutter_joystick.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'drone_comm.dart'; // Import the DroneComm class
import 'package:shared_preferences/shared_preferences.dart';

class DroneControlScreen extends StatefulWidget {
  const DroneControlScreen({Key? key}) : super(key: key);

  @override
  State<DroneControlScreen> createState() => _DroneControlScreenState();
}

class _DroneControlScreenState extends State<DroneControlScreen> {
  final DroneComm _droneComm = DroneComm(); // Instantiate DroneComm
  Timer? _commandTimer; // Timer for sending commands
  Timer? _armingTimer; // Timer for arming sequence
  Timer? _throttleDecayTimer; // Timer for gradual throttle decay

  // Define scaling factors
  static const double MAX_ROLL_PITCH_ANGLE = 30.0; // degrees
  static const double MAX_YAW_RATE = 200.0;      // degrees/second
  static const int MIN_THRUST = 1000;            // Minimum effective thrust (per protocol)
  static const int MAX_THRUST = 60000;           // Maximum safe thrust (updated from protocol)
  static const double DEFAULT_EXPO_EXPONENT = 1.1; // Default joystick sensitivity

  bool connected = false;
  bool _isArmed = false; // Track arming state
  double thrust = 0.0; // Joystick Y: -1 (top) to 1 (bottom) -> App Thrust 1.0 (top) to 0.0 (bottom)
  double yaw = 0.0;    // Joystick X: -1.0 to 1.0
  double roll = 0.0;   // Joystick X: -1.0 to 1.0
  double pitch = 0.0;  // Joystick Y: -1.0 to 1.0 
  bool yawOn = false;
  double rollTrim = 0.0; // Added for roll trim
  double pitchTrim = 0.0; // Added for pitch trim
  List<String> debugLines = ["Welcome to LiteWing!", "Ready."];
  String? currentSsid;
  
  // Separate tracking for each joystick to support multi-touch
  Offset? _leftJoystickStartPosition;
  Offset? _rightJoystickStartPosition;
  
  // Joystick visual states
  bool _leftJoystickActive = false;
  bool _rightJoystickActive = false;
  double _leftJoystickX = 0.0;
  double _leftJoystickY = 0.0;
  double _rightJoystickX = 0.0;
  double _rightJoystickY = 0.0;

  double expoExponent = 1.1;
  
  // Throttle decay variables
  double _lastThrustValue = 0.0; // Last thrust value when joystick was active
  bool _isThrottleDecaying = false; // Whether throttle is currently decaying
  DateTime? _thrustReleaseTime; // When the joystick was released

  @override
  void initState() {
    super.initState();
    _fetchSSID();
    _loadTrimValues();
    _loadExpoExponent();
  }

  @override
  void dispose() {
    _stopSendingCommands();
    _throttleDecayTimer?.cancel();
    _droneComm.close();
    super.dispose();
  }

  Future<void> _fetchSSID() async {
    final info = NetworkInfo();
    try {
      final ssid = await info.getWifiName();
      if (mounted) {
        setState(() {
          currentSsid = ssid;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          currentSsid = "Error fetching SSID";
        });
      }
      _addDebug("Error fetching SSID: $e");
    }
  }

  Future<void> _loadTrimValues() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      rollTrim = prefs.getDouble('rollTrim') ?? 0.0;
      pitchTrim = prefs.getDouble('pitchTrim') ?? 0.0;
    });
  }

  Future<void> _saveTrimValues() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('rollTrim', rollTrim);
    await prefs.setDouble('pitchTrim', pitchTrim);
  }

  Future<void> _loadExpoExponent() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      expoExponent = prefs.getDouble('expoExponent') ?? 1.1;
    });
  }

  Future<void> _saveExpoExponent() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('expoExponent', expoExponent);
  }

  void _addDebug(String msg) {
    if (mounted) {
      setState(() {
        debugLines.insert(0, msg); 
        if (debugLines.length > 6) debugLines = debugLines.sublist(0, 6); 
      });
    }
  }

  Future<void> _handleConnectDisconnect() async {
    if (connected) {
      // Handle Disconnect
      _stopSendingCommands();
      _droneComm.close(); // Close the socket
      if (mounted) {
        setState(() {
          connected = false;
          _isArmed = false; // Reset armed state
        });
        _addDebug("Disconnected from drone.");
      }
      return;
    }

    // Handle Connect
    await _fetchSSID(); // Refresh SSID
    if (currentSsid == null || !currentSsid!.toLowerCase().contains('litewing')) {
      if (mounted) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Not connected to LiteWing'),
            content: Text('Please connect to the LiteWing WiFi network to continue. Current: ${currentSsid ?? "Unknown"}'),
            actions: [
              TextButton(
                onPressed: () async {
                  Navigator.of(context).pop();
                  const String androidSettingsUri = 'android.settings.WIFI_SETTINGS';
                  const String iosSettingsUri = 'App-Prefs:root=WIFI';
                  try {
                    if (await canLaunchUrl(Uri(scheme: 'intent', path: androidSettingsUri))) {
                       await launchUrl(Uri(scheme: 'intent', path: androidSettingsUri));
                    } else if (await canLaunchUrl(Uri.parse(iosSettingsUri))) {
                       await launchUrl(Uri.parse(iosSettingsUri));
                    } else {
                      _addDebug("Could not open WiFi settings automatically.");
                      if(mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                             const SnackBar(content: Text("Could not open WiFi settings. Please open them manually."))
                          );
                      }
                    }
                  } catch (e) {
                     _addDebug("Error opening WiFi settings: $e");
                  }
                },
                child: const Text('Open WiFi Settings'),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
            ],
          ),
        );
      }
      return;
    }

    // SSID is OK, now attempt to connect the socket
    try {
      await _droneComm.connect();
      _addDebug("Drone UDP socket initialized.");
      if (mounted) {
        setState(() => connected = true);
        _startSendingCommands();
        _addDebug('Connected to drone. Starting arming sequence...');
        _addDebug('Keep joysticks centered during arming.');
      }
    } catch (e) {
      _addDebug("Error initializing drone socket: $e");
      if (mounted) {
        setState(() => connected = false); // Ensure not connected if socket fails
         ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text("Error connecting to drone: $e. Check WiFi & drone power."))
        );
      }
    }
  }

  void _startSendingCommands() {
    _commandTimer?.cancel();
    _armingTimer?.cancel();
    
    // Start with arming sequence
    if (!_isArmed) {
      _addDebug("Starting arming sequence (2 seconds)...");
      int armingPacketCount = 0;
      _armingTimer = Timer.periodic(const Duration(milliseconds: 20), (timer) {
        if (!connected || !mounted) {
          timer.cancel();
          return;
        }
        
        if (armingPacketCount >= 100) { // 2 seconds = 100 packets at 50Hz
          timer.cancel();
          _isArmed = true;
          _addDebug("Arming complete! Motors ready for thrust.");
          _startRegularCommands();
          return;
        }
        
        // Send zero thrust commands during arming
        final List<int> packet = _droneComm.createCommanderPacket(
          roll: 0.0,
          pitch: 0.0,
          yaw: 0.0,
          thrust: 0, // Zero thrust during arming
        );
        _droneComm.sendPacket(packet);
        armingPacketCount++;
        
        // Update debug every 25 packets (0.5 seconds)
        if (armingPacketCount % 25 == 0) {
          _addDebug("Arming... ${(armingPacketCount / 50.0).toStringAsFixed(1)}s");
        }
      });
    } else {
      _startRegularCommands();
    }
  }

  void _startRegularCommands() {
    _commandTimer = Timer.periodic(const Duration(milliseconds: 20), (timer) {
      if (!connected || !mounted) {
        timer.cancel();
        _droneComm.close();
        return;
      }

      // Scale thrust: App (0.0 to 1.0) -> Protocol (10000 to 60000)
      // Only apply thrust if armed and thrust > 0
      int protocolThrust = 0;
      if (_isArmed && thrust > 0.0) {
        protocolThrust = (MIN_THRUST + (thrust * (MAX_THRUST - MIN_THRUST))).round();
      }
      
      // Apply trim to roll and pitch, clamp to [-1.0, 1.0]
      double trimmedRoll = (roll + rollTrim).clamp(-1.0, 1.0);
      double trimmedPitch = (pitch + pitchTrim).clamp(-1.0, 1.0);
      double scaledRoll = trimmedRoll * MAX_ROLL_PITCH_ANGLE;
      double scaledPitch = trimmedPitch * MAX_ROLL_PITCH_ANGLE;
      double scaledYaw = (yawOn ? yaw : 0.0) * MAX_YAW_RATE;

      final List<int> packet = _droneComm.createCommanderPacket(
        roll: scaledRoll,
        pitch: scaledPitch,
        yaw: scaledYaw,
        thrust: protocolThrust,
      );
      _droneComm.sendPacket(packet);
    });
  }

  void _stopSendingCommands() {
    _armingTimer?.cancel();
    _commandTimer?.cancel();
    _armingTimer = null;
    _commandTimer = null;
    _isArmed = false; // Reset armed state
    
    // Send a few zero thrust packets before disconnecting for safety
    if (_droneComm != null) {
      for (int i = 0; i < 5; i++) {
        final packet = _droneComm.createCommanderPacket(
          roll: 0.0,
          pitch: 0.0,
          yaw: 0.0,
          thrust: 0,
        );
        _droneComm.sendPacket(packet);
      }
    }
    
    _addDebug("Command stream stopped. Drone disarmed.");
  }

  Widget _buildTopBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 8.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            decoration: BoxDecoration(
              color: Colors.grey[800],
              shape: BoxShape.circle,
            ),
            child: IconButton(
              icon: Icon(Icons.swap_horiz, color: yawOn ? Colors.white : Colors.grey[400]),
              tooltip: "Toggle Yaw",
              onPressed: () {
                setState(() {
                  yawOn = !yawOn;
                  if (!yawOn) {
                    yaw = 0.0;
                  }
                  _addDebug('Yaw ${yawOn ? 'on' : 'off'}');
                });
              },
            ),
          ),
          
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                    connected 
                      ? "Connected to: ${currentSsid ?? 'Drone'}"
                      : "Not Connected to Drone", 
                    style: TextStyle(
                      color: connected ? Colors.green[300] : Colors.red[300], 
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                    ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),

          Container(
            decoration: BoxDecoration(
              color: Colors.grey[800],
              shape: BoxShape.circle,
            ),
            child: IconButton(
              icon: Icon(Icons.link, color: connected ? Colors.green : Colors.grey[400]),
              tooltip: connected ? "Disconnect" : "Connect",
              onPressed: _handleConnectDisconnect,
            ),
          ),

        ],
      ),
    );
  }

  Widget _buildDebugPanel() {
    return Container(
      padding: const EdgeInsets.all(8.0),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.7),
        borderRadius: BorderRadius.circular(8.0),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: debugLines.map((line) => 
          Text(line, 
            style: const TextStyle(color: Colors.white, fontSize: 12),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          )
        ).toList(),
      ),
    );
  }

  Widget _buildCustomJoystickArea({
    required bool isLeftStick,
    required Function(double x, double y) onUpdate,
  }) {
    return Column(
      children: [
        Expanded(
          child: Container(
            margin: const EdgeInsets.all(8.0),
            // Removed border and background - just transparent area
      child: Builder(
        builder: (BuildContext context) {
          return GestureDetector(
            onPanStart: (details) {
              // Store the start position for drag calculations - separate for each joystick
              setState(() {
                if (isLeftStick) {
                  _leftJoystickStartPosition = details.localPosition;
                  _leftJoystickActive = true;
                } else {
                  _rightJoystickStartPosition = details.localPosition;
                  _rightJoystickActive = true;
                }
              });
            },
            onPanUpdate: (details) {
              // Use the appropriate start position for each joystick
              Offset? startPos = isLeftStick ? _leftJoystickStartPosition : _rightJoystickStartPosition;
              if (startPos != null) {
                _updateJoystickFromDrag(
                  startPos, 
                  details.localPosition, 
                  context, 
                  onUpdate, 
                  isLeftStick
                );
              }
            },
            onPanEnd: (details) {
              setState(() {
                if (isLeftStick) {
                  _leftJoystickStartPosition = null;
                  _leftJoystickActive = false;
                  _leftJoystickX = 0.0;
                  _leftJoystickY = 0.0;
                } else {
                  _rightJoystickStartPosition = null;
                  _rightJoystickActive = false;
                  _rightJoystickX = 0.0;
                  _rightJoystickY = 0.0;
                }
              });
              // Return to center when released
              onUpdate(0.0, 0.0);
            },
            onTapUp: (details) {
              setState(() {
                if (isLeftStick) {
                  _leftJoystickStartPosition = null;
                  _leftJoystickActive = false;
                  _leftJoystickX = 0.0;
                  _leftJoystickY = 0.0;
                } else {
                  _rightJoystickStartPosition = null;
                  _rightJoystickActive = false;
                  _rightJoystickX = 0.0;
                  _rightJoystickY = 0.0;
                }
              });
              // Handle tap and immediate release
              onUpdate(0.0, 0.0);
            },
            child: Container(
              width: double.infinity,
              height: double.infinity,
              child: Stack(
                children: [
                  // Background grid for visual reference
                  CustomPaint(
                    painter: JoystickGridPainter(),
                    size: Size.infinite,
                  ),
                  // Center point indicator - bigger
                  Center(
                    child: Container(
                      width: 16,
                      height: 16,
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.8),
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 1),
                      ),
                    ),
                  ),
                  // Joystick position indicator - always visible, moves from center based on drag
                  Positioned.fill(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        double offsetX = 0.0;
                        double offsetY = 0.0;
                        
                        if (isLeftStick) {
                          offsetX = _leftJoystickX * constraints.maxWidth / 4;
                          offsetY = _leftJoystickY * constraints.maxHeight / 4;
                        } else {
                          offsetX = _rightJoystickX * constraints.maxWidth / 4;
                          offsetY = _rightJoystickY * constraints.maxHeight / 4;
                        }
                        
                        return Align(
                          alignment: Alignment.center,
                          child: Transform.translate(
                            offset: Offset(offsetX, offsetY),
                            child: Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                color: Colors.white.withOpacity(0.6),
                                shape: BoxShape.circle,
                                border: Border.all(color: Colors.white, width: 2),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),

                ],
              ),
            ),
          );
        },
      ),
          ),
        ),
        // Label below joystick
        Padding(
          padding: const EdgeInsets.only(bottom: 8.0),
          child: Text(
            isLeftStick ? 'THRUST/YAW' : 'ROLL/PITCH',
            style: TextStyle(
              color: Colors.white70,
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.center,
          ),
        ),
      ],
    );
  }

  void _updateJoystickFromDrag(
    Offset startPosition,
    Offset currentPosition,
    BuildContext joystickContext,
    Function(double x, double y) onUpdate,
    bool isLeftStick,
  ) {
    // Get the size of the joystick area
    final RenderBox? renderBox = joystickContext.findRenderObject() as RenderBox?;
    if (renderBox == null) return;
    
    final size = renderBox.size;
    
    // Calculate drag delta from start position
    double deltaX = currentPosition.dx - startPosition.dx;
    double deltaY = currentPosition.dy - startPosition.dy;
    
    // Convert delta to normalized values (-1 to 1)
    // Use different sensitivity for left (thrust) vs right (roll/pitch) joysticks
    double sensitivityX = isLeftStick ? 8.0 : 6.0; // Reduced for roll - expo curve will amplify small movements
    double sensitivityY = isLeftStick ? 4.0 : 6.0; // Reduced for pitch - expo curve will amplify small movements
    
    double rawX = (deltaX * sensitivityX / size.width).clamp(-1.0, 1.0);
    double rawY = (deltaY * sensitivityY / size.height).clamp(-1.0, 1.0);
    
    // Apply progressive sensitivity curve only to right joystick (roll/pitch)
    double normalizedX = isLeftStick ? rawX : _applyProgressiveCurve(rawX);
    double normalizedY = isLeftStick ? rawY : _applyProgressiveCurve(rawY);
    
    // Update visual state for circle position
    setState(() {
      if (isLeftStick) {
        // If yaw is off, only allow vertical movement (thrust)
        if (!yawOn) {
          _leftJoystickX = 0.0;
          _leftJoystickY = normalizedY;
        } else {
          _leftJoystickX = normalizedX;
          _leftJoystickY = normalizedY;
        }
      } else {
        _rightJoystickX = normalizedX;
        _rightJoystickY = normalizedY;
      }
    });
    
    if (isLeftStick) {
      // For thrust: convert Y to 0-1 range (drag up = positive thrust)
      // Full power range 0-100%
      double thrustValue = math.max(0.0, -normalizedY);
      // Only pass yaw value if yaw is enabled
      double yawValue = yawOn ? normalizedX : 0.0;
      onUpdate(yawValue, thrustValue);
    } else {
      onUpdate(normalizedX, normalizedY);
          }
    }

  // Helper methods to get actual protocol values being sent to drone
  int _getActualThrustValue() {
    // Always show the thrust value regardless of armed state
    if (thrust <= 0.0) return 0;
    return (MIN_THRUST + (thrust * (MAX_THRUST - MIN_THRUST))).round();
  }

  int _getActualThrustPercentage() {
    // Convert thrust to percentage (0-100%)
    return (thrust * 100).round();
  }

  double _getActualYawValue() {
    return (yawOn ? yaw : 0.0) * MAX_YAW_RATE;
  }

  double _getActualRollValue() {
    return roll * MAX_ROLL_PITCH_ANGLE;
  }

    double _getActualPitchValue() {
    return pitch * MAX_ROLL_PITCH_ANGLE;
  }

  // EXPO CURVE for Roll/Pitch: Solves "0-15° not responsive, 15°+ over-responsive" problem
  // Maps: 80% of joystick range → 0-20° output, 20% extreme range → 20-30° output
  double _applyProgressiveCurve(double input) {
    double sign = input.sign;
    double absInput = input.abs();
    double output;
    if (absInput <= 0.8) {
      double normalizedInput = absInput / 0.8;
      output = 0.67 * math.pow(normalizedInput, expoExponent);
    } else {
      double extremeInput = (absInput - 0.8) / 0.2;
      output = 0.67 + (0.33 * extremeInput);
    }
    return sign * output.clamp(0.0, 1.0);
  }

  void _startThrottleDecay() {
    // Cancel any existing decay timer
    _throttleDecayTimer?.cancel();
    
    // Record the current thrust and release time
    _lastThrustValue = thrust;
    _thrustReleaseTime = DateTime.now();
    _isThrottleDecaying = true;
    
    // Start the decay timer - runs every 50ms for smooth decay
    _throttleDecayTimer = Timer.periodic(const Duration(milliseconds: 50), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      
      final elapsed = DateTime.now().difference(_thrustReleaseTime!);
      
      // Start decay immediately - gradually decrease to zero over 1.5 seconds
      const totalDecayDuration = 1500; // 1.5 seconds to decay to zero
      
      if (elapsed.inMilliseconds >= totalDecayDuration) {
        // Decay complete
        setState(() {
          thrust = 0.0;
          _isThrottleDecaying = false;
        });
        timer.cancel();
      } else {
        // Calculate decay progress (0.0 to 1.0)
        final decayProgress = elapsed.inMilliseconds / totalDecayDuration;
        final newThrust = _lastThrustValue * (1.0 - decayProgress);
        
        setState(() {
          thrust = math.max(0.0, newThrust);
        });
      }
    });
  }
  
  void _stopThrottleDecay() {
    _throttleDecayTimer?.cancel();
    _isThrottleDecaying = false;
    _thrustReleaseTime = null;
  }

  void _showTrimSettingsRightSheet() {
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 300),
      pageBuilder: (context, animation, secondaryAnimation) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Align(
              alignment: Alignment.centerRight,
              child: Material(
                child: Container(
                  width: MediaQuery.of(context).size.width * 0.8,
                  height: MediaQuery.of(context).size.height,
                                     decoration: const BoxDecoration(
                     color: Colors.black,
                   ),
                  child: Column(
                    children: [
                      // Header
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 4.0, vertical: 8.0),
                                                  decoration: BoxDecoration(
                            color: Colors.grey[900],
                            border: Border(bottom: BorderSide(color: Colors.grey[700]!, width: 1)),
                          ),
                        child: Row(
                          children: [
                            IconButton(
                              icon: const Icon(Icons.close, size: 20),
                              onPressed: () => Navigator.pop(context),
                              color: Colors.grey[300],
                            ),
                            const Expanded(
                              child: Text(
                                'Pitch & Roll Settings',
                                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Colors.white),
                                textAlign: TextAlign.center,
                              ),
                            ),
                            TextButton(
                              onPressed: () {
                                _saveTrimValues();
                                _saveExpoExponent();
                                Navigator.pop(context);
                              },
                              child: const Text('SAVE', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.white)),
                            ),
                          ],
                        ),
                      ),
                      // Scrollable content
                      Expanded(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _buildTrimSlider(
                                label: 'Roll Trim',
                                description: 'Compensates for left/right drift when joystick is centered',
                                value: rollTrim,
                                onChanged: (v) {
                                  setState(() => rollTrim = v);
                                  setModalState(() => rollTrim = v);
                                },
                                onReset: () {
                                  setState(() => rollTrim = 0.0);
                                  setModalState(() => rollTrim = 0.0);
                                },
                              ),
                              const SizedBox(height: 12),
                              _buildTrimSlider(
                                label: 'Pitch Trim',
                                description: 'Compensates for forward/backward drift when joystick is centered',
                                value: pitchTrim,
                                onChanged: (v) {
                                  setState(() => pitchTrim = v);
                                  setModalState(() => pitchTrim = v);
                                },
                                onReset: () {
                                  setState(() => pitchTrim = 0.0);
                                  setModalState(() => pitchTrim = 0.0);
                                },
                              ),
                              const SizedBox(height: 12),
                              _buildExpoSliderForModal(setModalState),
                              const SizedBox(height: 24), // Extra space at bottom
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        return SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(1.0, 0.0),
            end: Offset.zero,
          ).animate(CurvedAnimation(
            parent: animation,
            curve: Curves.easeInOut,
          )),
          child: child,
        );
      },
    );
  }

  Widget _buildTrimSlider({
    required String label,
    required String description,
    required double value,
    required ValueChanged<double> onChanged,
    required VoidCallback onReset,
  }) {
    final displayValue = (value * 30).toStringAsFixed(1);
    final Color activeColor = value == 0
        ? Colors.grey[400]!
        : (value > 0 ? Colors.green[700]! : Colors.red[700]!);
    
    return Card(
      elevation: 0,
      color: Colors.grey[800],
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(0)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10.0, vertical: 8.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600, 
                    fontSize: 13,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(
                    color: activeColor.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Text(
                    '$displayValue°',
                    style: TextStyle(
                      color: activeColor,
                      fontWeight: FontWeight.w600,
                      fontSize: 11,
                    ),
                  ),
                ),
                const Spacer(),
                GestureDetector(
                  onTap: onReset,
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    child: Icon(
                      Icons.refresh, 
                      size: 16, 
                      color: Colors.grey[400],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              description,
              style: TextStyle(
                fontSize: 11,
                color: Colors.grey[400],
                height: 1.1,
              ),
            ),
            const SizedBox(height: 4),
            SizedBox(
              height: 24,
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  activeTrackColor: activeColor,
                  inactiveTrackColor: Colors.grey[600],
                  thumbColor: activeColor,
                  overlayColor: activeColor.withOpacity(0.2),
                  trackHeight: 2.5,
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6.0),
                  overlayShape: const RoundSliderOverlayShape(overlayRadius: 12.0),
                ),
                child: Slider(
                  value: value,
                  min: -0.5,
                  max: 0.5,
                  divisions: 50,
                  label: '$displayValue°',
                  onChanged: onChanged,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildExpoSlider() {
    return Card(
      elevation: 0,
      color: Colors.grey[50],
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10.0, vertical: 8.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text(
                  'Joystick Sensitivity',
                  style: TextStyle(
                    fontWeight: FontWeight.w600, 
                    fontSize: 13,
                    color: Colors.black87,
                  ),
                ),
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(
                    color: Colors.blue[50],
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Text(
                    expoExponent.toStringAsFixed(2),
                    style: TextStyle(
                      color: Colors.blue[700],
                      fontWeight: FontWeight.w600,
                      fontSize: 11,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              'Controls how responsive the roll/pitch joystick feels. Lower = more sensitive for small movements.',
              style: TextStyle(
                fontSize: 11,
                color: Colors.grey[600],
                height: 1.1,
              ),
            ),
            const SizedBox(height: 4),
            SizedBox(
              height: 24,
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  activeTrackColor: Colors.blue[600],
                  inactiveTrackColor: Colors.grey[300],
                  thumbColor: Colors.blue[600],
                  overlayColor: Colors.blue[600]!.withOpacity(0.1),
                  trackHeight: 2.5,
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6.0),
                  overlayShape: const RoundSliderOverlayShape(overlayRadius: 12.0),
                ),
                child: Slider(
                  value: expoExponent,
                  min: 1.0,
                  max: 2.5,
                  divisions: 30,
                  label: expoExponent.toStringAsFixed(2),
                  onChanged: (v) => setState(() => expoExponent = v),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildExpoSliderForModal(StateSetter setModalState) {
    return Card(
      elevation: 0,
      color: Colors.grey[800],
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(0)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10.0, vertical: 8.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text(
                  'Joystick Sensitivity',
                  style: TextStyle(
                    fontWeight: FontWeight.w600, 
                    fontSize: 13,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(
                    color: Colors.blue[800]!.withOpacity(0.3),
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Text(
                    expoExponent.toStringAsFixed(2),
                    style: TextStyle(
                      color: Colors.blue[300],
                      fontWeight: FontWeight.w600,
                      fontSize: 11,
                    ),
                  ),
                ),
                const Spacer(),
                GestureDetector(
                  onTap: () {
                    setState(() => expoExponent = DEFAULT_EXPO_EXPONENT);
                    setModalState(() => expoExponent = DEFAULT_EXPO_EXPONENT);
                  },
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    child: Icon(
                      Icons.refresh, 
                      size: 16, 
                      color: Colors.grey[400],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              'Controls how responsive the roll/pitch joystick feels. Lower = more sensitive for small movements.',
              style: TextStyle(
                fontSize: 11,
                color: Colors.grey[400],
                height: 1.1,
              ),
            ),
            const SizedBox(height: 4),
            SizedBox(
              height: 24,
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  activeTrackColor: Colors.blue[700],
                  inactiveTrackColor: Colors.grey[600],
                  thumbColor: Colors.blue[700],
                  overlayColor: Colors.blue[700]!.withOpacity(0.2),
                  trackHeight: 2.5,
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6.0),
                  overlayShape: const RoundSliderOverlayShape(overlayRadius: 12.0),
                ),
                child: Slider(
                  value: expoExponent,
                  min: 1.0,
                  max: 2.5,
                  divisions: 30,
                  label: expoExponent.toStringAsFixed(2),
                  onChanged: (v) {
                    setState(() => expoExponent = v);
                    setModalState(() => expoExponent = v);
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            Column(
              children: [
                _buildTopBar(),
                Expanded(
                  child: Row(
                    children: [
                      // Left Joystick Area - Thrust & Yaw
                      Expanded(
                        flex: 2,
                        child: Column(
                          children: [
                            // Values above left joystick
                            Container(
                              padding: const EdgeInsets.symmetric(vertical: 8.0),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                                children: [
                                  Column(
                                    children: [
                                      Text(
                                        'THRUST',
                                        style: TextStyle(
                                          color: Colors.grey[400],
                                          fontSize: 10,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      Text(
                                        '${_getActualThrustPercentage()}%',
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 16,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ],
                                  ),
                                  Column(
                                    children: [
                                      Text(
                                        'YAW',
                                        style: TextStyle(
                                          color: Colors.grey[400],
                                          fontSize: 10,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      Text(
                                        '${_getActualYawValue().toStringAsFixed(0)}°/s',
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 16,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                            // Joystick
                            Expanded(
                              child: _buildCustomJoystickArea(
                                isLeftStick: true,
                                onUpdate: (x, y) {
                              if (mounted) {
                                setState(() {
                                      // Y axis: top = 1.0 (max thrust), center = 0.0, bottom = 0.0
                                      double newThrust = math.max(0.0, y);
                                      
                                      // Check if joystick was released (thrust went to 0)
                                      if (newThrust == 0.0 && thrust > 0.0 && !_isThrottleDecaying) {
                                        // Joystick was released, start decay
                                        _startThrottleDecay();
                                      } else if (newThrust > 0.0) {
                                        // Joystick is being actively used, stop any decay
                                        _stopThrottleDecay();
                                        thrust = newThrust;
                                      }
                                      // If decay is active, don't update thrust here (let decay timer handle it)
                                      else if (!_isThrottleDecaying) {
                                        thrust = newThrust;
                                      }
                                      
                                      // X axis: left = -1.0, center = 0.0, right = 1.0
                                  if (yawOn) {
                                        yaw = x;
                                  }
                                });
                              }
                            },
                          ),
                            ),
                          ],
                        ),
                      ),
                      // Center Debug Area - Minimal
                      Expanded(
                        flex: 1,
                        child: Center(
                        child: Container(
                            width: 120,
                            height: 60,
                            padding: const EdgeInsets.all(4.0),
                            decoration: BoxDecoration(
                              color: Colors.black.withOpacity(0.6),
                              borderRadius: BorderRadius.circular(6.0),
                              border: Border.all(color: Colors.grey[700]!, width: 1),
                            ),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: debugLines.take(3).map((line) => 
                                Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 0.5),
                                  child: Text(line, 
                                    style: const TextStyle(color: Colors.white70, fontSize: 8),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    textAlign: TextAlign.center,
                                  ),
                                )
                              ).toList(),
                            ),
                          ),
                        ),
                      ),
                      // Right Joystick Area - Roll & Pitch  
                      Expanded(
                        flex: 2,
                        child: Column(
                          children: [
                            // Values above right joystick
                            Container(
                              padding: const EdgeInsets.symmetric(vertical: 8.0),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                                children: [
                                  Column(
                                    children: [
                                      Text(
                                        'ROLL',
                                        style: TextStyle(
                                          color: Colors.grey[400],
                                          fontSize: 10,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      Text(
                                        '${_getActualRollValue().toStringAsFixed(0)}°',
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 16,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ],
                                  ),
                                  Column(
                                    children: [
                                      Text(
                                        'PITCH',
                                        style: TextStyle(
                                          color: Colors.grey[400],
                                          fontSize: 10,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      Text(
                                        '${_getActualPitchValue().toStringAsFixed(0)}°',
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 16,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                            // Joystick
                            Expanded(
                              child: _buildCustomJoystickArea(
                                isLeftStick: false,
                                onUpdate: (x, y) {
                              if (mounted) {
                                setState(() {
                                      roll = x;   // -1 to 1
                                      pitch = -y; // Invert Y: up = negative pitch, down = positive pitch
                                      
                                      // Debug expo curve effectiveness
                                      if (x.abs() > 0.1 || y.abs() > 0.1) {
                                        double rollDegrees = (roll * 30).abs();
                                        double pitchDegrees = (pitch * 30).abs();
                                        if (rollDegrees > pitchDegrees) {
                                          _addDebug("Roll: ${rollDegrees.toStringAsFixed(1)}° (JS: ${(x*100).toStringAsFixed(0)}%)");
                                        } else if (pitchDegrees > 0) {
                                          _addDebug("Pitch: ${pitchDegrees.toStringAsFixed(1)}° (JS: ${(y.abs()*100).toStringAsFixed(0)}%)");
                                        }
                                      }
                                });
                              }
                            },
                          ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            // Slider settings button - bottom right
            Positioned(
              bottom: 20,
              right: 20,
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.grey[800],
                  shape: BoxShape.circle,
                ),
                child: IconButton(
                  icon: Icon(Icons.tune, color: Colors.white),
                  tooltip: 'Trim Settings',
                  onPressed: () {
                    _showTrimSettingsRightSheet();
                  },
                ),
              ),
            ),

          ],
        ),
      ),
    );
  }
}

class JoystickGridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withOpacity(0.2)
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;

    final center = Offset(size.width / 2, size.height / 2);
    
    // Draw crosshair
    canvas.drawLine(
      Offset(0, center.dy),
      Offset(size.width, center.dy),
      paint,
    );
    canvas.drawLine(
      Offset(center.dx, 0),
      Offset(center.dx, size.height),
      paint,
    );
    
    // Draw concentric circles for reference
    final radius1 = math.min(size.width, size.height) * 0.25;
    final radius2 = math.min(size.width, size.height) * 0.4;
    
    canvas.drawCircle(center, radius1, paint);
    canvas.drawCircle(center, radius2, paint);
  }

  @override
  bool shouldRepaint(CustomPainter oldDelegate) => false;
}