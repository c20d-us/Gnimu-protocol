# Gnimu frame, v1 (draft)

> [!NOTE]
> **Draft.** This is one telemetry frame for the whole Gnimu family: Gnimu (GNSS+IMU), Gnimu-CAN (vehicle data), and an eventual all-in-one device that merges them into one stream. No device sends it yet; Gnimu-CAN will be the first.

The field tables below are generated from [`spec/frame-v1.json`](../spec/frame-v1.json), which is the source of truth. Edit the JSON and run `tools/generate.py`, never the tables.

## The idea

**One fixed layout, the same on every device.** Every field has one offset, type, scale and meaning, everywhere. Latitude is always at offset 24, RPM always at offset 106. A device fills the blocks it has, and sends every other field as 0 with its valid bit clear.

That makes one published table enough for everything:

- **Apps with a byte-offset schema** (AutoX Data Logger's custom BLE sensor today) are configured the same way for any Gnimu device.
- **Gnimu tools** (such as Gnimu Monitor) parse one format.
- **The all-in-one device** is just a device that fills every block. Nothing about the frame changes.

It's built to what fixed-layout consumers can read, and it's extended only in ways they ignore: fields an app isn't told to map, and characteristics it doesn't subscribe to. The AutoXDL developer confirmed both behaviours.

---

## Rules

These apply to every field, because any field may be mapped by an app.

- **Fixed length: 164 bytes.** Every notification is exactly this long. Fixed-layout consumers drop any other length, so the length is part of the spec version and never changes within it.
- **Little-endian**, two's-complement signed values.
- **Types** only from what fixed-layout consumers support: `u8`, `i16`, `u16`, `i32`, `f64`.
- **One value per field.** No bitfields or packed flags, except the validity masks, which are for Gnimu tools and not meant for mapping.
- **Scale** is a divisor from {1, 10, 100, 1000}. Each field's scale is chosen so the app shows the value in the listed unit.
- **Metric units only.** Converting to mph, °F or psi is the app's job. No field ever changes units.
- **Unaligned fields are normal.** Encode with byte writes or `memcpy`, never pointer casts. The `f64` fields are not 8-byte aligned in the frame.
- **Encoders round half away from zero, and saturate** to the field's type: a value past the end of its range is sent as the type's limit, never wrapped. Wrapping would turn a hard left spin into a right one.
- **Spare fields are reserved in every block.** A future spec version can give them a meaning without moving anything else. Until then they're sent as 0, invalid.

### Missing values

A field the device doesn't have, or doesn't have yet, is **0** with its `valid` bit clear. Fixed-layout apps can't express "missing", and 0 is the least misleading placeholder. Gnimu tools must go by the `valid` bit, never by the value: latitude 0, longitude 0 is a real place.

### Rate

A device sends the frame at a fixed rate while a client is subscribed, whether or not anything changed. Each field carries its latest value, and the `fresh` mask shows which ones changed since the previous frame.

AutoX Data Logger takes frames at any rate and aligns them to its GNSS source's cadence, so for that consumer the target is at or a little above the GNSS rate, 30 Hz at most. Data that genuinely needs a higher rate, such as the IMU's full sample rate, goes on a [stream characteristic](#streams), not into the frame.

At 164 bytes and 30 Hz, the frame is about 4.9 kB/s. Both the ESP32-C6 and the nRF52840 handle that easily.

### Fitting in one notification

164 bytes needs a BLE packet size (ATT MTU) of at least 167. iOS negotiates 185 automatically, and the device must accept a negotiated MTU of at least 167. A frame must never be split across notifications. The spec's length cap is **182 bytes** (MTU 185 minus 3), which leaves 18 bytes of headroom for a future version.

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
| Vertical velocity | Moving down (as u-blox reports it) |
| Heading | Degrees clockwise from true north, 0 to 359.99. This is the navigation convention, the opposite sense to yaw rate. |
| Gear | Forward gears 1, 2, 3 …; 0 is neutral; −1 is reverse |

### Raw and filtered

**Raw** IMU values are mounting-corrected but unfiltered: the latest sample at the moment the frame is built. **Filtered** values are the device's smoothed output, and the filter (type and cutoff or constant) is stated in the [schema](#schema). The two are separate fields, never one value that changes meaning. Raw values at the frame rate are sample-and-hold, so they can alias. For an app plotting at the GNSS rate, filtered is usually the better choice. Raw is there for diagnosing mounts and vibration.

---

## Layout

Field numbers index the `valid` and `fresh` masks: bit *n* is field *n*. The header and the masks have no field numbers, because they're always present.

### Header (offset 0, 24 bytes)

<!-- generated:header -->
| Offset | Type | Scale | Field | Unit / meaning |
|---|---|---|---|---|
| 0 | i32 | 1 | Device time | ms since boot, monotonic, never adjusted; wraps after 2^31 ms (about 24.8 days) |
| 4 | u8 | 1 | Sequence | counts up by one per frame, wraps at 255; a gap means a lost frame |
| 5 | u8 | 1 | Spec version | 1 |
| 6 | u8 | 1 | Device type | 1 Gnimu, 2 Gnimu-CAN, 3 all-in-one |
| 7 | u8 | 1 | State | 0 unknown, 1 starting, 2 running, 3 waiting, 4 fault |
| 8 | 8 bytes | — | Valid mask | bit n set: field n holds a real value |
| 16 | 8 bytes | — | Fresh mask | bit n set: field n changed since the previous frame |
<!-- /generated -->

**Device time is worth mapping in an app.** Fixed-layout apps typically stamp a sample when it arrives, which carries BLE timing jitter. With device time recorded as a channel, a log can be re-timed afterwards from the device's own clock.

### GNSS (offset 24, 60 bytes)

<!-- generated:gnss -->
| # | Offset | Type | Scale | Field | Unit |
|---|---|---|---|---|---|
| 0 | 24 | f64 | 1 | Latitude | degrees, WGS84 |
| 1 | 32 | f64 | 1 | Longitude | degrees, WGS84 |
| 2 | 40 | i32 | 1000 | Altitude above mean sea level | m (mm resolution) |
| 3 | 44 | i32 | 1000 | Height above ellipsoid | m (mm resolution) |
| 4 | 48 | u16 | 100 | Ground speed | km/h (to 655.35) |
| 5 | 50 | u16 | 100 | Heading of motion | degrees clockwise from true north |
| 6 | 52 | i16 | 100 | Vertical velocity | m/s, down positive |
| 7 | 54 | u16 | 1000 | Horizontal accuracy | m (saturates at 65.535) |
| 8 | 56 | u16 | 1000 | Vertical accuracy | m (saturates at 65.535) |
| 9 | 58 | u16 | 100 | Speed accuracy | km/h |
| 10 | 60 | u16 | 100 | Heading accuracy | degrees (saturates at 655.35) |
| 11 | 62 | u16 | 100 | PDOP | — |
| 12 | 64 | u8 | 1 | Fix type | 0 none, 2 2D, 3 3D, 4 GNSS + dead reckoning, 5 time only |
| 13 | 65 | u8 | 1 | Satellites used | count |
| 14 | 66 | i32 | 1 | GNSS time of week | ms |
| 15 | 70 | i32 | 1 | UTC date | YYYYMMDD, e.g. 20261030 |
| 16 | 74 | i32 | 1 | UTC time of day | ms since midnight |
| 17 | 78 | u16 | 1 | Time accuracy | ns (saturates at 65535) |
| 18 | 80 | i16 | — | *Spare* | |
| 19 | 82 | i16 | — | *Spare* | |
<!-- /generated -->

Lat/lon are `f64` because that's the only type a divisor-only scale can map to degrees at useful resolution.

**When GNSS fields are valid.** The receiver's status flags have no fields of their own; they decide the valid bits instead, so a valid bit means what the corresponding RaceBox flag meant:

| Fields | Valid when |
|---|---|
| Latitude, longitude, both heights, vertical velocity | Fix type 2 or 3 (or 4), and the receiver reports gnssFixOK |
| Ground speed, speed accuracy | Same as position |
| Heading of motion, heading accuracy | The receiver reports the heading valid. A device may also gate it on a minimum speed. |
| Horizontal and vertical accuracy, PDOP, fix type, satellites | Whenever the receiver has produced a solution, fix or not |
| GNSS time of week | The receiver's time is valid |
| UTC date | The receiver reports the date valid |
| UTC time of day, time accuracy | The receiver reports the time valid **and** fully resolved (leap seconds known) |

### IMU (offset 84, 22 bytes)

<!-- generated:imu -->
| # | Offset | Type | Scale | Field | Unit |
|---|---|---|---|---|---|
| 20 | 84 | i16 | 1000 | Accel X, raw | g (±32.767, 1 mg) |
| 21 | 86 | i16 | 1000 | Accel Y, raw | g |
| 22 | 88 | i16 | 1000 | Accel Z, raw | g |
| 23 | 90 | i16 | 1000 | Accel X, filtered | g |
| 24 | 92 | i16 | 1000 | Accel Y, filtered | g |
| 25 | 94 | i16 | 1000 | Accel Z, filtered | g |
| 26 | 96 | i16 | 10 | Roll rate | °/s (±3276.7, 0.1), right side down positive |
| 27 | 98 | i16 | 10 | Pitch rate | °/s, nose down positive |
| 28 | 100 | i16 | 10 | Yaw rate | °/s, turning left positive |
| 29 | 102 | i16 | — | *Spare* | |
| 30 | 104 | i16 | — | *Spare* | |
<!-- /generated -->

### Vehicle (offset 106, 52 bytes)

Standard channels with fixed meanings, whatever the source: an OBD-II PID, a manufacturer identifier, or a frame read off the bus. A vehicle profile maps its sources into these fields.

<!-- generated:vehicle -->
| # | Offset | Type | Scale | Field | Unit |
|---|---|---|---|---|---|
| 31 | 106 | i16 | 1 | Engine speed | rpm |
| 32 | 108 | i16 | 10 | Throttle position | % |
| 33 | 110 | i16 | 10 | Accelerator pedal position | % |
| 34 | 112 | i16 | 10 | Vehicle speed | km/h |
| 35 | 114 | i16 | 10 | Engine load | % |
| 36 | 116 | i16 | 10 | Coolant temperature | °C |
| 37 | 118 | i16 | 10 | Intake air temperature | °C |
| 38 | 120 | i16 | 10 | Oil temperature | °C |
| 39 | 122 | i16 | 10 | Oil pressure | kPa |
| 40 | 124 | i16 | 10 | Manifold absolute pressure | kPa |
| 41 | 126 | i16 | 1000 | Lambda | λ |
| 42 | 128 | i16 | 10 | Fuel level | % |
| 43 | 130 | i16 | 1 | Brake pressure | kPa |
| 44 | 132 | i16 | 10 | Steering wheel angle | °, left positive |
| 45 | 134 | i16 | 10 | Wheel speed, front left | km/h |
| 46 | 136 | i16 | 10 | Wheel speed, front right | km/h |
| 47 | 138 | i16 | 10 | Wheel speed, rear left | km/h |
| 48 | 140 | i16 | 10 | Wheel speed, rear right | km/h |
| 49 | 142 | i16 | 1 | Gear | −1 reverse, 0 neutral, 1 … |
| 50 | 144 | i16 | *schema* | Aux 1 | defined by the device's schema |
| 51 | 146 | i16 | *schema* | Aux 2 | defined by the device's schema |
| 52 | 148 | i16 | *schema* | Aux 3 | defined by the device's schema |
| 53 | 150 | i16 | *schema* | Aux 4 | defined by the device's schema |
| 54 | 152 | i16 | — | *Spare* | |
| 55 | 154 | i16 | — | *Spare* | |
| 56 | 156 | i16 | — | *Spare* | |
<!-- /generated -->

Boost is MAP minus barometric pressure, and is left to the app. The aux fields carry whatever a vehicle profile reads that has no standard field: the schema gives each one's name, unit and scale.

### Power (offset 158, 6 bytes)

<!-- generated:power -->
| # | Offset | Type | Scale | Field | Unit |
|---|---|---|---|---|---|
| 57 | 158 | u16 | 100 | Supply voltage | V: the vehicle supply, or the battery on battery devices |
| 58 | 160 | u8 | 1 | Battery charge | %, battery devices only |
| 59 | 161 | u8 | 1 | Charging | 0 or 1 |
| — | 162 | u8x2 | — | *Reserved* | 0 |
<!-- /generated -->

<!-- generated:summary -->
**Total: 164 bytes, 60 fields.** Mask bits 60–63 are unused.
<!-- /generated -->

### Which device fills what

| Block | Gnimu | Gnimu-CAN | All-in-one |
|---|---|---|---|
| Header | ✓ | ✓ | ✓ |
| GNSS | ✓ | | ✓ |
| IMU | ✓ | | ✓ |
| Vehicle | | ✓ (as its vehicle profile allows) | ✓ |
| Power | battery | vehicle supply | either |

---

## Service and characteristics

Each device type has its own 128-bit service UUID, advertised in its advertising data. AutoX Data Logger's scan only lists devices advertising the service UUID entered in its settings. The advertised name is the device type plus its 10-digit device ID, as Gnimu does today.

| Characteristic | Properties | Required | Purpose |
|---|---|---|---|
| **Frame** | Notify, Read | Yes | The frame. |
| **Schema** | Read | Yes | What this device fills, and the details the layout leaves open. |
| **Control** | Write, Notify | No | Commands and their replies. To be defined. |
| **Stream** *(one or more)* | Notify | No | Higher-rate data that doesn't fit the frame. To be defined. |

### Schema

The layout is fixed, so the schema only has to say what varies by device: which fields it fills, its frame rate, its filter, and what the aux fields mean. It's compact UTF-8 JSON, at most 512 bytes (one BLE long read):

```json
{"v":1,"d":"Gnimu-CAN","r":20,"f":[31,32,57],
 "x":[{"n":50,"k":"Oil temp 2","u":"°C","s":10}]}
```

| Key | Meaning |
|---|---|
| `v` | Spec version |
| `d` | Device type name |
| `r` | Frame rate, Hz |
| `f` | Field numbers this device fills (it may not have all of them valid at once) |
| `x` | Aux field definitions: field number `n`, name `k`, unit `u`, scale `s` |
| `flt` | *(IMU devices)* The filter behind the filtered fields, such as `"ema 0.33"` |

The device's `V` console command prints the same JSON, and the app-setup table (offset, type, scale and name for each filled field).

### Control

To be defined. It's where Gnimu's device commands (restart, re-trim, System OFF) would move from the RaceBox RX characteristic, and where a client could change settings such as the frame rate.

### Streams

To be defined when the first one is built (most likely the IMU at its full sample rate). Each notification carries a batch of samples, stamped with the device time of the first sample and the sample period, so a client can place every sample exactly.

---

## Versioning

- The spec version is in the header and the schema. Any change to an existing field's offset, type, scale, unit or meaning, or to the frame length, is a new version.
- A new version can give spare fields a meaning without moving anything else. Apps already set up keep working, as long as the length stays the same.
- A device sends exactly one version.

## Setting up AutoX Data Logger

Enter the device's service and frame UUIDs, set the packet length to **164**, and add up to four fields from the tables above, with the type, offset and scale as listed. The same settings work on any Gnimu device that fills those fields.

## Open questions

1. **Field list review.** Is anything missing that a device would plausibly send: a second lambda, fuel pressure, clutch or brake switches, ambient temperature, IMU temperature, a lap or marker counter? Anything added now costs nothing. Anything added later has to come out of the spares.
2. **Speed units.** Ground and vehicle speeds are km/h, so they display directly. m/s would be the SI choice. Does AutoXDL convert units on its own?
3. **Stream format,** once the first stream is needed.
4. **Multiple clients.** Sequence and freshness are per frame. If a device serves several clients at once, they'd need to be per subscription.
