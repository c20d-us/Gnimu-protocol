# Gnimu frame, v1 (in progress)

> [!NOTE]
> **In progress.** This is one telemetry frame for the whole Gnimu family: Gnimu (GNSS+IMU), Gnimu-CAN (vehicle data), and potentially an all-in-one device that merges them into one stream. v1 is complete enough to implement, but it isn't published and nothing depends on it yet, so it can still change as Gnimu-CAN's implementation turns things up. The [versioning rules](#versioning) apply once v1 is released. The Control and Stream characteristics are still to be defined.

## The idea

**One fixed layout, the same on every device.** Every field has one offset, type, scale and meaning, everywhere. E.g., Latitude is always at offset 10, RPM always at offset 75, etc. A device fills the blocks it's capable of, and sends every other field as 0 with its valid bit clear.

This makes one published table enough for everything:

- **Apps with a byte-offset schema** (such as AutoX Data Logger's custom BLE sensor) are configured the same way for any Gnimu device.
- **Gnimu tools** (such as Gnimu Monitor) parse one format.
- **An all-in-one device** is just a device that fills every block. Nothing about the frame changes.

It's built to what fixed-layout consumers can read, and it's extended only in ways they'll ignore: fields an app isn't told to map, and characteristics it doesn't subscribe to.

---

## Rules

These apply to the frame and every field, because any field may be mapped by an app.

- **Fixed length: 140 bytes.** Every notification is exactly this long. Fixed-layout consumers drop any other length, so the length is part of the spec version and never changes within it.
- **Little-endian**, two's-complement signed values.
- **Types** only from what fixed-layout consumers support: `u8`, `i16`, `u16`, `i32`, `f64`.
- **One value per field.** No bitfields or packed flags for telemetry fields.
- **Scale** is a divisor from {1, 10, 100, 1000}. Each field's scale is chosen so the app shows the value in the listed unit.
- **Metric units only.** Converting to mph, °F or psi is the app's job. No field ever changes units. Speeds are in km/h, like OBD-II, vehicle CAN data and most motorsport loggers. A device whose GNSS receiver reports m/s or mm/s converts (mm/s × 0.0036 = km/h).
- **Unaligned fields are normal.** Encode with byte writes or `memcpy`, never pointer casts. The `f64` fields are not 8-byte aligned in the frame.
- **Encoders round half away from zero, and saturate** to the field's type: a value past the end of its range is sent as the type's limit, never wrapped.
- **Spare bytes.** Every block ends with a few spare bytes, sent as 0, for fields to be added later. See [Blocks](#blocks).

### Missing values

A field the device doesn't have, or doesn't have yet, is **0** with its `valid` bit clear. Fixed-layout apps can't express "missing", and 0 is the least misleading placeholder.

### Rate

A device sends the frame at a fixed rate while a client is subscribed, whether or not anything changed. Each field carries its latest value.

Apps like AutoX Data Logger take frames at any rate and align them to the GNSS source's cadence, so for that type of consumer the target is at or above the GNSS rate. Data that genuinely needs a higher rate, such as the IMU's full sample rate, goes on a [stream characteristic](#streams), not into the frame.

At 140 bytes and 30 Hz, the frame is about 4.2 kB/s.

### Fitting in one notification

140 bytes needs a BLE packet size (ATT MTU) of at least 143. iOS negotiates 185 automatically, and the device must accept a negotiated MTU of at least 143. A frame must never be split across notifications. The spec's length cap is **182 bytes** (MTU 185 minus 3), which leaves 42 bytes of headroom.

---

## Conventions

### Axes

ISO 8855 vehicle axes: **x forward, y left, z up**, right-handed. Accelerations are specific force, which is what an accelerometer measures, so **at rest and level, a_z = +1 g**.

| Situation | a_x | a_y | a_z | Roll rate | Pitch rate | Yaw rate |
|---|---|---|---|---|---|---|
| Parked on level ground | 0 | 0 | +1.000 g | 0 | 0 | 0 |
| Accelerating forward | **+** | 0 | +1 g | 0 | 0 | 0 |
| Braking | **−** | 0 | +1 g | 0 | 0 | 0 |
| Steady left turn | 0 | **+** | +1 g | 0 | 0 | **+** |
| Steady right turn | 0 | **−** | +1 g | 0 | 0 | **−** |
| Body rolling onto its right side | | | | **+** | | |
| Nose diving under braking | | | | | **+** | |

Rates follow the right-hand rule about each axis: positive yaw is counter-clockwise seen from above (turning left), positive roll is right side down, and positive pitch is nose down.

The IMU values are in the vehicle frame, after the device's mounting correction (Gnimu's trim). The device's own orientation never shows through.

### Other signs

| Field | Positive means |
|---|---|
| Steering angle | Steering wheel turned left |
| Heading | Degrees clockwise from true north, 0 to 359.99. This is the navigation convention, the opposite sense to yaw rate. |
| Gear | Forward gears 1, 2, 3 …; 0 is neutral; −1 is reverse |

### Filtering

The IMU fields are assumed to be a device's **filtered** output, not raw values, unless explicitly designated as such in the device's documentation. How a device filters is its own business and isn't part of the protocol.

If raw IMU data at the sensor's full rate (100Hz, 400Hz, or higher) is to be sent, it belongs on a [stream characteristic](#streams).

---

## Layout

The frame is a header followed by four blocks: GNSS, IMU, vehicle and power. The header is always present and has no validity bits.

### Blocks

Every block follows the same three rules:

1. **It starts with its valid mask.** Bit *n* of the mask (little-endian, bit 0 the lowest) is set when the block's field on bit *n* holds a real value.
2. **Its fields follow in bit order,** contiguous from bit 0: the first field after the mask is bit 0, the next is bit 1, and so on. The tables below list each field's bit.
3. **It ends with spare bytes,** and the mask is the smallest of `u8`, `u16` or `u32` that has at least one free bit per spare byte. A field added later goes into the spare bytes and takes the block's next bit, so bit order and byte order always match, and nothing already in the block moves.

A client checks a field's valid bit in its own block's mask. A device that doesn't fill a block at all sends the block's mask as 0.

### Header

<!-- generated:header -->
*Offset 0, 8 bytes.*

| Offset | Type | Field | Meaning |
|---|---|---|---|
| 0 | i32 | Device time | ms since boot, monotonic, never adjusted; wraps after 2^31 ms (about 24.8 days) |
| 4 | u8 | Frame sequence | counts up by one per frame, wraps at 255; a gap means a lost frame |
| 5 | u8 | Spec version | 1 |
| 6 | u8 | Device capabilities | bits for the blocks the device fills: 1 GNSS, 2 IMU, 4 vehicle, 8 power; 16–128 reserved |
| 7 | u8 | Device state | 0 unknown, 1 starting, 2 running, 3 waiting, 4 fault |
<!-- /generated -->

**Capabilities** says which blocks the device fills, one bit each:

| Bit | Value | Capability | The device fills |
|---|---|---|---|
| 0 | 1 | GNSS | The GNSS block |
| 1 | 2 | IMU | The IMU block |
| 2 | 4 | Vehicle | The vehicle block, from whatever source it reads the car |
| 3 | 8 | Power | The power block |
| 4–7 | | Reserved | Sent as 0 |

It describes the device's potential, not its current state: a GNSS device without a valid fix still sets the GNSS bit, and Gnimu-CAN sets the Vehicle bit while it waits for the car to respond or broadcast. Each block's valid mask says what's available right now, and the [schema's](#schema) fill masks say exactly which fields of each block the device will provide. Like the valid masks, this data is present for diagnostic tools rather than for mapping in an app. The product name (Gnimu, Gnimu-CAN, ...) is in the advertised name, the schema and the Device Information Service.

**State** is the device's own condition, in terms that mean the same on every Gnimu device:

| Value | State | Meaning | Gnimu | Gnimu-CAN |
|---|---|---|---|---|
| 0 | Unknown | Not set; a client treats it as "no information" | | |
| 1 | Starting | Booting; data isn't expected yet | Starting | Starting |
| 2 | Running | Normal operation | Running, collecting data from the GNSS and IMU (if present), even if the data is not yet valid | Polling: an ECU is answering or broadcasting |
| 3 | Waiting | Up, but waiting for an outside source it can't do its job without | Not used | Waiting for the vehicle to respond or broadcast |
| 4 | Fault | Failed and not retrying | Fault | Fault |
| 5–255 | Reserved | | | |

State is about the device, not its data. Whether a field holds a value is in its block's valid mask: a GNSS device that's running without a fix yet says so through the fix field and the GNSS valid bits, not through the state. And on a device that reads a vehicle, running doesn't say whether the engine is running; the vehicle fields (engine speed, for one) say that.

**Device time is worth mapping in an app.** Fixed-layout apps typically stamp a sample when it arrives, which carries BLE timing jitter. With device time recorded as a channel, a log can be re-timed afterwards from the device's own clock.

### GNSS

<!-- generated:gnss -->
*Offset 8, 48 bytes.*

| Bit | Offset | Type | Scale | Field | Unit |
|---|---|---|---|---|---|
| — | 8 | u16 | — | **Valid mask** | bit *n* set: the field on bit *n* holds a real value |
| 0 | 10 | f64 | 1 | Latitude | degrees, WGS84 |
| 1 | 18 | f64 | 1 | Longitude | degrees, WGS84 |
| 2 | 26 | i32 | 1000 | Altitude above mean sea level | m (mm resolution) |
| 3 | 30 | u16 | 100 | Ground speed | km/h (to 655.35) |
| 4 | 32 | u16 | 100 | Heading of motion | degrees clockwise from true north |
| 5 | 34 | u16 | 1000 | Horizontal accuracy | m (saturates at 65.535) |
| 6 | 36 | u16 | 1000 | Vertical accuracy | m (saturates at 65.535) |
| 7 | 38 | u8 | 10 | Speed accuracy | km/h (saturates at 25.5) |
| 8 | 39 | u8 | 10 | PDOP | — (saturates at 25.5) |
| 9 | 40 | u8 | 1 | Fix type | 0 none, 2 2D, 3 3D, 4 GNSS + dead reckoning, 5 time only |
| 10 | 41 | u8 | 1 | Satellites used | count |
| 11 | 42 | f64 | 1 | UTC timestamp | ms since 1970-01-01 00:00 UTC (Unix time; no leap seconds) |
| 12 | 50 | u16 | 1 | Time accuracy | ns, accuracy of the UTC timestamp (saturates at 65535) |
| 13 | 52 | u16 | 1 | GNSS epoch age | ms from the GNSS solution's arrival to this frame (saturates at 65535) |
| — | 54 | 2 bytes | — | *Spare* | for fields added later |
<!-- /generated -->

Lat/lon are `f64` because that's the only type a divisor-only scale can map to degrees at useful resolution.

**Determining when GNSS fields are valid.** The receiver's status flags have no fields of their own; they decide the valid bits instead:

| Fields | Valid when |
|---|---|
| Latitude, longitude, altitude, ground speed, speed accuracy | Fix type 2, 3, or 4, and the receiver reports gnssFixOK |
| Heading of motion | The receiver reports the heading valid. A device may also clear it below a minimum speed, where GNSS heading is meaningless. |
| Horizontal and vertical accuracy, PDOP, fix type, satellites, GNSS epoch age | Whenever the receiver has produced a solution, fix or not |
| UTC timestamp, time accuracy | The receiver reports the date and time valid, and the time fully resolved (leap seconds known) |

**GNSS epoch age** ties the GNSS data to the device's clock. The device records its own time when each GNSS solution arrives, and the frame carries how long ago that was. So the epoch happened at *device time − epoch age*, at the moment given by the UTC timestamp. A client with both can map device time onto UTC exactly, and line up the IMU and vehicle data, which are stamped in device time, against each fix. The latency from the receiver's measurement to its output is small and fixed, and isn't included.

### IMU

<!-- generated:imu -->
*Offset 56, 15 bytes.*

| Bit | Offset | Type | Scale | Field | Unit |
|---|---|---|---|---|---|
| — | 56 | u8 | — | **Valid mask** | bit *n* set: the field on bit *n* holds a real value |
| 0 | 57 | i16 | 1000 | Accel X | g (±32.767, 1 mg), filtered |
| 1 | 59 | i16 | 1000 | Accel Y | g, filtered |
| 2 | 61 | i16 | 1000 | Accel Z | g, filtered |
| 3 | 63 | i16 | 10 | Roll rate | °/s (±3276.7, 0.1), filtered; right side down positive |
| 4 | 65 | i16 | 10 | Pitch rate | °/s, filtered; nose down positive |
| 5 | 67 | i16 | 10 | Yaw rate | °/s, filtered; turning left positive |
| — | 69 | 2 bytes | — | *Spare* | for fields added later |
<!-- /generated -->

### Vehicle

Standard channels with fixed meanings, whatever the source: an OBD-II PID, a manufacturer identifier, or a value read off the bus. A vehicle profile maps its sources into these fields.

<!-- generated:vehicle -->
*Offset 71, 62 bytes.*

| Bit | Offset | Type | Scale | Field | Unit | Mode 01 PID |
|---|---|---|---|---|---|---|
| — | 71 | u32 | — | **Valid mask** | bit *n* set: the field on bit *n* holds a real value | — |
| 0 | 75 | i16 | 1 | Engine speed | rpm | `0x0C` |
| 1 | 77 | i16 | 10 | Throttle position | % | `0x11` |
| 2 | 79 | i16 | 10 | Accelerator pedal position | % | `0x49` |
| 3 | 81 | i16 | 10 | Vehicle speed | km/h | `0x0D` |
| 4 | 83 | i16 | 10 | Coolant temperature | °C | `0x05` |
| 5 | 85 | i16 | 10 | Intake air temperature | °C | `0x0F` |
| 6 | 87 | i16 | 10 | Ambient air temperature | °C | `0x46` |
| 7 | 89 | i16 | 10 | Oil temperature | °C | `0x5C` |
| 8 | 91 | i16 | 10 | Transmission temperature | °C | — |
| 9 | 93 | i16 | 10 | Charge air cooler temperature | °C | `0x77` |
| 10 | 95 | i16 | 10 | Oil pressure | kPa | — |
| 11 | 97 | i16 | 10 | Boost pressure | kPa above atmospheric; negative under vacuum | `0x0B` − `0x33` |
| 12 | 99 | u8 | 1 | Fuel level | % | `0x2F` |
| 13 | 100 | i16 | 1 | Brake pressure | kPa | — |
| 14 | 102 | u8 | 1 | Brake switch | 0 released, 1 pressed | — |
| 15 | 103 | u8 | 1 | Clutch switch | 0 released, 1 pressed | — |
| 16 | 104 | i16 | 10 | Steering wheel angle | °, left positive | — |
| 17 | 106 | i16 | 10 | Vehicle yaw rate | °/s, turning left positive; from the car's own sensor | — |
| 18 | 108 | i16 | 1000 | Vehicle lateral acceleration | g, left positive; from the car's own sensor | — |
| 19 | 110 | i16 | 1000 | Vehicle longitudinal acceleration | g, forward positive; from the car's own sensor | — |
| 20 | 112 | i16 | 10 | Wheel speed, front left | km/h | — |
| 21 | 114 | i16 | 10 | Wheel speed, front right | km/h | — |
| 22 | 116 | i16 | 10 | Wheel speed, rear left | km/h | — |
| 23 | 118 | i16 | 10 | Wheel speed, rear right | km/h | — |
| 24 | 120 | i16 | 1 | Gear | −1 reverse, 0 neutral, 1 … | — |
| 25 | 122 | i16 | *schema* | Aux 1 | defined by the device's schema | — |
| 26 | 124 | i16 | *schema* | Aux 2 | defined by the device's schema | — |
| 27 | 126 | i16 | *schema* | Aux 3 | defined by the device's schema | — |
| 28 | 128 | i16 | *schema* | Aux 4 | defined by the device's schema | — |
| — | 130 | 3 bytes | — | *Spare* | for fields added later | — |
<!-- /generated -->

**Mode 01 PID** names the OBD-II Service 01 PID that measures the same quantity, to pin down what a field means. It isn't where the value has to come from: a manufacturer identifier or a value read off the bus fills the same field. The units match; the resolution may not (PID `0x11` steps by about 0.4 %, the field by 0.1 %). Fields marked — have no Service 01 equivalent and come only from manufacturer data. Gear is one of them: PID `0xA4` is the transmission's actual gear *ratio*, not the gear number.

**Boost** is sent ready to use: as the vehicle reports it, or computed by the device from manifold and barometric pressure.

**The vehicle's own yaw rate and accelerations** come from the car's stability-control sensors, read off the bus. They're separate from the IMU block, which is the device's own sensor, so a device with both sends both. They follow the same axis and sign conventions as the IMU.

**Switches** are 0 or 1. Many cars report only whether the brake pedal is pressed, not the pressure, so the brake switch is separate from brake pressure. The clutch switch shows gear-change timing.

The aux fields carry whatever a vehicle profile reads that has no standard field: the schema gives each one's name, unit and scale.

**Aux or spare?** The block has both, and they do different jobs:

| | Aux fields | Spare bytes |
|---|---|---|
| Meaning | Set by each device, declared in its [schema](#schema) | A future standard field, the same on every device |
| Usable | Now, with no change to the spec | Only once the spec adds a field there |
| App setup | Per device, from its schema | The same for every device, like any standard field |

Aux lets a vehicle profile send something the spec doesn't cover without waiting for it. The spare bytes let the spec itself grow within v1. A quantity can start as an aux field on one profile and, if it proves broadly useful, become a standard field in a spare.

### Power

<!-- generated:power -->
*Offset 133, 7 bytes.*

| Bit | Offset | Type | Scale | Field | Unit |
|---|---|---|---|---|---|
| — | 133 | u8 | — | **Valid mask** | bit *n* set: the field on bit *n* holds a real value |
| 0 | 134 | u16 | 100 | Supply voltage | V: the vehicle supply, or the battery on battery devices |
| 1 | 136 | u8 | 1 | Battery charge | %, battery devices only |
| 2 | 137 | u8 | 1 | Charging | 0 or 1 |
| — | 138 | 2 bytes | — | *Spare* | for fields added later |
<!-- /generated -->

<!-- generated:summary -->
**Total: 140 bytes, 52 fields.**
<!-- /generated -->

### Which device fills what

| | Gnimu | Gnimu-CAN | All-in-one |
|---|---|---|---|
| Capabilities | 11 (GNSS, IMU, power) | 12 (vehicle, power) | 15 (all) |
| Header | ✓ | ✓ | ✓ |
| GNSS | ✓ | | ✓ |
| IMU | ✓ | | ✓ |
| Vehicle | | ✓ (as its vehicle profile allows) | ✓ |
| Power | battery | vehicle supply | either |

---

## Service and characteristics

**Every Gnimu device uses the same UUIDs.** The product is in the advertised name and the Device Information Service, and what it provides is in the frame's capabilities byte, so the UUIDs don't need to vary, and an app set up for one Gnimu device works with any of them.

| Item | UUID | Properties | Required |
|---|---|---|---|
| **Service** | `9074beb4-2f1a-4b5f-9818-fe2d2277ef05` | | Yes |
| **Frame, v1** | `0752d3c3-ceaf-462f-a944-bcc06c57284b` | Notify, Read | Yes |
| **Schema** | `1c9b3945-10eb-4fd0-a5a4-b9d80842380d` | Read | Yes |
| **Device info** | `6d0adfef-8218-488a-a5f9-1ba05f422c22` | Read | Yes |
| **Control** | `4a645ea2-aa0c-4854-9c5d-e8c60b38a3b1` | Write, Notify | No. To be defined. |
| **Stream** *(one or more)* | To be assigned | Notify | No. To be defined. |

Every Gnimu device also provides the standard BLE **Device Information Service** (`0x180A`), described [below](#device-information-service).

The device advertises the service UUID. The advertised name is the device type plus its 10-digit device ID, such as `Gnimu-CAN 0301821570`, as Gnimu does today.

### One client at a time

In v1, a device accepts **one connection at a time**, and stops advertising while connected. The sequence number therefore describes what that one client has received. When the client disconnects, the device advertises again.

### Security

**Frame, Schema, Device info, Stream and the Device Information Service are open.** Telemetry is read-only, and any app can subscribe without pairing, exactly as with RaceBox and RaceChrono devices.

**Control requires an encrypted, bonded connection.** It will carry commands such as restart and System OFF, and a stranger's phone in the paddock shouldn't be able to send them. In practice:

- The phone's operating system only asks to pair when an app first touches a protected characteristic. Apps that only read the frame never touch Control, so they never see a pairing prompt.
- Gnimu devices have no screen or buttons, so pairing is BLE "Just Works": one tap on the phone's prompt, no PIN. After that the phone is bonded and reconnects silently.
- Just Works on its own would let any phone pair. So a device accepts **new** bonds only during a short window after it powers up (or when asked from its console). A phone already bonded can use Control at any time; a new one has to pair while the device's owner is plainly in control of it.

### Schema

The layout is fixed, so the schema only has to say what varies by device: which fields it fills, its frame rate, and what the aux fields mean. It's compact UTF-8 JSON, at most 512 bytes (one BLE long read):

```json
{"v":1,"d":"Gnimu-CAN","r":20,
 "fill":{"vehicle":3,"power":1},
 "aux":{"aux_1":{"k":"Ethanol content","u":"%","s":10}}}
```

| Key | Meaning |
|---|---|
| `v` | Spec version |
| `d` | Product name |
| `r` | Frame rate, Hz |
| `fill` | A **fill mask** per block the device fills, keyed by block name (`gnss`, `imu`, `vehicle`, `power`). Same bit layout as the block's valid mask, but it says which fields the device can provide at all, not which hold a value right now. Blocks the device doesn't fill are left out. |
| `aux` | Aux field definitions, keyed by field (`aux_1` to `aux_4`): name `k`, unit `u`, scale `s` |

A client compares the two masks field by field: fill bit and valid bit set, show the value; fill bit set but valid bit clear, the device has this field but not right now; fill bit clear, the device never provides it. In the example, Gnimu-CAN fills engine speed and throttle position (vehicle bits 0 and 1) and the supply voltage (power bit 0).

Fill masks describe the device as it's currently set up, not just its build: a device may clear bits for fields it has found unavailable, such as PIDs a car doesn't support.

A device's console can print the same information as an app-setup table: the service and frame UUIDs, the packet length, and the offset, type and scale of each field it fills.

### Device info

What the device is and how it's set up: the build it runs and its current settings. The [Schema](#schema) is for software reading the frame; Device info is for people and diagnostics, and for tools that show or, later, change a device's settings. It's the same information the device's `V` console command prints.

Compact UTF-8 JSON, at most 512 bytes (one BLE long read). Three keys are common to every device; everything under `cfg` is device-specific:

```json
{"v":1,
 "build":{"rev":"7f7efe5f4d6a","utc":"2026-10-30T17:27:43Z","target":"esp32c6"},
 "cfg":{"vehicle":"obd2","can":"auto 500/250","emit_hz":20,"run_v":13.2,"cutoff_v":11.8}}
```

| Key | Meaning |
|---|---|
| `v` | Device info format version, `1` |
| `build` | The firmware build: git revision `rev`, build time `utc`, and the `target` board |
| `cfg` | The device's settings, as a flat object of names to strings, numbers or booleans. Free-form per device type; documented by each device. |

Rules:

- **Values are current, not build-time.** Today every setting is fixed at boot, so the values never change while the device runs. If settings become changeable through [Control](#control) later, Device info shows the value in effect, and a client re-reads it after making a change.
- **Clients ignore keys they don't recognise,** so a device can add settings without breaking anything.
- **Identity isn't repeated here.** The device ID, model, firmware version and hardware are in the Device Information Service, where generic BLE tools can show them too.

### Device Information Service

The standard BLE service `0x180A`, which generic BLE tools (nRF Connect, LightBlue) display without knowing anything about Gnimu. Every Gnimu device provides these characteristics:

| Characteristic | UUID | Value |
|---|---|---|
| Manufacturer Name | `0x2A29` | `Gnimu` |
| Model Number | `0x2A24` | The device type name, such as `Gnimu-CAN` |
| Serial Number | `0x2A25` | The 10-digit device ID, as in the advertised name |
| Firmware Revision | `0x2A26` | The firmware version, such as `0.1.0` |
| Hardware Revision | `0x2A27` | The board and hardware profile, such as `XIAO ESP32C6, 12V carrier v1.0` |

A device that also emulates another protocol (Gnimu's RaceBox mode) may have to fill these with that protocol's expected values while it's in that mode. A device can only have one Device Information Service, so it always describes the mode the device is in.

### Control

To be defined, under the [security rule](#security) above. It's where Gnimu's device commands (restart, re-trim, System OFF) would move from the RaceBox RX characteristic, and where a client could change settings such as the frame rate.

### Streams

To be defined when the first one is built (most likely the IMU at its full sample rate). Each notification carries a batch of samples, stamped with the device time of the first sample and the sample period, so a client can place every sample exactly.

---

## Versioning

Once v1 is released:

- **Adding a field in a block's spare bytes stays v1.** It takes the block's next bit, nothing else moves, and the frame length doesn't change, so existing app setups keep working.
- **Any other change is a new version** with a new frame characteristic UUID: moving, resizing, re-scaling or removing a field, or changing the frame length.

The service UUID never changes. The version number is in the header and the schema.

## Setting up AutoX Data Logger

Enter the service UUID and the v1 frame UUID from the table above, set the packet length to **140**, and add up to four fields from the tables above, with the type, offset and scale as listed. The same settings work on every Gnimu device; fields a device doesn't fill read 0.

## Open questions

1. **Stream format,** once the first stream is needed.
2. **Multiple clients.** v1 devices accept one client at a time. Serving a phone and a dash display at once would need the sequence number per subscription.
