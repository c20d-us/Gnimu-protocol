# Gnimu protocol - one telemetry frame for the Gnimu family
# Copyright 2026 Chris Halstead
# SPDX-License-Identifier: Apache-2.0

"""Tests for the spec and the Python reference encoder. Run: python3 -m unittest discover tests"""

import json
import os
import sys
import unittest

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
sys.path.insert(0, os.path.join(ROOT, "tools"))

import gnimu_frame  # noqa: E402
import generate  # noqa: E402


def load_vectors():
    with open(os.path.join(ROOT, "vectors", "v1.json"), encoding="utf-8") as f:
        return json.load(f)


class SpecTest(unittest.TestCase):
    def test_spec_is_consistent(self):
        generate.validate(gnimu_frame.load_spec())

    def test_fields_do_not_overlap(self):
        spec = gnimu_frame.load_spec()
        used = [False] * spec["frame_bytes"]
        entries = spec["header"] + [f for b in spec["blocks"] for f in b["fields"]]
        for f in entries:
            for i in range(f["offset"], f["offset"] + spec["types"][f["type"]]):
                self.assertFalse(used[i], "byte %d used twice (%s)" % (i, f["key"]))
                used[i] = True
        self.assertTrue(all(used))


class VectorTest(unittest.TestCase):
    def test_encoder_matches_vectors(self):
        for v in load_vectors():
            with self.subTest(v["name"]):
                frame = gnimu_frame.encode(v["header"], v["values"], v.get("fresh", []))
                self.assertEqual(frame.hex(), v["hex"])

    def test_decoder_reads_vectors_back(self):
        spec = gnimu_frame.load_spec()
        fields = {f["key"]: f for f in gnimu_frame.numbered_fields(spec)}
        for v in load_vectors():
            with self.subTest(v["name"]):
                header, values, fresh = gnimu_frame.decode(bytes.fromhex(v["hex"]))
                for key in ("device_time_ms", "sequence", "device_type", "state"):
                    self.assertEqual(header[key], v["header"][key])
                self.assertEqual(header["spec_version"], spec["version"])
                self.assertEqual(set(values), set(v["values"]))
                self.assertEqual(fresh, set(v.get("fresh", [])))
                for key, expected in v["values"].items():
                    f = fields[key]
                    expected_raw = gnimu_frame.to_raw(f, expected)
                    self.assertEqual(gnimu_frame.to_raw(f, values[key]), expected_raw, key)


class EncodingTest(unittest.TestCase):
    def setUp(self):
        spec = gnimu_frame.load_spec()
        self.fields = {f["key"]: f for f in gnimu_frame.numbered_fields(spec)}

    def test_rounds_half_away_from_zero(self):
        self.assertEqual(gnimu_frame.to_raw(self.fields["steering_angle"], 12.25), 123)
        self.assertEqual(gnimu_frame.to_raw(self.fields["steering_angle"], -12.25), -123)

    def test_saturates_instead_of_wrapping(self):
        self.assertEqual(gnimu_frame.to_raw(self.fields["yaw_rate"], 5000), 32767)
        self.assertEqual(gnimu_frame.to_raw(self.fields["yaw_rate"], -5000), -32768)
        self.assertEqual(gnimu_frame.to_raw(self.fields["ground_speed"], -1), 0)

    def test_rejects_wrong_length(self):
        with self.assertRaises(ValueError):
            gnimu_frame.decode(bytes(20))


if __name__ == "__main__":
    unittest.main()
