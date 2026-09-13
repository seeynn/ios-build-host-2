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
        case .runawayOutput(let count): return "Webfoot decoder exceeded declared output at \(count) bytes"
        }
    }
}

/// Clean-room Swift translation of the Webfoot resource decoder copied by the
/// ALFP ROM from ROM 0x7D6F2C to IWRAM 0x03000000 during startup.
///
/// Resource kind 0 is stored raw. Kinds 1 and 2 share the same bitstream
/// machine, with the kind selecting the initial literal width. Stream bits are
/// consumed MSB-first inside little-endian 32-bit words. This is not Nintendo
/// BIOS LZ77.
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
                let mask = (UInt32(1) << UInt32(take)) - 1
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
        let kind = try rom.u32(offset)
        let declared = Int(try rom.u32(offset + 4))
        guard declared >= 0 else {
            throw WebfootDecodeError.decodedSizeMismatch(expected: 0, actual: declared)
        }

        if kind == 0 {
            let raw = try rom.slice(offset + 8, declared)
            return Result(data: raw, bytesConsumed: declared, declaredSize: declared)
        }
        guard kind == 1 || kind == 2 else {
            throw WebfootDecodeError.unsupportedType(kind)
        }

        var reader = BitReader(source: rom.data, byteOffset: offset + 8)
        var output = [UInt8]()
        output.reserveCapacity(declared)

        var literalBitCount = Int(kind)
        var literalBase = 0
        var distanceBitCount = 8
        var lastDistance = 1

        func ensureRoom(_ additional: Int, produced: Int) throws {
            guard additional >= 0, produced <= declared, additional <= declared - produced else {
                throw WebfootDecodeError.runawayOutput(produced + max(0, additional))
            }
        }

        func checkDistance(_ distance: Int, produced: Int) throws {
            guard distance > 0 && distance <= produced else {
                throw WebfootDecodeError.invalidBackReference(distance: distance, produced: produced)
            }
        }

        func append(_ value: Int, into out: inout [UInt8]) throws {
            try ensureRoom(1, produced: out.count)
            out.append(UInt8(truncatingIfNeeded: value))
        }

        func copyBackReference(distance: Int, length: Int, into out: inout [UInt8]) throws {
            try checkDistance(distance, produced: out.count)
            try ensureRoom(length, produced: out.count)
            for _ in 0..<length { out.append(out[out.count - distance]) }
        }

        func readPrefix(_ br: inout BitReader) throws -> Int {
            var value = 1
            while true {
                value = (value << 1) | (try br.readBit())
                if try br.readBit() == 0 { return value }
            }
        }

        while true {
            if try reader.readBit() != 0 {
                let value = try reader.readBits(literalBitCount) + literalBase
                try append(value, into: &output)
                continue
            }

            if try reader.readBit() != 0 {
                let code = try readPrefix(&reader)
                var distance: Int
                var length: Int
                if code == 2 {
                    distance = lastDistance
                    length = try readPrefix(&reader)
                } else {
                    guard code >= 3 else {
                        throw WebfootDecodeError.invalidBackReference(distance: 0, produced: output.count)
                    }
                    let low = try reader.readBits(distanceBitCount)
                    distance = low + ((code - 3) << distanceBitCount)
                    lastDistance = distance
                    length = try readPrefix(&reader)
                    if distance >= 0x10000 { length += 3 }
                    else if distance >= 0x37FF { length += 2 }
                    else if distance >= 0x027F { length += 1 }
                    else if distance <= 0x007F { length += 4 }
                }
                try copyBackReference(distance: distance, length: length, into: &output)
                continue
            }

            if try reader.readBit() == 0 {
                let distance = try reader.readBits(7)
                if distance != 0 {
                    lastDistance = distance
                    try copyBackReference(distance: distance, length: try reader.readBits(2) + 2, into: &output)
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
                try append(0, into: &output)
                continue
            }
            if tiny > 0 {
                try copyBackReference(distance: tiny, length: 1, into: &output)
                continue
            }

            if try reader.readBit() != 0 {
                repeat {
                    try ensureRoom(256, produced: output.count)
                    for _ in 0..<256 { output.append(UInt8(try reader.readBits(8))) }
                } while try reader.readBit() != 0
                continue
            }

            literalBase = 0
            literalBitCount = 7 + (try reader.readBit())
            if literalBitCount == 7 { literalBase = try reader.readBits(8) }
        }
    }
}
