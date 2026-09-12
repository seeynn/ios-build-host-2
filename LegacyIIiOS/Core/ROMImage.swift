import Foundation

enum ROMError: Error, CustomStringConvertible {
    case fileMissing
    case tooSmall
    case unsupportedGameCode(String)
    case outOfBounds(Int, Int)

    var description: String {
        switch self {
        case .fileMissing: return "Bundled ALFP ROM is missing"
        case .tooSmall: return "ROM image is too small to be a valid GBA cartridge"
        case .unsupportedGameCode(let code): return "Expected Legacy of Goku II Europe (ALFP), got \(code)"
        case .outOfBounds(let offset, let count): return "ROM read outside bounds at 0x\(String(offset, radix: 16)) (\(count) bytes)"
        }
    }
}

struct ROMImage {
    let data: Data
    let title: String
    let gameCode: String

    init(data: Data) throws {
        guard data.count >= 0xC0 else { throw ROMError.tooSmall }
        self.data = data
        self.title = Self.ascii(data, 0xA0..<0xAC)
        self.gameCode = Self.ascii(data, 0xAC..<0xB0)
        guard gameCode == "ALFP" else { throw ROMError.unsupportedGameCode(gameCode) }
    }

    static func bundled() throws -> ROMImage {
        guard let url = Bundle.main.url(forResource: "LegacyII_Europe_ALFP", withExtension: "gba") else {
            throw ROMError.fileMissing
        }
        return try ROMImage(data: Data(contentsOf: url, options: .mappedIfSafe))
    }

    func u8(_ offset: Int) throws -> UInt8 {
        guard offset >= 0 && offset < data.count else { throw ROMError.outOfBounds(offset, 1) }
        return data[offset]
    }

    func u16(_ offset: Int) throws -> UInt16 {
        let bytes = try slice(offset, 2)
        return UInt16(bytes[0]) | UInt16(bytes[1]) << 8
    }

    func u32(_ offset: Int) throws -> UInt32 {
        let bytes = try slice(offset, 4)
        return UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
    }

    func slice(_ offset: Int, _ count: Int) throws -> Data {
        guard offset >= 0, count >= 0, offset + count <= data.count else {
            throw ROMError.outOfBounds(offset, count)
        }
        return data.subdata(in: offset..<(offset + count))
    }

    func fileOffset(fromROMPointer pointer: UInt32) -> Int? {
        guard pointer >= 0x0800_0000 && pointer < 0x0A00_0000 else { return nil }
        let offset = Int(pointer - 0x0800_0000)
        return offset < data.count ? offset : nil
    }

    private static func ascii(_ data: Data, _ range: Range<Int>) -> String {
        String(bytes: data[range], encoding: .ascii)?.trimmingCharacters(in: .controlCharacters.union(.whitespaces)) ?? ""
    }
}
