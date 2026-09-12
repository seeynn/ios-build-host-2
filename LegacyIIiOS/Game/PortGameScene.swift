import CoreGraphics
import Foundation
import SpriteKit

final class PortGameScene: SKScene {
    private let romURL: URL
    private let saveURL: URL

    private let backgroundNode = SKSpriteNode()
    private let actorLayer = SKNode()
    private let hudNode = SKSpriteNode()
    private let dialogueNode = SKSpriteNode()
    private let cinematicNode = SKSpriteNode()

    private var runtime: NativeBridgeRuntime?
    private var rom: ROMImage?
    private var sceneDescriptors: [Int] = []
    private var sceneCache: [Int: ALFPSceneData.IndexedScene] = [:]
    private var currentScene: ALFPSceneData.IndexedScene?
    private var currentSceneDescriptor: Int?
    private var currentSceneImage: CGImage?
    private var learnedPalette: [UInt8: UInt32] = [:]
    private var paletteConfidence: Double = 0

    private var cameraTopLeftX: Double?
    private var cameraTopLeftY: Double?
    private var lastScroll: NativeBridgeRuntime.BackgroundOffset?

    private var frameCounter = 0
    private var fieldConfidence = 0
    private var cinematicConfidence = 0
    private var fieldPresentationActive = false

    private let portraitHeight = 520
    private let originalViewportHeight = 160
    private let hudHeight = 40

    private var verticalExtension: Int {
        (portraitHeight - originalViewportHeight) / 2
    }

    var input = InputState()

    init(size: CGSize, romURL: URL, saveURL: URL) {
        self.romURL = romURL
        self.saveURL = saveURL
        super.init(size: size)
        scaleMode = .aspectFill
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMove(to view: SKView) {
        backgroundColor = .black
        view.ignoresSiblingOrder = true
        view.isMultipleTouchEnabled = true
        view.contentMode = .scaleAspectFill
        view.backgroundColor = .black

        backgroundNode.anchorPoint = CGPoint(x: 0, y: 0)
        backgroundNode.position = .zero
        backgroundNode.size = CGSize(width: 240, height: portraitHeight)
        backgroundNode.zPosition = -1000
        addChild(backgroundNode)

        cinematicNode.anchorPoint = CGPoint(x: 0, y: 0)
        cinematicNode.position = .zero
        cinematicNode.size = CGSize(width: 240, height: portraitHeight)
        cinematicNode.zPosition = -900
        addChild(cinematicNode)

        actorLayer.zPosition = 100
        addChild(actorLayer)

        hudNode.anchorPoint = CGPoint(x: 0, y: 0)
        hudNode.position = CGPoint(x: 0, y: portraitHeight - hudHeight - 10)
        hudNode.size = CGSize(width: 240, height: hudHeight)
        hudNode.zPosition = 5000
        hudNode.isHidden = true
        addChild(hudNode)

        dialogueNode.anchorPoint = CGPoint(x: 0.5, y: 0)
        dialogueNode.position = CGPoint(x: 120, y: 54)
        dialogueNode.zPosition = 5100
        dialogueNode.isHidden = true
        addChild(dialogueNode)

        do {
            let image = try ROMImage(data: Data(contentsOf: romURL, options: .mappedIfSafe))
            rom = image
            sceneDescriptors = ALFPSceneData.scanSceneDescriptors(in: image)

            let bridge = try NativeBridgeRuntime()
            try bridge.start(romURL: romURL, saveURL: saveURL)
            runtime = bridge
            showCinematic(bridge)
        } catch {
            installFailureWorld(message: error.localizedDescription)
        }
    }

    override func update(_ currentTime: TimeInterval) {
        guard let runtime else { return }
        runtime.runFrame(input: input)
        frameCounter &+= 1
        guard frameCounter == 1 || frameCounter % 2 == 0 else { return }
        refreshPresentation(runtime)
    }

    private func refreshPresentation(_ runtime: NativeBridgeRuntime) {
        let fieldNow = isConvincingFieldFrame(runtime)
        if fieldNow {
            fieldConfidence = min(8, fieldConfidence + 1)
            cinematicConfidence = 0
        } else {
            cinematicConfidence = min(8, cinematicConfidence + 1)
            fieldConfidence = 0
        }

        if !fieldPresentationActive && fieldConfidence >= 3 {
            fieldPresentationActive = true
            resetFieldCalibration(keepScene: false)
        } else if fieldPresentationActive && cinematicConfidence >= 3 {
            fieldPresentationActive = false
            resetFieldCalibration(keepScene: true)
        }

        if fieldPresentationActive {
            showField(runtime)
        } else {
            showCinematic(runtime)
        }
    }

    /// Menus contain OAM too, so simply finding a sprite is not enough. A field
    /// frame must have an actor-sized sprite reasonably close to the gameplay
    /// camera centre. This keeps title/save/options screens out of the world path.
    private func isConvincingFieldFrame(_ runtime: NativeBridgeRuntime) -> Bool {
        guard runtime.isLikelyFieldFrame(), let actor = runtime.playerSpriteCandidate() else { return false }
        let cx = Double(actor.screenX) + Double(actor.width) * 0.5
        let cy = Double(actor.screenY) + Double(actor.height) * 0.70
        return abs(cx - 120) < 74 && abs(cy - 92) < 62
    }

    private func showField(_ runtime: NativeBridgeRuntime) {
        cinematicNode.isHidden = true
        backgroundNode.isHidden = false
        actorLayer.isHidden = false

        // Never force the first decoded map underneath a different live scene.
        // That was the source of the checkerboard/rock corruption in the last IPA.
        if currentScene == nil || frameCounter % 90 == 0 {
            resolveCurrentScene(runtime)
        }

        if currentScene != nil {
            updateFieldCamera(runtime)
            refreshValidatedSceneImage(runtime)
        }

        refreshFieldBackground(runtime)
        refreshActors(runtime)
        refreshOriginalUI(runtime)
    }

    private func showCinematic(_ runtime: NativeBridgeRuntime) {
        backgroundNode.isHidden = true
        actorLayer.isHidden = true
        hudNode.isHidden = true
        dialogueNode.isHidden = true
        cinematicNode.isHidden = false

        guard let frame = runtime.framebufferImage(),
              let image = makePhoneCinematic(from: frame) else { return }
        let texture = SKTexture(cgImage: image)
        texture.filteringMode = .nearest
        cinematicNode.texture = texture
    }

    private func resolveCurrentScene(_ runtime: NativeBridgeRuntime) {
        guard let rom,
              let descriptor = runtime.activeSceneDescriptorOffset(candidates: sceneDescriptors) else {
            currentScene = nil
            currentSceneDescriptor = nil
            currentSceneImage = nil
            learnedPalette.removeAll(keepingCapacity: true)
            paletteConfidence = 0
            return
        }

        guard descriptor != currentSceneDescriptor || currentScene == nil else { return }

        do {
            let decoded: ALFPSceneData.IndexedScene
            if let cached = sceneCache[descriptor] {
                decoded = cached
            } else {
                decoded = try ALFPSceneData.decodeScene(in: rom, at: descriptor)
                sceneCache[descriptor] = decoded
            }
            currentSceneDescriptor = descriptor
            currentScene = decoded
            currentSceneImage = nil
            learnedPalette.removeAll(keepingCapacity: true)
            paletteConfidence = 0
            resetFieldCalibration(keepScene: true)
        } catch {
            currentScene = nil
            currentSceneDescriptor = nil
            currentSceneImage = nil
            learnedPalette.removeAll(keepingCapacity: true)
            paletteConfidence = 0
        }
    }

    private func updateFieldCamera(_ runtime: NativeBridgeRuntime) {
        guard let scene = currentScene else { return }
        let offsets = runtime.backgroundOffsets()
        let scroll = offsets.max(by: { $0.index < $1.index })

        if cameraTopLeftX == nil || cameraTopLeftY == nil {
            if let player = runtime.playerSpriteCandidate() {
                let playerCenterX = Double(player.screenX) + Double(player.width) * 0.5
                let playerFootY = Double(player.screenY + player.height - 2)
                cameraTopLeftX = Double(scene.spawnX) - playerCenterX
                cameraTopLeftY = Double(scene.spawnY) - playerFootY
            } else {
                cameraTopLeftX = Double(scene.spawnX - 120)
                cameraTopLeftY = Double(scene.spawnY - 80)
            }
            lastScroll = scroll
            return
        }

        if let scroll, let previous = lastScroll, scroll.index == previous.index {
            cameraTopLeftX! += Double(wrappedDelta(from: previous.x, to: scroll.x, modulus: 512))
            cameraTopLeftY! += Double(wrappedDelta(from: previous.y, to: scroll.y, modulus: 512))
        }
        lastScroll = scroll
    }

    /// Learn the scene palette by comparing the authored indexed field with the
    /// actual hardware framebuffer at the live camera position. A mismatched map
    /// produces low confidence and is rejected instead of ever being displayed.
    private func refreshValidatedSceneImage(_ runtime: NativeBridgeRuntime) {
        guard let scene = currentScene,
              let cameraX = cameraTopLeftX,
              let cameraY = cameraTopLeftY,
              frameCounter == 1 || currentSceneImage == nil || frameCounter % 30 == 0,
              let frame = runtime.framebufferImage(),
              let rgba = canonicalRGBA(frame) else { return }

        let baseX = Int(cameraX.rounded())
        let baseY = Int(cameraY.rounded())
        var votes: [UInt8: [UInt32: Int]] = [:]
        var totals: [UInt8: Int] = [:]
        var samples = 0

        // Skip the top HUD and the very bottom edge where dialogue/UI commonly sits.
        for sy in stride(from: 38, to: 136, by: 2) {
            let worldY = baseY + sy
            guard worldY >= 0, worldY < scene.height else { continue }
            for sx in stride(from: 0, to: 240, by: 2) {
                let worldX = baseX + sx
                guard worldX >= 0, worldX < scene.width else { continue }

                let paletteIndex = scene.pixels[worldY * scene.width + worldX]
                let offset = (sy * 240 + sx) * 4
                let color = quantizedColor(r: rgba[offset], g: rgba[offset + 1], b: rgba[offset + 2])
                votes[paletteIndex, default: [:]][color, default: 0] += 1
                totals[paletteIndex, default: 0] += 1
                samples += 1
            }
        }

        guard samples > 1000 else { return }
        var dominantMatches = 0
        var framePalette: [UInt8: UInt32] = [:]
        for (index, colors) in votes {
            guard let best = colors.max(by: { $0.value < $1.value }) else { continue }
            dominantMatches += best.value
            let total = totals[index] ?? 1
            if best.value >= 4 && Double(best.value) / Double(total) >= 0.46 {
                framePalette[index] = best.key
            }
        }

        let confidence = Double(dominantMatches) / Double(samples)
        paletteConfidence = confidence

        // Wrong descriptors/camera calibrations are intentionally discarded.
        guard confidence >= 0.64, framePalette.count >= 12 else {
            currentSceneImage = nil
            return
        }

        for (index, color) in framePalette {
            learnedPalette[index] = color
        }

        let fallback = runtime.colorizedSceneImage(scene)
        currentSceneImage = makeSceneImage(scene, learned: learnedPalette, fallback: fallback)
    }

    private func refreshFieldBackground(_ runtime: NativeBridgeRuntime) {
        if let scene = currentScene,
           paletteConfidence >= 0.64,
           let image = currentSceneImage,
           let cameraX = cameraTopLeftX,
           let cameraY = cameraTopLeftY {
            let maxX = max(0, scene.width - 240)
            let maxY = max(0, scene.height - portraitHeight)
            let cropX = min(max(Int(cameraX.rounded()), 0), maxX)
            let portraitTop = Int(cameraY.rounded()) - verticalExtension
            let cropY = min(max(portraitTop, 0), maxY)
            if let crop = image.cropping(to: CGRect(x: cropX, y: cropY, width: 240, height: portraitHeight)) {
                installBackgroundTexture(crop)
                return
            }
        }

        // Until a scene is positively matched, use the live tile renderer. Never
        // show an unvalidated decoded map under the real actors.
        if let fallback = runtime.portraitBackgroundImage(height: portraitHeight) {
            installBackgroundTexture(fallback)
        }
    }

    private func installBackgroundTexture(_ image: CGImage) {
        let texture = SKTexture(cgImage: image)
        texture.filteringMode = .nearest
        backgroundNode.texture = texture
    }

    private func refreshActors(_ runtime: NativeBridgeRuntime) {
        actorLayer.removeAllChildren()
        for sprite in runtime.spriteFrames() {
            if sprite.screenY >= 0 && sprite.screenY < 34 { continue }
            if sprite.screenY < -48 || sprite.screenY > 184 { continue }

            let targetTopY = sprite.screenY + verticalExtension
            let centerX = CGFloat(sprite.screenX) + CGFloat(sprite.width) * 0.5
            let centerYFromTop = CGFloat(targetTopY) + CGFloat(sprite.height) * 0.5
            let spriteKitY = CGFloat(portraitHeight) - centerYFromTop
            if centerYFromTop + CGFloat(sprite.height) < 0 || centerYFromTop > CGFloat(portraitHeight) { continue }

            let texture = SKTexture(cgImage: sprite.image)
            texture.filteringMode = .nearest
            let node = SKSpriteNode(texture: texture, size: CGSize(width: sprite.width, height: sprite.height))
            node.position = CGPoint(x: centerX, y: spriteKitY)
            node.zPosition = CGFloat(100 - sprite.priority)
            actorLayer.addChild(node)
        }
    }

    private func refreshOriginalUI(_ runtime: NativeBridgeRuntime) {
        guard let frame = runtime.framebufferImage() else {
            hudNode.isHidden = true
            dialogueNode.isHidden = true
            return
        }

        if looksLikeHUD(frame), let hud = frame.cropping(to: CGRect(x: 0, y: 0, width: 240, height: hudHeight)) {
            let texture = SKTexture(cgImage: hud)
            texture.filteringMode = .nearest
            hudNode.texture = texture
            hudNode.isHidden = false
        } else {
            hudNode.isHidden = true
        }

        if let rect = dialogueRect(in: frame), let dialogue = frame.cropping(to: rect) {
            let texture = SKTexture(cgImage: dialogue)
            texture.filteringMode = .nearest
            dialogueNode.texture = texture
            let aspect = CGFloat(dialogue.width) / CGFloat(max(dialogue.height, 1))
            let targetWidth: CGFloat = 220
            let targetHeight = min(118, max(42, targetWidth / aspect))
            dialogueNode.size = CGSize(width: targetWidth, height: targetHeight)
            dialogueNode.position = CGPoint(x: 120, y: 46)
            dialogueNode.isHidden = false
        } else {
            dialogueNode.isHidden = true
        }
    }

    // MARK: - Portrait cinematic/menu presentation

    /// Present the cartridge frame once, without duplicating or vertically
    /// stretching it. The unused portrait space is extended from the frame's edge
    /// colours so title screens, legal cards and Android cutscenes feel intentional.
    private func makePhoneCinematic(from frame: CGImage) -> CGImage? {
        guard let source = canonicalRGBA(frame), frame.width == 240, frame.height == 160 else { return nil }
        let width = 240
        let height = portraitHeight
        var output = [UInt8](repeating: 0, count: width * height * 4)

        let topColor = averageEdgeColor(source, width: width, height: 160, yRange: 0..<8)
        let bottomColor = averageEdgeColor(source, width: width, height: 160, yRange: 152..<160)
        for y in 0..<height {
            let t = Double(y) / Double(max(height - 1, 1))
            let r = UInt8(Double(topColor.0) * (1 - t) + Double(bottomColor.0) * t)
            let g = UInt8(Double(topColor.1) * (1 - t) + Double(bottomColor.1) * t)
            let b = UInt8(Double(topColor.2) * (1 - t) + Double(bottomColor.2) * t)
            for x in 0..<width {
                let d = (y * width + x) * 4
                output[d] = r; output[d + 1] = g; output[d + 2] = b; output[d + 3] = 255
            }
        }

        let nonDarkBounds = visibleContentBounds(source, width: width, height: 160)
        let darkRatio = imageDarkRatio(source, width: width, height: 160)
        var sourceRect = CGRect(x: 0, y: 0, width: 240, height: 160)

        // Black-backed intro/cutscene plates often have huge unused borders. Crop
        // only those borders and enlarge the actual art while preserving aspect.
        if darkRatio > 0.68, let bounds = nonDarkBounds,
           bounds.width < 224 || bounds.height < 142 {
            sourceRect = bounds.insetBy(dx: -4, dy: -4).intersection(CGRect(x: 0, y: 0, width: 240, height: 160))
        }

        let scale = min(232.0 / sourceRect.width, 300.0 / sourceRect.height)
        let targetW = max(1, Int((sourceRect.width * scale).rounded()))
        let targetH = max(1, Int((sourceRect.height * scale).rounded()))
        let targetX = (width - targetW) / 2
        let targetY = (height - targetH) / 2

        blitNearest(
            source,
            sourceWidth: width,
            sourceHeight: 160,
            sourceRect: sourceRect,
            destination: &output,
            destinationWidth: width,
            destinationHeight: height,
            targetX: targetX,
            targetY: targetY,
            targetWidth: targetW,
            targetHeight: targetH
        )

        return makeRGBAImage(output, width: width, height: height)
    }

    // MARK: - Image helpers

    private func canonicalRGBA(_ image: CGImage) -> [UInt8]? {
        var rgba = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &rgba,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: image.width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .none
        context.translateBy(x: 0, y: CGFloat(image.height))
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return rgba
    }

    private func quantizedColor(r: UInt8, g: UInt8, b: UInt8) -> UInt32 {
        let qr = UInt32(r >> 3)
        let qg = UInt32(g >> 3)
        let qb = UInt32(b >> 3)
        return qr | (qg << 5) | (qb << 10)
    }

    private func unpackColor(_ value: UInt32) -> (UInt8, UInt8, UInt8) {
        let r = Int(value & 31)
        let g = Int((value >> 5) & 31)
        let b = Int((value >> 10) & 31)
        return (
            UInt8((r * 255 + 15) / 31),
            UInt8((g * 255 + 15) / 31),
            UInt8((b * 255 + 15) / 31)
        )
    }

    private func makeSceneImage(
        _ scene: ALFPSceneData.IndexedScene,
        learned: [UInt8: UInt32],
        fallback: CGImage?
    ) -> CGImage? {
        var fallbackPalette: [UInt8: UInt32] = [:]
        if let fallback, let rgba = canonicalRGBA(fallback) {
            for i in 0..<scene.pixels.count where fallbackPalette.count < 256 {
                let index = scene.pixels[i]
                if fallbackPalette[index] != nil { continue }
                let o = i * 4
                fallbackPalette[index] = quantizedColor(r: rgba[o], g: rgba[o + 1], b: rgba[o + 2])
            }
        }

        var output = [UInt8](repeating: 0, count: scene.width * scene.height * 4)
        for i in 0..<scene.pixels.count {
            let index = scene.pixels[i]
            let packed = learned[index] ?? fallbackPalette[index] ?? 0
            let color = unpackColor(packed)
            let o = i * 4
            output[o] = color.0; output[o + 1] = color.1; output[o + 2] = color.2; output[o + 3] = 255
        }
        return makeRGBAImage(output, width: scene.width, height: scene.height)
    }

    private func averageEdgeColor(_ rgba: [UInt8], width: Int, height: Int, yRange: Range<Int>) -> (UInt8, UInt8, UInt8) {
        var r = 0, g = 0, b = 0, count = 0
        for y in yRange.clamped(to: 0..<height) {
            for x in stride(from: 0, to: width, by: 4) {
                let o = (y * width + x) * 4
                r += Int(rgba[o]); g += Int(rgba[o + 1]); b += Int(rgba[o + 2]); count += 1
            }
        }
        let c = max(count, 1)
        return (UInt8(r / c), UInt8(g / c), UInt8(b / c))
    }

    private func imageDarkRatio(_ rgba: [UInt8], width: Int, height: Int) -> Double {
        var dark = 0, samples = 0
        for y in stride(from: 0, to: height, by: 2) {
            for x in stride(from: 0, to: width, by: 2) {
                let o = (y * width + x) * 4
                if Int(rgba[o]) + Int(rgba[o + 1]) + Int(rgba[o + 2]) < 90 { dark += 1 }
                samples += 1
            }
        }
        return Double(dark) / Double(max(samples, 1))
    }

    private func visibleContentBounds(_ rgba: [UInt8], width: Int, height: Int) -> CGRect? {
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                let o = (y * width + x) * 4
                let brightness = Int(rgba[o]) + Int(rgba[o + 1]) + Int(rgba[o + 2])
                if brightness <= 42 { continue }
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    private func blitNearest(
        _ source: [UInt8],
        sourceWidth: Int,
        sourceHeight: Int,
        sourceRect: CGRect,
        destination: inout [UInt8],
        destinationWidth: Int,
        destinationHeight: Int,
        targetX: Int,
        targetY: Int,
        targetWidth: Int,
        targetHeight: Int
    ) {
        let sx0 = Int(sourceRect.minX.rounded(.down))
        let sy0 = Int(sourceRect.minY.rounded(.down))
        let sw = max(1, Int(sourceRect.width.rounded(.down)))
        let sh = max(1, Int(sourceRect.height.rounded(.down)))
        for dy in 0..<targetHeight {
            let y = targetY + dy
            guard y >= 0, y < destinationHeight else { continue }
            let sy = min(sourceHeight - 1, sy0 + dy * sh / max(targetHeight, 1))
            for dx in 0..<targetWidth {
                let x = targetX + dx
                guard x >= 0, x < destinationWidth else { continue }
                let sx = min(sourceWidth - 1, sx0 + dx * sw / max(targetWidth, 1))
                let s = (sy * sourceWidth + sx) * 4
                let d = (y * destinationWidth + x) * 4
                destination[d] = source[s]
                destination[d + 1] = source[s + 1]
                destination[d + 2] = source[s + 2]
                destination[d + 3] = 255
            }
        }
    }

    private func makeRGBAImage(_ rgba: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    private func looksLikeHUD(_ image: CGImage) -> Bool {
        let stats = pixelStats(image, rect: CGRect(x: 0, y: 0, width: 240, height: hudHeight))
        return stats.darkRatio > 0.34 && stats.brightRatio > 0.018
    }

    private func dialogueRect(in image: CGImage) -> CGRect? {
        guard let rgba = canonicalRGBA(image), image.width == 240, image.height == 160 else { return nil }
        var borderRows: [Int] = []
        for y in 30..<159 {
            var bright = 0, dark = 0
            for x in 0..<240 {
                let o = (y * 240 + x) * 4
                let sum = Int(rgba[o]) + Int(rgba[o + 1]) + Int(rgba[o + 2])
                if sum > 620 { bright += 1 }
                if sum < 105 { dark += 1 }
            }
            if bright >= 72 && dark >= 52 { borderRows.append(y) }
        }
        if let first = borderRows.first, let last = borderRows.last, last - first >= 15, last - first <= 112 {
            let top = max(24, first - 4)
            let bottom = min(160, last + 5)
            return CGRect(x: 4, y: top, width: 232, height: bottom - top)
        }
        return nil
    }

    private func pixelStats(_ image: CGImage, rect: CGRect) -> (darkRatio: Double, brightRatio: Double) {
        guard let rgba = canonicalRGBA(image) else { return (0, 0) }
        let minX = max(0, Int(rect.minX)), maxX = min(image.width, Int(rect.maxX))
        let minY = max(0, Int(rect.minY)), maxY = min(image.height, Int(rect.maxY))
        var dark = 0, bright = 0, samples = 0
        for y in minY..<maxY {
            for x in stride(from: minX, to: maxX, by: 2) {
                let o = (y * image.width + x) * 4
                let sum = Int(rgba[o]) + Int(rgba[o + 1]) + Int(rgba[o + 2])
                if sum < 120 { dark += 1 }
                if sum > 620 { bright += 1 }
                samples += 1
            }
        }
        let c = Double(max(samples, 1))
        return (Double(dark) / c, Double(bright) / c)
    }

    private func wrappedDelta(from old: Int, to new: Int, modulus: Int) -> Int {
        var delta = new - old
        let half = modulus / 2
        if delta > half { delta -= modulus }
        if delta < -half { delta += modulus }
        return delta
    }

    private func resetFieldCalibration(keepScene: Bool = false) {
        cameraTopLeftX = nil
        cameraTopLeftY = nil
        lastScroll = nil
        paletteConfidence = 0
        if !keepScene {
            currentScene = nil
            currentSceneDescriptor = nil
            currentSceneImage = nil
            learnedPalette.removeAll(keepingCapacity: true)
        }
    }

    private func installFailureWorld(message: String) {
        let label = SKLabelNode(text: "Native portrait runtime failed")
        label.fontName = "Menlo-Bold"
        label.fontSize = 11
        label.fontColor = .white
        label.position = CGPoint(x: 120, y: 275)
        addChild(label)

        let detail = SKLabelNode(text: String(message.prefix(80)))
        detail.fontName = "Menlo"
        detail.fontSize = 6
        detail.fontColor = SKColor(white: 0.8, alpha: 1)
        detail.position = CGPoint(x: 120, y: 255)
        addChild(detail)
    }
}

private extension Range where Bound == Int {
    func clamped(to limits: Range<Int>) -> Range<Int> {
        max(lowerBound, limits.lowerBound)..<min(upperBound, limits.upperBound)
    }
}
