<p>
  <img src="https://raw.githubusercontent.com/c20d-us/Gnimu-branding/main/svg/gnimu-icon-default-rounded.svg" alt="Gnimu icon" height="72">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/c20d-us/Gnimu-branding/main/wordmark/gnimu-wordmark-transparent-white.svg">
    <img src="https://raw.githubusercontent.com/c20d-us/Gnimu-branding/main/wordmark/gnimu-wordmark-transparent-navy.svg" alt="gnimu" height="72">
  </picture>
</p>

# Gnimu protocol: one telemetry frame for the Gnimu family

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![Spec: v1 in progress](https://img.shields.io/badge/spec-v1%20in%20progress-orange.svg)](docs/frame.md)
[![Reference: C++11 and Python](https://img.shields.io/badge/reference-C%2B%2B11%20%7C%20Python-00599C.svg)](#reference-implementations)

The Gnimu protocol defines how Gnimu-family devices stream telemetry over BLE (Bluetooth Low Energy): [Gnimu](https://github.com/c20d-us/Gnimu) (GNSS+IMU), [Gnimu-CAN](https://github.com/c20d-us/Gnimu-CAN) (vehicle CAN data), and a potential all-in-one device that merges them into one stream.

At its core is one fixed-layout frame, used by every device. Every field has an offset, type, scale and meaning. Every device also uses the same BLE UUIDs, so an app set up for one Gnimu device works with all of them. A device fills the blocks it has and leaves the rest zero and marked invalid. A single published table is enough to read any Gnimu device, in a Gnimu tool or in any app that maps fields by byte offset, such as [AutoX Data Logger](https://autoxdrivermod.com)'s custom BLE sensor.

> [!NOTE]
> **In progress.** v1 is complete enough to implement, with reference implementations and test vectors, but it isn't published and nothing depends on it yet, so it can still change. Gnimu-CAN will be the first device to send it. The Control and Stream characteristics are still to be defined.

---

## The frame at a glance

140 bytes, little-endian, sent at a fixed rate while a client is subscribed.

| Block | Offset | Bytes | Contents |
|---|---|---|---|
| Header | 0 | 8 | Device time, sequence, spec version, capabilities, state |
| GNSS | 8 | 48 | Position, altitude, speed, heading, accuracies, PDOP, fix, satellites, UTC timestamp, epoch age |
| IMU | 56 | 15 | Filtered accelerations and rotation rates, in vehicle axes |
| Vehicle | 71 | 62 | RPM, throttle, speeds, temperatures (including ambient), pressures, boost, brake and clutch, steering, the car's own yaw and accelerations, wheel speeds, gear, aux |
| Power | 133 | 7 | Supply voltage, battery charge, charging |

Each block starts with its own valid mask, so a block can be read without the rest of the frame.

The full specification, with every field, the axis and sign conventions, the BLE UUIDs and security, and the versioning rules, is in **[docs/frame.md](docs/frame.md)**.

---

## Repo layout

```
spec/frame-v1.json       The source of truth: every field's offset, type, scale and unit
docs/frame.md            The specification (its field tables are generated from the JSON)
include/gnimu_frame/     C++11 reference encoder and decoder, for firmware and host tools
  frame_v1.h             Encoder and Decoder classes (hand-written)
  layout_v1.h            Offsets, types, scales and mask bits (generated)
tools/
  gnimu_frame.py         Python reference encoder and decoder
  generate.py            Validates the spec and regenerates everything derived from it
vectors/v1.json          Test vectors: example frames with their values and exact bytes
tests/                   Python and C++ tests against the vectors
```

## Changing the spec

1. Edit [`spec/frame-v1.json`](spec/frame-v1.json), and the prose in [`docs/frame.md`](docs/frame.md) if needed.
2. Run `tools/generate.py`. It validates the layout (no gaps or overlaps, each block's mask first and its fields' bits in order, mask sizes, within the length cap) and regenerates the C++ layout header, the C++ test data and the doc's field tables.
3. If the change alters any vector's bytes, run `tools/generate.py --update-vectors` and check the new hex is what you intended. The vectors are the fixed reference both encoders are tested against, so they only change on purpose.
4. Run `tests/run.sh`.

Python 3.9 or later and a C++11 compiler are all it needs; there are no packages to install.

## Reference implementations

- **C++** ([`include/gnimu_frame/frame_v1.h`](include/gnimu_frame/frame_v1.h)): header-only C++11 with no platform dependencies. Firmware copies the two headers in `include/gnimu_frame/` into its own source tree, and notes the spec version it copied.
- **Python** ([`tools/gnimu_frame.py`](tools/gnimu_frame.py)): encode and decode by field name, for host tools and tests.

Both round half away from zero and saturate out-of-range values, and both produce exactly the bytes in [`vectors/v1.json`](vectors/v1.json).

## Testing

```bash
tests/run.sh
```

It checks the generated files are current, then runs the Python tests and the C++ tests (built as C++11 with warnings as errors) against the shared vectors. Run it before committing a spec change.

---

## License & Terms

Copyright 2026 Chris Halstead. The specification, reference implementations, tools and test vectors are licensed under the [Apache License, Version 2.0](LICENSE). You can implement the protocol in any software, open or closed source, and the license includes a patent grant from contributors.

The Gnimu firmware and hardware are separate works under their own licenses; see their repositories.

The Gnimu name and logo are not covered by this license. See the [Gnimu branding usage policy](https://github.com/c20d-us/Gnimu-branding/blob/main/LICENSE.md).
