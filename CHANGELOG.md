# Changelog

## v1 (in progress, unreleased)

- The Gnimu frame: 140 bytes and 52 fields: an 8-byte header, then GNSS, IMU, vehicle and power blocks.
- Each block starts with its own valid mask (bit *n* is the block's *n*th field) and ends with spare bytes; fields added later take the next bit.
- A capabilities byte for the blocks a device fills, and per-block fill masks in the schema for the fields it provides.
- GNSS: position, altitude, speed, heading, accuracies, PDOP, fix, satellites, a UTC timestamp, time accuracy, and the epoch age that places each fix on the device's clock.
- IMU: filtered accelerations and rotation rates in ISO 8855 vehicle axes.
- Vehicle: engine, temperatures, pressures, boost, brake and clutch, steering, the car's own yaw and accelerations, wheel speeds, gear, and four aux fields.
- Metric units, speeds in km/h.
- One set of BLE UUIDs for every Gnimu device; Schema and Device info characteristics; the standard Device Information Service.
- One client at a time. Control requires a bonded connection, with new bonds only in a window after power-up.
- C++11 and Python reference encoders and decoders, and six test vectors.
