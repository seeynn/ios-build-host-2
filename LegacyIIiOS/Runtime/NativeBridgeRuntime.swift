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

    func displayMode() -> Int {
        Int(read16(0x0400_0000) & 0x7)
    }

    func backgroundOffsets() -> [BackgroundOffset] {
        let dispcnt = read16(0x0400_0000)
        let mode = Int(dispcnt & 0x7)
        guard mode == 0 || mode == 1 else { return [] }
        let maxRegularBG = mode == 0 ? 3 : 1
        return (0...maxRegularBG).compactMap { bg in
            let enabled = (dispcnt & (UInt16(1) << UInt16(8 + bg))) != 0
            guard enabled else { return nil }
            return BackgroundOffset(
                index: bg,
                x: Int(read16(0x0400_0010 + UInt32(bg * 4)) & 0x01FF),
                y: Int(read16(0x0400_0012 + UInt32(bg * 4)) & 0x01FF)
            )
        }
    }

    /// Field screens are bright, tile-backed mode-0/1 scenes with at least one
    /// normal actor-sized OAM object. Title cards, legal screens and the small
    /// opening cutscenes fail one of these checks and are presented cinematically.
    func isLikelyFieldFrame() -> Bool {
        let mode = displayMode()
        guard mode == 0 || mode == 1, framebufferNonDarkRatio() > 0.52 else { return false }
        return spriteFrames().contains { sprite in
            sprite.width >= 8 && sprite.width <= 48 &&
            sprite.height >= 16 && sprite.height <= 48 &&
            sprite.screenX > -24 && sprite.screenX < 232 &&
            sprite.screenY >= 18 && sprite.screenY < 154
        }
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

    /// The game keeps current resource pointers in work RAM. Looking for one of
    /// the catalogued scene descriptors gives the portrait renderer a practical
    /// live map identity without hard-coding story order.
    func activeSceneDescriptorOffset(candidates: [Int]) -> Int? {
        guard !candidates.isEmpty else { return nil }
        let pointers = Set(candidates.map { UInt32(0x0800_0000 + $0) })
        var hits: [UInt32: Int] = [:]

        func scan(_ start: UInt32, _ byteCount: Int) {
            var address = start
            let end = start + UInt32(byteCount)
            while address + 3 < end {
                let value = read32(address)
                if pointers.contains(value) { hits[value, default: 0] += 1 }
                address += 4
            }
        }

        scan(0x0200_0000, 0x40000)
        scan(0x0300_0000, 0x8000)

        guard let best = hits.max(by: { $0.value < $1.value })?.key else { return nil }
        return Int(best - 0x0800_0000)
    }

    func colorizedSceneImage(_ scene: ALFPSceneData.IndexedScene) -> CGImage? {
        var rgba = [UInt8](repeating: 0, count: scene.width * scene.height * 4)
        for (pixel, paletteIndex) in scene.pixels.enumerated() {
            let color = read16(0x0500_0000 + UInt32(Int(paletteIndex) * 2))
            writeBGR555(color, into: &rgba, at: pixel * 4, alpha: 255)
        }
        return makeRGBAImage(rgba, width: scene.width, height: scene.height)
    }

    /// A deliberate portrait treatment for title/legal/cutscene frames. It fills
    /// the complete 240x520 canvas with an ambient version of the current frame,
    /// then enlarges the authored content. This replaces the old tiny 240x160 box
    /// and prevents duplicated HUD/text strips from appearing above/below it.
    func cinematicPortraitImage(height portraitHeight: Int = 520) -> CGImage? {
        guard let source = framebufferRGBA() else { return nil }
        let sourceWidth = 240
        let sourceHeight = 160
        var output = [UInt8](repeating: 0, count: sourceWidth * portraitHeight * 4)

        // Full-height ambient backdrop. Keep it dark so the sharp foreground frame
        // reads as intentional rather than as a stretched emulator screen.
        for y in 0..<portraitHeight {
            let sy = min(sourceHeight - 1, y * sourceHeight / portraitHeight)
            for x in 0..<sourceWidth {
                let src = (sy * sourceWidth + x) * 4
                let dst = (y * sourceWidth + x) * 4
                output[dst] = UInt8(Int(source[src]) * 34 / 100)
                output[dst + 1] = UInt8(Int(source[src + 1]) * 34 / 100)
                output[dst + 2] = UInt8(Int(source[src + 2]) * 34 / 100)
                output[dst + 3] = 255
            }
        }

        let bounds = visibleContentBounds(source, width: sourceWidth, height: sourceHeight)
        let darkRatio = 1.0 - framebufferNonDarkRatio()
        let foregroundRect: (x: Int, y: Int, w: Int, h: Int)
        let targetRect: (x: Int, y: Int, w: Int, h: Int)

        if darkRatio > 0.58, let bounds {
            let pad = 6
            let x = max(0, bounds.x - pad)
            let y = max(0, bounds.y - pad)
            let w = min(sourceWidth - x, bounds.w + pad * 2)
            let h = min(sourceHeight - y, bounds.h + pad * 2)
            foregroundRect = (x, y, max(1, w), max(1, h))

            let uniform = min(224.0 / Double(max(w, 1)), 300.0 / Double(max(h, 1)))
            var tw = max(1, Int(Double(w) * uniform))
            var th = max(1, Int(Double(h) * uniform))
            // Very wide old-GBA cutscene plates looked tiny on a Pro Max. Give
            // them a portrait-aware minimum height while preserving their width.
            if Double(w) / Double(max(h, 1)) > 2.4 {
                tw = min(232, max(tw, 220))
                th = max(th, 132)
            }
            targetRect = ((240 - tw) / 2, (portraitHeight - th) / 2, tw, th)
        } else {
            foregroundRect = (0, 0, sourceWidth, sourceHeight)
            // Full-frame title/menu/legal art gets a larger 240x224 presentation
            // rather than being left as a tiny 160px-high Game Boy rectangle.
            targetRect = (0, (portraitHeight - 224) / 2, 240, 224)
        }

        blitNearest(
            source,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            sourceRect: foregroundRect,
            into: &output,
            destinationWidth: sourceWidth,
            destinationHeight: portraitHeight,
            destinationRect: targetRect
        )
        return makeRGBAImage(output, width: sourceWidth, height: portraitHeight)
    }

    /// Reconstruct the live GBA regular backgrounds into a portrait canvas. This
    /// remains a fallback for field scenes whose authored descriptor is not yet
    /// resolved; the main field path uses full ROM scene data instead.
    func portraitBackgroundImage(height portraitHeight: Int = 520) -> CGImage? {
        let dispcnt = read16(0x0400_0000)
        let mode = Int(dispcnt & 0x7)
        guard mode == 0 || mode == 1 else {
            return cinematicPortraitImage(height: portraitHeight)
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

        guard !backgrounds.isEmpty else { return cinematicPortraitImage(height: portraitHeight) }
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
                    let rawX = bg.hOffset + x
                    let rawY = bg.vOffset + relativeScreenY
                    // Never modulo-wrap the extra portrait rows. Hardware wrap is
                    // correct for 160px GBA output but produced the repeated bands
                    // seen on iPhone. Clamp to the streamed tilemap edge instead.
                    let mapX = min(max(rawX, 0), bg.width - 1)
                    let mapY = min(max(rawY, 0), bg.height - 1)
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

    private func framebufferRGBA() -> [UInt8]? {
        guard let base = videoBuffer.baseAddress else { return nil }
        let raw = UnsafeRawPointer(base).assumingMemoryBound(to: UInt8.self)
        var rgba = [UInt8](repeating: 0, count: 240 * 160 * 4)
        for pixel in 0..<(240 * 160) {
            let source = pixel * 4
            let dest = source
            rgba[dest] = raw[source + 2]
            rgba[dest + 1] = raw[source + 1]
            rgba[dest + 2] = raw[source]
            rgba[dest + 3] = 255
        }
        return rgba
    }

    private func framebufferNonDarkRatio() -> Double {
        guard let rgba = framebufferRGBA() else { return 0 }
        var visible = 0
        let samples = 240 * 160 / 4
        for pixel in stride(from: 0, to: 240 * 160, by: 4) {
            let offset = pixel * 4
            if Int(rgba[offset]) + Int(rgba[offset + 1]) + Int(rgba[offset + 2]) > 54 {
                visible += 1
            }
        }
        return Double(visible) / Double(max(samples, 1))
    }

    private func visibleContentBounds(_ rgba: [UInt8], width: Int, height: Int) -> (x: Int, y: Int, w: Int, h: Int)? {
        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let sum = Int(rgba[offset]) + Int(rgba[offset + 1]) + Int(rgba[offset + 2])
                if sum > 66 {
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                    minY = min(minY, y)
                    maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return (minX, minY, maxX - minX + 1, maxY - minY + 1)
    }

    private func blitNearest(
        _ source: [UInt8],
        sourceWidth: Int,
        sourceHeight: Int,
        sourceRect: (x: Int, y: Int, w: Int, h: Int),
        into destination: inout [UInt8],
        destinationWidth: Int,
        destinationHeight: Int,
        destinationRect: (x: Int, y: Int, w: Int, h: Int)
    ) {
        guard sourceRect.w > 0, sourceRect.h > 0, destinationRect.w > 0, destinationRect.h > 0 else { return }
        for dy in 0..<destinationRect.h {
            let outY = destinationRect.y + dy
            guard outY >= 0, outY < destinationHeight else { continue }
            let sy = sourceRect.y + min(sourceRect.h - 1, dy * sourceRect.h / destinationRect.h)
            for dx in 0..<destinationRect.w {
                let outX = destinationRect.x + dx
                guard outX >= 0, outX < destinationWidth else { continue }
                let sx = sourceRect.x + min(sourceRect.w - 1, dx * sourceRect.w / destinationRect.w)
                let src = (sy * sourceWidth + sx) * 4
                let dst = (outY * destinationWidth + outX) * 4
                destination[dst] = source[src]
                destination[dst + 1] = source[src + 1]
                destination[dst + 2] = source[src + 2]
                destination[dst + 3] = 255
            }
        }
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
