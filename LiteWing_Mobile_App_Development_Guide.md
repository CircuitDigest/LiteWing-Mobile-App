# LiteWing Mobile App Development Guide

This guide provides comprehensive documentation for developing a mobile application to control the LiteWing drone via WiFi, including height hold functionality.

## Table of Contents
1. [WiFi Communication Protocol](#wifi-communication-protocol)
2. [CRTP Packet Structure](#crtp-packet-structure)
3. [Flight Control Commands](#flight-control-commands)
4. [Height Hold Implementation](#height-hold-implementation)
5. [Parameter System](#parameter-system)
6. [Logging/Telemetry System](#logging-telemetry-system)
7. [Safety & Timeouts](#safety--timeouts)
8. [Network Configuration](#network-configuration)
9. [Mobile App Architecture](#mobile-app-architecture)
10. [Example Implementations](#example-implementations)

---

## 1. WiFi Communication Protocol

### Network Configuration
- **WiFi Mode**: Access Point (AP)
- **Default IP**: `192.168.43.42`
- **SSID Format**: `{CONFIG_WIFI_BASE_SSID}_{MAC_ADDRESS}`
- **Password**: Defined in `WIFI_PWD` 
- **Channel**: Configurable (default varies)
- **Protocol**: UDP on port **2390**

### Connection Process
1. Connect to drone's WiFi network
2. Send UDP packets to `192.168.43.42:2390`
3. All packets must include **checksum** as last byte
4. Use CRTP packet format inside UDP payload

### UDP Packet Structure
```
[CRTP_HEADER][CRTP_DATA][CHECKSUM]
```
- **Maximum payload**: 30 bytes + header + checksum
- **Checksum**: Simple sum of all bytes (excluding checksum itself)

---

## 2. CRTP Packet Structure

### Basic CRTP Header
```c
typedef struct {
    uint8_t size;                    // Size of data (excluding header)
    union {
        uint8_t header;              // Port (4bits) + Channel (2bits) + Reserved (2bits)
        struct {
            uint8_t channel : 2;     // Channel within port
            uint8_t reserved : 2;    // Reserved bits
            uint8_t port : 4;        // CRTP port
        };
    };
    uint8_t data[30];               // Payload data
} CRTPPacket;
```

### Important CRTP Ports
```c
CRTP_PORT_CONSOLE          = 0x00  // Debug output
CRTP_PORT_PARAM            = 0x02  // Parameter system
CRTP_PORT_SETPOINT         = 0x03  // Basic flight commands
CRTP_PORT_MEM              = 0x04  // Memory access
CRTP_PORT_LOG              = 0x05  // Telemetry logging
CRTP_PORT_LOCALIZATION     = 0x06  // Position data
CRTP_PORT_SETPOINT_GENERIC = 0x07  // Advanced flight commands
CRTP_PORT_SETPOINT_HL      = 0x08  // High-level commands
```

---

## 3. Flight Control Commands

### Basic Flight Commands (CRTP_PORT_SETPOINT, Channel 0)

**Packet Format - Legacy RPYT:**
```c
struct CommanderCrtpLegacyValues {
    float roll;        // degrees (-30 to +30)
    float pitch;       // degrees (-30 to +30) 
    float yaw;         // degrees/sec (-400 to +400)
    uint16_t thrust;   // 1000-60000 (0 = motor stop)
} __attribute__((packed));
```

**Example Mobile App Joystick Mapping:**
```javascript
// Left stick: Thrust (Y) + Yaw (X)
// Right stick: Pitch (Y) + Roll (X)

const packet = {
    roll: rightStickX * 30,      // -30 to +30 degrees
    pitch: rightStickY * 30,     // -30 to +30 degrees  
    yaw: leftStickX * 400,       // -400 to +400 deg/sec
    thrust: (leftStickY + 1) * 30000  // 0 to 60000
};
```

### Advanced Flight Commands (CRTP_PORT_SETPOINT_GENERIC, Channel 0)

**Available Command Types:**
```c
enum packet_type {
    stopType          = 0,  // Emergency stop
    velocityWorldType = 1,  // World-frame velocity
    zDistanceType     = 2,  // Altitude + attitude
    cppmEmuType       = 3,  // RC emulation
    altHoldType       = 4,  // Altitude hold mode
    hoverType         = 5,  // Position hold
    fullStateType     = 6,  // Full state control
    positionType      = 7,  // Position control
};
```

---

## 4. Height Hold Implementation

### Altitude Hold Command (Type 4)
```c
struct altHoldPacket_s {
    float roll;        // radians
    float pitch;       // radians  
    float yawrate;     // deg/s
    float zVelocity;   // m/s (vertical velocity)
} __attribute__((packed));
```

**Mobile Implementation:**
```javascript
function sendAltHoldCommand(rollDeg, pitchDeg, yawRateDegS, zVelMS) {
    const packet = new ArrayBuffer(17); // 1 byte type + 16 bytes data
    const view = new DataView(packet);
    
    view.setUint8(0, 4);  // altHoldType
    view.setFloat32(1, rollDeg * Math.PI / 180, true);   // radians
    view.setFloat32(5, pitchDeg * Math.PI / 180, true);  // radians
    view.setFloat32(9, yawRateDegS, true);               // deg/s
    view.setFloat32(13, zVelMS, true);                   // m/s vertical
    
    sendCRTPPacket(0x07, 0, packet); // Port 7, Channel 0
}
```

### Z-Distance Hold (Type 2)
```c
struct zDistancePacket_s {
    float roll;         // degrees
    float pitch;        // degrees
    float yawrate;      // deg/s  
    float zDistance;    // meters (absolute height)
} __attribute__((packed));
```

### Flight Mode Control
Enable altitude hold by setting flight mode:
```c
// Send parameter: "flightmode.althold" = 1
```

---

## 5. Parameter System

### Parameter Access via CRTP
**Port**: `CRTP_PORT_PARAM` (0x02)

**Get Parameter Value:**
```javascript
function getParameter(group, name) {
    // Send parameter request packet
    const packet = createParamGetPacket(group, name);
    sendCRTPPacket(0x02, 0, packet);
}
```

**Set Parameter Value:**
```javascript
function setParameter(group, name, value) {
    const packet = createParamSetPacket(group, name, value);
    sendCRTPPacket(0x02, 1, packet);
}
```

### Important Parameters for Mobile App

**Flight Modes:**
- `flightmode.althold` - Enable altitude hold (boolean)
- `flightmode.poshold` - Enable position hold (boolean)  
- `stabilizer.roll` - Roll control mode (0=rate, 1=angle)
- `stabilizer.pitch` - Pitch control mode (0=rate, 1=angle)
- `stabilizer.yaw` - Yaw control mode (0=rate, 1=angle)

**PID Tuning:**
- `pid_attitude.roll_kp` - Roll attitude P gain
- `pid_attitude.roll_ki` - Roll attitude I gain  
- `pid_attitude.roll_kd` - Roll attitude D gain
- (Similar for pitch, yaw)

**Motor & Safety:**
- `motor.m1` - Motor 1 power (read-only)
- `system.armed` - System armed status (boolean)
- `commander.enHighLevel` - Enable high-level commander

---

## 6. Logging/Telemetry System

### Log Data Access via CRTP
**Port**: `CRTP_PORT_LOG` (0x05)

### Important Log Variables

**Attitude & Position:**
- `stabilizer.roll` - Current roll angle (degrees)
- `stabilizer.pitch` - Current pitch angle (degrees)
- `stabilizer.yaw` - Current yaw angle (degrees)
- `stateEstimate.x` - X position (meters)
- `stateEstimate.y` - Y position (meters)  
- `stateEstimate.z` - Z position (meters)

**Velocity:**
- `stateEstimate.vx` - X velocity (m/s)
- `stateEstimate.vy` - Y velocity (m/s)
- `stateEstimate.vz` - Z velocity (m/s)

**Sensors:**
- `acc.x/y/z` - Accelerometer data (G)
- `gyro.x/y/z` - Gyroscope data (deg/s)
- `mag.x/y/z` - Magnetometer data (gauss)
- `baro.pressure` - Barometric pressure (mbar)
- `baro.asl` - Altitude above sea level (m)

**System Status:**
- `pm.vbat` - Battery voltage (V)
- `pm.state` - Power management state
- `radio.rssi` - Signal strength
- `system.load` - CPU load percentage

### Setting up Log Streaming
```javascript
function startLogStream(variables, frequency) {
    // Create log block with desired variables
    const logBlock = createLogBlock(variables, frequency);
    sendCRTPPacket(0x05, 0, logBlock);
}

// Example: Stream attitude at 50Hz
startLogStream(['stabilizer.roll', 'stabilizer.pitch', 'stabilizer.yaw'], 50);
```

---

## 7. Safety & Timeouts

### Command Priorities
```c
#define COMMANDER_PRIORITY_DISABLE 0
#define COMMANDER_PRIORITY_CRTP    1  // Your mobile app commands
#define COMMANDER_PRIORITY_EXTRX   2  // External receiver (higher priority)
```

### Critical Timeouts
- **Command Timeout**: 500ms - Switch to stabilize mode
- **Shutdown Timeout**: 2000ms - Complete motor stop
- **Connection Timeout**: If no commands received, drone automatically stabilizes

### Safety Implementation in Mobile App
```javascript
class DroneController {
    constructor() {
        this.commandInterval = setInterval(() => {
            this.sendHeartbeat();
        }, 100); // Send command every 100ms
    }
    
    sendHeartbeat() {
        // Send current stick positions even if unchanged
        this.sendFlightCommand(this.currentSticks);
    }
    
    emergencyStop() {
        // Send stop command
        const stopPacket = new ArrayBuffer(1);
        new DataView(stopPacket).setUint8(0, 0); // stopType
        this.sendCRTPPacket(0x07, 0, stopPacket);
    }
}
```

---

## 8. Network Configuration 

### WiFi Connection Details
Based on the firmware analysis:

```javascript
const DRONE_CONFIG = {
    ip: "192.168.43.42",
    port: 2390,
    ssidPattern: /^LiteWing_[A-F0-9]{12}$/,  // Adjust based on CONFIG_WIFI_BASE_SSID
    maxPacketSize: 32,  // 30 bytes data + header + checksum
    commandRate: 50     // Hz - recommended command frequency
};
```

### Connection Flow
1. **Scan for drone WiFi** (SSID matching pattern)
2. **Connect to drone network** (password required)
3. **Open UDP socket** to `192.168.43.42:2390`
4. **Send initial parameters** to configure flight modes
5. **Start command/telemetry loops**

---

## 9. Mobile App Architecture

### Recommended App Structure
```
DroneController/
├── Connection/
│   ├── WiFiManager.js          // WiFi discovery/connection
│   ├── UDPClient.js            // UDP communication
│   └── CRTPProtocol.js         // CRTP packet handling
├── FlightControl/
│   ├── CommandSender.js        // Flight commands
│   ├── FlightModes.js          // Mode management (height hold, etc.)
│   └── SafetyManager.js        // Timeouts, emergency stop
├── Telemetry/
│   ├── LogManager.js           // Log variable streaming
│   ├── ParameterManager.js     // Parameter get/set
│   └── TelemetryProcessor.js   // Data processing/filtering
└── UI/
    ├── VirtualJoystick.js      // Touch controls
    ├── FlightInstruments.js    // Attitude indicator, altimeter
    └── ParameterEditor.js      // PID tuning, mode switches
```

### Key Classes

**DroneController (Main)**
```javascript
class DroneController {
    constructor() {
        this.connection = new UDPClient();
        this.crtp = new CRTPProtocol();
        this.flightControl = new CommandSender();
        this.telemetry = new LogManager();
        this.safety = new SafetyManager();
    }
    
    async connect(ssid, password) {
        await this.connection.connect(ssid, password);
        this.startControlLoop();
        this.startTelemetryLoop();
    }
    
    enableHeightHold(enable) {
        this.flightControl.setParameter("flightmode.althold", enable);
        this.flightControl.setMode("altHold");
    }
}
```

---

## 10. Example Implementations

### Complete Flight Command Function
```javascript
function sendFlightCommand(joysticks, heightHold = false) {
    const { leftX, leftY, rightX, rightY } = joysticks;
    
    if (heightHold) {
        // Use altitude hold mode
        const packet = new ArrayBuffer(17);
        const view = new DataView(packet);
        
        view.setUint8(0, 4); // altHoldType
        view.setFloat32(1, rightX * 0.5, true);        // roll (radians)
        view.setFloat32(5, rightY * 0.5, true);        // pitch (radians)  
        view.setFloat32(9, leftX * 400, true);         // yaw rate (deg/s)
        view.setFloat32(13, (leftY - 0.5) * 2, true);  // z velocity (m/s)
        
        sendCRTPPacket(0x07, 0, packet);
    } else {
        // Use basic thrust mode
        const packet = new ArrayBuffer(14);
        const view = new DataView(packet);
        
        view.setFloat32(0, rightX * 30, true);         // roll (degrees)
        view.setFloat32(4, rightY * 30, true);         // pitch (degrees)
        view.setFloat32(8, leftX * 400, true);         // yaw rate (deg/s)
        view.setUint16(12, leftY * 60000, true);       // thrust (0-60000)
        
        sendCRTPPacket(0x03, 0, packet);
    }
}
```

### Height Hold Toggle Implementation
```javascript
class HeightHoldManager {
    constructor(droneController) {
        this.drone = droneController;
        this.enabled = false;
        this.targetHeight = 0;
    }
    
    async toggle() {
        this.enabled = !this.enabled;
        
        if (this.enabled) {
            // Get current height as target
            this.targetHeight = await this.drone.telemetry.getValue("stateEstimate.z");
            
            // Enable altitude hold mode
            await this.drone.parameters.set("flightmode.althold", 1);
            
            console.log(`Height hold enabled at ${this.targetHeight}m`);
        } else {
            // Disable altitude hold mode
            await this.drone.parameters.set("flightmode.althold", 0);
            
            console.log("Height hold disabled");
        }
    }
    
    adjustTarget(deltaHeight) {
        if (this.enabled) {
            this.targetHeight += deltaHeight;
            // Send new target via position command
            this.drone.flightControl.sendPositionCommand(null, null, this.targetHeight);
        }
    }
}
```

### Real-time Telemetry Display
```javascript
class TelemetryDisplay {
    constructor(droneController) {
        this.drone = droneController;
        this.setupLogStreaming();
    }
    
    async setupLogStreaming() {
        // Stream essential flight data at 20Hz
        await this.drone.telemetry.createLogBlock("flight_data", [
            "stabilizer.roll",
            "stabilizer.pitch", 
            "stabilizer.yaw",
            "stateEstimate.z",
            "pm.vbat"
        ], 20);
        
        this.drone.telemetry.onData("flight_data", (data) => {
            this.updateUI(data);
        });
    }
    
    updateUI(telemetry) {
        document.getElementById("roll").textContent = telemetry.roll.toFixed(1) + "°";
        document.getElementById("pitch").textContent = telemetry.pitch.toFixed(1) + "°";
        document.getElementById("yaw").textContent = telemetry.yaw.toFixed(1) + "°";
        document.getElementById("altitude").textContent = telemetry.z.toFixed(2) + "m";
        document.getElementById("battery").textContent = telemetry.vbat.toFixed(1) + "V";
        
        // Update attitude indicator graphics
        this.attitudeIndicator.setAttitude(telemetry.roll, telemetry.pitch);
    }
}
```

### UDP Communication Implementation
```javascript
class UDPClient {
    constructor() {
        this.socket = null;
        this.connected = false;
        this.droneIP = "192.168.43.42";
        this.dronePort = 2390;
    }
    
    async connect() {
        // Platform-specific UDP socket creation
        // For React Native, use react-native-udp
        // For web, use WebRTC data channels or WebSocket bridge
        this.socket = new UDPSocket();
        await this.socket.connect(this.droneIP, this.dronePort);
        this.connected = true;
    }
    
    send(data) {
        if (!this.connected) return false;
        
        // Add checksum
        const checksum = this.calculateChecksum(data);
        const packet = new Uint8Array(data.length + 1);
        packet.set(data);
        packet[data.length] = checksum;
        
        this.socket.send(packet);
        return true;
    }
    
    calculateChecksum(data) {
        let sum = 0;
        for (let byte of data) {
            sum += byte;
        }
        return sum & 0xFF;
    }
}
```

### CRTP Protocol Handler
```javascript
class CRTPProtocol {
    constructor(udpClient) {
        this.udp = udpClient;
    }
    
    sendPacket(port, channel, data) {
        const header = (port << 4) | (channel & 0x03);
        const packet = new Uint8Array(data.length + 2);
        
        packet[0] = data.length;  // Size
        packet[1] = header;       // Header
        packet.set(data, 2);      // Data
        
        return this.udp.send(packet);
    }
    
    // Convenience methods for different packet types
    sendSetpoint(roll, pitch, yaw, thrust) {
        const data = new ArrayBuffer(14);
        const view = new DataView(data);
        
        view.setFloat32(0, roll, true);
        view.setFloat32(4, pitch, true);
        view.setFloat32(8, yaw, true);
        view.setUint16(12, thrust, true);
        
        this.sendPacket(0x03, 0, new Uint8Array(data));
    }
    
    sendAltHold(roll, pitch, yawRate, zVelocity) {
        const data = new ArrayBuffer(17);
        const view = new DataView(data);
        
        view.setUint8(0, 4);  // altHoldType
        view.setFloat32(1, roll, true);
        view.setFloat32(5, pitch, true);
        view.setFloat32(9, yawRate, true);
        view.setFloat32(13, zVelocity, true);
        
        this.sendPacket(0x07, 0, new Uint8Array(data));
    }
    
    sendEmergencyStop() {
        const data = new Uint8Array([0]); // stopType
        this.sendPacket(0x07, 0, data);
    }
}
```

---

## Quick Start Checklist

### Essential Mobile App Features
- [ ] **WiFi Discovery & Connection** - Automatically find and connect to drone
- [ ] **Virtual Joysticks** - Touch controls for flight  
- [ ] **Height Hold Toggle** - Easy altitude hold activation
- [ ] **Emergency Stop** - Large, accessible stop button
- [ ] **Telemetry Display** - Real-time attitude, altitude, battery
- [ ] **Connection Status** - Visual indicator of drone connectivity
- [ ] **Safety Timeouts** - Automatic command sending (100ms interval)

### Advanced Features  
- [ ] **Parameter Editor** - PID tuning interface
- [ ] **Flight Data Recording** - Log telemetry for analysis
- [ ] **Waypoint Navigation** - Position-based flight planning
- [ ] **Camera Control** - If camera hardware available
- [ ] **Auto-hover** - Position hold mode
- [ ] **Return-to-Home** - Automatic landing at takeoff point

---

## Protocol Reference Summary

### Key Network Settings
- **Drone IP**: `192.168.43.42`
- **UDP Port**: `2390`
- **Command Rate**: 50-100Hz (10-20ms intervals)
- **Max Packet**: 32 bytes (including checksum)

### Critical CRTP Commands
- **Basic Flight**: Port `0x03`, Channel `0` (RPYT format)
- **Height Hold**: Port `0x07`, Channel `0`, Type `4`
- **Emergency Stop**: Port `0x07`, Channel `0`, Type `0`
- **Parameters**: Port `0x02`, Various channels
- **Telemetry**: Port `0x05`, Various channels

### Safety Requirements
- **Command Timeout**: < 500ms or drone stabilizes
- **Heartbeat**: Send commands every 100ms minimum
- **Emergency Stop**: Always accessible in UI
- **Connection Monitor**: Detect and handle disconnections

This documentation provides everything needed to build a comprehensive mobile application for controlling your LiteWing drone via WiFi, with special focus on implementing height hold functionality! 