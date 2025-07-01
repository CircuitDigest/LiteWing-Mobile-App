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

  void _checkConnectionTimeout() {
    if (_lastPingResponse != null && _isDroneConnected) {
      final timeSinceLastPing = DateTime.now().difference(_lastPingResponse!);
      if (timeSinceLastPing.inSeconds > 1) {
        _isDroneConnected = false;
        if (onConnectionStatusChange != null) onConnectionStatusChange!(false);
      }
    }
  }

  void close() {
    _pingTimer?.cancel();
    _pingTimer = null;
    _voltageTimer?.cancel();
    _voltageTimer = null;
    _socket?.close();
    _socket = null;
    _isDroneConnected = false;
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