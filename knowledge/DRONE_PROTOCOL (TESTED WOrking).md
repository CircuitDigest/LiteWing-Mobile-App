# LiteWing Drone Control Protocol Documentation

## Overview
This document details our findings on controlling the LiteWing drone via UDP commands. The drone uses a modified version of the Crazy RealTime Protocol (CRTP) for communication.

## Network Configuration
- **Drone IP**: 192.168.43.42
- **Command Port**: 2390 (for sending control commands)
- **Data Port**: 2391 (for receiving telemetry)
- **Local Port**: 2399 (for binding local socket)

## Packet Structure
Each command packet follows this format:
```python
packet = bytearray([
    HEADER,             # 1 byte  - Channel and Port information
    *ROLL_BYTES,        # 4 bytes - Float32 little-endian
    *PITCH_BYTES,       # 4 bytes - Float32 little-endian
    *YAW_BYTES,        # 4 bytes - Float32 little-endian
    *THRUST_BYTES,     # 2 bytes - Uint16 little-endian
    CHECKSUM           # 1 byte  - Sum of all previous bytes & 0xFF
])
```

**Important Notes on Roll, Pitch, and Yaw Values:**

*   **Units:** The drone firmware expects these `float32` values to represent physical units:
    *   `ROLL`: Degrees (e.g., a sensible range for joystick mapping might be -30.0 to +30.0 degrees).
    *   `PITCH`: Degrees (e.g., a sensible range for joystick mapping might be -30.0 to +30.0 degrees). The value placed *in the packet* is inverted (see below).
    *   `YAW`: Degrees per second (e.g., a sensible range for joystick mapping might be -200.0 to +200.0 deg/s).
*   **Scaling from Normalized Input:** If your application (e.g., UI with joysticks) produces normalized outputs (typically -1.0 to 1.0), these must be scaled to the appropriate degree/deg/s values before being used to construct the packet.
    *   Example: `scaled_roll = joystick_roll_outpuRt[-1.0 to 1.0] * MAX_ROLL_ANGLE_DEGREES`
*   **Pitch Inversion:** The `PITCH_BYTES` in the packet must contain the *inverted* pitch value. For example, if you want the drone to pitch nose down by 10 degrees (which might correspond to a positive logical pitch in your app depending on coordinate system), the value in the packet should be `-10.0`.
    *   If your application considers Joystick UP as positive pitch for nose DOWN, and your joystick output for UP is `+1.0` (after any app-level inversion of raw joystick Y data), this `+1.0` would be scaled (e.g., to `+30.0` degrees) and then inverted to `-30.0` for the packet.

### Example Packet Creation
```python
def create_commander_packet(roll, pitch, yaw, thrust):
    """Create a commander packet following the CRTP protocol"""
    # Header byte (channel 0, port 3)
    HEADER_COMMANDER = (0x30 | (CRTP_PORT_COMMANDER << 4))  # 0x30 = channel 0, port 3
    packet = bytearray([HEADER_COMMANDER])
    
    # Add roll, pitch, yaw (float32, little-endian) and thrust (uint16)
    # Note: pitch is inverted as per protocol
    packet.extend(struct.pack('<fff', float(roll), float(-pitch), float(yaw)))
    packet.extend(struct.pack('<H', int(thrust)))
    
    # Calculate checksum (sum of all bytes)
    checksum = sum(packet) & 0xFF
    packet.append(checksum)
    
    return packet
```

## Key Protocol Findings

### 1. Connection Maintenance
- The drone requires continuous "keep-alive" packets to maintain connection
- Keep-alive is done by sending zero-thrust commands (0,0,0,0)
- Blue LED blinks when receiving valid packets
- Example keep-alive implementation:
```python
def keep_alive_loop():
    """Continuously send zero throttle commands"""
    while not stop_event.is_set():
        packet = create_commander_packet(0.0, 0.0, 0.0, 0)
        send_command_with_socket(packet)
        time.sleep(0.1)  # Send every 100ms
```

### 2. Motor Control
- Thrust range: 0 to 65535 (uint16)
- Minimum effective thrust: ~10000
- Maximum safe test thrust: ~20000
- Motors require "arming" sequence before accepting thrust commands

### 3. Critical Findings
1. **Command Timing**:
   - Commands must be sent repeatedly to maintain effect
   - 100ms interval between commands works well
   - Minimum 2-second duration for reliable motor response

2. **Safety Protocol**:
   - Always start with zero thrust
   - Use gradual thrust increase/decrease
   - Maintain keep-alive between commands
   - Example safe motor test:
```python
def motor_test():
    # Pause keep-alive
    keep_alive_event.set()
    time.sleep(0.1)
    
    try:
        # Send thrust for 2 seconds
        start_time = time.time()
        while time.time() - start_time < 2.0:
            packet = create_commander_packet(0.0, 0.0, 0.0, 10000)
            send_command_with_socket(packet)
            time.sleep(0.1)
        
        # Gradual shutdown
        for thrust in [7500, 5000, 2500, 0]:
            packet = create_commander_packet(0.0, 0.0, 0.0, thrust)
            send_command_with_socket(packet)
            time.sleep(0.1)
    
    finally:
        # Resume keep-alive
        keep_alive_event.clear()
```

## Common Issues and Solutions

1. **Command Failures**:
   - **Issue**: Commands not reaching drone
   - **Solution**: Ensure continuous keep-alive packets

2. **Intermittent Response**:
   - **Issue**: Motors spin briefly/inconsistently
   - **Solution**: Maintain command for duration, pause keep-alive during thrust

3. **Connection Loss**:
   - **Issue**: Drone stops responding
   - **Solution**: Implement reliable keep-alive thread

## Best Practices

1. **Connection Management**:
   - Start keep-alive immediately on connection
   - Handle disconnection gracefully
   - Monitor blue LED for packet reception

2. **Command Sequencing**:
   - Always start with zero thrust
   - Use gradual thrust changes
   - Maintain command for desired duration
   - Return to zero thrust smoothly

3. **Safety**:
   - Implement emergency stop
   - Use command locks to prevent conflicts
   - Monitor command responses
   - Set safe thrust limits

## Next Steps for Joystick Implementation

1. **Required Features**:
   - Real-time command sending
   - Smooth thrust transitions
   - Emergency stop capability
   - Connection status monitoring

2. **Considerations**:
   - Joystick sampling rate
   - Command throttling
   - Thrust scaling
   - Connection reliability

## References
- CRTP Protocol Documentation
- LiteWing Android App Implementation
- UDP Communication Standards 