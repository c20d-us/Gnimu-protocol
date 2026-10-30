# Gnimu protocol - one telemetry frame for the Gnimu family
# Copyright 2026 Chris Halstead
# SPDX-License-Identifier: Apache-2.0

"""Reference encoder and decoder for the Gnimu frame, driven by spec/frame-v1.json.

Values are in the units the spec lists (degrees, km/h, g, ...). Encoding
multiplies by the field's scale, rounds half away from zero, and saturates to
the field's type. Aux fields have no fixed scale, so they take raw integers.
"""

import json
import math
import os
import struct

SPEC_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "spec", "frame-v1.json")

# struct format and integer range per wire type.
TYPES = {
    "u8": ("<B", 0, 0xFF),
    "i16": ("<h", -0x8000, 0x7FFF),
    "u16": ("<H", 0, 0xFFFF),
    "i32": ("<i", -0x80000000, 0x7FFFFFFF),
    "f64": ("<d", None, None),
    "mask64": ("<Q", 0, 0xFFFFFFFFFFFFFFFF),
}


def load_spec(path=SPEC_PATH):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def numbered_fields(spec):
    """Every field with a field number, in number order."""
    out = [f for b in spec["blocks"] for f in b["fields"] if "number" in f]
    return sorted(out, key=lambda f: f["number"])


def _round_half_away(x):
    return int(math.floor(abs(x) + 0.5)) * (1 if x >= 0 else -1)


def to_raw(field, value):
    """Engineering value to the integer (or float) that goes on the wire."""
    fmt, lo, hi = TYPES[field["type"]]
    if field["type"] == "f64":
        return float(value)
    scale = field["scale"]
    raw = _round_half_away(value * scale) if scale is not None else int(value)
    return max(lo, min(hi, raw))


def from_raw(field, raw):
    if field["type"] == "f64" or field["scale"] is None:
        return raw
    return raw / field["scale"]


def encode(header, values, fresh=(), spec=None):
    """Builds one frame.

    header: device_time_ms, sequence, device_type, state.
    values: {field key: value}; every key present is marked valid.
    fresh:  field keys to mark fresh.
    """
    spec = spec or load_spec()
    frame = bytearray(spec["frame_bytes"])
    by_key = {f["key"]: f for f in numbered_fields(spec)}
    hdr = {f["key"]: f for f in spec["header"]}

    valid_mask = 0
    fresh_mask = 0
    for key, value in values.items():
        field = by_key[key]
        struct.pack_into(TYPES[field["type"]][0], frame, field["offset"], to_raw(field, value))
        valid_mask |= 1 << field["number"]
    for key in fresh:
        fresh_mask |= 1 << by_key[key]["number"]

    struct.pack_into("<i", frame, hdr["device_time_ms"]["offset"], header["device_time_ms"])
    frame[hdr["sequence"]["offset"]] = header["sequence"] & 0xFF
    frame[hdr["spec_version"]["offset"]] = spec["version"]
    frame[hdr["device_type"]["offset"]] = header["device_type"]
    frame[hdr["state"]["offset"]] = header["state"]
    struct.pack_into("<Q", frame, hdr["valid_mask"]["offset"], valid_mask)
    struct.pack_into("<Q", frame, hdr["fresh_mask"]["offset"], fresh_mask)
    return bytes(frame)


def decode(frame, spec=None):
    """Returns (header dict, {key: value} for valid fields, set of fresh keys)."""
    spec = spec or load_spec()
    if len(frame) != spec["frame_bytes"]:
        raise ValueError("frame is %d bytes, expected %d" % (len(frame), spec["frame_bytes"]))
    header = {}
    for f in spec["header"]:
        header[f["key"]] = struct.unpack_from(TYPES[f["type"]][0], frame, f["offset"])[0]
    values = {}
    fresh = set()
    for field in numbered_fields(spec):
        bit = 1 << field["number"]
        if header["valid_mask"] & bit:
            raw = struct.unpack_from(TYPES[field["type"]][0], frame, field["offset"])[0]
            values[field["key"]] = from_raw(field, raw)
        if header["fresh_mask"] & bit:
            fresh.add(field["key"])
    return header, values, fresh
