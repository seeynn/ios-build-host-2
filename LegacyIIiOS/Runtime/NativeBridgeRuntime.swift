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

    private let bridge = EmulatorBridge()
    private let core: UnsafeMutablePointer<mCore>
    private var videoBuffer: UnsafeMutableBufferPointer<color_t>
    private var audioSamples: UnsafeMutableBufferPointer<Int16>
    private var keys: UInt32 = 0
    private var started = false

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
        bridge.resetAudioQueue()
    }

    /// Reconstruct the live GBA regular backgrounds into a portrait canvas.
    /// The original 240×160 hardware viewport sits in the middle of the 240×520
    /// canvas, with additional world rows sampled above and below from the live
    /// BG tilemaps. No 240×160 emulator window is shown during regular field play.
    func portraitBackgroundImage(height portraitHeight: Int = 520) -> CGImage? {
        let dispcnt = read16(0x0400_0000)
        let mode = Int(dispcnt & 0x7)
        guard mode == 0 || mode == 1 else {
            return fallbackPortraitImage(height: portraitHeight)
        }

        var backgrounds: [RegularBG] = []
        let maxRegularBG = mode == 0 ? 3 : 1
        for bg in 0...maxRegularBG {
            let enabled = (dispcnt & (UInt16(1) << UInt16(8 + bg))) != 0
            guard enabled else { continue }
            let cnt = read16(0x0400_0008 + UInt32(bg * 2))
            let sizeCode = Int((cnt >> 14) & 0x3)
            let dimensions: (Int, Int)
            switch sizeCode {
            case 0: dimensions = (256, 256)
            case 1: dimensions = (512, 256)
            case 2: dimensions = (256, 512)
            default: dimensions = (512, 512)
            }
            backgrounds.append(RegularBG(
                index: bg,
                priority: Int(cnt & 0x3),
                charBase: 0x0600_0000 + UInt32((cnt >> 2) & 0x3) * 0x4000,
                screenBase: 0x0600_0000 + UInt32((cnt >> 8) & 0x1F) * 0x800,
                is8bpp: (cnt & 0x0080) != 0,
                width: dimensions.0,
                height: dimensions.1,
                hOffset: Int(read16(0x0400_0010 + UInt32(bg * 4)) & 0x01FF),
                vOffset: Int(read16(0x0400_0012 + UInt32(bg * 4)) & 0x01FF),
                sizeCode: sizeCode
            ))
        }

        guard !backgrounds.isEmpty else { return fallbackPortraitImage(height: portraitHeight) }

        // Draw low-priority content first. At equal priority, a lower BG number is on top.
        backgrounds.sort {
            if $0.priority != $1.priority { return $0.priority > $1.priority }
            return $0.index > $1.index
        }

        var rgba = [UInt8](repeating: 0, count: 240 * portraitHeight * 4)
        let backdrop = read16(0x0500_0000)
        let verticalExtension = (portraitHeight - 160) / 2

        for y in 0..<portraitHeight {
            for x in 0..<240 {
                let out = (y * 240 + x) * 4
                writeBGR555(backdrop, into: &rgba, at: out, alpha: 255)
                let relativeScreenY = y - verticalExtension

                for bg in backgrounds {
                    let mapX = positiveModulo(bg.hOffset + x, bg.width)
                    let mapY = positiveModulo(bg.vOffset + relativeScreenY, bg.height)
                    guard let paletteIndex = regularBGPaletteIndex(bg, mapX: mapX, mapY: mapY), paletteIndex != 0 else { continue }
                    let color = read16(0x0500_0000 + UInt32(paletteIndex * 2))
                    writeBGR555(color, into: &rgba, at: out, alpha: 255)
                }
            }
        }

        return makeRGBAImage(rgba, width: 240, height: portraitHeight)
    }

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
            // Preserve off-screen actors below the original hardware viewport instead
            // of folding every y>=160 to the top. Only the wrap band is negative.
            if x >= 480 { x -= 512 }
            if y >= 224 { y -= 256 }

            let width = dimensions.0
            let height = dimensions.1
            if x + width <= -40 || x >= 280 || y + height <= -190 || y >= 350 { continue }

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

    private func regularBGPaletteIndex(_ bg: RegularBG, mapX: Int, mapY: Int) -> Int? {
        let tileX = mapX >> 3
        let tileY = mapY >> 3
        let blockX = tileX >> 5
        let blockY = tileY >> 5
        let blockIndex: Int
        switch bg.sizeCode {
        case 0: blockIndex = 0
        case 1: blockIndex = blockX
        case 2: blockIndex = blockY
        default: blockIndex = blockY * 2 + blockX
        }

        let entryX = tileX & 31
        let entryY = tileY & 31
        let entryAddress = bg.screenBase + UInt32(blockIndex * 0x800 + (entryY * 32 + entryX) * 2)
        let entry = read16(entryAddress)
        let tileNumber = Int(entry & 0x03FF)
        let hFlip = (entry & 0x0400) != 0
        let vFlip = (entry & 0x0800) != 0
        let localX = hFlip ? 7 - (mapX & 7) : (mapX & 7)
        let localY = vFlip ? 7 - (mapY & 7) : (mapY & 7)

        if bg.is8bpp {
            let address = bg.charBase + UInt32(tileNumber * 64 + localY * 8 + localX)
            return Int(read8(address))
        } else {
            let address = bg.charBase + UInt32(tileNumber * 32 + localY * 4 + localX / 2)
            let packed = read8(address)
            let nibble = localX & 1 == 0 ? packed & 0x0F : packed >> 4
            if nibble == 0 { return 0 }
            let bank = Int((entry >> 12) & 0xF)
            return bank * 16 + Int(nibble)
        }
    }

    private func fallbackPortraitImage(height portraitHeight: Int) -> CGImage? {
        guard let frame = framebufferImage() else { return nil }
        guard let frameData = frame.dataProvider?.data,
              let bytes = CFDataGetBytePtr(frameData) else { return nil }
        var rgba = [UInt8](repeating: 0, count: 240 * portraitHeight * 4)
        let yOffset = max(0, (portraitHeight - 160) / 2)

        for y in 0..<160 {
            for x in 0..<240 {
                let source = (y * 240 + x) * 4
                let dest = ((y + yOffset) * 240 + x) * 4
                // mGBA's color_t buffer is BGRA on Apple little-endian targets.
                rgba[dest] = bytes[source + 2]
                rgba[dest + 1] = bytes[source + 1]
                rgba[dest + 2] = bytes[source]
                rgba[dest + 3] = 255
            }
        }
        return makeRGBAImage(rgba, width: 240, height: portraitHeight)
    }

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
                if paletteIndex == 0 { rgba[out + 3] = 0; continue }
                let color = read16(0x0500_0200 + UInt32(paletteIndex * 2))
                writeBGR555(color, into: &rgba, at: out, alpha: 255)
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

    private func writeBGR555(_ value: UInt16, into rgba: inout [UInt8], at offset: Int, alpha: UInt8) {
        let r = Int(value & 0x1F)
        let g = Int((value >> 5) & 0x1F)
        let b = Int((value >> 10) & 0x1F)
        rgba[offset] = UInt8((r * 255 + 15) / 31)
        rgba[offset + 1] = UInt8((g * 255 + 15) / 31)
        rgba[offset + 2] = UInt8((b * 255 + 15) / 31)
        rgba[offset + 3] = alpha
    }

    private func positiveModulo(_ value: Int, _ modulus: Int) -> Int {
        let result = value % modulus
        return result >= 0 ? result : result + modulus
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
