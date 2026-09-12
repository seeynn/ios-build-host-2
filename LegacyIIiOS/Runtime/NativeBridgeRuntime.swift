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

    private let bridge = EmulatorBridge()
    private let core: UnsafeMutablePointer<mCore>
    private var videoBuffer: UnsafeMutableBufferPointer<color_t>
    private var audioSamples: UnsafeMutableBufferPointer<Int16>
    private var keys: UInt32 = 0
    private var started = false

    private let sampleRate = 32_768.0
    private let sampleCount = 1024

    init() throws {
        guard let created = GBACoreCreate() else {
            throw RuntimeError.coreAllocationFailed
        }
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
        guard mCoreLoadFile(core, romPath) else {
            throw RuntimeError.romLoadFailed
        }
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

    func backgroundPaletteRGBA() -> [UInt8] {
        var rgba = [UInt8](repeating: 0, count: 256 * 4)
        for index in 0..<256 {
            let color = read16(0x0500_0000 + UInt32(index * 2))
            writeBGR555(color, into: &rgba, at: index * 4, transparent: false)
        }
        return rgba
    }

    func spriteFrames() -> [SpriteFrame] {
        let dispcnt = read16(0x0400_0000)
        let oneDimensional = (dispcnt & 0x0040) != 0
        let mode = Int(dispcnt & 0x0007)
        let objectBase: UInt32 = mode >= 3 ? 0x0601_4000 : 0x0601_0000

        var output: [SpriteFrame] = []
        output.reserveCapacity(48)

        for index in 0..<128 {
            let base = 0x0700_0000 + UInt32(index * 8)
            let attr0 = read16(base)
            let attr1 = read16(base + 2)
            let attr2 = read16(base + 4)

            let affine = (attr0 & 0x0100) != 0
            if !affine && (attr0 & 0x0200) != 0 { continue }
            if affine { continue }

            let shape = Int((attr0 >> 14) & 0x3)
            let size = Int((attr1 >> 14) & 0x3)
            guard let dimensions = spriteDimensions(shape: shape, size: size) else { continue }

            var x = Int(attr1 & 0x01FF)
            var y = Int(attr0 & 0x00FF)
            if x >= 256 { x -= 512 }
            if y >= 160 { y -= 256 }

            let width = dimensions.0
            let height = dimensions.1
            if x + width <= -8 || x >= 248 || y + height <= -8 || y >= 168 { continue }

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

            output.append(SpriteFrame(
                screenX: x,
                screenY: y,
                width: width,
                height: height,
                priority: priority,
                image: image
            ))
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
        let raw = UnsafeRawBufferPointer(start: audioSamples.baseAddress, count: available * 4)
        _ = bridge.writeAudioSamples(samples: raw)
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
        let tilesHigh = height / 8
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

                let tileNumber: Int
                if oneDimensional {
                    tileNumber = tileY * tilesWide + tileX
                } else {
                    tileNumber = tileY * 32 + tileX
                }
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
                writeBGR555(color, into: &rgba, at: out, transparent: false)
            }
        }

        let data = Data(rgba) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    private func writeBGR555(_ value: UInt16, into rgba: inout [UInt8], at offset: Int, transparent: Bool) {
        let r5 = Int(value & 0x1F)
        let g5 = Int((value >> 5) & 0x1F)
        let b5 = Int((value >> 10) & 0x1F)
        rgba[offset] = UInt8((r5 * 255 + 15) / 31)
        rgba[offset + 1] = UInt8((g5 * 255 + 15) / 31)
        rgba[offset + 2] = UInt8((b5 * 255 + 15) / 31)
        rgba[offset + 3] = transparent ? 0 : 255
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
}

extension NativeBridgeRuntime {
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
