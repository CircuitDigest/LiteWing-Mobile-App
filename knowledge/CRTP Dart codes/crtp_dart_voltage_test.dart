import 'dart:io';
import 'dart:typed_data';
import 'dart:convert';
import 'dart:async';

class CRTPDroneConnection {
  static const String DRONE_IP = '192.168.43.42';
  static const int DRONE_PORT = 2390;
  
  RawDatagramSocket? _socket;
  bool _isConnected = false;
  double? _lastVoltage;
  
  // CRTP packet structure constants
  static const int CRTP_PORT_CONSOLE = 0x00;
  static const int CRTP_PORT_PARAM = 0x02;
  static const int CRTP_PORT_COMMANDER = 0x03;
  static const int CRTP_PORT_LOGGING = 0x05;
  static const int CRTP_PORT_LINKCTRL = 0x0F;
  
  static const int CRTP_CHANNEL_TOC = 0x00;
  static const int CRTP_CHANNEL_SETTINGS = 0x01;
  static const int CRTP_CHANNEL_LOGDATA = 0x02;

  Future<bool> connect() async {
    try {
      print('Connecting to drone at $DRONE_IP:$DRONE_PORT...');
      
      // Create UDP socket
      _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      
      if (_socket != null) {
        _socket!.listen((RawSocketEvent event) {
          if (event == RawSocketEvent.read) {
            _handleIncomingData();
          }
        });
        
        // Send initial connection packets (from packet log)
        await _sendConnectionSequence();
        
        _isConnected = true;
        print('Connected to drone!');
        return true;
      }
      
      return false;
    } catch (e) {
      print('Error connecting to drone: $e');
      return false;
    }
  }

  Future<void> _sendConnectionSequence() async {
    try {
      // Initial handshake packets from log
      await _sendPacket([0xff, 0x01, 0x01, 0x01]);
      await Future.delayed(Duration(milliseconds: 100));
      
      await _sendPacket([0xfd, 0x00, 0xfd]);
      await Future.delayed(Duration(milliseconds: 100));
      
      print('Connection sequence sent');
    } catch (e) {
      print('Error sending connection sequence: $e');
    }
  }

  Future<void> _sendPacket(List<int> data) async {
    if (_socket == null) return;
    
    var packet = Uint8List.fromList(data);
    _socket!.send(packet, InternetAddress(DRONE_IP), DRONE_PORT);
    
    print('[SENT] ${packet.length} bytes: ${packet.map((e) => e.toRadixString(16).padLeft(2, '0')).join(' ')}');
  }

  void _handleIncomingData() {
    try {
      Datagram? datagram = _socket?.receive();
      if (datagram != null) {
        _parseIncomingPacket(datagram.data);
      }
    } catch (e) {
      print('Error handling incoming data: $e');
    }
  }

  void _parseIncomingPacket(Uint8List data) {
    if (data.length == 0) return;
    
    print('[RECEIVED] ${data.length} bytes: ${data.map((e) => e.toRadixString(16).padLeft(2, '0')).join(' ')}');
    
    // Parse CRTP header
    int header = data[0];
    int port = (header >> 4) & 0x0F;
    int channel = header & 0x0F;
    
    print('    Port: $port, Channel: $channel');
    
    // Check for voltage data (Port 5, Channel 2)
    if (port == 5 && channel == 2 && data.length >= 10) {
      _parseVoltageData(data);
    }
  }

  void _parseVoltageData(Uint8List data) {
    try {
      // Voltage data format from log: 52 01 XX XX 25 YY YY YY YY ZZ
      // Voltage is in bytes 5-8 as little-endian float32
      if (data.length >= 9 && data[0] == 0x52 && data[1] == 0x01) {
        // Extract voltage bytes (indices 5-8)
        var voltageBytes = data.sublist(5, 9);
        
        // Convert little-endian bytes to float32
        var byteData = ByteData(4);
        for (int i = 0; i < 4; i++) {
          byteData.setUint8(i, voltageBytes[i]);
        }
        double voltage = byteData.getFloat32(0, Endian.little);
        
        _lastVoltage = voltage;
        print('Battery Voltage: ${voltage.toStringAsFixed(2)} V');
      }
    } catch (e) {
      print('Error parsing voltage data: $e');
    }
  }

  Future<double?> requestBatteryVoltage() async {
    if (!_isConnected || _socket == null) {
      print('Not connected to drone');
      return null;
    }

    try {
      print('Setting up voltage logging...');
      
      // Add log config packet from log: 5d 06 01 77 02 00 dd
      await _sendPacket([0x5d, 0x06, 0x01, 0x77, 0x02, 0x00, 0xdd]);
      await Future.delayed(Duration(milliseconds: 200));
      
      // Start logging packet from log: 5d 03 01 0a 6b
      await _sendPacket([0x5d, 0x03, 0x01, 0x0a, 0x6b]);
      await Future.delayed(Duration(milliseconds: 200));
      
      print('Voltage logging started, waiting for data...');
      
      // Wait for voltage data to arrive
      int attempts = 0;
      while (_lastVoltage == null && attempts < 20) {
        await Future.delayed(Duration(milliseconds: 100));
        attempts++;
      }
      
      // Stop logging: 5d 04 01 62
      await _sendPacket([0x5d, 0x04, 0x01, 0x62]);
      
      return _lastVoltage;
      
    } catch (e) {
      print('Error requesting battery voltage: $e');
      return null;
    }
  }

  void disconnect() {
    try {
      if (_socket != null) {
        // Send disconnect packets from log
        _sendPacket([0x3c, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 
                     0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x3c]);
        _sendPacket([0xff, 0x01, 0x01, 0x01]);
        
        Future.delayed(Duration(milliseconds: 100), () {
          _socket?.close();
        });
      }
      
      _isConnected = false;
      print('Disconnected from drone');
    } catch (e) {
      print('Error disconnecting: $e');
    }
  }

  bool get isConnected => _isConnected;
  double? get lastVoltage => _lastVoltage;
}

// Main function to test the connection
void main() async {
  print('Starting CRTP drone connection test...');
  
  CRTPDroneConnection drone = CRTPDroneConnection();
  
  // Connect to drone
  bool connected = await drone.connect();
  
  if (connected) {
    print('Connection successful!');
    
    // Wait 4 seconds
    print('Waiting 4 seconds...');
    await Future.delayed(Duration(seconds: 4));
    
    // Request battery voltage
    print('Requesting battery voltage...');
    double? voltage = await drone.requestBatteryVoltage();
    
    if (voltage != null) {
      print('Final result: Battery Voltage: ${voltage.toStringAsFixed(2)} V');
    } else {
      print('Failed to get battery voltage');
    }
    
    // Wait another 4 seconds
    print('Waiting another 4 seconds...');
    await Future.delayed(Duration(seconds: 4));
    
    // Disconnect
    drone.disconnect();
  } else {
    print('Failed to connect to drone');
  }
  
  print('Test completed');
} 