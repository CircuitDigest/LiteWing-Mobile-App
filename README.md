# LiteWing Mobile App

A professional Flutter-based mobile application for controlling LiteWing drones via WiFi. Features advanced joystick controls, real-time telemetry, and a comprehensive user interface designed for optimal flight experience.

## 🚁 Features

### Flight Control
- **Dual Joystick Interface**: Left stick for Thrust/Yaw, Right stick for Roll/Pitch
- **Advanced Exponential Curve**: Solves sensitivity issues with 80% of range covering 0-20° for precise control
- **Multi-touch Support**: Independent joystick operation with drag-based movement
- **Real-time Value Display**: Shows actual protocol values (0-100% thrust, ±30° angles, ±200°/s yaw)

### Communication & Safety
- **WiFi Connection Management**: Automatic drone discovery and connection status
- **UDP Protocol**: Custom 0x30 header protocol at 50Hz (20ms intervals)
- **Safety Features**: Arming sequence, emergency stop, command timeouts
- **Connection Verification**: Real-time monitoring of drone responsiveness

### User Interface
- **Professional Design**: Clean monochrome interface optimized for flight operations
- **Cross-platform**: Supports Android, iOS, Web, and Desktop platforms
- **Responsive Controls**: Visual feedback with position indicators and status displays
- **Debug Console**: Real-time diagnostic information and connection status

## 📱 Screenshots

*Add screenshots of your app here*

## 🚀 Getting Started

### Prerequisites
- Flutter SDK (latest stable version)
- Android Studio / VS Code with Flutter extension
- LiteWing drone with WiFi capability

### Installation

1. **Clone the repository**
   ```bash
   git clone https://github.com/CircuitDigest/LiteWing-Mobile-App.git
   cd LiteWing-Mobile-App
   ```

2. **Install dependencies**
   ```bash
   flutter pub get
   ```

3. **Run the app**
   ```bash
   flutter run
   ```

### Build for Release

**Android APK:**
```bash
flutter build apk --release
```

**iOS (requires Mac):**
```bash
flutter build ios --release
```

## 🔧 Configuration

### Drone Connection
1. Connect your device to the LiteWing WiFi network (SSID: `LiteWing_XXXXXX`)
2. Launch the app and tap "Connect"
3. Wait for the green status indicator showing "Connected & Verified"

### Network Settings
- **Drone IP**: `192.168.43.42`
- **Port**: `2390`
- **Protocol**: UDP with custom packet format
- **Command Rate**: 50Hz

## 🎮 Usage

### Basic Flight Controls
- **Left Joystick**: 
  - Vertical: Thrust (0-100%)
  - Horizontal: Yaw rotation (±200°/s) - toggle ON/OFF
- **Right Joystick**:
  - Horizontal: Roll (±30°)
  - Vertical: Pitch (±30°)

### Safety Procedures
1. Ensure drone is on a stable surface
2. Connect to drone WiFi
3. Launch app and connect
4. Keep joysticks centered during 2-second arming sequence
5. Start with small movements to test responsiveness
6. Use emergency disconnect if needed

## 📚 Documentation

- **[LiteWing Mobile App Development Guide](LiteWing_Mobile_App_Development_Guide.md)**: Complete protocol documentation
- **[Protocol Specifications](knowledge/DRONE_PROTOCOL%20(TESTED%20WOrking).md)**: Tested working protocol details
- **Knowledge Base**: Comprehensive reference materials in `/knowledge` directory

## 🛠 Technical Architecture

### Core Components
- **`lib/main.dart`**: App entry point and navigation
- **`lib/drone_control_screen.dart`**: Main flight interface with advanced joystick controls
- **`lib/drone_comm.dart`**: UDP communication and protocol handling
- **`lib/drone_control_page.dart`**: Additional control interfaces

### Key Technologies
- **Flutter**: Cross-platform UI framework
- **UDP Sockets**: Direct drone communication
- **Custom Widgets**: Professional joystick implementation
- **Real-time Updates**: 50Hz command transmission

## 🤝 Contributing

We welcome contributions! Please follow these steps:

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

### Development Guidelines
- Follow Flutter/Dart style guidelines
- Test on multiple devices/platforms
- Update documentation for new features
- Ensure safety features remain intact

## 📋 Roadmap

- [ ] Add telemetry logging and replay
- [ ] Implement waypoint navigation
- [ ] Add camera control interface
- [ ] Develop altitude hold functionality
- [ ] Create flight data analysis tools
- [ ] Add multi-drone support

## 🐛 Known Issues

- iOS may require additional permissions for UDP sockets
- Web version has limited UDP capabilities (consider WebRTC bridge)
- Ensure proper WiFi connection before launching app

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🙏 Acknowledgments

- Built for CircuitDigest LiteWing drone platform
- Inspired by Bitcraze Crazyflie control systems
- Flutter community for excellent documentation and packages

## 📞 Support

For support and questions:
- Create an issue in this repository
- Check the documentation in `/knowledge` directory
- Review the comprehensive development guide

---

**⚠️ Safety Note**: Always fly responsibly and follow local regulations. This app is for educational and recreational purposes. Ensure proper testing in safe environments before normal operation.
