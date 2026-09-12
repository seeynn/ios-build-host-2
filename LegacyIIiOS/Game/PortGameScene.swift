import CoreGraphics
import Foundation
import SpriteKit

final class PortGameScene: SKScene {
    private let romURL: URL
    private let saveURL: URL

    private let fieldNode = SKSpriteNode()
    private let hardwareOverlayNode = SKSpriteNode()
    private let cinematicBackdropNode = SKSpriteNode()
    private let cinematicPrimaryNode = SKSpriteNode()
    private let cinematicSecondaryNode = SKSpriteNode()

    private var runtime: NativeBridgeRuntime?
    private var rom: ROMImage?
    private var sceneDescriptors: [Int] = []
    private var sceneCache: [Int: ALFPSceneData.IndexedScene] = [:]
    private var currentScene: ALFPSceneData.IndexedScene?
    private var currentSceneImage: CGImage?
    private var currentSceneDescriptor: Int?

    private var cameraTopLeftX: Double?
    private var cameraTopLeftY: Double?
    private var lastScroll: NativeBridgeRuntime.BackgroundOffset?
    private var usedFirstSceneFallback = false

    private var frameCounter = 0
    private var fieldConfidence = 0
    private var cinematicConfidence = 0
    private var fieldPresentationActive = false

    private let portraitHeight = 520
    private let originalViewportHeight = 160
    private var verticalExtension: Int { (portraitHeight - originalViewportHeight) / 2 }

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
        view.backgroundColor = .black
        view.ignoresSiblingOrder = true
        view.isMultipleTouchEnabled = true
        view.contentMode = .scaleAspectFill

        fieldNode.anchorPoint = CGPoint(x: 0, y: 0)
        fieldNode.position = .zero
        fieldNode.size = CGSize(width: 240, height: portraitHeight)
        fieldNode.zPosition = -1000
        addChild(fieldNode)

        hardwareOverlayNode.anchorPoint = CGPoint(x: 0, y: 0)
        hardwareOverlayNode.position = CGPoint(x: 0, y: verticalExtension)
        hardwareOverlayNode.size = CGSize(width: 240, height: originalViewportHeight)
        hardwareOverlayNode.zPosition = 2000
        addChild(hardwareOverlayNode)

        cinematicBackdropNode.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        cinematicBackdropNode.position = CGPoint(x: 120, y: portraitHeight / 2)
        cinematicBackdropNode.zPosition = -900
        addChild(cinematicBackdropNode)

        cinematicPrimaryNode.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        cinematicPrimaryNode.position = CGPoint(x: 120, y: portraitHeight / 2)
        cinematicPrimaryNode.zPosition = -800
        addChild(cinematicPrimaryNode)

        cinematicSecondaryNode.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        cinematicSecondaryNode.zPosition = -790
        addChild(cinematicSecondaryNode)

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
        let regularHardware = runtime.displayMode() <= 1 && !runtime.backgroundOffsets().isEmpty
        let fieldNow = runtime.isLikelyFieldFrame()
            || (fieldPresentationActive && currentScene != nil && regularHardware)

        if fieldNow {
            fieldConfidence = min(8, fieldConfidence + 1)
            cinematicConfidence = 0
        } else {
            cinematicConfidence = min(8, cinematicConfidence + 1)
            fieldConfidence = 0
        }

        if !fieldPresentationActive && fieldConfidence >= 2 {
            fieldPresentationActive = true
            resetFieldCalibration()
        } else if fieldPresentationActive && cinematicConfidence >= 8 {
            fieldPresentationActive = false
            resetFieldCalibration(keepScene: true)
        }

        if fieldPresentationActive { showField(runtime) }
        else { showCinematic(runtime) }
    }

    private func showField(_ runtime: NativeBridgeRuntime) {
        fieldNode.isHidden = false
        hardwareOverlayNode.isHidden = false
        cinematicBackdropNode.isHidden = true
        cinematicPrimaryNode.isHidden = true
        cinematicSecondaryNode.isHidden = true

        if frameCounter % 30 == 0 || currentScene == nil { resolveCurrentScene(runtime) }
        updateFieldCamera(runtime)
        refreshFieldBackground(runtime)
        refreshHardwareOverlay(runtime)
    }

    private func resolveCurrentScene(_ runtime: NativeBridgeRuntime) {
        guard let rom else { return }
        var descriptor = runtime.activeSceneDescriptorOffset(candidates: sceneDescriptors)
        if descriptor == nil && !usedFirstSceneFallback {
            descriptor = ALFPSceneData.firstSceneDescriptorOffset
            usedFirstSceneFallback = true
        }
        guard let descriptor else { return }
        guard descriptor != currentSceneDescriptor || currentScene == nil else { return }

        do {
            let decoded: ALFPSceneData.IndexedScene
            if let cached = sceneCache[descriptor] { decoded = cached }
            else {
                decoded = try ALFPSceneData.decodeScene(in: rom, at: descriptor)
                sceneCache[descriptor] = decoded
            }
            currentSceneDescriptor = descriptor
            currentScene = decoded
            currentSceneImage = runtime.colorizedSceneImage(decoded)
            resetFieldCalibration(keepScene: true)
        } catch {
            if let fallback = try? ALFPSceneData.decodeFirstScene(in: rom) {
                currentSceneDescriptor = fallback.descriptorOffset
                currentScene = fallback
                sceneCache[fallback.descriptorOffset] = fallback
                currentSceneImage = runtime.colorizedSceneImage(fallback)
                resetFieldCalibration(keepScene: true)
            }
        }
    }

    private func updateFieldCamera(_ runtime: NativeBridgeRuntime) {
        guard let scene = currentScene else { return }
        let offsets = runtime.backgroundOffsets()
        let scroll = offsets.max(by: { $0.index < $1.index })

        if cameraTopLeftX == nil || cameraTopLeftY == nil {
            var estimateX = Double(scene.spawnX - 120)
            var estimateY = Double(scene.spawnY - 80)
            if let player = runtime.playerSpriteCandidate() {
                let playerCenterX = Double(player.screenX) + Double(player.width) * 0.5
                let playerFootY = Double(player.screenY + player.height - 2)
                estimateX = Double(scene.spawnX) - playerCenterX
                estimateY = Double(scene.spawnY) - playerFootY
            }
            if let matched = matchedCameraPosition(runtime, estimateX: estimateX, estimateY: estimateY) {
                cameraTopLeftX = matched.x
                cameraTopLeftY = matched.y
            } else {
                cameraTopLeftX = estimateX
                cameraTopLeftY = estimateY
            }
            lastScroll = scroll
            return
        }

        if let scroll, let previous = lastScroll, scroll.index == previous.index {
            cameraTopLeftX! += Double(wrappedDelta(from: previous.x, to: scroll.x, modulus: 512))
            cameraTopLeftY! += Double(wrappedDelta(from: previous.y, to: scroll.y, modulus: 512))
        }
        lastScroll = scroll

        if frameCounter % 120 == 0,
           let x = cameraTopLeftX,
           let y = cameraTopLeftY,
           let matched = matchedCameraPosition(runtime, estimateX: x, estimateY: y, radius: 20) {
            cameraTopLeftX = matched.x
            cameraTopLeftY = matched.y
        }
    }

    private func refreshFieldBackground(_ runtime: NativeBridgeRuntime) {
        if frameCounter % 240 == 0, let scene = currentScene {
            currentSceneImage = runtime.colorizedSceneImage(scene)
        }

        guard let scene = currentScene,
              let image = currentSceneImage,
              let cameraX = cameraTopLeftX,
              let cameraY = cameraTopLeftY else {
            installSafeHardwareFallback(runtime)
            return
        }

        let maxX = max(0, scene.width - 240)
        let maxY = max(0, scene.height - portraitHeight)
        let cropX = min(max(Int(cameraX.rounded()), 0), maxX)
        let portraitTop = Int(cameraY.rounded()) - verticalExtension
        let cropY = min(max(portraitTop, 0), maxY)

        guard let crop = image.cropping(to: CGRect(x: cropX, y: cropY, width: 240, height: portraitHeight)) else {
            installSafeHardwareFallback(runtime)
            return
        }
        installFieldTexture(crop)
    }

    private func installSafeHardwareFallback(_ runtime: NativeBridgeRuntime) {
        guard let hardware = runtime.portraitBackgroundImage(height: originalViewportHeight),
              let portrait = aspectFillImage(hardware, width: 240, height: portraitHeight) else { return }
        installFieldTexture(portrait)
    }

    private func installFieldTexture(_ image: CGImage) {
        let texture = SKTexture(cgImage: image)
        texture.filteringMode = .nearest
        fieldNode.texture = texture
    }

    private func refreshHardwareOverlay(_ runtime: NativeBridgeRuntime) {
        guard let frame = runtime.framebufferImage(),
              let background = runtime.portraitBackgroundImage(height: originalViewportHeight),
              let overlay = differenceOverlay(frame: frame, background: background) else {
            hardwareOverlayNode.isHidden = true
            return
        }
        let texture = SKTexture(cgImage: overlay)
        texture.filteringMode = .nearest
        hardwareOverlayNode.texture = texture
        hardwareOverlayNode.isHidden = false
    }

    private func showCinematic(_ runtime: NativeBridgeRuntime) {
        fieldNode.isHidden = true
        hardwareOverlayNode.isHidden = true
        cinematicBackdropNode.isHidden = false
        cinematicPrimaryNode.isHidden = false
        cinematicSecondaryNode.isHidden = true

        guard let frame = runtime.framebufferImage() else { return }
        let fullTexture = SKTexture(cgImage: frame)
        fullTexture.filteringMode = .nearest
        cinematicBackdropNode.texture = fullTexture
        cinematicBackdropNode.size = CGSize(width: 780, height: 520)
        cinematicBackdropNode.alpha = 0.34

        if looksLikeTitleScreen(frame) {
            installTitleComposition(frame)
            return
        }

        let sourceRect = cinematicContentRect(frame)
        let crop = frame.cropping(to: sourceRect) ?? frame
        let texture = SKTexture(cgImage: crop)
        texture.filteringMode = .nearest
        cinematicPrimaryNode.texture = texture

        let aspect = CGFloat(crop.width) / CGFloat(max(crop.height, 1))
        let maxWidth: CGFloat = 232
        let maxHeight: CGFloat = 320
        var targetWidth = maxWidth
        var targetHeight = targetWidth / max(aspect, 0.01)
        if targetHeight > maxHeight {
            targetHeight = maxHeight
            targetWidth = targetHeight * aspect
        }
        cinematicPrimaryNode.size = CGSize(width: targetWidth, height: targetHeight)
        cinematicPrimaryNode.position = CGPoint(x: 120, y: 260)
        cinematicPrimaryNode.alpha = 1
    }

    private func installTitleComposition(_ frame: CGImage) {
        if let logo = frame.cropping(to: CGRect(x: 0, y: 10, width: 240, height: 105)) {
            let texture = SKTexture(cgImage: logo)
            texture.filteringMode = .nearest
            cinematicPrimaryNode.texture = texture
            cinematicPrimaryNode.size = CGSize(width: 234, height: 102)
            cinematicPrimaryNode.position = CGPoint(x: 120, y: 326)
        }
        if let menu = frame.cropping(to: CGRect(x: 38, y: 92, width: 164, height: 66)) {
            let texture = SKTexture(cgImage: menu)
            texture.filteringMode = .nearest
            cinematicSecondaryNode.texture = texture
            cinematicSecondaryNode.size = CGSize(width: 194, height: 78)
            cinematicSecondaryNode.position = CGPoint(x: 120, y: 205)
            cinematicSecondaryNode.isHidden = false
        }
    }

    private func cinematicContentRect(_ image: CGImage) -> CGRect {
        guard var bounds = visibleContentBounds(image) else {
            return CGRect(x: 0, y: 0, width: image.width, height: image.height)
        }
        let aspect = bounds.width / max(bounds.height, 1)
        if aspect > 2.0 {
            let desiredWidth = min(bounds.width, bounds.height * 1.35)
            bounds.origin.x += (bounds.width - desiredWidth) * 0.5
            bounds.size.width = desiredWidth
        }
        return bounds.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }

    private func visibleContentBounds(_ image: CGImage) -> CGRect? {
        guard let pixels = rgbaPixels(image) else { return nil }
        let width = image.width
        let height = image.height
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let sum = Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2])
                if sum < 42 { continue }
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let pad = 5
        let x = max(0, minX - pad), y = max(0, minY - pad)
        let right = min(width, maxX + pad + 1), bottom = min(height, maxY + pad + 1)
        return CGRect(x: x, y: y, width: right - x, height: bottom - y)
    }

    private func looksLikeTitleScreen(_ image: CGImage) -> Bool {
        guard let pixels = rgbaPixels(image) else { return false }
        var purple = 0, colorful = 0, samples = 0
        for y in stride(from: 0, to: image.height, by: 2) {
            for x in stride(from: 0, to: image.width, by: 2) {
                let i = (y * image.width + x) * 4
                let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
                if r > 70 && b > 80 && g < max(r, b) * 3 / 4 { purple += 1 }
                if max(r, max(g, b)) - min(r, min(g, b)) > 80 { colorful += 1 }
                samples += 1
            }
        }
        let count = Double(max(samples, 1))
        return Double(purple) / count > 0.10 && Double(colorful) / count > 0.24
    }

    private func matchedCameraPosition(
        _ runtime: NativeBridgeRuntime,
        estimateX: Double,
        estimateY: Double,
        radius: Int = 80
    ) -> (x: Double, y: Double)? {
        guard let scene = currentScene,
              let sceneImage = currentSceneImage,
              let hardware = runtime.portraitBackgroundImage(height: originalViewportHeight),
              let scenePixels = rgbaPixels(sceneImage),
              let hardwarePixels = rgbaPixels(hardware) else { return nil }

        let maxX = max(0, scene.width - 240), maxY = max(0, scene.height - 160)
        let baseX = min(max(Int(estimateX.rounded()), 0), maxX)
        let baseY = min(max(Int(estimateY.rounded()), 0), maxY)

        func score(_ x0: Int, _ y0: Int, sampleStride: Int) -> Int64 {
            var total: Int64 = 0, samples: Int64 = 0
            for sy in Swift.stride(from: 4, to: 156, by: sampleStride) {
                for sx in Swift.stride(from: 4, to: 236, by: sampleStride) {
                    let hi = (sy * 240 + sx) * 4
                    let si = ((y0 + sy) * scene.width + (x0 + sx)) * 4
                    total += Int64(abs(Int(hardwarePixels[hi]) - Int(scenePixels[si])))
                    total += Int64(abs(Int(hardwarePixels[hi + 1]) - Int(scenePixels[si + 1])))
                    total += Int64(abs(Int(hardwarePixels[hi + 2]) - Int(scenePixels[si + 2])))
                    samples += 1
                }
            }
            return samples > 0 ? total / samples : Int64.max
        }

        var bestX = baseX, bestY = baseY, bestScore = Int64.max
        let coarseStep = 8
        let minX = max(0, baseX - radius), maxSearchX = min(maxX, baseX + radius)
        let minY = max(0, baseY - radius), maxSearchY = min(maxY, baseY + radius)
        for y in Swift.stride(from: minY, through: maxSearchY, by: coarseStep) {
            for x in Swift.stride(from: minX, through: maxSearchX, by: coarseStep) {
                let candidate = score(x, y, sampleStride: 12)
                if candidate < bestScore { bestScore = candidate; bestX = x; bestY = y }
            }
        }

        for y in max(0, bestY - coarseStep)...min(maxY, bestY + coarseStep) {
            for x in max(0, bestX - coarseStep)...min(maxX, bestX + coarseStep) {
                let candidate = score(x, y, sampleStride: 8)
                if candidate < bestScore { bestScore = candidate; bestX = x; bestY = y }
            }
        }
        return (Double(bestX), Double(bestY))
    }

    private func differenceOverlay(frame: CGImage, background: CGImage) -> CGImage? {
        guard frame.width == 240, frame.height == 160,
              background.width == 240, background.height == 160,
              let foreground = rgbaPixels(frame),
              let base = rgbaPixels(background) else { return nil }

        let width = 240, height = 160
        var mask = [Bool](repeating: false, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let p = y * width + x, i = p * 4
                let dr = abs(Int(foreground[i]) - Int(base[i]))
                let dg = abs(Int(foreground[i + 1]) - Int(base[i + 1]))
                let db = abs(Int(foreground[i + 2]) - Int(base[i + 2]))
                mask[p] = max(dr, max(dg, db)) > 22 || dr + dg + db > 46
            }
        }
        var expanded = mask
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) where mask[y * width + x] {
                for yy in (y - 1)...(y + 1) {
                    for xx in (x - 1)...(x + 1) { expanded[yy * width + xx] = true }
                }
            }
        }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for p in 0..<(width * height) where expanded[p] {
            let i = p * 4
            rgba[i] = foreground[i]; rgba[i + 1] = foreground[i + 1]
            rgba[i + 2] = foreground[i + 2]; rgba[i + 3] = 255
        }
        return makeRGBAImage(rgba, width: width, height: height, alpha: true)
    }

    private func aspectFillImage(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard let source = rgbaPixels(image) else { return nil }
        let sourceW = image.width, sourceH = image.height
        let targetAspect = Double(width) / Double(height), sourceAspect = Double(sourceW) / Double(sourceH)
        var cropX = 0, cropY = 0, cropW = sourceW, cropH = sourceH
        if sourceAspect > targetAspect {
            cropW = max(1, Int(Double(sourceH) * targetAspect)); cropX = (sourceW - cropW) / 2
        } else {
            cropH = max(1, Int(Double(sourceW) / targetAspect)); cropY = (sourceH - cropH) / 2
        }
        var out = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            let sy = cropY + min(cropH - 1, y * cropH / height)
            for x in 0..<width {
                let sx = cropX + min(cropW - 1, x * cropW / width)
                let si = (sy * sourceW + sx) * 4, di = (y * width + x) * 4
                out[di] = source[si]; out[di + 1] = source[si + 1]
                out[di + 2] = source[si + 2]; out[di + 3] = 255
            }
        }
        return makeRGBAImage(out, width: width, height: height, alpha: false)
    }

    private func rgbaPixels(_ image: CGImage) -> [UInt8]? {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .none
        context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels
    }

    private func makeRGBAImage(_ rgba: [UInt8], width: Int, height: Int, alpha: Bool) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        let info = alpha ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: info.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    private func wrappedDelta(from old: Int, to new: Int, modulus: Int) -> Int {
        var delta = new - old
        let half = modulus / 2
        if delta > half { delta -= modulus }
        if delta < -half { delta += modulus }
        return delta
    }

    private func resetFieldCalibration(keepScene: Bool = false) {
        cameraTopLeftX = nil; cameraTopLeftY = nil; lastScroll = nil
        if !keepScene {
            currentScene = nil; currentSceneImage = nil; currentSceneDescriptor = nil
            usedFirstSceneFallback = false
        }
    }

    private func installFailureWorld(message: String) {
        let title = SKLabelNode(text: "Native portrait runtime failed")
        title.fontName = "Menlo-Bold"; title.fontSize = 11; title.fontColor = .white
        title.position = CGPoint(x: 120, y: 275); addChild(title)
        let detail = SKLabelNode(text: String(message.prefix(80)))
        detail.fontName = "Menlo"; detail.fontSize = 6
        detail.fontColor = SKColor(white: 0.8, alpha: 1)
        detail.position = CGPoint(x: 120, y: 255); addChild(detail)
    }
}
