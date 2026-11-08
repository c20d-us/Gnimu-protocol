#!/usr/bin/env bash
# Gnimu protocol - one telemetry frame for the Gnimu family
# Copyright 2026 Chris Halstead
# SPDX-License-Identifier: Apache-2.0

# Usage: tests/run.sh
#
# Checks the generated files are current, then runs the Python, C++ and Swift
# reference tests against the shared test vectors. The C++ builds as C++11,
# the oldest standard the Gnimu firmware compiles with, with warnings as errors.
# The Swift tests are skipped, with a note, where there's no Swift toolchain.
set -euo pipefail
cd "$(dirname "$0")/.."

python3 tools/generate.py --check
python3 -m unittest discover -s tests -v 2>&1 | tail -n 3

out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
${CXX:-c++} -std=c++11 -Wall -Wextra -Werror -o "$out/test_frame" tests/test_frame.cpp
"$out/test_frame"

if command -v swift >/dev/null 2>&1; then
  if swift test >"$out/swift.log" 2>&1; then
    echo "Swift reference: $(grep -E 'Test run with' "$out/swift.log" | sed 's/^[^T]*//')"
  else
    tail -n 40 "$out/swift.log" >&2
    exit 1
  fi
else
  echo "Swift not found: skipping the Swift reference tests"
fi
