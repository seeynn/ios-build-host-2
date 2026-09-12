import Foundation

enum WebfootDecodeError: Error, CustomStringConvertible {
    case unsupportedType(UInt32)
    case truncatedInput
    case invalidBackReference(distance: Int, produced: Int)
    case decodedSizeMismatch(expected: Int, actual: Int)
    case runawayOutput(Int)

    var description: String {
        switch self {
        case .unsupportedType(let type): return "Unsupported Webfoot resource type \(type)"
        case .truncatedInput: return "Compressed Webfoot stream ended unexpectedly"
        case .invalidBackReference(let distance, let produced):
            return "Invalid Webfoot back-reference distance \(distance) with \(produced) bytes produced"
        case .decodedSizeMismatch(let expected, let actual):
            return "Webfoot decoded-size mismatch: expected \(expected), produced \(actual)"
        case .runawayOutput(let count): return "Webfoot decoder exceeded safety limit at \(count) bytes"
        }
    }
}

enum WebfootDecoder {
    struct Result {
        let data: Data
        let bytesConsumed: Int
        let declaredSize: Int
    }

    private struct BitReader {
        let source: Data
        var byteOffset: Int
        var word: UInt32 = 0
        var remaining = 0

        mutating func readBit() throws -> Int {
            if remaining == 0 { try refill() }
            let bit = Int((word >> 31) & 1)
            word &<<= 1
            remaining -= 1
            return bit
        }

        mutating func readBits(_ count: Int) throws -> Int {
            precondition(count >= 0 && count <= 31)
            var need = count
            var value = 0
            while need > 0 {
                if remaining == 0 { try refill() }
                let take = min(need, remaining)
                let mask: UInt32 = take == 32 ? .max : ((UInt32(1) << UInt32(take)) - 1)
                let part = Int((word >> UInt32(32 - take)) & mask)
                value = (value << take) | part
                word &<<= UInt32(take)
                remaining -= take
                need -= take
            }
            return value
        }

        mutating func refill() throws {
            guard byteOffset + 4 <= source.count else { throw WebfootDecodeError.truncatedInput }
            let b0 = UInt32(source[byteOffset])
            let b1 = UInt32(source[byteOffset + 1]) << 8
            let b2 = UInt32(source[byteOffset + 2]) << 16
            let b3 = UInt32(source[byteOffset + 3]) << 24
            word = b0 | b1 | b2 | b3
            byteOffset += 4
            remaining = 32
        }
    }

    static func decodeResource(in rom: ROMImage, at offset: Int) throws -> Result {
        let type = try rom.u32(offset)
        let declared = Int(try rom.u32(offset + 4))
        guard type == 1 else { throw WebfootDecodeError.unsupportedType(type) }

        var reader = BitReader(source: rom.data, byteOffset: offset + 8)
        var output = [UInt8]()
        output.reserveCapacity(declared)

        var literalBitCount = 1
        var deltaBase = 0
        var distanceBitCount = 8
        var lastDistance = 1

        func checkDistance(_ distance: Int, _ produced: Int) throws {
            guard distance > 0 && distance <= produced else {
                throw WebfootDecodeError.invalidBackReference(distance: distance, produced: produced)
            }
        }

        func ensureCapacitySafety(_ count: Int) throws {
            if count > max(declared + 4096, declared * 2) {
                throw WebfootDecodeError.runawayOutput(count)
            }
        }

        func copyBackReference(distance: Int, length: Int, into out: inout [UInt8]) throws {
            try checkDistance(distance, out.count)
            for _ in 0..<length {
                out.append(out[out.count - distance])
                try ensureCapacitySafety(out.count)
            }
        }

        func readPrefix(_ br: inout BitReader) throws -> Int {
            var value = 1
            while true {
                value = (value << 1) + (try br.readBit())
                if try br.readBit() == 0 { return value }
            }
        }

        while true {
            try ensureCapacitySafety(output.count)

            if try reader.readBit() == 1 {
                let value = try reader.readBits(literalBitCount)
                output.append(UInt8(truncatingIfNeeded: value + deltaBase))
                continue
            }

            if try reader.readBit() == 1 {
                var prefix = try readPrefix(&reader)
                var length: Int
                if prefix == 2 {
                    length = try readPrefix(&reader)
                } else {
                    prefix -= 3
                    let low = try reader.readBits(distanceBitCount)
                    lastDistance = low + (prefix << distanceBitCount)
                    length = try readPrefix(&reader)
                    if lastDistance >= 0x10000 { length += 3 }
                    else if lastDistance >= 0x37FF { length += 2 }
                    else if lastDistance >= 0x027F { length += 1 }
                    else if lastDistance <= 127 { length += 4 }
                }
                try copyBackReference(distance: lastDistance, length: length, into: &output)
                continue
            }

            if try reader.readBit() == 0 {
                let distance = try reader.readBits(7)
                if distance != 0 {
                    lastDistance = distance
                    let length = try reader.readBits(2) + 2
                    try copyBackReference(distance: lastDistance, length: length, into: &output)
                    continue
                }

                let control = try reader.readBits(2)
                if control == 0 {
                    guard output.count == declared else {
                        throw WebfootDecodeError.decodedSizeMismatch(expected: declared, actual: output.count)
                    }
                    return Result(data: Data(output), bytesConsumed: reader.byteOffset - (offset + 8), declaredSize: declared)
                }
                distanceBitCount = try reader.readBits(control + 3)
                continue
            }

            let tiny = try reader.readBits(4) - 1
            if tiny == 0 {
                output.append(UInt8(truncatingIfNeeded: deltaBase))
                continue
            }
            if tiny > 0 {
                try checkDistance(tiny, output.count)
                let value = Int(output[output.count - tiny]) + deltaBase
                output.append(UInt8(truncatingIfNeeded: value))
                continue
            }

            if try reader.readBit() == 1 {
                repeat {
                    for _ in 0..<4 { output.append(UInt8(try reader.readBits(8))) }
                    try ensureCapacitySafety(output.count)
                } while try reader.readBit() == 1
                continue
            }

            deltaBase = 0
            let modeBit = try reader.readBit()
            literalBitCount = 7 + modeBit
            if literalBitCount == 8 { continue }
            deltaBase = try reader.readBits(8)
        }
    }
}
