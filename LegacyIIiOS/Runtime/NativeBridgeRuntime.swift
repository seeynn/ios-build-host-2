import AVFoundation
import CoreGraphics
import Foundation
import mGBA

final class NativeBridgeRuntime {
    struct SpriteFrame {
        let screenX: Int
        let screenY: Int
        let width: Int
        let height: Int
        let priority: Int
        let image: CGImage
    }

    struct BackgroundOffset {
        let index: Int
        let x: Int
        let y: Int
    }

    private struct RegularBG {
        let index: Int
        let priority: Int
        let charBase: UInt32
        let is8bpp: Bool
    }

    private let bridge = EmulatorBridge()
    private let core: UnsafeMutablePointer<mCore>
    private var videoBuffer: UnsafeMutableBufferPointer<color_t>
    private var audioSamples: UnsafeMutableBufferPointer<Int16>
    private var keys: UInt32 = 0
    private var started = false
    private var romImage: ROMImage?

    // Webfoot's live field-layer objects cache four decoded 32x32-tile chunks.
    // The resource pointer at +0x10 identifies the authored layer and the owner
    // bytes at +0x24 say which chunks are resident in the four 0x800-byte slots.
    // Adjacent portrait rows can therefore be read from the real authored chunk
    // descriptors instead of wrapping the GBA's 512px hardware tilemap ring.
    private let alfpFieldResourceVtable: UInt32 = 0x080056F9
    private let fieldChunkBytes = 0x800
    private var fieldObjects = [UInt32](repeating: 0, count: 4)
    private var decodedFieldChunks: [UInt32: Data] = [:]

    private let sampleRate = 32_768.0
    private let sampleCount = 1024

    init() throws {
        guard let created = GBACoreCreate() else { throw RuntimeError.coreAllocationFailed }
        core = created
        mCoreInitConfig(core, nil)
        var options = mCoreOptions()
        options.useBios = true
        mCoreConfigLoadDefaults(&core.pointee.config, &options)
        guard core.pointee.`init`(core) else {
            core.pointee.deinit(core)
            throw RuntimeError.coreInitializationFailed
        }

        core.pointee.setAudioBufferSize(core, sampleCount)
        let left = core.pointee.getAudioChannel(core, 0)
        let right = core.pointee.getAudioChannel(core, 1)
        let clockRate = core.pointee.frequency(core)
        let fauxClock = GBAAudioCalculateRatio(1, 60, 1)
        blip_set_rates(left, Double(clockRate), sampleRate * Double(fauxClock))
        blip_set_rates(right, Double(clockRate), sampleRate * Double(fauxClock))

        videoBuffer = .allocate(capacity: 240 * 160)
        videoBuffer.initialize(repeating: 0)
        core.pointee.setVideoBuffer(core, videoBuffer.baseAddress, 240)
        audioSamples = .allocate(capacity: sampleCount * 2)
        audioSamples.initialize(repeating: 0)
    }

    deinit {
        if started { core.pointee.unloadROM(core) }
        mCoreConfigDeinit(&core.pointee.config)
        core.pointee.deinit(core)
        videoBuffer.deallocate()
        audioSamples.deallocate()
    }

    func start(romURL: URL, saveURL: URL) throws {
        let romPath = filePath(romURL)
        let savePath = filePath(saveURL)
        romImage = try ROMImage(data: Data(contentsOf: romURL, options: .mappedIfSafe))
        fieldObjects = [UInt32](repeating: 0, count: 4)
        decodedFieldChunks.removeAll(keepingCapacity: true)

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
    }

    func reset() {
        guard started else { return }
        core.pointee.reset(core)
        fieldObjects = [UInt32](repeating: 0, count: 4)
        decodedFieldChunks.removeAll(keepingCapacity: true)
        bridge.resetAudioQueue()
    }

    func displayMode() -> Int {
        Int(read16(0x0400_0000) & 0x7)
    }

    func backgroundOffsets() -> [BackgroundOffset] {
        let dispcnt = read16(0x0400_0000)
        guard Int(dispcnt & 0x7) == 0 else { return [] }
        return (0...3).compactMap { bg in
            let enabled = (dispcnt & (UInt16(1) << UInt16(8 + bg))) != 0
            guard enabled else { return nil }
            let object = fieldObjects[bg]
            let resource = object == 0 ? 0 : read32(object + 0x10)
            let resolved = resolvedScroll(bg: bg, object: object, resource: resource)
            return BackgroundOffset(index: bg, x: resolved.x, y: resolved.y)
        }
    }

    func isLikelyFieldFrame() -> Bool {
        guard displayMode() == 0 else { return false }
        return resolveFieldObjects() >= 3
    }

    func playerSpriteCandidate() -> SpriteFrame? {
        spriteFrames()
            .filter {
                $0.width >= 8 && $0.width <= 48 &&
                $0.height >= 16 && $0.height <= 48 &&
                $0.screenX > -24 && $0.screenX < 232 &&
                $0.screenY >= 18 && $0.screenY < 154
            }
            .min { lhs, rhs in
                let lx = Double(lhs.screenX) + Double(lhs.width) * 0.5
                let ly = Double(lhs.screenY) + Double(lhs.height) * 0.75
                let rx = Double(rhs.screenX) + Double(rhs.width) * 0.5
                let ry = Double(rhs.screenY) + Double(rhs.height) * 0.75
                let ld = (lx - 120) * (lx - 120) + (ly - 92) * (ly - 92)
                let rd = (rx - 120) * (rx - 120) + (ry - 92) * (ry - 92)
                return ld < rd
            }
    }

    // MARK: - Authored portrait field

    /// Builds a true 240x520 field view from the live Webfoot field resources.
    /// Nothing is repeated, clamped, guessed or stretched. The 160px hardware
    /// view remains the center of the camera and the extra 180px above/below are
    /// read from adjacent authored chunks. Tile graphics and RGB555 colours come
    /// from the live VRAM/palette state, so animation and palette changes remain
    /// exactly the game's own.
    func authoredPortraitBackgroundImage(height portraitHeight: Int = 520) -> CGImage? {
        guard portraitHeight >= 160,
              displayMode() == 0,
              resolveFieldObjects() >= 3 else { return nil }

        let dispcnt = read16(0x0400_0000)
        var backgrounds: [RegularBG] = []
        for bg in 0...3 {
            guard fieldObjects[bg] != 0,
                  (dispcnt & (UInt16(1) << UInt16(8 + bg))) != 0 else { continue }
            let cnt = read16(0x0400_0008 + UInt32(bg * 2))
            backgrounds.append(RegularBG(
                index: bg,
                priority: Int(cnt & 0x3),
                charBase: 0x0600_0000 + UInt32((cnt >> 2) & 0x3) * 0x4000,
                is8bpp: (cnt & 0x0080) != 0
            ))
        }
        guard backgrounds.count >= 3 else { return nil }

        // Back to front. Lower BG number wins ties on hardware.
        backgrounds.sort {
            if $0.priority != $1.priority { return $0.priority > $1.priority }
            return $0.index > $1.index
        }

        var scroll: [Int: (x: Int, y: Int)] = [:]
        for bg in backgrounds {
            let object = fieldObjects[bg.index]
            let resource = read32(object + 0x10)
            scroll[bg.index] = resolvedScroll(bg: bg.index, object: object, resource: resource)
        }

        let extensionY = (portraitHeight - 160) / 2
        let backdrop = read16(0x0500_0000)
        var rgba = [UInt8](repeating: 0, count: 240 * portraitHeight * 4)

        for y in 0..<portraitHeight {
            let hardwareY = y - extensionY
            for x in 0..<240 {
                let out = (y * 240 + x) * 4
                writeRGB555(backdrop, into: &rgba, at: out, alpha: 255)

                for bg in backgrounds {
                    guard let bgScroll = scroll[bg.index] else { continue }
                    let worldX = bgScroll.x + x
                    let worldY = bgScroll.y + hardwareY
                    guard let entry = fieldEntry(
                        object: fieldObjects[bg.index],
                        worldX: worldX,
                        worldY: worldY
                    ), let paletteIndex = fieldPaletteIndex(
                        bg: bg,
                        entry: entry,
                        worldX: worldX,
                        worldY: worldY
                    ), paletteIndex != 0 else { continue }

                    let color = read16(0x0500_0000 + UInt32(paletteIndex * 2))
                    writeRGB555(color, into: &rgba, at: out, alpha: 255)
                }
            }
        }
        return makeRGBAImage(rgba, width: 240, height: portraitHeight)
    }

    private func resolveFieldObjects() -> Int {
        var valid = 0
        for layer in 0..<4 {
            if fieldObjectValid(fieldObjects[layer], layer: layer) { valid += 1 }
        }
        if valid >= 3 { return valid }

        fieldObjects = [UInt32](repeating: 0, count: 4)
        var address: UInt32 = 0x0200_0000
        while address + 0x2030 < 0x0204_0000 {
            let resource = read32(address + 0x10)
            if isROMPointer(resource), read32(resource) == alfpFieldResourceVtable {
                let width = Int(read32(resource + 4))
                let height = Int(read32(resource + 8))
                let layer = Int((read32(resource + 0x10) >> 16) & 0xFF)
                let columns = Int(read8(resource + 0x14))
                let rows = Int(read8(resource + 0x15))
                if layer >= 0, layer < 4,
                   width > 0, height > 0,
                   width % 256 == 0, height % 256 == 0,
                   columns > 0, rows > 0,
                   columns * rows <= 0xFF {
                    fieldObjects[layer] = address
                }
            }
            address += 4
        }
        return fieldObjects.enumerated().filter { fieldObjectValid($0.element, layer: $0.offset) }.count
    }

    private func fieldObjectValid(_ object: UInt32, layer: Int) -> Bool {
        guard object >= 0x0200_0000, object + 0x2030 < 0x0204_0000 else { return false }
        let resource = read32(object + 0x10)
        guard isROMPointer(resource), read32(resource) == alfpFieldResourceVtable else { return false }
        let resourceLayer = Int((read32(resource + 0x10) >> 16) & 0xFF)
        let columns = Int(read8(resource + 0x14))
        let rows = Int(read8(resource + 0x15))
        return resourceLayer == layer && columns > 0 && rows > 0 && columns * rows <= 0xFF
    }

    private func fieldEntry(object: UInt32, worldX: Int, worldY: Int) -> UInt16? {
        guard worldX >= 0, worldY >= 0, object != 0 else { return nil }
        let resource = read32(object + 0x10)
        guard isROMPointer(resource) else { return nil }
        let columns = Int(read8(resource + 0x14))
        let rows = Int(read8(resource + 0x15))
        guard columns > 0, rows > 0,
              worldX < columns * 256,
              worldY < rows * 256 else { return nil }

        let tileX = worldX >> 3
        let tileY = worldY >> 3
        let chunkX = tileX >> 5
        let chunkY = tileY >> 5
        let chunkIndex = chunkY * columns + chunkX
        guard chunkIndex >= 0, chunkIndex <= 0xFE else { return nil }

        let localX = tileX & 31
        let localY = tileY & 31
        let byteOffset = (localY * 32 + localX) * 2

        for slot in 0..<4 where Int(read8(object + 0x24 + UInt32(slot))) == chunkIndex {
            let base = object + 0x30 + UInt32(slot * fieldChunkBytes + byteOffset)
            return read16(base)
        }

        let descriptor = read32(resource + 0x18 + UInt32(chunkIndex * 4))
        guard let chunk = decodedFieldChunk(descriptor), byteOffset + 1 < chunk.count else { return nil }
        return UInt16(chunk[byteOffset]) | (UInt16(chunk[byteOffset + 1]) << 8)
    }

    private func decodedFieldChunk(_ descriptor: UInt32) -> Data? {
        if let cached = decodedFieldChunks[descriptor] { return cached }
        guard let romImage,
              isROMPointer(descriptor),
              let offset = romImage.fileOffset(fromROMPointer: descriptor),
              let decoded = try? WebfootDecoder.decodeResource(in: romImage, at: offset).data,
              decoded.count == fieldChunkBytes else { return nil }
        decodedFieldChunks[descriptor] = decoded
        return decoded
    }

    private func resolvedScroll(bg: Int, object: UInt32, resource: UInt32) -> (x: Int, y: Int) {
        let rawX = Int(read16(0x0400_0010 + UInt32(bg * 4)))
        let rawY = Int(read16(0x0400_0012 + UInt32(bg * 4)))
        guard object != 0, isROMPointer(resource) else { return (rawX, rawY) }
        let columns = Int(read8(resource + 0x14))
        let rows = Int(read8(resource + 0x15))
        return (
            reconstructScroll(raw: rawX, dimension: columns * 256, object: object, columns: columns, axisX: true),
            reconstructScroll(raw: rawY, dimension: rows * 256, object: object, columns: columns, axisX: false)
        )
    }

    /// Some emulators preserve Webfoot's upper scroll bits and some expose only
    /// the GBA 9-bit ring. If upper bits are missing, infer the 512px page from
    /// the live four-chunk owner table. This does not guess a map: candidates are
    /// accepted solely by overlap with chunks the game itself has cached.
    private func reconstructScroll(raw: Int, dimension: Int, object: UInt32, columns: Int, axisX: Bool) -> Int {
        guard dimension > 512, raw < 512, columns > 0 else { return raw }
        var owners: [Int] = []
        for slot in 0..<4 {
            let owner = Int(read8(object + 0x24 + UInt32(slot)))
            if owner != 0xFF { owners.append(owner) }
        }
        guard !owners.isEmpty else { return raw }

        var best = raw
        var bestScore = -1
        var candidate = raw
        while candidate < dimension {
            let startChunk = candidate / 256
            let endCoord = min(dimension - 1, candidate + (axisX ? 239 : 159))
            let endChunk = endCoord / 256
            var score = 0
            for owner in owners {
                let ownerAxis = axisX ? (owner % columns) : (owner / columns)
                if ownerAxis >= startChunk && ownerAxis <= endChunk { score += 1 }
            }
            if score > bestScore {
                bestScore = score
                best = candidate
            }
            candidate += 512
        }
        return best
    }

    private func fieldPaletteIndex(bg: RegularBG, entry: UInt16, worldX: Int, worldY: Int) -> Int? {
        let tileNumber = Int(entry & 0x03FF)
        let hFlip = (entry & 0x0400) != 0
        let vFlip = (entry & 0x0800) != 0
        let px0 = worldX & 7
        let py0 = worldY & 7
        let px = hFlip ? 7 - px0 : px0
        let py = vFlip ? 7 - py0 : py0

        if bg.is8bpp {
            let address = bg.charBase + UInt32(tileNumber * 64 + py * 8 + px)
            return Int(read8(address))
        }

        let address = bg.charBase + UInt32(tileNumber * 32 + py * 4 + px / 2)
        let packed = read8(address)
        let nibble = px & 1 == 0 ? packed & 0x0F : packed >> 4
        guard nibble != 0 else { return 0 }
        let bank = Int((entry >> 12) & 0xF)
        return bank * 16 + Int(nibble)
    }

    // MARK: - OAM sprites / hardware frame

    func spriteFrames() -> [SpriteFrame] {
        let dispcnt = read16(0x0400_0000)
        let oneDimensional = (dispcnt & 0x0040) != 0
        let mode = Int(dispcnt & 0x0007)
        let objectBase: UInt32 = mode >= 3 ? 0x0601_4000 : 0x0601_0000
        var output: [SpriteFrame] = []
        output.reserveCapacity(64)

        for index in 0..<128 {
            let base = 0x0700_0000 + UInt32(index * 8)
            let attr0 = read16(base)
            let attr1 = read16(base + 2)
            let attr2 = read16(base + 4)
            let affine = (attr0 & 0x0100) != 0
            if affine || (attr0 & 0x0200) != 0 { continue }

            let shape = Int((attr0 >> 14) & 0x3)
            let size = Int((attr1 >> 14) & 0x3)
            guard let dimensions = spriteDimensions(shape: shape, size: size) else { continue }

            var x = Int(attr1 & 0x01FF)
            var y = Int(attr0 & 0x00FF)
            if x >= 480 { x -= 512 }
            if y >= 224 { y -= 256 }

            let width = dimensions.0
            let height = dimensions.1
            if x + width <= -40 || x >= 280 || y + height <= -40 || y >= 200 { continue }

            let is8bpp = (attr0 & 0x2000) != 0
            let hFlip = (attr1 & 0x1000) != 0
            let vFlip = (attr1 & 0x2000) != 0
            let tileIndex = Int(attr2 & 0x03FF)
            let paletteBank = Int((attr2 >> 12) & 0xF)
            let priority = Int((attr2 >> 10) & 0x3)
            guard let image = makeSpriteImage(
                objectBase: objectBase,
                tileIndex: tileIndex,
                width: width,
                height: height,
                is8bpp: is8bpp,
                paletteBank: paletteBank,
                oneDimensional: oneDimensional,
                hFlip: hFlip,
                vFlip: vFlip
            ) else { continue }
            output.append(SpriteFrame(screenX: x, screenY: y, width: width, height: height, priority: priority, image: image))
        }
        return output
    }

    func framebufferImage() -> CGImage? {
        let bytes = Data(bytes: videoBuffer.baseAddress!, count: 240 * 160 * MemoryLayout<color_t>.stride)
        guard let provider = CGDataProvider(data: bytes as CFData) else { return nil }
        return CGImage(
            width: 240,
            height: 160,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: 240 * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    // MARK: - Input / audio / memory

    private func apply(input: InputState) {
        var next: UInt32 = 0
        if input.a { next |= 1 << UInt32(GBA_KEY_A.rawValue) }
        if input.b { next |= 1 << UInt32(GBA_KEY_B.rawValue) }
        if input.select { next |= 1 << UInt32(GBA_KEY_SELECT.rawValue) }
        if input.start { next |= 1 << UInt32(GBA_KEY_START.rawValue) }
        if input.right { next |= 1 << UInt32(GBA_KEY_RIGHT.rawValue) }
        if input.left { next |= 1 << UInt32(GBA_KEY_LEFT.rawValue) }
        if input.up { next |= 1 << UInt32(GBA_KEY_UP.rawValue) }
        if input.down { next |= 1 << UInt32(GBA_KEY_DOWN.rawValue) }
        if input.r { next |= 1 << UInt32(GBA_KEY_R.rawValue) }
        if input.l { next |= 1 << UInt32(GBA_KEY_L.rawValue) }
        keys = next
        core.pointee.setKeys(core, keys)
    }

    private func pumpAudio() {
        let left = core.pointee.getAudioChannel(core, 0)
        let right = core.pointee.getAudioChannel(core, 1)
        var available = Int(blip_samples_avail(left))
        available = min(available, sampleCount)
        guard available > 0 else { return }
        blip_read_samples(left, audioSamples.baseAddress, Int32(available), 1)
        blip_read_samples(right, audioSamples.baseAddress?.advanced(by: 1), Int32(available), 1)
        _ = bridge.writeAudioSamples(samples: UnsafeRawBufferPointer(start: audioSamples.baseAddress, count: available * 4))
    }

    private func read8(_ address: UInt32) -> UInt8 {
        UInt8(truncatingIfNeeded: core.pointee.rawRead8(core, address, -1))
    }

    private func read16(_ address: UInt32) -> UInt16 {
        UInt16(truncatingIfNeeded: core.pointee.rawRead16(core, address, -1))
    }

    private func read32(_ address: UInt32) -> UInt32 {
        UInt32(read16(address)) | (UInt32(read16(address + 2)) << 16)
    }

    private func isROMPointer(_ value: UInt32) -> Bool {
        value >= 0x0800_0000 && value < 0x0880_0000
    }

    private func makeSpriteImage(
        objectBase: UInt32,
        tileIndex: Int,
        width: Int,
        height: Int,
        is8bpp: Bool,
        paletteBank: Int,
        oneDimensional: Bool,
        hFlip: Bool,
        vFlip: Bool
    ) -> CGImage? {
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let tilesWide = width / 8
        let tileBytes = is8bpp ? 64 : 32
        let baseOffset = tileIndex * 32

        for outY in 0..<height {
            let sourceY = vFlip ? (height - 1 - outY) : outY
            let tileY = sourceY / 8
            let pixelY = sourceY & 7
            for outX in 0..<width {
                let sourceX = hFlip ? (width - 1 - outX) : outX
                let tileX = sourceX / 8
                let pixelX = sourceX & 7
                let tileNumber = oneDimensional ? tileY * tilesWide + tileX : tileY * 32 + tileX
                let tileAddress = objectBase + UInt32(baseOffset + tileNumber * tileBytes)
                let paletteIndex: Int
                if is8bpp {
                    paletteIndex = Int(read8(tileAddress + UInt32(pixelY * 8 + pixelX)))
                } else {
                    let packed = read8(tileAddress + UInt32(pixelY * 4 + pixelX / 2))
                    let nibble = pixelX & 1 == 0 ? (packed & 0x0F) : (packed >> 4)
                    paletteIndex = paletteBank * 16 + Int(nibble)
                }
                let out = (outY * width + outX) * 4
                if paletteIndex == 0 {
                    rgba[out + 3] = 0
                    continue
                }
                let color = read16(0x0500_0200 + UInt32(paletteIndex * 2))
                writeRGB555(color, into: &rgba, at: out, alpha: 255)
            }
        }
        return makeRGBAImage(rgba, width: width, height: height, alphaInfo: .premultipliedLast)
    }

    private func makeRGBAImage(
        _ rgba: [UInt8],
        width: Int,
        height: Int,
        alphaInfo: CGImageAlphaInfo = .noneSkipLast
    ) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: alphaInfo.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    private func writeRGB555(_ value: UInt16, into rgba: inout [UInt8], at offset: Int, alpha: UInt8) {
        let r = Int(value & 0x1F)
        let g = Int((value >> 5) & 0x1F)
        let b = Int((value >> 10) & 0x1F)
        rgba[offset] = UInt8((r * 255 + 15) / 31)
        rgba[offset + 1] = UInt8((g * 255 + 15) / 31)
        rgba[offset + 2] = UInt8((b * 255 + 15) / 31)
        rgba[offset + 3] = alpha
    }

    private func spriteDimensions(shape: Int, size: Int) -> (Int, Int)? {
        switch (shape, size) {
        case (0, 0): return (8, 8)
        case (0, 1): return (16, 16)
        case (0, 2): return (32, 32)
        case (0, 3): return (64, 64)
        case (1, 0): return (16, 8)
        case (1, 1): return (32, 8)
        case (1, 2): return (32, 16)
        case (1, 3): return (64, 32)
        case (2, 0): return (8, 16)
        case (2, 1): return (8, 32)
        case (2, 2): return (16, 32)
        case (2, 3): return (32, 64)
        default: return nil
        }
    }

    private func filePath(_ url: URL) -> String {
        if #available(iOS 16.0, *) { return url.path(percentEncoded: false) }
        return url.path
    }

    enum RuntimeError: LocalizedError {
        case coreAllocationFailed
        case coreInitializationFailed
        case romLoadFailed

        var errorDescription: String? {
            switch self {
            case .coreAllocationFailed: return "Could not allocate the hidden GBA runtime."
            case .coreInitializationFailed: return "Could not initialize the hidden GBA runtime."
            case .romLoadFailed: return "Could not load the imported game into the hidden runtime."
            }
        }
    }
}
