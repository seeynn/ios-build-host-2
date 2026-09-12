import Foundation

enum ALFPSceneDecodeError: Error, CustomStringConvertible {
    case invalidPointer(UInt32)
    case invalidLayerMethod(UInt32)
    case invalidDimensions(width: Int, height: Int)
    case invalidChunkSize(Int)
    case invalidGraphicsBank(index: Int, size: Int)
    case invalidTileID(Int)
    case malformedAssembly
    case invalidAttributeMaskSize(Int)

    var description: String {
        switch self {
        case .invalidPointer(let pointer): return "Invalid ALFP ROM pointer 0x\(String(pointer, radix: 16))"
        case .invalidLayerMethod(let method): return "Unexpected field-layer method 0x\(String(method, radix: 16))"
        case .invalidDimensions(let width, let height): return "Unsupported field dimensions \(width)x\(height)"
        case .invalidChunkSize(let count): return "Expected a 0x800-byte field chunk, got \(count) bytes"
        case .invalidGraphicsBank(let index, let size): return "Graphics bank \(index) decoded to \(size) bytes, expected 0x4000"
        case .invalidTileID(let id): return "Field map referenced assembled tile \(id) outside the tile atlas"
        case .malformedAssembly: return "Malformed ALFP field graphics assembly stream"
        case .invalidAttributeMaskSize(let count): return "Expected 0x2000-byte ALFP tile attribute mask, got \(count) bytes"
        }
    }
}

enum ALFPSceneData {
    static let firstSceneDescriptorOffset = 0x00129E38
    static let standardLayerMethod: UInt32 = 0x080056F9

    struct IndexedScene {
        let width: Int
        let height: Int
        let pixels: [UInt8]
        let spawnX: Int
        let spawnY: Int
        let attributeB: [UInt8]
    }

    private struct StandardLayer {
        let descriptorOffset: Int
        let widthPixels: Int
        let heightPixels: Int
        let gridWidth: Int
        let gridHeight: Int
        let entries: [UInt16]
        var widthTiles: Int { widthPixels / 8 }
        var heightTiles: Int { heightPixels / 8 }
    }

    private struct TileAtlas { let tiles: [[UInt8]] }

    static func decodeFirstScene(in rom: ROMImage) throws -> IndexedScene {
        let scene = firstSceneDescriptorOffset
        let top = try decodeStandardLayer(in: rom, pointer: try rom.u32(scene + 0x18))
        let middle = try decodeStandardLayer(in: rom, pointer: try rom.u32(scene + 0x1C))
        let base = try decodeStandardLayer(in: rom, pointer: try rom.u32(scene + 0x20))
        guard base.widthPixels == 1024, base.heightPixels == 1024 else {
            throw ALFPSceneDecodeError.invalidDimensions(width: base.widthPixels, height: base.heightPixels)
        }

        let assemblyPointer = try rom.u32(scene + 0x48)
        guard let assemblyOffset = rom.fileOffset(fromROMPointer: assemblyPointer) else {
            throw ALFPSceneDecodeError.invalidPointer(assemblyPointer)
        }
        let bankPointer = try rom.u32(scene + 0x4C)
        guard let bankOffset = rom.fileOffset(fromROMPointer: bankPointer) else {
            throw ALFPSceneDecodeError.invalidPointer(bankPointer)
        }
        let atlas = try assembleFieldTiles(in: rom, assemblyOffset: assemblyOffset, bankTableOffset: bankOffset)

        var pixels = try render(layer: base, using: atlas.tiles)
        try overlay(layer: middle, using: atlas.tiles, onto: &pixels)
        try overlay(layer: top, using: atlas.tiles, onto: &pixels)

        let packedSpawn = try rom.u32(scene + 0x30)
        let spawnX = Int(packedSpawn & 0xFFFF)
        let spawnY = Int((packedSpawn >> 16) & 0xFFFF)
        let attributeB = try decodeWorldAttributePlane(in: rom, pointer: try rom.u32(scene + 0x38), layers: [top, middle, base])

        return IndexedScene(width: 1024, height: 1024, pixels: pixels, spawnX: spawnX, spawnY: spawnY, attributeB: attributeB)
    }

    private static func decodeStandardLayer(in rom: ROMImage, pointer: UInt32) throws -> StandardLayer {
        guard let offset = rom.fileOffset(fromROMPointer: pointer) else { throw ALFPSceneDecodeError.invalidPointer(pointer) }
        let method = try rom.u32(offset)
        guard method == standardLayerMethod else { throw ALFPSceneDecodeError.invalidLayerMethod(method) }
        let width = Int(try rom.u32(offset + 4))
        let height = Int(try rom.u32(offset + 8))
        guard width > 0, height > 0, width % 8 == 0, height % 8 == 0 else {
            throw ALFPSceneDecodeError.invalidDimensions(width: width, height: height)
        }
        let gridWidth = Int(try rom.u8(offset + 0x14))
        let gridHeight = Int(try rom.u8(offset + 0x15))
        let widthTiles = width / 8
        let heightTiles = height / 8
        var entries = [UInt16](repeating: 0, count: widthTiles * heightTiles)

        for chunkY in 0..<gridHeight {
            for chunkX in 0..<gridWidth {
                let index = chunkY * gridWidth + chunkX
                let chunkPointer = try rom.u32(offset + 0x18 + index * 4)
                guard let chunkOffset = rom.fileOffset(fromROMPointer: chunkPointer) else { continue }
                guard try rom.u32(chunkOffset) == 1, try rom.u32(chunkOffset + 4) == 0x800 else { continue }
                let result = try WebfootDecoder.decodeResource(in: rom, at: chunkOffset)
                guard result.data.count == 0x800 else { throw ALFPSceneDecodeError.invalidChunkSize(result.data.count) }
                for localY in 0..<32 {
                    let worldTileY = chunkY * 32 + localY
                    if worldTileY >= heightTiles { continue }
                    for localX in 0..<32 {
                        let worldTileX = chunkX * 32 + localX
                        if worldTileX >= widthTiles { continue }
                        let sourceIndex = localY * 32 + localX
                        entries[worldTileY * widthTiles + worldTileX] = dataU16(result.data, sourceIndex * 2)
                    }
                }
            }
        }
        return StandardLayer(descriptorOffset: offset, widthPixels: width, heightPixels: height, gridWidth: gridWidth, gridHeight: gridHeight, entries: entries)
    }

    private static func assembleFieldTiles(in rom: ROMImage, assemblyOffset: Int, bankTableOffset: Int) throws -> TileAtlas {
        let assembly = try WebfootDecoder.decodeResource(in: rom, at: assemblyOffset).data
        guard assembly.count % 2 == 0 else { throw ALFPSceneDecodeError.malformedAssembly }
        var runningSourceTile = 0
        var tiles = [[UInt8]]()
        var bankCache: [Int: Data] = [:]

        for index in 0..<(assembly.count / 2) {
            runningSourceTile += Int(dataU16(assembly, index * 2))
            let bankIndex = runningSourceTile >> 8
            let sourceTile = runningSourceTile & 0xFF
            let bank: Data
            if let cached = bankCache[bankIndex] {
                bank = cached
            } else {
                let pointer = try rom.u32(bankTableOffset + bankIndex * 4)
                guard let offset = rom.fileOffset(fromROMPointer: pointer) else { throw ALFPSceneDecodeError.invalidPointer(pointer) }
                let decoded = try WebfootDecoder.decodeResource(in: rom, at: offset).data
                guard decoded.count == 0x4000 else { throw ALFPSceneDecodeError.invalidGraphicsBank(index: bankIndex, size: decoded.count) }
                bankCache[bankIndex] = decoded
                bank = decoded
            }
            let start = sourceTile * 64
            tiles.append(Array(bank[start..<(start + 64)]))
        }
        return TileAtlas(tiles: tiles)
    }

    private static func render(layer: StandardLayer, using atlas: [[UInt8]]) throws -> [UInt8] {
        var output = [UInt8](repeating: 0, count: layer.widthPixels * layer.heightPixels)
        try draw(layer: layer, using: atlas, onto: &output, transparentZero: false)
        return output
    }

    private static func overlay(layer: StandardLayer, using atlas: [[UInt8]], onto output: inout [UInt8]) throws {
        try draw(layer: layer, using: atlas, onto: &output, transparentZero: true)
    }

    private static func draw(layer: StandardLayer, using atlas: [[UInt8]], onto output: inout [UInt8], transparentZero: Bool) throws {
        let width = layer.widthPixels
        for tileY in 0..<layer.heightTiles {
            for tileX in 0..<layer.widthTiles {
                let entry = layer.entries[tileY * layer.widthTiles + tileX]
                let tileID = Int(entry & 0x03FF)
                guard tileID < atlas.count else { throw ALFPSceneDecodeError.invalidTileID(tileID) }
                let hFlip = (entry & 0x0400) != 0
                let vFlip = (entry & 0x0800) != 0
                let tile = atlas[tileID]
                for py in 0..<8 {
                    let sy = vFlip ? 7 - py : py
                    for px in 0..<8 {
                        let sx = hFlip ? 7 - px : px
                        let value = tile[sy * 8 + sx]
                        if transparentZero && value == 0 { continue }
                        output[(tileY * 8 + py) * width + tileX * 8 + px] = value
                    }
                }
            }
        }
    }

    private static func decodeWorldAttributePlane(in rom: ROMImage, pointer: UInt32, layers: [StandardLayer]) throws -> [UInt8] {
        guard let offset = rom.fileOffset(fromROMPointer: pointer) else { throw ALFPSceneDecodeError.invalidPointer(pointer) }
        let mask = try WebfootDecoder.decodeResource(in: rom, at: offset).data
        guard mask.count == 0x2000 else { throw ALFPSceneDecodeError.invalidAttributeMaskSize(mask.count) }
        var output = [UInt8](repeating: 0, count: 1024 * 1024)
        for layer in layers {
            for tileY in 0..<layer.heightTiles {
                for tileX in 0..<layer.widthTiles {
                    let entry = layer.entries[tileY * layer.widthTiles + tileX]
                    let tileID = Int(entry & 0x03FF)
                    let hFlip = (entry & 0x0400) != 0
                    let vFlip = (entry & 0x0800) != 0
                    let maskBase = tileID * 8
                    for py in 0..<8 {
                        let sy = vFlip ? 7 - py : py
                        let row = mask[maskBase + sy]
                        for px in 0..<8 {
                            let sx = hFlip ? 7 - px : px
                            if ((row >> UInt8(7 - sx)) & 1) == 0 { continue }
                            let dx = tileX * 8 + px
                            let dy = tileY * 8 + py
                            if dx < 1024 && dy < 1024 { output[dy * 1024 + dx] = 1 }
                        }
                    }
                }
            }
        }
        return output
    }

    private static func dataU16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }
}
