import CoreGraphics
import Foundation
import mGBA

/// Hidden mGBA game runtime with a native, authored-resource portrait renderer.
/// The GBA framebuffer is used only as an exact fallback for modes that have not
/// yet been reconstructed. Field gameplay is rebuilt from ALFP's authored data.
final class NativeBridgeRuntime {
    struct SpriteFrame {
        let oamIndex: Int
        let screenX: Int
        let screenY: Int
        let width: Int
        let height: Int
        let priority: Int
        let isHUD: Bool
        let image: CGImage
    }

    struct FieldActorFrame {
        let objectAddress: UInt32
        let screenX: Int
        let screenY: Int
        let worldX: Int
        let worldY: Int
        let width: Int
        let height: Int
        let image: CGImage
    }

    private struct RegularBG {
        let index: Int
        let priority: Int
        let charBase: UInt32
        let screenBase: UInt32
        let is8bpp: Bool
        let width: Int
        let height: Int
        let hOffset: Int
        let vOffset: Int
        let sizeCode: Int
    }

    private struct FieldLayer {
        let objectAddress: UInt32
        let resourcePointer: UInt32
        let layer: Int
        let chunkColumns: Int
        let chunkRows: Int
    }

    private struct ActorFrameDescriptor {
        let pointer: UInt32
        let originX: Int
        let originY: Int
        let width: Int
        let height: Int
        let hFlip: Bool
        let vFlip: Bool
        let graphicsPointer: UInt32
    }

    private let bridge = EmulatorBridge()
    private var core: UnsafeMutablePointer<mCore>!
    private var videoBuffer: UnsafeMutableBufferPointer<color_t>!
    private var audioSamples: UnsafeMutableBufferPointer<Int16>!
    private var started = false
    private var romImage: ROMImage?
    private var fieldLayers: [Int: FieldLayer] = [:]
    private var decodedChunks: [UInt32: Data] = [:]
    private var fieldScanGeneration = 0
    private var characterStructures = Set<UInt32>()
    private var actorObjectAddresses: [UInt32] = []
    private var lastActorObjectScan = -10_000
    private var decodedActorGraphics: [UInt32: Data] = [:]
    private var actorExpansionEnabled = false

    private static let sampleRate = 32_768.0
    private static let sampleCount = 1024
    private static let fieldChunkByteCount = 0x800
    private static let ewramStart: UInt32 = 0x0200_0000
    private static let ewramEnd: UInt32 = 0x0204_0000
    private static let fieldLayerVtable: UInt32 = 0x0802_3D18
    private static let fieldResourceMethod: UInt32 = 0x0800_56F9
    private static let characterTableOffset = 0x0069_2E68
    private static let characterCount = 150
    private static let cameraObjectAddress: UInt32 = 0x0300_0F30
    private static let cameraSignatureLiteralOffset = 0x0001_54D0
    private static let cameraPointerTableOffset = 0x0002_CE60

    init() throws {
        guard let created = GBACoreCreate() else { throw RuntimeError.coreAllocationFailed }
        core = created
        mCoreInitConfig(created, nil)
        var options = mCoreOptions()
        options.useBios = true
        mCoreConfigLoadDefaults(&created.pointee.config, &options)
        guard created.pointee.`init`(created) else {
            created.pointee.deinit(created)
            core = nil
            throw RuntimeError.coreInitializationFailed
        }
        created.pointee.setAudioBufferSize(created, Self.sampleCount)
        let left = created.pointee.getAudioChannel(created, 0)
        let right = created.pointee.getAudioChannel(created, 1)
        let clockRate = created.pointee.frequency(created)
        let fauxClock = GBAAudioCalculateRatio(1, 60, 1)
        blip_set_rates(left, Double(clockRate), Self.sampleRate * Double(fauxClock))
        blip_set_rates(right, Double(clockRate), Self.sampleRate * Double(fauxClock))
        videoBuffer = .allocate(capacity: 240 * 160)
        videoBuffer.initialize(repeating: 0)
        created.pointee.setVideoBuffer(created, videoBuffer.baseAddress, 240)
        audioSamples = .allocate(capacity: Self.sampleCount * 2)
        audioSamples.initialize(repeating: 0)
    }

    deinit {
        if let core {
            mCoreConfigDeinit(&core.pointee.config)
            core.pointee.deinit(core)
        }
        videoBuffer?.deallocate()
        audioSamples?.deallocate()
    }

    func start(romURL: URL, saveURL: URL) throws {
        let rom = try ROMImage(data: Data(contentsOf: romURL, options: .mappedIfSafe))
        romImage = rom
        fieldLayers.removeAll(keepingCapacity: true)
        decodedChunks.removeAll(keepingCapacity: true)
        fieldScanGeneration = 0
        actorObjectAddresses.removeAll(keepingCapacity: true)
        decodedActorGraphics.removeAll(keepingCapacity: true)
        lastActorObjectScan = -10_000
        configureActorCatalog(in: rom)
        let romPath = filePath(romURL)
        let savePath = filePath(saveURL)
        core.pointee.opts.savegamePath = strdup(savePath)
        guard mCoreLoadFile(core, romPath) else { throw RuntimeError.romLoadFailed }
        _ = mCoreLoadSaveFile(core, savePath, false)
        core.pointee.reset(core)
        started = true
    }

    func runFrame(input: InputState) {
        guard started else { return }
        apply(input: input)
        core.pointee.runFrame(core)
        pumpAudio()
        fieldScanGeneration &+= 1
    }

    func reset() {
        guard started else { return }
        core.pointee.reset(core)
        fieldLayers.removeAll(keepingCapacity: true)
        decodedChunks.removeAll(keepingCapacity: true)
        actorObjectAddresses.removeAll(keepingCapacity: true)
        lastActorObjectScan = -10_000
        bridge.resetAudioQueue()
    }

    func isFieldGameplay() -> Bool {
        guard started else { return false }
        let dispcnt = read16(0x0400_0000)
        guard (dispcnt & 0x0007) == 0, (dispcnt & 0x1F40) == 0x1F40 else { return false }
        for bg in 0..<4 {
            let cnt = read16(0x0400_0008 + UInt32(bg * 2))
            guard Int((cnt >> 14) & 0x3) == 0 else { return false }
            guard Int((cnt >> 8) & 0x1F) == 28 + bg else { return false }
        }
        return true
    }

    func portraitBackgroundImage(height portraitHeight: Int = 520) -> CGImage? {
        guard started else { return nil }
        guard isFieldGameplay() else { return fallbackPortraitImage(height: portraitHeight) }
        let backgrounds = regularBackgrounds()
        guard backgrounds.count == 4 else { return fallbackPortraitImage(height: portraitHeight) }
        resolveFieldLayersIfNeeded()
        guard fieldLayers.count == 4 else { return fallbackPortraitImage(height: portraitHeight) }
        guard visibleFieldMatchesHardware(backgrounds: backgrounds) else {
            return fallbackPortraitImage(height: portraitHeight)
        }
        var origins: [Int: (x: Int, y: Int)] = [:]
        origins.reserveCapacity(backgrounds.count)
        for bg in backgrounds {
            guard let origin = authoredScrollOrigin(for: bg) else {
                return fallbackPortraitImage(height: portraitHeight)
            }
            origins[bg.index] = origin
        }
        let extensionY = max(0, (portraitHeight - 160) / 2)
        let backdrop = read16(0x0500_0000)
        var rgba = [UInt8](repeating: 0, count: 240 * portraitHeight * 4)
        for y in 0..<portraitHeight {
            let screenY = y - extensionY
            for x in 0..<240 {
                let out = (y * 240 + x) * 4
                writeBGR555(backdrop, into: &rgba, at: out, alpha: 255)
                for bg in backgrounds {
                    guard let origin = origins[bg.index] else { continue }
                    let worldX = origin.x + x
                    let worldY = origin.y + screenY
                    guard let entry = fieldEntry(layer: bg.index, worldX: worldX, worldY: worldY),
                          let palette = paletteIndex(bg: bg, entry: entry, worldX: worldX, worldY: worldY),
                          palette != 0 else { continue }
                    writeBGR555(read16(0x0500_0000 + UInt32(palette * 2)), into: &rgba, at: out, alpha: 255)
                }
            }
        }
        return makeRGBAImage(rgba, width: 240, height: portraitHeight)
    }

    func spriteFrames() -> [SpriteFrame] {
        guard started else { return [] }
        let dispcnt = read16(0x0400_0000)
        let oneDimensional = (dispcnt & 0x0040) != 0
        let mode = Int(dispcnt & 0x0007)
        let objectBase: UInt32 = mode >= 3 ? 0x0601_4000 : 0x0601_0000
        let gameplay = isFieldGameplay()
        var frames: [SpriteFrame] = []
        for index in 0..<128 {
            let base = 0x0700_0000 + UInt32(index * 8)
            let attr0 = read16(base)
            let attr1 = read16(base + 2)
            let attr2 = read16(base + 4)
            let affine = (attr0 & 0x0100) != 0
            let disabled = !affine && (attr0 & 0x0200) != 0
            if affine || disabled { continue }
            guard let dimensions = spriteDimensions(shape: Int((attr0 >> 14) & 0x3), size: Int((attr1 >> 14) & 0x3)) else { continue }
            var x = Int(attr1 & 0x01FF)
            var y = Int(attr0 & 0x00FF)
            if x >= 480 { x -= 512 }
            if y >= 224 { y -= 256 }
            let width = dimensions.0
            let height = dimensions.1
            if x + width <= -40 || x >= 280 || y + height <= -190 || y >= 350 { continue }
            guard let image = makeSpriteImage(objectBase: objectBase, tileIndex: Int(attr2 & 0x03FF), width: width, height: height, is8bpp: (attr0 & 0x2000) != 0, paletteBank: Int((attr2 >> 12) & 0xF), oneDimensional: oneDimensional, hFlip: (attr1 & 0x1000) != 0, vFlip: (attr1 & 0x2000) != 0) else { continue }
            let isHUD = gameplay && index <= 2 && x < 112 && y >= 0 && y < 40
            frames.append(SpriteFrame(oamIndex: index, screenX: x, screenY: y, width: width, height: height, priority: Int((attr2 >> 10) & 0x3), isHUD: isHUD, image: image))
        }
        return frames
    }

    func expandedFieldActorFrames(liveSprites: [SpriteFrame], portraitHeight: Int = 520) -> [FieldActorFrame] {
        guard started, isFieldGameplay(), actorExpansionEnabled else { return [] }
        refreshActorObjectsIfNeeded()
        guard !actorObjectAddresses.isEmpty else { return [] }
        let cameraX = signed32(read32(Self.cameraObjectAddress + 0x1C))
        let cameraY = signed32(read32(Self.cameraObjectAddress + 0x20))
        let viewLeft = signed32(read32(Self.cameraObjectAddress + 0x0C))
        let viewTop = signed32(read32(Self.cameraObjectAddress + 0x10))
        let viewRight = signed32(read32(Self.cameraObjectAddress + 0x14))
        let viewBottom = signed32(read32(Self.cameraObjectAddress + 0x18))
        guard viewRight > viewLeft, viewBottom > viewTop,
              viewRight - viewLeft >= 160, viewRight - viewLeft <= 512,
              viewBottom - viewTop >= 96, viewBottom - viewTop <= 384 else { return [] }
        let extensionY = max(0, (portraitHeight - 160) / 2)
        let portraitTop = -extensionY
        let portraitBottom = 160 + extensionY
        let worldSprites = liveSprites.filter { !$0.isHUD }
        var output: [FieldActorFrame] = []
        output.reserveCapacity(actorObjectAddresses.count)
        for object in actorObjectAddresses {
            guard characterStructures.contains(read32(object + 0x48)),
                  let descriptor = currentActorFrameDescriptor(object: object) else { continue }
            let worldAnchorX = fixedPoint8_8(read32(object + 0x158))
            let worldAnchorY = fixedPoint8_8(read32(object + 0x15C))
            let worldX = worldAnchorX + descriptor.originX
            let worldY = worldAnchorY + descriptor.originY
            let screenX = worldX - cameraX
            let screenY = worldY - cameraY
            guard screenX + descriptor.width > -64, screenX < 304,
                  screenY + descriptor.height > portraitTop - 64,
                  screenY < portraitBottom + 64 else { continue }
            if screenY + descriptor.height > -32, screenY < 192 {
                let storedX = signed32(read32(object + 0x40))
                let storedY = signed32(read32(object + 0x44))
                if abs(storedX - screenX) > 4 || abs(storedY - screenY) > 4 { continue }
            }
            let alreadyInOAM = worldSprites.contains {
                abs($0.screenX - screenX) <= 2 && abs($0.screenY - screenY) <= 2 &&
                $0.width == descriptor.width && $0.height == descriptor.height
            }
            if alreadyInOAM { continue }
            guard let image = makeActorFrameImage(descriptor) else { continue }
            output.append(FieldActorFrame(objectAddress: object, screenX: screenX, screenY: screenY, worldX: worldX, worldY: worldY, width: descriptor.width, height: descriptor.height, image: image))
        }
        if output.count > 128 { return [] }
        return output
    }

    func framebufferImage() -> CGImage? {
        guard let base = videoBuffer.baseAddress else { return nil }
        let data = Data(bytes: base, count: 240 * 160 * MemoryLayout<color_t>.stride)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: 240, height: 160, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 240 * 4, space: renderColorSpace(), bitmapInfo: CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    private func configureActorCatalog(in rom: ROMImage) {
        characterStructures.removeAll(keepingCapacity: true)
        actorExpansionEnabled = false
        guard let signature = try? rom.u32(Self.cameraSignatureLiteralOffset), signature == 0x0802_CE60,
              let camera = try? rom.u32(Self.cameraPointerTableOffset), camera == Self.cameraObjectAddress else { return }
        for index in 0..<Self.characterCount {
            let offset = Self.characterTableOffset + index * 4
            guard let pointer = try? rom.u32(offset), rom.fileOffset(fromROMPointer: pointer) != nil else {
                characterStructures.removeAll(); return
            }
            characterStructures.insert(pointer)
        }
        actorExpansionEnabled = characterStructures.count == Self.characterCount
    }

    private func refreshActorObjectsIfNeeded() {
        let interval = 12
        if !actorObjectAddresses.isEmpty, fieldScanGeneration - lastActorObjectScan < interval { return }
        lastActorObjectScan = fieldScanGeneration
        var found: [UInt32] = []
        found.reserveCapacity(48)
        var object = Self.ewramStart
        let end = Self.ewramEnd - 0x160
        while object <= end {
            let character = read32(object + 0x48)
            if characterStructures.contains(character), let descriptor = currentActorFrameDescriptor(object: object) {
                let worldX = fixedPoint8_8(read32(object + 0x158))
                let worldY = fixedPoint8_8(read32(object + 0x15C))
                let direction = Int(read8(object + 0x10))
                if direction >= 0, direction < 4, worldX > -2048, worldX < 16384, worldY > -2048, worldY < 16384, descriptor.width > 0, descriptor.height > 0 {
                    found.append(object)
                    if found.count > 256 { actorObjectAddresses.removeAll(keepingCapacity: true); return }
                }
            }
            object &+= 4
        }
        actorObjectAddresses = found
    }

    private func currentActorFrameDescriptor(object: UInt32) -> ActorFrameDescriptor? {
        var pointer = read32(object + 0x3C)
        if let descriptor = actorFrameDescriptor(pointer: pointer) { return descriptor }
        let table = read32(object + 0x4C)
        let direction = Int(read8(object + 0x10))
        let frameIndex = Int(read16(object + 0x14))
        guard direction >= 0, direction < 4, frameIndex >= 0, frameIndex < 256,
              isReadableAddress(table &+ UInt32(direction * 4)) else { return nil }
        let sequence = read32(table &+ UInt32(direction * 4))
        guard isROMPointer(sequence) else { return nil }
        pointer = sequence &+ UInt32(frameIndex * 12)
        return actorFrameDescriptor(pointer: pointer)
    }

    private func actorFrameDescriptor(pointer: UInt32) -> ActorFrameDescriptor? {
        guard let rom = romImage, let offset = rom.fileOffset(fromROMPointer: pointer), offset + 12 <= rom.data.count,
              let widthByte = try? rom.u8(offset + 2), let heightByte = try? rom.u8(offset + 3),
              let attributes = try? rom.u32(offset + 4), let graphicsPointer = try? rom.u32(offset + 8),
              let graphicsOffset = rom.fileOffset(fromROMPointer: graphicsPointer), graphicsOffset + 8 <= rom.data.count,
              let kind = try? rom.u32(graphicsOffset), let decodedSize = try? rom.u32(graphicsOffset + 4) else { return nil }
        let width = Int(widthByte), height = Int(heightByte)
        let validDimensions = [8, 16, 32, 64]
        guard validDimensions.contains(width), validDimensions.contains(height),
              (UInt16(truncatingIfNeeded: attributes) & 0x2000) != 0, kind <= 2,
              decodedSize == UInt32(width * height) else { return nil }
        let attr1 = UInt16(truncatingIfNeeded: attributes >> 16)
        let originX = Int(Int8(bitPattern: (try? rom.u8(offset)) ?? 0))
        let originY = Int(Int8(bitPattern: (try? rom.u8(offset + 1)) ?? 0))
        return ActorFrameDescriptor(pointer: pointer, originX: originX, originY: originY, width: width, height: height, hFlip: (attr1 & 0x1000) != 0, vFlip: (attr1 & 0x2000) != 0, graphicsPointer: graphicsPointer)
    }

    private func makeActorFrameImage(_ descriptor: ActorFrameDescriptor) -> CGImage? {
        guard let rom = romImage, let graphicsOffset = rom.fileOffset(fromROMPointer: descriptor.graphicsPointer) else { return nil }
        let graphics: Data
        if let cached = decodedActorGraphics[descriptor.graphicsPointer] { graphics = cached }
        else {
            guard let decoded = try? WebfootDecoder.decodeResource(in: rom, at: graphicsOffset), decoded.data.count == descriptor.width * descriptor.height else { return nil }
            graphics = decoded.data
            decodedActorGraphics[descriptor.graphicsPointer] = graphics
        }
        let width = descriptor.width, height = descriptor.height, tilesWide = width / 8
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for outY in 0..<height {
            let sourceY = descriptor.vFlip ? height - 1 - outY : outY
            let tileY = sourceY / 8, pixelY = sourceY & 7
            for outX in 0..<width {
                let sourceX = descriptor.hFlip ? width - 1 - outX : outX
                let tileX = sourceX / 8, pixelX = sourceX & 7
                let tile = tileY * tilesWide + tileX
                let source = tile * 64 + pixelY * 8 + pixelX
                guard source >= 0, source < graphics.count else { continue }
                let palette = Int(graphics[source])
                if palette == 0 { continue }
                let out = (outY * width + outX) * 4
                writeBGR555(read16(0x0500_0200 + UInt32(palette * 2)), into: &rgba, at: out, alpha: 255)
            }
        }
        return makeRGBAImage(rgba, width: width, height: height, alphaInfo: .premultipliedLast)
    }

    private func regularBackgrounds() -> [RegularBG] {
        let dispcnt = read16(0x0400_0000)
        guard Int(dispcnt & 0x7) == 0 else { return [] }
        var output: [RegularBG] = []
        for bg in 0..<4 {
            guard (dispcnt & (UInt16(1) << UInt16(8 + bg))) != 0 else { continue }
            let cnt = read16(0x0400_0008 + UInt32(bg * 2))
            let sizeCode = Int((cnt >> 14) & 0x3)
            let dimensions: (Int, Int)
            switch sizeCode { case 0: dimensions = (256,256); case 1: dimensions = (512,256); case 2: dimensions = (256,512); default: dimensions = (512,512) }
            output.append(RegularBG(index: bg, priority: Int(cnt & 0x3), charBase: 0x0600_0000 + UInt32((cnt >> 2) & 0x3) * 0x4000, screenBase: 0x0600_0000 + UInt32((cnt >> 8) & 0x1F) * 0x800, is8bpp: (cnt & 0x0080) != 0, width: dimensions.0, height: dimensions.1, hOffset: Int(read16(0x0400_0010 + UInt32(bg * 4))), vOffset: Int(read16(0x0400_0012 + UInt32(bg * 4))), sizeCode: sizeCode))
        }
        output.sort { $0.priority != $1.priority ? $0.priority > $1.priority : $0.index > $1.index }
        return output
    }

    private func resolveFieldLayersIfNeeded() {
        if fieldLayers.count == 4, fieldLayers.values.allSatisfy({ fieldLayerStillValid($0) }) { return }
        if !fieldLayers.isEmpty && fieldScanGeneration % 20 != 0 { return }
        var resolved: [Int: FieldLayer] = [:]
        var object = Self.ewramStart
        while object + 0x2030 < Self.ewramEnd {
            guard read32(object + 0x08) == Self.fieldLayerVtable else { object &+= 4; continue }
            let resource = read32(object + 0x10)
            if let descriptor = validateFieldResource(pointer: resource), resolved[descriptor.layer] == nil {
                let chunkCount = descriptor.chunkColumns * descriptor.chunkRows
                var validOwners = true
                for slot in 0..<4 { let owner = Int(read8(object + 0x24 + UInt32(slot))); if owner != 0xFF && owner >= chunkCount { validOwners = false; break } }
                if validOwners { resolved[descriptor.layer] = FieldLayer(objectAddress: object, resourcePointer: resource, layer: descriptor.layer, chunkColumns: descriptor.chunkColumns, chunkRows: descriptor.chunkRows) }
            }
            object &+= 4
        }
        fieldLayers = resolved
    }

    private func fieldLayerStillValid(_ field: FieldLayer) -> Bool {
        guard read32(field.objectAddress + 0x08) == Self.fieldLayerVtable, read32(field.objectAddress + 0x10) == field.resourcePointer, let descriptor = validateFieldResource(pointer: field.resourcePointer) else { return false }
        return descriptor.layer == field.layer && descriptor.chunkColumns == field.chunkColumns && descriptor.chunkRows == field.chunkRows
    }

    private func validateFieldResource(pointer: UInt32) -> (layer: Int, chunkColumns: Int, chunkRows: Int)? {
        guard let rom = romImage, let offset = rom.fileOffset(fromROMPointer: pointer),
              let method = try? rom.u32(offset), method == Self.fieldResourceMethod,
              let width = try? rom.u32(offset + 4), let height = try? rom.u32(offset + 8), width >= 256, width <= 8192, height >= 256, height <= 8192, width % 8 == 0, height % 8 == 0,
              let layerWord = try? rom.u32(offset + 0x10), let columnsByte = try? rom.u8(offset + 0x14), let rowsByte = try? rom.u8(offset + 0x15) else { return nil }
        let layer = Int((layerWord >> 16) & 0xFF), columns = Int(columnsByte), rows = Int(rowsByte), chunkCount = columns * rows
        guard layer >= 0, layer < 4, columns > 0, rows > 0, chunkCount <= 0xFF, offset + 0x18 + chunkCount * 4 <= rom.data.count else { return nil }
        for index in 0..<min(chunkCount,3) {
            guard let chunkDescriptor = try? rom.u32(offset + 0x18 + index * 4), let descriptorOffset = rom.fileOffset(fromROMPointer: chunkDescriptor), let kind = try? rom.u32(descriptorOffset), let decodedSize = try? rom.u32(descriptorOffset + 4), kind <= 2, decodedSize == UInt32(Self.fieldChunkByteCount) else { return nil }
        }
        return (layer, columns, rows)
    }

    private func authoredScrollOrigin(for bg: RegularBG) -> (x: Int, y: Int)? {
        guard let field = fieldLayers[bg.index] else { return nil }
        let anchorX = signed32(read32(field.objectAddress + 0x28)), anchorY = signed32(read32(field.objectAddress + 0x2C))
        guard let x = reconstructAuthoredScroll(hardwareValue: bg.hOffset, anchorChunk: anchorX, anchorBias: 8, worldExtent: field.chunkColumns * 256), let y = reconstructAuthoredScroll(hardwareValue: bg.vOffset, anchorChunk: anchorY, anchorBias: 48, worldExtent: field.chunkRows * 256) else { return nil }
        return (x,y)
    }

    private func reconstructAuthoredScroll(hardwareValue: Int, anchorChunk: Int, anchorBias: Int, worldExtent: Int) -> Int? {
        let lowNine = hardwareValue & 0x01FF, upper = max(4,(worldExtent + 1535)/512)
        for k in -4...upper { let candidate = lowNine + k * 512; if floorDiv(candidate - anchorBias,256) == anchorChunk { return candidate } }
        return nil
    }

    private func visibleFieldMatchesHardware(backgrounds: [RegularBG]) -> Bool {
        let xs=[12,64,120,176,228], ys=[12,48,80,112,148]; var comparisons=0, matches=0
        for bg in backgrounds {
            guard let origin=authoredScrollOrigin(for:bg) else{return false}
            for y in ys { for x in xs {
                guard let entry=fieldEntry(layer:bg.index,worldX:origin.x+x,worldY:origin.y+y), let authored=paletteIndex(bg:bg,entry:entry,worldX:origin.x+x,worldY:origin.y+y), let hardware=regularBGPaletteIndex(bg,mapX:positiveModulo(bg.hOffset+x,bg.width),mapY:positiveModulo(bg.vOffset+y,bg.height)) else{continue}
                comparisons += 1; if authored == hardware { matches += 1 }
            }}
        }
        return comparisons >= 40 && Double(matches)/Double(comparisons) >= 0.72
    }

    private func fieldEntry(layer:Int,worldX:Int,worldY:Int)->UInt16? {
        guard worldX>=0,worldY>=0,let field=fieldLayers[layer],let rom=romImage,worldX<field.chunkColumns*256,worldY<field.chunkRows*256 else{return nil}
        let tileX=worldX>>3,tileY=worldY>>3,chunkX=tileX>>5,chunkY=tileY>>5,chunkIndex=chunkY*field.chunkColumns+chunkX
        guard chunkIndex>=0,chunkIndex<field.chunkColumns*field.chunkRows else{return nil}
        let byteOffset=(((tileY&31)*32)+(tileX&31))*2
        for slot in 0..<4 { if Int(read8(field.objectAddress+0x24+UInt32(slot)))==chunkIndex { return read16(field.objectAddress+0x30+UInt32(slot*Self.fieldChunkByteCount)+UInt32(byteOffset)) } }
        guard let resourceOffset=rom.fileOffset(fromROMPointer:field.resourcePointer),let descriptor=try? rom.u32(resourceOffset+0x18+chunkIndex*4) else{return nil}
        let decoded:Data
        if let cached=decodedChunks[descriptor]{decoded=cached}else{guard let descriptorOffset=rom.fileOffset(fromROMPointer:descriptor),let result=try? WebfootDecoder.decodeResource(in:rom,at:descriptorOffset),result.data.count==Self.fieldChunkByteCount else{return nil};decodedChunks[descriptor]=result.data;decoded=result.data}
        guard byteOffset+1<decoded.count else{return nil};return UInt16(decoded[byteOffset])|(UInt16(decoded[byteOffset+1])<<8)
    }

    private func paletteIndex(bg:RegularBG,entry:UInt16,worldX:Int,worldY:Int)->Int? {
        let tile=Int(entry&0x03FF),x=(entry&0x0400) != 0 ? 7-(worldX&7):(worldX&7),y=(entry&0x0800) != 0 ? 7-(worldY&7):(worldY&7)
        if bg.is8bpp{return Int(read8(bg.charBase+UInt32(tile*64+y*8+x)))}
        let packed=read8(bg.charBase+UInt32(tile*32+y*4+x/2)),nibble=(x&1)==0 ? packed&0x0F:packed>>4
        if nibble==0{return 0};return Int((entry>>12)&0xF)*16+Int(nibble)
    }

    private func regularBGPaletteIndex(_ bg:RegularBG,mapX:Int,mapY:Int)->Int? {
        let tileX=mapX>>3,tileY=mapY>>3,blockX=tileX>>5,blockY=tileY>>5,block:Int
        switch bg.sizeCode{case 0:block=0;case 1:block=blockX;case 2:block=blockY;default:block=blockY*2+blockX}
        let address=bg.screenBase+UInt32(block*0x800+(((tileY&31)*32+(tileX&31))*2));return paletteIndex(bg:bg,entry:read16(address),worldX:mapX,worldY:mapY)
    }

    private func fallbackPortraitImage(height portraitHeight:Int)->CGImage? {
        guard let frame=framebufferImage(),let data=frame.dataProvider?.data,let bytes=CFDataGetBytePtr(data) else{return nil}
        var rgba=[UInt8](repeating:0,count:240*portraitHeight*4);let yOffset=max(0,(portraitHeight-160)/2)
        for y in 0..<160{for x in 0..<240{let source=(y*240+x)*4,destination=((y+yOffset)*240+x)*4;rgba[destination]=bytes[source+2];rgba[destination+1]=bytes[source+1];rgba[destination+2]=bytes[source];rgba[destination+3]=255}}
        return makeRGBAImage(rgba,width:240,height:portraitHeight)
    }

    private func apply(input:InputState){var keys:UInt32=0;if input.a{keys|=UInt32(1)<<UInt32(GBA_KEY_A.rawValue)};if input.b{keys|=UInt32(1)<<UInt32(GBA_KEY_B.rawValue)};if input.select{keys|=UInt32(1)<<UInt32(GBA_KEY_SELECT.rawValue)};if input.start{keys|=UInt32(1)<<UInt32(GBA_KEY_START.rawValue)};if input.right{keys|=UInt32(1)<<UInt32(GBA_KEY_RIGHT.rawValue)};if input.left{keys|=UInt32(1)<<UInt32(GBA_KEY_LEFT.rawValue)};if input.up{keys|=UInt32(1)<<UInt32(GBA_KEY_UP.rawValue)};if input.down{keys|=UInt32(1)<<UInt32(GBA_KEY_DOWN.rawValue)};if input.r{keys|=UInt32(1)<<UInt32(GBA_KEY_R.rawValue)};if input.l{keys|=UInt32(1)<<UInt32(GBA_KEY_L.rawValue)};core.pointee.setKeys(core,keys)}

    private func pumpAudio(){let left=core.pointee.getAudioChannel(core,0),right=core.pointee.getAudioChannel(core,1);var available=blip_samples_avail(left);if available>Int32(Self.sampleCount){available=Int32(Self.sampleCount)};guard available>0 else{return};blip_read_samples(left,audioSamples.baseAddress,available,1);blip_read_samples(right,audioSamples.baseAddress?.advanced(by:1),available,1);_=bridge.writeAudioSamples(samples:UnsafeRawBufferPointer(start:audioSamples.baseAddress,count:Int(available)<<2))}

    private func makeSpriteImage(objectBase:UInt32,tileIndex:Int,width:Int,height:Int,is8bpp:Bool,paletteBank:Int,oneDimensional:Bool,hFlip:Bool,vFlip:Bool)->CGImage? {
        var rgba=[UInt8](repeating:0,count:width*height*4);let tilesWide=width/8,tileBytes=is8bpp ? 64:32,baseOffset=tileIndex*32
        for outY in 0..<height{let sourceY=vFlip ? height-1-outY:outY,tileY=sourceY/8,pixelY=sourceY&7;for outX in 0..<width{let sourceX=hFlip ? width-1-outX:outX,tileX=sourceX/8,pixelX=sourceX&7,tileNumber=oneDimensional ? tileY*tilesWide+tileX:tileY*32+tileX,tileAddress=objectBase+UInt32(baseOffset+tileNumber*tileBytes);let palette:Int;if is8bpp{palette=Int(read8(tileAddress+UInt32(pixelY*8+pixelX)))}else{let packed=read8(tileAddress+UInt32(pixelY*4+pixelX/2)),nibble=(pixelX&1)==0 ? packed&0x0F:packed>>4;if nibble==0{continue};palette=paletteBank*16+Int(nibble)};if palette==0{continue};writeBGR555(read16(0x0500_0200+UInt32(palette*2)),into:&rgba,at:(outY*width+outX)*4,alpha:255)}}
        return makeRGBAImage(rgba,width:width,height:height,alphaInfo:.premultipliedLast)
    }

    private func makeRGBAImage(_ rgba:[UInt8],width:Int,height:Int,alphaInfo:CGImageAlphaInfo = .noneSkipLast)->CGImage?{guard let provider=CGDataProvider(data:Data(rgba) as CFData) else{return nil};return CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,space:renderColorSpace(),bitmapInfo:CGBitmapInfo(rawValue:alphaInfo.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)}
    private func renderColorSpace()->CGColorSpace{CGColorSpace(name:CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()}
    private func writeBGR555(_ value:UInt16,into rgba:inout[UInt8],at offset:Int,alpha:UInt8){let r=Int(value&0x1F),g=Int((value>>5)&0x1F),b=Int((value>>10)&0x1F);rgba[offset]=UInt8((r*255+15)/31);rgba[offset+1]=UInt8((g*255+15)/31);rgba[offset+2]=UInt8((b*255+15)/31);rgba[offset+3]=alpha}
    private func read8(_ address:UInt32)->UInt8{UInt8(truncatingIfNeeded:core.pointee.rawRead8(core,address,-1))}
    private func read16(_ address:UInt32)->UInt16{UInt16(truncatingIfNeeded:core.pointee.rawRead16(core,address,-1))}
    private func read32(_ address:UInt32)->UInt32{UInt32(truncatingIfNeeded:core.pointee.rawRead32(core,address,-1))}
    private func isROMPointer(_ address:UInt32)->Bool{guard let rom=romImage else{return false};return rom.fileOffset(fromROMPointer:address) != nil}
    private func isReadableAddress(_ address:UInt32)->Bool{if address>=0x0200_0000&&address<0x0204_0000{return true};if address>=0x0300_0000&&address<0x0300_8000{return true};return isROMPointer(address)}
    private func signed32(_ value:UInt32)->Int{Int(Int32(bitPattern:value))}
    private func fixedPoint8_8(_ value:UInt32)->Int{Int(Int32(bitPattern:value)>>8)}
    private func floorDiv(_ value:Int,_ divisor:Int)->Int{value>=0 ? value/divisor:-((-value+divisor-1)/divisor)}
    private func positiveModulo(_ value:Int,_ modulus:Int)->Int{let result=value%modulus;return result>=0 ? result:result+modulus}
    private func spriteDimensions(shape:Int,size:Int)->(Int,Int)?{switch(shape,size){case(0,0):return(8,8);case(0,1):return(16,16);case(0,2):return(32,32);case(0,3):return(64,64);case(1,0):return(16,8);case(1,1):return(32,8);case(1,2):return(32,16);case(1,3):return(64,32);case(2,0):return(8,16);case(2,1):return(8,32);case(2,2):return(16,32);case(2,3):return(32,64);default:return nil}}
    private func filePath(_ url:URL)->String{if #available(iOS 16.0,*){return url.path(percentEncoded:false)};return url.path}

    enum RuntimeError:LocalizedError{case coreAllocationFailed;case coreInitializationFailed;case romLoadFailed;var errorDescription:String?{switch self{case .coreAllocationFailed:return"Could not allocate the hidden GBA runtime.";case .coreInitializationFailed:return"Could not initialize the hidden GBA runtime.";case .romLoadFailed:return"Could not load the imported game into the hidden runtime."}}}
}
