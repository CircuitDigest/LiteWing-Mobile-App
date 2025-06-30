import 'dart:async'; // Added for Timer
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_joystick/flutter_joystick.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'drone_comm.dart'; // Import the DroneComm class

class DroneControlScreen extends StatefulWidget {
  const DroneControlScreen({Key? key}) : super(key: key);

  @override
  State<DroneControlScreen> createState() => _DroneControlScreenState();
}

class _DroneControlScreenState extends State<DroneControlScreen> {
  final DroneComm _droneComm = DroneComm(); // Instantiate DroneComm
  Timer? _commandTimer; // Timer for sending commands
  Timer? _armingTimer; // Timer for arming sequence

  // Define scaling factors
  static const double MAX_ROLL_PITCH_ANGLE = 30.0; // degrees
  static const double MAX_YAW_RATE = 200.0;      // degrees/second
  static const int MIN_THRUST = 1000;            // Minimum effective thrust (per protocol)
  static const int MAX_THRUST = 60000;           // Maximum safe thrust (updated from protocol)

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

  @override
  void initState() {
    super.initState();
    _fetchSSID();
  }

  @override
  void dispose() {
    _stopSendingCommands();
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
      
      double scaledRoll = roll * MAX_ROLL_PITCH_ANGLE;
      double scaledPitch = pitch * MAX_ROLL_PITCH_ANGLE;
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
              icon: Icon(
                connected ? Icons.link : Icons.link_off,
                color: connected ? Colors.green : Colors.grey[400],
              ),
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
    
    if (absInput < 0.05) {
      // Dead zone for very small movements
      return 0.0;
    }
    
    // Custom expo curve that favors 0-20° range
    // Maps joystick input 0-1 to output that heavily favors 0-0.67 (0-20°)
    
    double output;
    if (absInput <= 0.8) {
      // First 80% of joystick movement maps to 0-20° (0-0.67 normalized)
      // Use exponential curve: output = 0.67 * (input/0.8)^2.5
      double normalizedInput = absInput / 0.8; // 0-1 for first 80%
      output = 0.67 * math.pow(normalizedInput, 2.5); // Expo curve favoring small movements
    } else {
      // Last 20% of joystick movement maps to 20-30° (0.67-1.0 normalized)
      double extremeInput = (absInput - 0.8) / 0.2; // 0-1 for last 20%
      output = 0.67 + (0.33 * extremeInput); // Linear mapping for extreme range
    }
    
    return sign * output.clamp(0.0, 1.0);
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
                                      thrust = math.max(0.0, y);
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