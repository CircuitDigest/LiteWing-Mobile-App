import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class OrientationGuide extends StatefulWidget {
  final Widget child;
  
  const OrientationGuide({Key? key, required this.child}) : super(key: key);

  @override
  State<OrientationGuide> createState() => _OrientationGuideState();
}

class _OrientationGuideState extends State<OrientationGuide> {
  @override
  void initState() {
    super.initState();
    // Set preferred orientations for drone control
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
      DeviceOrientation.portraitUp,
    ]);
  }

  @override
  void dispose() {
    // Reset orientations when disposing
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
} 