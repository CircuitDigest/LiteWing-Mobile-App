import 'dart:io';
import 'dart:typed_data';
import 'dart:async';

class DroneComm {
  RawDatagramSocket? _socket;
  InternetAddress? _droneIp;
  final int _dronePort = 2390; // Command port
  final int _localPort = 2399; // Local binding port

  static const int HEADER_COMMANDER = 0x30;

  Future<void> connect() async {
    try {
      _droneIp = InternetAddress('192.168.43.42');
      _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, _localPort);
      print('DroneComm: Socket bound to ${_socket?.address.address}:${_socket?.port}');
    } catch (e) {
      print('DroneComm: Error binding socket: $e');
      rethrow; // Allow UI to catch and display
    }
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
      print('DroneComm: Socket or IP not initialized. Cannot send packet.');
      return;
    }
    try {
      _socket!.send(packet, _droneIp!, _dronePort);
    } catch (e) {
      print('DroneComm: Error sending packet: $e');
    }
  }

  void close() {
    _socket?.close();
    _socket = null;
    print('DroneComm: Socket closed.');
  }
}