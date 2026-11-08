// Gnimu protocol - one telemetry frame for the Gnimu family
// Copyright 2026 Chris Halstead
// SPDX-License-Identifier: Apache-2.0

// Reference decoder for the Gnimu frame, v1, in plain Swift with no platform
// dependencies. The layout itself (offsets, types, scales) is in
// LayoutV1.swift, which is generated from spec/frame-v1.json.
//
// Types are marked `nonisolated` so the files also work copied into an app that
// defaults its own code to the main actor. That needs Swift 6.1 or later.
//
// A frame is accepted if it is exactly the spec's length and carries the spec
// version this decoder reads. Anything else the spec allows to vary within v1 is
// tolerated: reserved capability bits, reserved state values, and valid-mask
// bits with no field yet (a later field in a block's spare bytes takes the next
// bit, and stays v1).

extension GnimuFrameV1.WireType {
    /// Bytes the type takes on the wire.
    public nonisolated var width: Int {
        switch self {
        case .u8: return 1
        case .i16, .u16: return 2
        case .i32: return 4
        case .f64: return 8
        }
    }
}

extension GnimuFrameV1 {

    /// The header's capability bits: the blocks the device fills, whatever it
    /// has right now (the blocks' valid masks say that). Bits 4-7 are reserved
    /// and kept as received.
    public nonisolated struct Capabilities: OptionSet, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }

        public static let gnss = Capabilities(rawValue: 1)
        public static let imu = Capabilities(rawValue: 2)
        public static let vehicle = Capabilities(rawValue: 4)
        public static let power = Capabilities(rawValue: 8)
    }

    /// The device's own condition, meaning the same on every Gnimu device.
    public nonisolated enum DeviceState: UInt8, Sendable {
        case unknown = 0
        case starting = 1
        case running = 2
        case waiting = 3
        case fault = 4
    }

    public nonisolated enum DecodeError: Error, Equatable, Sendable {
        /// Not exactly `frameBytes` long. Carries the length received.
        case wrongLength(Int)
        /// A spec version this decoder doesn't read. Carries the byte received.
        case unsupportedVersion(UInt8)
    }

    /// One received frame. Fields are read by `Field`, in the units the spec
    /// lists (degrees, km/h, g, and so on), and are `nil` when the device has
    /// not marked them valid.
    public nonisolated struct Frame: Sendable {
        /// Milliseconds since the device booted. Wraps after 2^31 ms.
        public let deviceTimeMs: Int32
        /// Counts up by one per frame, wrapping at 255. A gap means a lost frame.
        public let sequence: UInt8
        public let specVersion: UInt8
        public let capabilities: Capabilities
        /// The state byte as received, including reserved values.
        public let stateRaw: UInt8

        private let bytes: [UInt8]

        /// The state, or `.unknown` for a value this decoder doesn't know.
        public var state: DeviceState { DeviceState(rawValue: stateRaw) ?? .unknown }

        public init<Bytes: Collection>(_ received: Bytes) throws where Bytes.Element == UInt8 {
            guard received.count == GnimuFrameV1.frameBytes else {
                throw DecodeError.wrongLength(received.count)
            }
            let b = Array(received)
            let version = b[GnimuFrameV1.specVersionOffset]
            guard version == GnimuFrameV1.specVersion else {
                throw DecodeError.unsupportedVersion(version)
            }
            bytes = b
            deviceTimeMs = Int32(bitPattern: UInt32(truncatingIfNeeded:
                Frame.littleEndian(b, at: GnimuFrameV1.deviceTimeMsOffset, count: 4)))
            sequence = b[GnimuFrameV1.sequenceOffset]
            specVersion = version
            capabilities = Capabilities(rawValue: b[GnimuFrameV1.capabilitiesOffset])
            stateRaw = b[GnimuFrameV1.stateOffset]
        }

        /// A block's valid mask, as received.
        public func mask(of block: Block) -> UInt32 {
            let info = GnimuFrameV1.blocks[block.rawValue]
            return UInt32(truncatingIfNeeded:
                Frame.littleEndian(bytes, at: info.maskOffset, count: info.maskBytes))
        }

        /// Whether the device marked the field valid.
        public func isValid(_ field: Field) -> Bool {
            let info = GnimuFrameV1.fields[field.rawValue]
            let maskOffset = GnimuFrameV1.blocks[info.block.rawValue].maskOffset
            return (bytes[maskOffset + info.bit / 8] >> UInt8(info.bit % 8)) & 1 != 0
        }

        /// The field in the spec's units, or `nil` if it isn't valid. Aux fields
        /// have no fixed scale; their value is the raw integer.
        public func value(_ field: Field) -> Double? {
            guard isValid(field) else { return nil }
            let info = GnimuFrameV1.fields[field.rawValue]
            let u = Frame.littleEndian(bytes, at: info.offset, count: info.type.width)
            let raw: Double
            switch info.type {
            case .f64: return Double(bitPattern: u)
            case .u8: raw = Double(UInt8(truncatingIfNeeded: u))
            case .u16: raw = Double(UInt16(truncatingIfNeeded: u))
            case .i16: raw = Double(Int16(bitPattern: UInt16(truncatingIfNeeded: u)))
            case .i32: raw = Double(Int32(bitPattern: UInt32(truncatingIfNeeded: u)))
            }
            return info.scale == 0 ? raw : raw / Double(info.scale)
        }

        private static func littleEndian(_ b: [UInt8], at offset: Int, count: Int) -> UInt64 {
            var v: UInt64 = 0
            for i in 0..<count { v |= UInt64(b[offset + i]) << UInt64(8 * i) }
            return v
        }
    }
}
