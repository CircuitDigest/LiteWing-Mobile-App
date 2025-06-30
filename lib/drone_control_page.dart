import 'package:flutter/material.dart';
import 'dart:io';
import 'drone_comm.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';

class DroneControlPage extends StatefulWidget {
  const DroneControlPage({Key? key}) : super(key: key);

  @override
  State<DroneControlPage> createState() => _DroneControlPageState();
}

class _DroneControlPageState extends State<DroneControlPage> {
  String? _ssid;
  bool _isSending = false;
  String? _status;

  @override
  void initState() {
    super.initState();
    _fetchSSID();
  }

  Future<void> _fetchSSID() async {
    // Request location permission
    var status = await Permission.location.request();
    if (!status.isGranted) {
      setState(() {
        _ssid = 'Location permission denied';
      });
      return;
    }
    try {
      final info = NetworkInfo();
      final ssid = await info.getWifiName();
      setState(() {
        _ssid = ssid ?? 'Not available';
      });
    } catch (e) {
      setState(() {
        _ssid = 'Error fetching SSID';
      });
    }
  }

  Future<void> _connectToDrone() async {
    setState(() {
      _isSending = true;
      _status = null;
    });
    try {
      final drone = DroneComm();
      await drone.spinMotorsFor1Sec();
      drone.closeSocket();
      setState(() {
        _status = 'Command sent!';
      });
    } catch (e) {
      setState(() {
        _status = 'Error: $e';
      });
    } finally {
      setState(() {
        _isSending = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Drone Control')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Connected WiFi: ${_ssid ?? 'Loading...'}'),
              const SizedBox(height: 32),
              _isSending
                  ? const CircularProgressIndicator()
                  : ElevatedButton(
                      onPressed: _connectToDrone,
                      child: const Text('Connect'),
                    ),
              if (_status != null) ...[
                const SizedBox(height: 16),
                Text(_status!),
              ],
            ],
          ),
        ),
      ),
    );
  }
} 