// Gnimu protocol - one telemetry frame for the Gnimu family
// Copyright 2026 Chris Halstead
// SPDX-License-Identifier: Apache-2.0

// Checks the Swift reference decoder against the same test vectors as the Python
// and C++ references, then covers what the vectors don't: rejection, tolerance
// of what the spec lets vary within v1, and the layout's own consistency.
// Built and run by tests/run.sh, or with `swift test`.

import Testing
@testable import GnimuFrame

private typealias V1 = GnimuFrameV1

private func bytes(fromHex hex: String) -> [UInt8] {
    var out: [UInt8] = []
    var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        out.append(UInt8(hex[index..<next], radix: 16)!)
        index = next
    }
    return out
}

/// A frame of zeros with the spec version set, so it decodes with nothing valid.
private func blankFrame() -> [UInt8] {
    var b = [UInt8](repeating: 0, count: V1.frameBytes)
    b[V1.specVersionOffset] = V1.specVersion
    return b
}

private func setValid(_ frame: inout [UInt8], _ field: V1.Field) {
    let info = V1.fields[field.rawValue]
    let maskOffset = V1.blocks[info.block.rawValue].maskOffset
    frame[maskOffset + info.bit / 8] |= UInt8(1 << (info.bit % 8))
}

private func put(_ frame: inout [UInt8], _ field: V1.Field, raw: UInt64) {
    let info = V1.fields[field.rawValue]
    for i in 0..<info.type.width {
        frame[info.offset + i] = UInt8((raw >> UInt64(8 * i)) & 0xFF)
    }
}

// MARK: - The shared vectors

struct VectorTests {
    @Test(arguments: gnimuFrameV1TestVectors)
    func decodesTheVectorExactly(_ vector: GnimuFrameV1TestVector) throws {
        let frame = try V1.Frame(bytes(fromHex: vector.hex))

        #expect(frame.deviceTimeMs == vector.deviceTimeMs)
        #expect(frame.sequence == vector.sequence)
        #expect(frame.specVersion == V1.specVersion)
        #expect(frame.capabilities.rawValue == vector.capabilities)
        #expect(frame.stateRaw == vector.state)

        var decoded: [String: Double] = [:]
        for field in V1.Field.allCases {
            let key = V1.fields[field.rawValue].key
            let value = frame.value(field)
            #expect(frame.isValid(field) == (value != nil), "\(key)")
            if let value { decoded[key] = value }
        }
        #expect(decoded == vector.values)
    }

    @Test func thereAreSixVectors() {
        #expect(gnimuFrameV1TestVectors.count == 6)
    }
}

// MARK: - Rejection

struct RejectionTests {
    @Test(arguments: [0, 1, 20, 139, 141, 182])
    func wrongLengthIsRejected(length: Int) {
        #expect(throws: V1.DecodeError.wrongLength(length)) {
            try V1.Frame([UInt8](repeating: 0, count: length))
        }
    }

    @Test(arguments: [UInt8(0), 2, 255])
    func anotherSpecVersionIsRejected(version: UInt8) {
        var frame = blankFrame()
        frame[V1.specVersionOffset] = version
        #expect(throws: V1.DecodeError.unsupportedVersion(version)) { try V1.Frame(frame) }
    }

    @Test func aCollectionOtherThanAnArrayWorks() throws {
        let slice = ([0xFF] + blankFrame() + [0xFF])[1...V1.frameBytes]
        #expect(try V1.Frame(slice).sequence == 0)
    }
}

// MARK: - What may vary within v1

struct ToleranceTests {
    @Test func reservedStateValuesReadAsUnknownButAreKept() throws {
        for (raw, expected) in [(0, V1.DeviceState.unknown), (1, .starting), (2, .running),
                                (3, .waiting), (4, .fault), (5, .unknown), (255, .unknown)] {
            var frame = blankFrame()
            frame[V1.stateOffset] = UInt8(raw)
            let decoded = try V1.Frame(frame)
            #expect(decoded.state == expected, "state \(raw)")
            #expect(decoded.stateRaw == UInt8(raw))
        }
    }

    @Test func reservedCapabilityBitsAreKeptAndDontHideTheRealOnes() throws {
        var frame = blankFrame()
        frame[V1.capabilitiesOffset] = 0xF0 | 12
        let c = try V1.Frame(frame).capabilities
        #expect(c.rawValue == 0xFC)
        #expect(c.contains(.vehicle) && c.contains(.power))
        #expect(!c.contains(.gnss) && !c.contains(.imu))
    }

    @Test func validMaskBitsWithNoFieldYetAreIgnored() throws {
        // Every bit of every mask set, including the spare ones a later field
        // would take. Only the fields defined today read as valid.
        var frame = blankFrame()
        for block in V1.Block.allCases {
            let info = V1.blocks[block.rawValue]
            for i in 0..<info.maskBytes { frame[info.maskOffset + i] = 0xFF }
        }
        let decoded = try V1.Frame(frame)
        #expect(V1.Field.allCases.allSatisfy { decoded.isValid($0) })
        #expect(decoded.mask(of: .gnss) == 0xFFFF)
        #expect(decoded.mask(of: .vehicle) == 0xFFFF_FFFF)
    }

    @Test func eachValidBitMakesExactlyOneFieldValid() throws {
        for field in V1.Field.allCases {
            var frame = blankFrame()
            setValid(&frame, field)
            let decoded = try V1.Frame(frame)
            let valid = V1.Field.allCases.filter { decoded.isValid($0) }
            #expect(valid == [field], "\(V1.fields[field.rawValue].key)")
        }
    }

    @Test func aFieldThatIsntValidReadsAsNilWhateverItsBytesHold() throws {
        var frame = blankFrame()
        put(&frame, .engineSpeed, raw: 0x1234)
        let decoded = try V1.Frame(frame)
        #expect(decoded.value(.engineSpeed) == nil)
    }
}

// MARK: - Reading values

struct ValueTests {
    @Test func latitudeIsReadFromItsUnalignedOffset() throws {
        var frame = blankFrame()
        let info = V1.fields[V1.Field.latitude.rawValue]
        #expect(info.offset % 8 != 0)                       // not 8-byte aligned, as the spec warns
        put(&frame, .latitude, raw: (-33.8688).bitPattern)
        setValid(&frame, .latitude)
        #expect(try V1.Frame(frame).value(.latitude) == -33.8688)
    }

    @Test func signedFieldsReadNegative() throws {
        var frame = blankFrame()
        put(&frame, .gear, raw: UInt64(UInt16(bitPattern: -1)))
        put(&frame, .boost, raw: UInt64(UInt16(bitPattern: -123)))      // 12.3 kPa under vacuum, scale 10
        put(&frame, .altitudeMsl, raw: UInt64(UInt32(bitPattern: -4500)))  // -4.5 m, scale 1000
        for f in [V1.Field.gear, .boost, .altitudeMsl] { setValid(&frame, f) }
        let decoded = try V1.Frame(frame)
        #expect(decoded.value(.gear) == -1)
        #expect(decoded.value(.boost) == -12.3)
        #expect(decoded.value(.altitudeMsl) == -4.5)
    }

    @Test func unsignedFieldsReadTheirFullRange() throws {
        var frame = blankFrame()
        put(&frame, .supplyVoltage, raw: 0xFFFF)            // scale 100
        put(&frame, .satellites, raw: 0xFF)
        setValid(&frame, .supplyVoltage)
        setValid(&frame, .satellites)
        let decoded = try V1.Frame(frame)
        #expect(decoded.value(.supplyVoltage) == 655.35)
        #expect(decoded.value(.satellites) == 255)
    }

    @Test func deviceTimeIsSignedAndLittleEndian() throws {
        var frame = blankFrame()
        frame[0] = 0xFF; frame[1] = 0xFF; frame[2] = 0xFF; frame[3] = 0x7F
        #expect(try V1.Frame(frame).deviceTimeMs == Int32.max)
        frame[3] = 0x80
        #expect(try V1.Frame(frame).deviceTimeMs == Int32.min + 0x00FF_FFFF)
    }

    @Test func auxFieldsAreRawBecauseTheyHaveNoFixedScale() throws {
        var frame = blankFrame()
        put(&frame, .aux1, raw: UInt64(UInt16(bitPattern: -250)))
        setValid(&frame, .aux1)
        #expect(V1.fields[V1.Field.aux1.rawValue].scale == 0)
        #expect(try V1.Frame(frame).value(.aux1) == -250)
    }
}

// MARK: - The layout

struct LayoutTests {
    @Test func tablesAgreeWithTheirCounts() {
        #expect(V1.Field.allCases.count == V1.fieldCount)
        #expect(V1.fields.count == V1.fieldCount)
        #expect(V1.Block.allCases.count == V1.blocks.count)
        for (i, field) in V1.Field.allCases.enumerated() { #expect(field.rawValue == i) }
    }

    @Test func everyByteOfTheFrameIsUsedOnce() {
        var uses = [Int](repeating: 0, count: V1.frameBytes)
        func mark(_ offset: Int, _ count: Int) { for i in offset..<offset + count { uses[i] += 1 } }

        mark(V1.deviceTimeMsOffset, 4)
        mark(V1.sequenceOffset, 1)
        mark(V1.specVersionOffset, 1)
        mark(V1.capabilitiesOffset, 1)
        mark(V1.stateOffset, 1)
        for info in V1.blocks { mark(info.maskOffset, info.maskBytes) }
        for info in V1.fields { mark(info.offset, info.type.width) }

        // What's left is each block's spare bytes: the block's end is its offset
        // plus its size, and the frame ends at the last block's end.
        for info in V1.blocks {
            let lastField = V1.fields.filter { V1.blocks[$0.block.rawValue].offset == info.offset }
                .map { $0.offset + $0.type.width }.max() ?? info.maskOffset + info.maskBytes
            #expect(lastField <= info.offset + info.bytes)
            for i in lastField..<info.offset + info.bytes { uses[i] += 1 }
        }
        #expect(uses.allSatisfy { $0 == 1 })
    }

    @Test func eachFieldSitsInsideItsOwnBlockAndBitsRunInOrder() {
        for block in V1.Block.allCases {
            let info = V1.blocks[block.rawValue]
            let inBlock = V1.fields.filter { $0.block == block }
            #expect(inBlock.map(\.bit) == Array(0..<inBlock.count), "\(block)")
            for f in inBlock {
                #expect(f.offset >= info.maskOffset + info.maskBytes)
                #expect(f.offset + f.type.width <= info.offset + info.bytes)
            }
            // The mask has a free bit for every spare byte, so a later field can take one.
            let used = inBlock.map { $0.offset + $0.type.width }.max() ?? 0
            let spare = info.offset + info.bytes - used
            #expect(info.maskBytes * 8 >= inBlock.count + spare, "\(block)")
        }
    }
}
