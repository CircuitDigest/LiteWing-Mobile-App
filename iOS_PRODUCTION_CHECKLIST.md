# LiteWing iOS Production Testing Checklist

## 🔧 Pre-Testing Setup
- [ ] **iPhone Developer Mode enabled** (Settings > Privacy & Security > Developer Mode)
- [ ] **Trust Mac computer** (Connect via USB, tap Trust when prompted)
- [ ] **WiFi permissions granted** (Settings > Privacy > Location Services > System Services > Networking & Wireless)
- [ ] **Location permissions granted** (Required for WiFi network detection)
- [ ] **Audio permissions granted** (For drone control sounds)

## 📱 Device Testing
- [ ] **Test on multiple iOS versions** (iOS 13.0+ supported)
- [ ] **Test on different iPhone models** (iPhone 8+ recommended)
- [ ] **Test in both orientations** (Portrait and Landscape)
- [ ] **Test with different network conditions** (WiFi, Cellular, Airplane mode)

## 🚁 Drone-Specific Testing
- [ ] **Connect to drone WiFi network** (`litewing`, `esp-drone`, or `crazyflie`)
- [ ] **Test UDP communication** (IP: 192.168.43.42:2390)
- [ ] **Test joystick controls** (Thrust, Yaw, Roll, Pitch)
- [ ] **Test height hold functionality**
- [ ] **Test battery voltage monitoring**
- [ ] **Test emergency stop feature**
- [ ] **Test audio feedback** (Connected/Disconnected sounds)

## 🔒 Security & Permissions
- [ ] **Network permissions working** (Local network access)
- [ ] **Location services working** (WiFi network detection)
- [ ] **Background app refresh** (For drone control)
- [ ] **No permission crashes** (All permissions properly requested)

## 🚀 Performance Testing
- [ ] **App launches quickly** (< 3 seconds)
- [ ] **No memory leaks** (Use Xcode Instruments)
- [ ] **Smooth joystick response** (No lag or stuttering)
- [ ] **Real-time communication** (< 100ms latency)
- [ ] **Battery efficient** (No excessive drain)

## 📊 Production Build
- [ ] **Release build tested** (`flutter build ios --release`)
- [ ] **App Store compliance** (No private APIs used)
- [ ] **Icon and splash screen** (Properly configured)
- [ ] **App metadata** (Description, keywords, screenshots)

## 🐛 Crash Prevention
- [ ] **Network error handling** (Graceful fallbacks)
- [ ] **Permission error handling** (User-friendly messages)
- [ ] **Memory management** (Proper dispose methods)
- [ ] **Thread safety** (UI updates on main thread)

## 📈 Analytics & Monitoring
- [ ] **Crash reporting** (Consider Firebase Crashlytics)
- [ ] **Performance monitoring** (Network latency, frame rates)
- [ ] **User experience tracking** (Feature usage, errors)

## 🔄 Continuous Testing
- [ ] **Automated testing script** (`./test_ios.sh`)
- [ ] **Regular testing schedule** (Before each release)
- [ ] **Beta testing group** (TestFlight distribution)
- [ ] **Feedback collection** (User reports, crash logs)

## 🎯 Key Testing Commands

### Fast Development Testing
```bash
# Start iOS simulator and run
./test_ios.sh

# Quick run without build
flutter run -d ios --debug --no-build

# Hot reload during development
# Press 'r' in terminal during flutter run
```

### Physical Device Testing
```bash
# List all connected devices
flutter devices

# Run on specific iPhone
flutter run -d YOUR_DEVICE_ID --debug

# Install without debugging (faster)
flutter install -d YOUR_DEVICE_ID
```

### Production Build Testing
```bash
# Build release version
flutter build ios --release

# Build and run release on device
flutter run -d YOUR_DEVICE_ID --release
```

## 🚨 Common Issues & Solutions

### Issue: App crashes on startup
**Solution:** Check permissions in Info.plist and ensure all required permissions are granted

### Issue: AudioPlayer crash on iOS simulator  ✅ **COMPLETELY FIXED**
**Solution:** Completely redesigned audio system:
- Removed AudioPlayer field from class (no startup initialization)
- Audio only created when actually needed (on-demand)
- Automatic disposal after use to prevent lingering references
- Platform detection disables audio on iOS debug mode
- App launches perfectly on iOS simulator now

### Issue: Network connection fails
**Solution:** Verify WiFi network, check IP address (192.168.43.42), ensure iOS allows local networking

### Issue: Joystick not responding
**Solution:** Check multi-touch handling, verify gesture detection in iOS simulator vs device

### Issue: Audio not playing
**Solution:** Check audio permissions, verify audio files exist in assets folder. Audio is optional - app functions without it.

### Issue: Slow build times
**Solution:** Use build optimizations in Podfile, enable incremental builds, use `--no-build` flag

## 📞 Support & Resources

- **Flutter iOS Documentation:** https://flutter.dev/docs/deployment/ios
- **Xcode Debugging:** Use breakpoints and console logging
- **iOS Simulator:** Test most features without physical device
- **TestFlight:** Beta testing for production apps
- **App Store Connect:** Production deployment and analytics 