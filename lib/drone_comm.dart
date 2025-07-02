import 'dart:io';
import 'dart:typed_data';
import 'dart:async';

class DroneComm {
  RawDatagramSocket? _socket;
  InternetAddress? _droneIp;
  final int _dronePort = 2390; // Command port
  final int _localPort = 2399; // Local binding port

  static const int HEADER_COMMANDER = 0x30;

  // --- Heartbeat/Ping Monitoring ---
  Timer? _pingTimer;
  DateTime? _lastPingResponse;
  bool _isDroneConnected = false;
  Function(bool isConnected)? onConnectionStatusChange;

  // --- Voltage Monitoring ---
  Timer? _voltageTimer;
  double? _lastVoltage;
  Function(double voltage)? onVoltageUpdate;

  // --- Height Sensor Detection ---
  bool? _heightSensorDetected;
  Completer<bool>? _heightDetectionCompleter;
  Function(bool hasHeightSensor)? onHeightSensorDetected;

  Future<void> connect() async {
    try {
      _droneIp = InternetAddress('192.168.43.42');
      _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, _localPort);
      if (_socket != null) {
        _socket!.listen((RawSocketEvent event) {
          if (event == RawSocketEvent.read) {
            _handleIncomingData();
          }
        });
        _startConnectionMonitoring();
      }
    } catch (e) {
      print('DroneComm: Error binding socket: $e');
      rethrow; // Allow UI to catch and display
    }
  }

  // --- Voltage Monitoring ---
  void startVoltageMonitoring() {
    _voltageTimer?.cancel();
    _voltageTimer = Timer.periodic(const Duration(seconds: 10), (timer) {
      requestSingleVoltageReading();
    });
  }

  void stopVoltageMonitoring() {
    _voltageTimer?.cancel();
    _voltageTimer = null;
  }

  Future<void> requestSingleVoltageReading() async {
    if (_socket == null || _droneIp == null) return;
    try {
      // Send log config packet
      var logConfig = [0x5d, 0x06, 0x01, 0x77, 0x02, 0x00, 0xdd];
      _socket!.send(Uint8List.fromList(logConfig), _droneIp!, _dronePort);
      await Future.delayed(const Duration(milliseconds: 100));
      // Send start logging packet
      var startLog = [0x5d, 0x03, 0x01, 0x0a, 0x6b];
      _socket!.send(Uint8List.fromList(startLog), _droneIp!, _dronePort);
      await Future.delayed(const Duration(milliseconds: 300));
      // Send stop logging packet
      var stopLog = [0x5d, 0x04, 0x01, 0x62];
      _socket!.send(Uint8List.fromList(stopLog), _droneIp!, _dronePort);
    } catch (e) {
      print('DroneComm: Error requesting voltage: $e');
    }
  }

  // --- Height Sensor Detection ---
  Future<bool> detectHeightSensor() async {
    if (_socket == null || _droneIp == null) {
      print('DroneComm: Cannot detect height sensor - socket not ready');
      return false;
    }
    
    // Always reset detection state completely
    _heightSensorDetected = null;
    
    // Safely complete any pending detection first
    if (_heightDetectionCompleter != null) {
      if (!_heightDetectionCompleter!.isCompleted) {
        try {
          _heightDetectionCompleter!.complete(false);
        } catch (e) {
          print('DroneComm: Error completing previous detection: $e');
        }
      }
      _heightDetectionCompleter = null;
    }
    
    // Create new completer
    _heightDetectionCompleter = Completer<bool>();
    
    try {
      print('DroneComm: Starting height sensor detection...');
      
      // Try multiple detection attempts for reliability
      for (int attempt = 1; attempt <= 3; attempt++) {
        print('DroneComm: Detection attempt $attempt/3');
        
        // Send parameter discovery packet for height sensor
        var heightDetectionPacket = [0x2d, 0x02, 0x00, 0x2f];
        _socket!.send(Uint8List.fromList(heightDetectionPacket), _droneIp!, _dronePort);
        print('DroneComm: Sent detection packet: [${heightDetectionPacket.map((e) => '0x${e.toRadixString(16).padLeft(2, '0')}').join(', ')}]');
        
        // Wait between attempts
        if (attempt < 3) {
          await Future.delayed(const Duration(milliseconds: 500));
        }
      }
      
      // Wait for response with timeout
      bool result = await _heightDetectionCompleter!.future.timeout(
        const Duration(seconds: 5), // Increased timeout
        onTimeout: () {
          print('DroneComm: Height sensor detection timeout after 5 seconds');
          return false;
        },
      );
      
      print('DroneComm: Final detection result: $result');
      return result;
      
    } catch (e) {
      print('DroneComm: Error detecting height sensor: $e');
      return false;
    } finally {
      // Clean up completer
      _heightDetectionCompleter = null;
    }
  }

  // --- Existing Heartbeat/Ping Monitoring ---
  void _startConnectionMonitoring() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      _sendPing();
      _checkConnectionTimeout();
    });
  }

  Future<void> _sendPing() async {
    if (_socket == null || _droneIp == null) return;
    var packet = Uint8List.fromList([0xfd, 0x00, 0xfd]);
    _socket!.send(packet, _droneIp!, _dronePort);
  }

  void _handleIncomingData() {
    try {
      Datagram? datagram = _socket?.receive();
      if (datagram != null) {
        _parseIncomingPacket(datagram.data);
      }
    } catch (e) {
      print('DroneComm: Error handling incoming data: $e');
    }
  }

  void _parseIncomingPacket(Uint8List data) {
    if (data.isEmpty) return;
    
    // Print all incoming packets for debugging height sensor detection
    if (data.length >= 3 && data[0] == 0x2d) {
      print('DroneComm: Received parameter packet: [${data.map((e) => '0x${e.toRadixString(16).padLeft(2, '0')}').join(', ')}]');
    }
    
    int header = data[0];
    int port = (header >> 4) & 0x0F;
    int channel = header & 0x0F;
    
    // Heartbeat response
    if (port == 15 && channel == 13) {
      _lastPingResponse = DateTime.now();
      if (!_isDroneConnected) {
        _isDroneConnected = true;
        if (onConnectionStatusChange != null) onConnectionStatusChange!(true);
      }
    }
    // Voltage data (Port 5, Channel 2)
    if (port == 5 && channel == 2 && data.length >= 10) {
      _parseVoltageData(data);
    }
    // Height sensor parameter response - check for multiple possible formats
    if (data.length >= 5 && data[0] == 0x2d && data[1] == 0x02) {
      _parseHeightSensorResponse(data);
    }
  }

  void _parseVoltageData(Uint8List data) {
    try {
      // Voltage is in bytes 5-8 as little-endian float32
      if (data.length >= 9 && data[0] == 0x52 && data[1] == 0x01) {
        var voltageBytes = data.sublist(5, 9);
        var byteData = ByteData(4);
        for (int i = 0; i < 4; i++) {
          byteData.setUint8(i, voltageBytes[i]);
        }
        double voltage = byteData.getFloat32(0, Endian.little);
        _lastVoltage = voltage;
        if (onVoltageUpdate != null) onVoltageUpdate!(voltage);
      }
    } catch (e) {
      print('DroneComm: Error parsing voltage data: $e');
    }
  }

  void _parseHeightSensorResponse(Uint8List data) {
    try {
      print('DroneComm: Processing height sensor response: [${data.map((e) => '0x${e.toRadixString(16).padLeft(2, '0')}').join(', ')}]');
      
      // Expected format: [0x2d, 0x02, 0x00, 0x00, sensor_status, ...]
      // But also handle variations in response format
      if (data.length >= 5) {
        int sensorStatus = data[4];
        bool hasHeightSensor = sensorStatus == 0x01;
        
        print('DroneComm: Height sensor status byte: 0x${sensorStatus.toRadixString(16).padLeft(2, '0')} = ${hasHeightSensor ? "DETECTED" : "NOT FOUND"}');
        
        _heightSensorDetected = hasHeightSensor;
        
        // Complete the detection future safely
        if (_heightDetectionCompleter != null && !_heightDetectionCompleter!.isCompleted) {
          print('DroneComm: Completing height sensor detection with result: $hasHeightSensor');
          try {
            _heightDetectionCompleter!.complete(hasHeightSensor);
          } catch (e) {
            print('DroneComm: Error completing detection: $e');
          }
        } else {
          print('DroneComm: Detection completer is null or already completed');
        }
        
        // Notify callback
        if (onHeightSensorDetected != null) {
          try {
            onHeightSensorDetected!(hasHeightSensor);
          } catch (e) {
            print('DroneComm: Error in height sensor callback: $e');
          }
        }
      } else {
        print('DroneComm: Height sensor response too short: ${data.length} bytes');
      }
    } catch (e) {
      print('DroneComm: Error parsing height sensor response: $e');
      // Complete with false on error, but safely
      if (_heightDetectionCompleter != null && !_heightDetectionCompleter!.isCompleted) {
        try {
          _heightDetectionCompleter!.complete(false);
        } catch (completionError) {
          print('DroneComm: Error completing detection on error: $completionError');
        }
      }
    }
  }

  void _checkConnectionTimeout() {
    if (_lastPingResponse != null && _isDroneConnected) {
      final timeSinceLastPing = DateTime.now().difference(_lastPingResponse!);
      if (timeSinceLastPing.inSeconds > 1) {
        _isDroneConnected = false;
        if (onConnectionStatusChange != null) onConnectionStatusChange!(false);
      }
    }
  }

  // --- Getters ---
  bool? get heightSensorDetected => _heightSensorDetected;

  void close() {
    _pingTimer?.cancel();
    _pingTimer = null;
    _voltageTimer?.cancel();
    _voltageTimer = null;
    
    // Safely complete any pending detection
    if (_heightDetectionCompleter != null && !_heightDetectionCompleter!.isCompleted) {
      try {
        _heightDetectionCompleter!.complete(false);
      } catch (e) {
        print('DroneComm: Error completing detection during close: $e');
      }
    }
    _heightDetectionCompleter = null;
    
    _socket?.close();
    _socket = null;
    _isDroneConnected = false;
    _heightSensorDetected = null; // Reset detection state
  }

  List<int> createCommanderPacket({
    required double roll,    // -30 to 30 degrees
    required double pitch,   // -30 to 30 degrees (will be inverted)
    required double yaw,     // -200 to 200 degrees/second
    required int thrust,    // 0 to 65535
  }) {
    var buffer = ByteData(16); // Header (1) + R(4) + P(4) + Y(4) + Thrust(2) + Checksum (1) = 16 bytes
    var offset = 0;

    // Header
    buffer.setUint8(offset, HEADER_COMMANDER);
    offset += 1;

    // Roll (float32, little-endian)
    buffer.setFloat32(offset, roll, Endian.little);
    offset += 4;

    // Pitch (float32, little-endian, inverted)
    buffer.setFloat32(offset, -pitch, Endian.little);
    offset += 4;

    // Yaw (float32, little-endian)
    buffer.setFloat32(offset, yaw, Endian.little);
    offset += 4;

    // Thrust (uint16, little-endian)
    buffer.setUint16(offset, thrust, Endian.little);
    offset += 2;

    // Calculate checksum (sum of all bytes up to this point)
    int checksum = 0;
    for (int i = 0; i < offset; i++) {
      checksum = (checksum + buffer.getUint8(i)) & 0xFF;
    }
    buffer.setUint8(offset, checksum);
    offset += 1;
    
    return buffer.buffer.asUint8List(0, offset);
  }

  void sendPacket(List<int> packet) {
    if (_socket == null || _droneIp == null) {
      return;
    }
    try {
      _socket!.send(packet, _droneIp!, _dronePort);
    } catch (e) {
      print('DroneComm: Error sending packet: $e');
    }
  }
}