import 'dart:async'; // Added for Timer and TimeoutException
import 'dart:math' as math;
import 'dart:typed_data'; // Added for ByteData
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'; // Added for kDebugMode
import 'package:flutter/services.dart'; // Added for PlatformException and MissingPluginException
// Removed unused import: flutter_joystick
import 'package:network_info_plus/network_info_plus.dart';
// import 'package:url_launcher/url_launcher.dart'; // Removed for iOS compatibility
import 'drone_comm.dart'; // Import the DroneComm class
// Removed height hold screen import - no longer needed
// import 'package:shared_preferences/shared_preferences.dart'; // Removed for iOS compatibility
// Audio removed for iOS compatibility - audioplayers_darwin causes crashes

class DroneControlScreen extends StatefulWidget {
  const DroneControlScreen({Key? key}) : super(key: key);

  @override
  State<DroneControlScreen> createState() => _DroneControlScreenState();
}

class _DroneControlScreenState extends State<DroneControlScreen> {
  final DroneComm _droneComm = DroneComm(); // Instantiate DroneComm
  // Audio functionality completely removed for iOS compatibility
  Timer? _commandTimer; // Timer for sending commands
  Timer? _armingTimer; // Timer for arming sequence
  Timer? _throttleDecayTimer; // Timer for gradual throttle decay

  // Define scaling factors
  static const double MAX_ROLL_PITCH_ANGLE = 30.0; // degrees
  static const double MAX_YAW_RATE = 50.0;       // degrees/second
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
  
  // Height hold variables
  bool _isHeightHoldActive = false;
  bool _isLanding = false; // Track if drone is in landing sequence
  bool _emergencyStopPressed = false; // Track if emergency stop was pressed
  double _targetHeight = 0.3; // Current target height in meters
  static const double MIN_HEIGHT = 0.2; // Minimum height (20cm)
  static const double MAX_HEIGHT = 1.5; // Maximum height (150cm)
  static const double HEIGHT_CHANGE_RATE = 1.0; // Height change rate (m/s)
  static const double LANDING_RATE = 0.3; // Landing descent rate (m/s)
  Timer? _landingTimer; // Timer for smooth landing
  
  // Supported drone WiFi network names
  static const List<String> supportedDroneNetworks = [
    'litewing',
    'esp-drone', 
    'crazyflie'
  ];
  
  double rollTrim = 0.0; // Added for roll trim
  double pitchTrim = 0.0; // Added for pitch trim
  List<String> debugLines = ["LiteWing by CircuitDigest", "Ready."];
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

  double? _batteryVoltage;

  /// Audio completely disabled for iOS compatibility
  bool get _isAudioEnabled => false;

  @override
  void initState() {
    super.initState();
    _fetchSSID();
    _loadTrimValues();
    _loadExpoExponent();
    // Register voltage callback (always)
    _droneComm.onVoltageUpdate = (double voltage) {
      if (mounted) {
        setState(() {
          _batteryVoltage = voltage;
        });
      }
    };
  }

  @override
  void dispose() {
    _stopSendingCommands();
    _throttleDecayTimer?.cancel();
    _landingTimer?.cancel();
    _droneComm.close();
    // Audio functionality completely removed for iOS compatibility
    super.dispose();
  }

  // Debug logging - disabled in production
  static const bool _debugLogging = kDebugMode;
  
  static void _log(String message) {
    if (_debugLogging) {
      debugPrint('DroneControlScreen: $message');
    }
  }

  /// Audio functionality removed for iOS compatibility
  Future<void> _playAudioFile(String assetPath) async {
    // Audio completely disabled - no-op function
    _log('Audio disabled for iOS compatibility');
  }

  Future<void> _fetchSSID() async {
    final info = NetworkInfo();
    try {
      // Add timeout for iOS network requests to prevent hanging
      final ssid = await info.getWifiName().timeout(
        const Duration(seconds: 3),
        onTimeout: () {
          _addDebug("Network info request timed out - this is normal on iOS simulator");
          return null;
        },
      );
      
      if (mounted) {
        setState(() {
          currentSsid = ssid;
        });
      }
    } on MissingPluginException catch (e) {
      if (mounted) {
        setState(() {
          currentSsid = "Network info not available";
        });
      }
      _addDebug("Network info plugin not available: $e");
    } on PlatformException catch (e) {
      String errorMessage;
      String displayMessage;
      
      // Handle iOS-specific WiFi access errors
      if (e.code == 'location_permission_denied') {
        errorMessage = "Location permission required to get WiFi name";
        displayMessage = "Permission required";
      } else if (e.code == 'location_services_disabled') {
        errorMessage = "Location services disabled";
        displayMessage = "Location services needed";
      } else if (e.code == 'wifi_info_permission_denied') {
        errorMessage = "WiFi info permission denied - iOS requires location permission";
        displayMessage = "WiFi access restricted";
      } else if (e.message?.contains('NEHotspotNetwork') ?? false) {
        errorMessage = "iOS network helper error - this is expected on first run";
        displayMessage = "Network detection in progress";
        // Add specific guidance for iOS network errors
        _addDebug("iOS Network: First run network detection - grant permissions when prompted");
      } else {
        errorMessage = "Platform error: ${e.message}";
        displayMessage = "Network info unavailable";
      }
      
      if (mounted) {
        setState(() {
          currentSsid = displayMessage;
        });
      }
      _addDebug("WiFi info: $errorMessage");
    } on TimeoutException catch (e) {
      if (mounted) {
        setState(() {
          currentSsid = "Network detection timeout";
        });
      }
      _addDebug("Network detection timed out - this is normal on iOS");
    } catch (e) {
      if (mounted) {
        setState(() {
          currentSsid = "WiFi info unavailable";
        });
      }
      _addDebug("Error fetching WiFi info: $e");
    }
  }

  Future<void> _loadTrimValues() async {
    // SharedPreferences disabled for iOS compatibility - use defaults
    setState(() {
      rollTrim = 0.0;
      pitchTrim = 0.0;
    });
  }

  Future<void> _saveTrimValues() async {
    // SharedPreferences disabled for iOS compatibility - no-op
    _log('Trim values not saved (iOS compatibility mode)');
  }

  Future<void> _loadExpoExponent() async {
    // SharedPreferences disabled for iOS compatibility - use default
    setState(() {
      expoExponent = 1.1;
    });
  }

  Future<void> _saveExpoExponent() async {
    // SharedPreferences disabled for iOS compatibility - no-op
    _log('Expo exponent not saved (iOS compatibility mode)');
  }

  void _addDebug(String msg) {
    if (mounted) {
      setState(() {
        debugLines.insert(0, msg); 
        if (debugLines.length > 10) debugLines = debugLines.sublist(0, 10); // Increased limit
      });
    }
  }
  
  bool _isConnectedToDrone() {
    if (currentSsid == null) return false;
    
    String ssidLower = currentSsid!.toLowerCase();
    
    // Debug: Show what network is being checked
    _addDebug("Checking network: '$currentSsid'");
    
    // Check if it's a supported drone network
    bool isSupported = supportedDroneNetworks.any((network) => ssidLower.contains(network.toLowerCase()));
    
    if (!isSupported) {
      _addDebug("Network '$currentSsid' not recognized as drone network");
      _addDebug("Supported: ${supportedDroneNetworks.join(', ')}");
    }
    
    return isSupported;
  }

  Future<void> _playConnectSound() async {
    await _playAudioFile('sounds/connected.mp3');
  }

  Future<void> _playDisconnectSound() async {
    await _playAudioFile('sounds/disconnected.mp3');
  }

  void _requestImmediateVoltage() {
    // Request a single voltage reading immediately
    _droneComm.requestSingleVoltageReading();
  }

  Future<void> _launchTutorial() async {
    // URL launcher disabled for iOS compatibility
    const String tutorialUrl = 'https://circuitdigest.com/articles/litewing-mobile-app-for-esp32-drones-crazyflie-esp-drone';
    _addDebug("Tutorial URL (iOS compatibility mode):");
    _addDebug(tutorialUrl);
    _addDebug("Copy URL to browser to view tutorial");
  }

  Widget _buildDebugLine(String line) {
    return Text(
      line,
      style: const TextStyle(
        color: Color(0xFFf1f2f2),
        fontSize: 11,
      ),
      maxLines: null,
      overflow: TextOverflow.visible,
      textAlign: TextAlign.left,
    );
  }



  void _toggleHeightHold() {
    if (_isHeightHoldActive) {
      // Start smooth landing sequence
      _startSmoothLanding();
    } else {
      // Show popup to get target height
      _showHeightInputDialog();
    }
  }
  
  void _startSmoothLanding() {
    setState(() {
      _isLanding = true;
    });
    
    _addDebug("Starting smooth landing...");
    _addDebug("Gradually reducing height to land safely");
    
    // Timer to gradually reduce height every 100ms
    _landingTimer = Timer.periodic(const Duration(milliseconds: 100), (timer) {
      setState(() {
        _targetHeight -= LANDING_RATE * 0.1; // Reduce by landing rate * 0.1s
        
        if (_targetHeight <= MIN_HEIGHT) {
          // Landing complete
          _targetHeight = MIN_HEIGHT;
          timer.cancel();
          
          // Wait a moment at minimum height, then fully deactivate
          Future.delayed(const Duration(seconds: 1), () {
            setState(() {
              _isHeightHoldActive = false;
              _isLanding = false;
            });
            _addDebug("Landing complete - Height hold DEACTIVATED");
            _addDebug("Back to normal manual flight");
          });
        }
      });
    });
  }
  
  void _emergencyStop() {
    // Cancel all timers
    _landingTimer?.cancel();
    _commandTimer?.cancel();
    _throttleDecayTimer?.cancel();
    
    // Reset all states
    setState(() {
      _isHeightHoldActive = false;
      _isLanding = false;
      _isArmed = false;
      _emergencyStopPressed = true; // Mark emergency stop as pressed
      thrust = 0.0;
      yaw = 0.0;
      roll = 0.0;
      pitch = 0.0;
    });
    
    // Send zero thrust commands immediately
    for (int i = 0; i < 5; i++) {
      final List<int> stopPacket = _droneComm.createCommanderPacket(
        roll: 0.0,
        pitch: 0.0,
        yaw: 0.0,
        thrust: 0,
      );
      _droneComm.sendPacket(stopPacket);
    }
    
    _addDebug("🚨 EMERGENCY STOP ACTIVATED 🚨");
    _addDebug("All motors stopped immediately");
    _addDebug("Restart connection to resume flight");
    
    // Restart command sending after a brief pause
    Future.delayed(const Duration(milliseconds: 500), () {
      if (connected && mounted) {
        _startSendingCommands();
      }
    });
    
    // Reset emergency stop color after 3 seconds
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) {
        setState(() {
          _emergencyStopPressed = false;
        });
      }
    });
  }
  
  void _showHeightInputDialog() {
    double selectedHeight = _targetHeight * 100; // Convert to cm
    
    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: Colors.grey[900],
          title: const Text(
            'Set Target Height',
            style: TextStyle(
              color: const Color(0xFFf1f2f2),
              fontSize: 20,
              fontWeight: FontWeight.w600,
            ),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Target Height: ${selectedHeight.toStringAsFixed(0)} cm',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Colors.blue,
                ),
              ),
              const SizedBox(height: 20),
              Slider(
                value: selectedHeight,
                min: 20.0,
                max: 150.0,
                divisions: 26, // 20,25,30...150 (5cm steps)
                label: '${selectedHeight.toStringAsFixed(0)} cm',
                activeColor: Colors.blue,
                onChanged: (value) {
                  setDialogState(() {
                    selectedHeight = (value / 5).round() * 5.0; // Round to nearest 5cm
                  });
                },
              ),
              const SizedBox(height: 10),
              Text(
                '20 cm - 150 cm range',
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.grey[400],
                ),
              ),
            ],
          ),
          actions: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.grey[300],
                    backgroundColor: Colors.grey[700],
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                  ),
                  child: const Text(
                    'Cancel',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                TextButton(
                  onPressed: () {
                    Navigator.of(context).pop();
                    _startHeightHoldWithCountdown(selectedHeight);
                  },
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFFf1f2f2),
                    backgroundColor: Colors.blue[700],
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                  ),
                  child: const Text(
                    'Start',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
  
  Future<void> _startHeightHoldWithCountdown(double heightCm) async {
    _addDebug("Height hold starting in...");
    
    // 3 second countdown
    for (int i = 3; i > 0; i--) {
      _addDebug("$i");
      await Future.delayed(const Duration(seconds: 1));
    }
    
    // Activate height hold
    setState(() {
      _targetHeight = heightCm / 100.0; // Convert cm to meters
      _isHeightHoldActive = true;
    });
    
    _addDebug("Height hold ACTIVATED - ${heightCm.toStringAsFixed(0)}cm target");
    _addDebug("Left stick: normal throttle, Right stick: horizontal");
    _enableHeightHoldCommander();
  }
  
  Future<void> _enableHeightHoldCommander() async {
    try {
      // Enable high-level commander
      var enablePacket1 = [0x2e, 0x02, 0x00, 0x01, 0x31];
      _droneComm.sendPacket(enablePacket1);
      
      await Future.delayed(const Duration(milliseconds: 200));
      
      var enablePacket2 = [0x2f, 0x02, 0x01];
      _droneComm.sendPacket(enablePacket2);
      
      _addDebug("Height hold commander enabled");
    } catch (e) {
      _addDebug("Error enabling height hold: $e");
    }
  }
  
  void _sendHeightHoldPacket() {
    try {
      // Fixed target height (no joystick control)
      // Height is set via popup dialog only
      
      // Horizontal movement with right joystick (with trim and increased sensitivity)
      double trimmedRoll = (roll + rollTrim).clamp(-1.0, 1.0);
      double trimmedPitch = (pitch + pitchTrim).clamp(-1.0, 1.0);
      
      double vx = trimmedPitch * 0.6;  // Forward/backward velocity (increased sensitivity)
      double vy = -trimmedRoll * 0.6;  // Left/right velocity (increased sensitivity)
      double yawRate = (yawOn ? yaw : 0.0) * MAX_YAW_RATE; // Yaw control if enabled
      
      // Create 19-byte hover setpoint packet
      var packet = <int>[];
      
      // Header (1 byte)
      packet.add(0x7c); // Port 7, Channel 12
      
      // Command type (1 byte)
      packet.add(0x05); // Hover setpoint command
      
      // VX - Forward/backward velocity (4 bytes, float32, little-endian)
      var vxBytes = _floatToLittleEndianBytes(vx);
      packet.addAll(vxBytes);
      
      // VY - Left/right velocity (4 bytes, float32, little-endian)
      var vyBytes = _floatToLittleEndianBytes(vy);
      packet.addAll(vyBytes);
      
      // Yaw rate (4 bytes, float32, little-endian)
      var yawBytes = _floatToLittleEndianBytes(yawRate);
      packet.addAll(yawBytes);
      
      // Height (4 bytes, float32, little-endian)
      var heightBytes = _floatToLittleEndianBytes(_targetHeight);
      packet.addAll(heightBytes);
      
      // Calculate checksum using CORRECT algorithm: sum of all data bytes
      int checksum = 0;
      for (int i = 0; i < 18; i++) {
        checksum += packet[i];
      }
      checksum = checksum & 0xFF; // Take lower 8 bits
      packet.add(checksum);
      
      _droneComm.sendPacket(packet);
      
    } catch (e) {
      _addDebug("Error sending height hold packet: $e");
    }
  }
  
  List<int> _floatToLittleEndianBytes(double value) {
    var buffer = ByteData(4);
    buffer.setFloat32(0, value, Endian.little);
    return buffer.buffer.asUint8List().toList();
  }

  String _getJoystickLabel(bool isLeftStick) {
    // Left stick is always THRUST/YAW regardless of height hold mode
    return isLeftStick ? 'THRUST/YAW' : 'ROLL/PITCH';
  }

  // Removed _navigateToHeightHoldMode - no longer needed

  Future<void> _handleConnectDisconnect() async {
    // Set up connection status callback for heartbeat
    _droneComm.onConnectionStatusChange = (bool isConnected) {
      if (mounted) {
        setState(() {
          connected = isConnected;
        });
        _addDebug(isConnected ? 'Drone connection verified (heartbeat)' : 'Drone connection lost (heartbeat)');
        if (isConnected) {
          _droneComm.startVoltageMonitoring();
          _requestImmediateVoltage(); // Request voltage immediately upon connection
          _playConnectSound();
        } else {
          _droneComm.stopVoltageMonitoring();
          _playDisconnectSound();
          setState(() {
            _batteryVoltage = null;
            _isArmed = false; // Reset armed state
            _isHeightHoldActive = false; // Deactivate height hold on connection loss
            _isLanding = false; // Stop landing sequence
          });
          // Cancel height hold related timers
          _landingTimer?.cancel();
        }
      }
    };

    if (connected) {
      // Handle Disconnect
      _stopSendingCommands();
      _droneComm.close(); // Close the socket
      if (mounted) {
        setState(() {
          connected = false;
          _isArmed = false; // Reset armed state
          _isHeightHoldActive = false; // Deactivate height hold on manual disconnect
          _isLanding = false; // Stop landing sequence
        });
        // Cancel height hold related timers
        _landingTimer?.cancel();
        _addDebug("Disconnected from drone.");
      }
      return;
    }

    // Handle Connect
    await _fetchSSID(); // Refresh SSID
    if (!_isConnectedToDrone()) {
      if (mounted) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            backgroundColor: Colors.grey[900],
            title: const Text(
              'Not connected to drone',
              style: TextStyle(
                color: Color(0xFFf1f2f2),
                fontSize: 20,
                fontWeight: FontWeight.w600,
              ),
            ),
            content: Text(
              'Network detection: ${currentSsid ?? "Unknown"}\n\nSupported networks: LiteWing, ESP-DRONE, Crazyflie\n\nIf you\'re connected to a drone WiFi network, use "Force Connect" to bypass iOS network restrictions.',
              style: const TextStyle(
                color: Color(0xFFf1f2f2),
                fontSize: 16,
              ),
            ),
            actions: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.grey[300],
                      backgroundColor: Colors.grey[700],
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    ),
                    child: const Text(
                      'Cancel',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: () async {
                      Navigator.of(context).pop();
                      // Force connect - bypass network check
                      _addDebug("Connecting to drone...");
                      
                      try {
                        await _droneComm.connect();
                        _addDebug("Connected to drone!");
                        if (mounted) {
                          setState(() => connected = true);
                          
                          _startSendingCommands();
                          _addDebug('Starting arming sequence...');
                          _addDebug('Keep joysticks centered during arming.');
                          _addDebug('Blue button = Height Hold Mode');
                        }
                      } catch (e) {
                        String userFriendlyError = "Connection failed. Check WiFi and drone power.";
                        _addDebug("Connection error: $userFriendlyError");
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(userFriendlyError),
                              backgroundColor: Colors.red[700],
                              duration: const Duration(seconds: 5),
                            ),
                          );
                        }
                      }
                    },
                    style: TextButton.styleFrom(
                      foregroundColor: const Color(0xFFf1f2f2),
                      backgroundColor: Colors.green[700],
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                    ),
                    child: const Text(
                      'Connect to Drone',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: () async {
                      Navigator.of(context).pop();
                      const String androidSettingsUri = 'android.settings.WIFI_SETTINGS';
                      const String iosSettingsUri = 'App-Prefs:root=WIFI';
                      // URL launcher disabled for iOS compatibility
                      _addDebug("WiFi settings launch disabled (iOS compatibility)");
                      _addDebug("Please open WiFi settings manually:");
                      _addDebug("iOS: Settings → Wi-Fi");
                      _addDebug("Android: Settings → Connections → Wi-Fi");
                      if(mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: const Text("Please open WiFi settings manually (iOS compatibility mode)"),
                            backgroundColor: Colors.orange[700],
                            duration: const Duration(seconds: 4),
                          ),
                        );
                      }
                    },
                    style: TextButton.styleFrom(
                      foregroundColor: const Color(0xFFf1f2f2),
                      backgroundColor: Colors.blue[700],
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    ),
                    child: const Text(
                      'WiFi Settings',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
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
        _addDebug('Blue button (bottom left) = Height Hold Mode');
      }
    } catch (e) {
      String userFriendlyError;
      if (e.toString().contains('Port') && e.toString().contains('already in use')) {
        userFriendlyError = "Port already in use. Please close other drone control apps and try again.";
      } else if (e.toString().contains('Permission denied')) {
        userFriendlyError = "Network permission denied. Please check app permissions.";
      } else if (e.toString().contains('Network unreachable')) {
        userFriendlyError = "Cannot reach drone. Check WiFi connection to drone network.";
      } else if (e.toString().contains('connection')) {
        userFriendlyError = "Connection failed. Ensure drone is powered on and WiFi is connected.";
      } else {
        userFriendlyError = "Connection error. Check WiFi connection and drone power.";
      }
      
      _addDebug("Connection error: $userFriendlyError");
      if (mounted) {
        setState(() => connected = false); // Ensure not connected if socket fails
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(userFriendlyError),
            backgroundColor: Colors.red[700],
            duration: const Duration(seconds: 5),
            action: SnackBarAction(
              label: 'Retry',
              textColor: const Color(0xFFf1f2f2),
              onPressed: () => _handleConnectDisconnect(),
            ),
          ),
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
          _requestImmediateVoltage(); // Request voltage immediately after arming
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

      if (_isHeightHoldActive) {
        // Send height hold commands
        _sendHeightHoldPacket();
      } else {
        // Normal manual commands
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
      }
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
              icon: Icon(Icons.swap_horiz, color: yawOn ? Colors.orange : Colors.grey[400]),
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
          
          // Center Logo
          Expanded(
            child: Center(
              child: Image.asset(
                'assets/pics/main_logo_(400x120)-01.png',
                height: 48,
                fit: BoxFit.contain,
              ),
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
        children: [
          ...debugLines.map((line) => 
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 0.5),
              child: Text(
                line,
                style: const TextStyle(color: Color(0xFFf1f2f2), fontSize: 8),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
              ),
            )
          ),
          SizedBox(height: 8),
          _buildBatteryDisplay(),
        ],
      ),
    );
  }

  Widget _buildBatteryDisplay() {
    IconData batteryIcon;
    Color iconColor;
    Color textColor;
    final voltage = _batteryVoltage;
    if (voltage == null) {
      batteryIcon = Icons.battery_unknown;
      iconColor = const Color(0xFFf1f2f2);
      textColor = Colors.grey;
    } else if (voltage >= 4.0) {
      batteryIcon = Icons.battery_full;
      iconColor = voltage < 3.8 ? Colors.red : const Color(0xFFf1f2f2);
      textColor = voltage < 3.8 ? Colors.red : Colors.grey;
    } else if (voltage >= 3.8) {
      batteryIcon = Icons.battery_5_bar;
      iconColor = const Color(0xFFf1f2f2);
      textColor = Colors.grey;
    } else if (voltage >= 3.6) {
      batteryIcon = Icons.battery_3_bar;
      iconColor = Colors.red;
      textColor = Colors.red;
    } else if (voltage >= 3.4) {
      batteryIcon = Icons.battery_2_bar;
      iconColor = Colors.red;
      textColor = Colors.red;
    } else {
      batteryIcon = Icons.battery_1_bar;
      iconColor = Colors.red;
      textColor = Colors.red;
    }
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(batteryIcon, color: iconColor, size: 20),
        const SizedBox(width: 4),
        Text(
          voltage != null ? '${voltage.toStringAsFixed(2)} V' : '--',
          style: TextStyle(
            color: textColor,
            fontSize: 14,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }

  Widget _buildHeightDisplay() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.height, color: Colors.blue, size: 20),
        const SizedBox(width: 4),
        Text(
          '${(_targetHeight * 100).toStringAsFixed(0)} cm',
          style: const TextStyle(
            color: Colors.blue,
            fontSize: 14,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
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
                  // No center dot - removed as requested
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
                              width: 45,
                              height: 45,
                              decoration: BoxDecoration(
                                color: Colors.grey[600],
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: Colors.grey[400]!,
                                  width: 2,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: Color(0xFF000000).withOpacity(0.3),
                                    blurRadius: 4,
                                    offset: Offset(0, 2),
                                  ),
                                ],
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
            _getJoystickLabel(isLeftStick),
            style: TextStyle(
              color: Color(0xFFf1f2f2).withOpacity(0.7),
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
      
      // Start decay immediately - gradually decrease to zero over 0.75 seconds
      const totalDecayDuration = 750; // 0.75 seconds to decay to zero
      
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
                             barrierColor: Color(0xFF000000).withOpacity(0.54),
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
                                     decoration: BoxDecoration(
                     color: Colors.grey[900],
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
                                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: const Color(0xFFf1f2f2)),
                                textAlign: TextAlign.center,
                              ),
                            ),
                            TextButton(
                              onPressed: () {
                                _saveTrimValues();
                                _saveExpoExponent();
                                Navigator.pop(context);
                              },
                              child: const Text('SAVE', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFFf1f2f2))),
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
                                description: 'Increase if drone drifts left • Decrease if drone drifts right',
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
                                description: 'Increase if drone drifts backward • Decrease if drone drifts forward',
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
                    color: Color(0xFFf1f2f2),
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
                Text(
                  'Joystick Sensitivity',
                  style: TextStyle(
                    fontWeight: FontWeight.w600, 
                    fontSize: 13,
                    color: Color(0xFF000000).withOpacity(0.87),
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
                    color: Color(0xFFf1f2f2),
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
      backgroundColor: const Color(0xFF000000),
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
                      // Center Debug Area - Perfectly centered with Connection + Debug + Battery
                      Expanded(
                        flex: 1,
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              // Connection status text above debug window
                              Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    connected 
                                      ? "Connected to: ${currentSsid ?? 'Drone'}"
                                      : "Not Connected to Drone", 
                                    style: TextStyle(
                                      color: connected ? const Color(0xFFf1f2f2) : Colors.grey[400], 
                                      fontSize: 12,
                                      fontWeight: FontWeight.w500,
                                    ),
                                    textAlign: TextAlign.center,
                                  ),
                                  if (!connected) ...[
                                    const SizedBox(height: 4),
                                    GestureDetector(
                                      onTap: _launchTutorial,
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                        decoration: BoxDecoration(
                                          borderRadius: BorderRadius.circular(12),
                                          color: Colors.transparent,
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          mainAxisAlignment: MainAxisAlignment.center,
                                          children: [
                                            Icon(
                                              Icons.link,
                                              size: 14,
                                              color: Colors.blue[400],
                                            ),
                                            const SizedBox(width: 4),
                                            Text(
                                              "How to Fly",
                                              style: TextStyle(
                                                color: Colors.blue[400],
                                                fontSize: 11,
                                                fontWeight: FontWeight.w500,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                              const SizedBox(height: 12), // Slightly more space above debug window
                              
                              // Debug Window - Centered
                              Container(
                                width: double.infinity,
                                height: 120,
                                padding: const EdgeInsets.all(8.0),
                                decoration: BoxDecoration(
                                  color: Color(0xFF000000).withOpacity(0.7),
                                  borderRadius: BorderRadius.circular(8.0),
                                  border: Border.all(color: Colors.grey[600]!, width: 1),
                                ),
                                child: SingleChildScrollView(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: debugLines.take(5).map((line) =>
                                      Padding(
                                        padding: const EdgeInsets.symmetric(vertical: 1.0),
                                        child: _buildDebugLine(line),
                                      )
                                    ).toList(),
                                  ),
                                ),
                              ),
                              
                              const SizedBox(height: 12), // Space between debug window and battery
                              
                              // Battery Display - Below debug window
                              _buildBatteryDisplay(),
                            ],
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
                                          color: Color(0xFFf1f2f2),
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
                                          color: Color(0xFFf1f2f2),
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
            // Height Hold button - bottom left (always visible)
            Positioned(
              bottom: 20,
              left: 20,
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.grey[800], // Same grey circle as other buttons
                  shape: BoxShape.circle,
                ),
                child: IconButton(
                  icon: Icon(
                    Icons.height, 
                    color: _isHeightHoldActive ? Colors.blue : Colors.grey[400], // Blue when active, grey when inactive
                    size: 28
                  ),
                  tooltip: _isHeightHoldActive ? 'Stop Height Hold' : 'Start Height Hold',
                  onPressed: connected ? () {
                    _toggleHeightHold();
                  } : null, // Disable when not connected
                ),
              ),
            ),
            // Height display next to height hold button - bottom left
            if (connected && _isHeightHoldActive)
              Positioned(
                bottom: 25,
                left: 80, // Next to the height hold button
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Color(0xFF000000).withOpacity(0.7),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    _isLanding 
                        ? 'LANDING ${(_targetHeight * 100).toStringAsFixed(0)}cm'
                        : '${(_targetHeight * 100).toStringAsFixed(0)}cm',
                    style: TextStyle(
                      color: _isLanding ? Colors.orange : Colors.blue,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            

            
            // Emergency Stop button - center left (matching other button styles)
            if (connected)
              Positioned(
                left: 20,
                top: MediaQuery.of(context).size.height / 2 - 24, // Center vertically (24 = half of 48px button)
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.grey[800], // Grey background like other buttons
                    shape: BoxShape.circle,
                  ),
                  child: IconButton(
                    icon: Icon(Icons.stop, color: _emergencyStopPressed ? Colors.red : Colors.grey[400]), // Grey by default, red when pressed
                    tooltip: 'Emergency Stop',
                    onPressed: () {
                      _emergencyStop();
                    },
                  ),
                ),
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
                  icon: Icon(Icons.tune, color: Colors.grey[400]),
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
      ..color = Color(0xFFf1f2f2).withOpacity(0.2)
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;

    final center = Offset(size.width / 2, size.height / 2);
    final crosshairLength = math.min(size.width, size.height) * 0.4; // Further increased size
    
    // Draw shorter crosshair
    canvas.drawLine(
      Offset(center.dx - crosshairLength, center.dy),
      Offset(center.dx + crosshairLength, center.dy),
      paint,
    );
    canvas.drawLine(
      Offset(center.dx, center.dy - crosshairLength),
      Offset(center.dx, center.dy + crosshairLength),
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


