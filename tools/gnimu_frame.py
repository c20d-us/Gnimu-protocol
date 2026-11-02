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
}

MASK_BYTES = {"mask8": 1, "mask16": 2, "mask32": 4}


def load_spec(path=SPEC_PATH):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def data_fields(spec):
    """Every data field as (block, field), in frame order: not masks or spares."""
    return [(b, f) for b in spec["blocks"] for f in b["fields"] if f["type"] in TYPES]


def _mask(block):
    return block["fields"][0]


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


def encode(header, values, spec=None):
    """Builds one frame.

    header: device_time_ms, sequence, capabilities, state.
    values: {field key: value}; every key present is marked valid in its block's mask.
    """
    spec = spec or load_spec()
    frame = bytearray(spec["frame_bytes"])
    by_key = {f["key"]: (b, f) for b, f in data_fields(spec)}
    hdr = {f["key"]: f for f in spec["header"]}

    masks = {b["key"]: 0 for b in spec["blocks"]}
    for key, value in values.items():
        block, field = by_key[key]
        struct.pack_into(TYPES[field["type"]][0], frame, field["offset"], to_raw(field, value))
        masks[block["key"]] |= 1 << field["bit"]
    for b in spec["blocks"]:
        m = _mask(b)
        frame[m["offset"]:m["offset"] + MASK_BYTES[m["type"]]] = masks[b["key"]].to_bytes(MASK_BYTES[m["type"]], "little")

    struct.pack_into("<i", frame, hdr["device_time_ms"]["offset"], header["device_time_ms"])
    frame[hdr["sequence"]["offset"]] = header["sequence"] & 0xFF
    frame[hdr["spec_version"]["offset"]] = spec["version"]
    frame[hdr["capabilities"]["offset"]] = header["capabilities"]
    frame[hdr["state"]["offset"]] = header["state"]
    return bytes(frame)


def decode(frame, spec=None):
    """Returns (header dict, {key: value} for valid fields)."""
    spec = spec or load_spec()
    if len(frame) != spec["frame_bytes"]:
        raise ValueError("frame is %d bytes, expected %d" % (len(frame), spec["frame_bytes"]))
    header = {f["key"]: struct.unpack_from(TYPES[f["type"]][0], frame, f["offset"])[0] for f in spec["header"]}
    values = {}
    for b in spec["blocks"]:
        m = _mask(b)
        mask = int.from_bytes(frame[m["offset"]:m["offset"] + MASK_BYTES[m["type"]]], "little")
        for field in b["fields"][1:]:
            if field["type"] in TYPES and mask & (1 << field["bit"]):
                raw = struct.unpack_from(TYPES[field["type"]][0], frame, field["offset"])[0]
                values[field["key"]] = from_raw(field, raw)
    return header, values
