// Gnimu protocol - one telemetry frame for the Gnimu family
// Copyright 2026 Chris Halstead
// SPDX-License-Identifier: Apache-2.0

// Checks the C++ reference encoder and decoder against the same test vectors
// as the Python reference. Built and run by tests/run.sh.

#include <stdio.h>
#include <string.h>

#include "../include/gnimu_frame/frame_v1.h"

using namespace gnimu_frame::v1;

namespace {

struct VectorValue {
  Field field;
  double value;
  bool fresh;
};

struct Vector {
  const char *name;
  int32_t deviceTimeMs;
  uint8_t sequence;
  uint8_t deviceType;
  uint8_t state;
  const VectorValue *values;
  size_t count;
  const char *hex;
};

#include "vectors_v1.inc"

int failures = 0;

void check(bool ok, const char *vector, const char *what) {
  if (!ok) {
    printf("FAIL %s: %s\n", vector, what);
    failures++;
  }
}

void toHex(const uint8_t *p, size_t n, char *out) {
  for (size_t i = 0; i < n; i++) snprintf(out + 2 * i, 3, "%02x", p[i]);
}

void testVector(const Vector &v) {
  Encoder enc;
  enc.begin(v.deviceTimeMs, v.sequence, v.deviceType, v.state);
  for (size_t i = 0; i < v.count; i++) enc.set(v.values[i].field, v.values[i].value, v.values[i].fresh);
  const uint8_t *frame = enc.finish();

  char hex[2 * kFrameBytes + 1];
  toHex(frame, kFrameBytes, hex);
  check(strcmp(hex, v.hex) == 0, v.name, "encoded bytes differ from the vector");

  Decoder dec(frame);
  check(dec.deviceTimeMs() == v.deviceTimeMs, v.name, "device time");
  check(dec.sequence() == v.sequence, v.name, "sequence");
  check(dec.specVersion() == kSpecVersion, v.name, "spec version");
  check(dec.deviceType() == v.deviceType, v.name, "device type");
  check(dec.state() == v.state, v.name, "state");
  for (size_t i = 0; i < v.count; i++) {
    check(dec.valid(v.values[i].field), v.name, "valid bit");
    check(dec.fresh(v.values[i].field) == v.values[i].fresh, v.name, "fresh bit");
  }
}

void testDecoderUnits() {
  Encoder enc;
  enc.begin(0, 0, 3, 2);
  enc.set(Field::AccelYFiltered, -0.85, true);
  enc.set(Field::Latitude, 47.6205063, true);
  enc.set(Field::Gear, -1, false);
  Decoder dec(enc.finish());
  check(dec.value(Field::AccelYFiltered) == -0.85, "units", "accel y");
  check(dec.value(Field::Latitude) == 47.6205063, "units", "latitude");
  check(dec.value(Field::Gear) == -1, "units", "gear");
  check(!dec.valid(Field::EngineSpeed) && dec.value(Field::EngineSpeed) == 0, "units", "unset field");
}

}  // namespace

int main() {
  for (const Vector &v : kVectors) testVector(v);
  testDecoderUnits();
  if (failures) return 1;
  printf("C++ reference: %u vectors passed\n", static_cast<unsigned>(sizeof(kVectors) / sizeof(kVectors[0])));
  return 0;
}
