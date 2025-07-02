void main() {
  print('🔍 VERIFYING CHECKSUM ALGORITHM');
  print('=====================================');
  
  // Test packets from Python with known checksums
  List<Map<String, dynamic>> testPackets = [
    {
      'name': '0.5m hover',
      'hex': '7c 05 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 3f',
      'expected_checksum': 0xc0,
    },
    {
      'name': '1.0m hover', 
      'hex': '7c 05 00 00 00 00 00 00 00 00 00 00 00 00 00 00 80 3f',
      'expected_checksum': 0x40,
    },
    {
      'name': '0.8m hover',
      'hex': '7c 05 00 00 00 00 00 00 00 00 00 00 00 00 cd cc 4c 3f',
      'expected_checksum': 0xa5,
    },
    {
      'name': 'vx=0.3, h=0.8',
      'hex': '7c 05 9a 99 99 3e 00 00 00 00 00 00 00 00 cd cc 4c 3f',
      'expected_checksum': 0xaf,
    },
    {
      'name': 'vx=0.01, h=0.8',
      'hex': '7c 05 0a d7 23 3c 00 00 00 00 00 00 00 00 cd cc 4c 3f',
      'expected_checksum': 0xe5,
    },
    {
      'name': 'vy=0.01, h=0.8',
      'hex': '7c 05 00 00 00 00 0a d7 23 3c 00 00 00 00 cd cc 4c 3f',
      'expected_checksum': 0xe5,
    },
    {
      'name': 'zero height',
      'hex': '7c 05 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00',
      'expected_checksum': 0x81,
    },
    {
      'name': '0.6m takeoff',
      'hex': '7c 05 00 00 00 00 00 00 00 00 00 00 00 00 9a 99 19 3f',
      'expected_checksum': 0x0c,
    },
  ];
  
  bool allCorrect = true;
  
  for (var packet in testPackets) {
    print('\\n--- ${packet['name']} ---');
    
    // Parse hex string to bytes
    List<String> hexBytes = packet['hex'].split(' ');
    List<int> bytes = hexBytes.map((hex) => int.parse(hex, radix: 16)).toList();
    
    // Calculate sum of all bytes (first 18 bytes, excluding checksum)
    int sum = 0;
    for (int i = 0; i < 18; i++) {
      sum += bytes[i];
    }
    
    // Calculate checksum methods
    int simpleSum = sum & 0xFF;  // Your proposed method
    int xorSum = bytes.take(18).reduce((a, b) => a ^ b);  // XOR method
    
    int expectedChecksum = packet['expected_checksum'];
    
    print('Packet: ${packet['hex']}');
    print('Sum of bytes (0-17): 0x${sum.toRadixString(16)} (${sum})');
    print('Simple sum & 0xFF: 0x${simpleSum.toRadixString(16).padLeft(2, '0')}');
    print('XOR checksum: 0x${xorSum.toRadixString(16).padLeft(2, '0')}');
    print('Expected checksum: 0x${expectedChecksum.toRadixString(16).padLeft(2, '0')}');
    
    if (simpleSum == expectedChecksum) {
      print('✅ SIMPLE SUM METHOD MATCHES!');
    } else if (xorSum == expectedChecksum) {
      print('✅ XOR METHOD MATCHES!');
    } else {
      print('❌ NEITHER METHOD MATCHES!');
      allCorrect = false;
    }
  }
  
  print('\\n' + '='*50);
  if (allCorrect) {
    print('🎯 CHECKSUM ALGORITHM CONFIRMED!');
    print('Method: (sum of all data bytes) & 0xFF');
  } else {
    print('❌ Need to investigate further...');
  }
  print('='*50);
} 