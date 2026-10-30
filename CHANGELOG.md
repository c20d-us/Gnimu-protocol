# Changelog

## v1 (draft, unreleased)

- First draft of the Gnimu frame: 164 bytes, 60 fields in header, GNSS, IMU, vehicle and power blocks, with spare fields in each.
- Covers every value in the RaceBox data message, with its status flags expressed as valid-bit rules.
- C++11 and Python reference encoders and decoders, and six test vectors.
