// swift-tools-version: 5.9
// Gnimu protocol - one telemetry frame for the Gnimu family
// Copyright 2026 Chris Halstead
// SPDX-License-Identifier: Apache-2.0

// The Swift reference decoder as a package, so `swift test` can check it and a
// Swift app can depend on it. An app can instead copy the two files in
// swift/Sources/GnimuFrame into its own source tree, as firmware copies the C++
// headers.

import PackageDescription

let package = Package(
    name: "GnimuFrame",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "GnimuFrame", targets: ["GnimuFrame"]),
    ],
    targets: [
        .target(name: "GnimuFrame", path: "swift/Sources/GnimuFrame"),
        .testTarget(name: "GnimuFrameTests", dependencies: ["GnimuFrame"], path: "swift/Tests/GnimuFrameTests"),
    ]
)
