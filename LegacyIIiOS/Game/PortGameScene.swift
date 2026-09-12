import CoreGraphics
import Foundation
import SpriteKit

final class PortGameScene: SKScene {
    private let romURL: URL
    private let saveURL: URL

    private let fieldNode = SKSpriteNode()
    private let actorLayer = SKNode()
    private let hudNode = SKSpriteNode()
    private let dialogueNode = SKSpriteNode()
    private let cinematicNode = SKSpriteNode()

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
    private var frameCounter = 0
    private var fieldPresentationActive = false
    private var failedFieldChecks = 0

    private let portraitHeight = 520
    private let originalViewportHeight = 160
    private let fieldAcceptScore: Int64 = 92
    private let fieldDropScore: Int64 = 122

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
        view.backgroundColor = .black
        view.ignoresSiblingOrder = true
        view.isMultipleTouchEnabled = true
        view.contentMode = .scaleAspectFill

        fieldNode.anchorPoint = CGPoint(x: 0, y: 0)
        fieldNode.position = .zero
        fieldNode.size = CGSize(width: 240, height: portraitHeight)
        fieldNode.zPosition = -1000
        addChild(fieldNode)

        cinematicNode.anchorPoint = CGPoint(x: 0, y: 0)
        cinematicNode.position = .zero
        cinematicNode.size = CGSize(width: 240, height: portraitHeight)
        cinematicNode.zPosition = -900
        addChild(cinematicNode)

        actorLayer.zPosition = 100
        addChild(actorLayer)

        hudNode.anchorPoint = CGPoint(x: 0, y: 0)
        hudNode.position = CGPoint(x: 8, y: portraitHeight - 42)
        hudNode.zPosition = 4000
        hudNode.isHidden = true
        addChild(hudNode)

        dialogueNode.anchorPoint = CGPoint(x: 0.5, y: 0)
        dialogueNode.position = CGPoint(x: 120, y: 78)
        dialogueNode.zPosition = 4100
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
        if fieldPresentationActive {
            if runtime.displayMode() > 1 || runtime.backgroundOffsets().isEmpty {
                leaveFieldPresentation()
                showCinematic(runtime)
                return
            }

            if frameCounter % 120 == 0, !verifyCurrentField(runtime) {
                failedFieldChecks += 1
            } else if frameCounter % 120 == 0 {
                failedFieldChecks = 0
            }

            if failedFieldChecks >= 2 {
                leaveFieldPresentation()
                showCinematic(runtime)
                return
            }

            showField(runtime)
            return
        }

        if runtime.isLikelyFieldFrame(), frameCounter % 6 == 0,
           resolveVerifiedField(runtime) {
            fieldPresentationActive = true
            failedFieldChecks = 0
            showField(runtime)
        } else {
            showCinematic(runtime)
        }
    }

    private func showField(_ runtime: NativeBridgeRuntime) {
        fieldNode.isHidden = false
        actorLayer.isHidden = false
        cinematicNode.isHidden = true

        updateFieldCamera(runtime)
        refreshFieldBackground(runtime)
        refreshActors(runtime)
        refreshOriginalUI(runtime)
    }

    private func leaveFieldPresentation() {
        fieldPresentationActive = false
        failedFieldChecks = 0
        actorLayer.removeAllChildren()
        hudNode.isHidden = true
        dialogueNode.isHidden = true
        cameraTopLeftX = nil
        cameraTopLeftY = nil
        lastScroll = nil
        currentScene = nil
        currentSceneImage = nil
        currentSceneDescriptor = nil
    }

    // MARK: - Verified authored field selection

    private struct FieldMatch {
        let descriptor: Int
        let scene: ALFPSceneData.IndexedScene
        let image: CGImage
        let x: Double
        let y: Double
        let score: Int64
    }

    private func resolveVerifiedField(_ runtime: NativeBridgeRuntime) -> Bool {
        guard let rom, !sceneDescriptors.isEmpty else { return false }

        var ordered: [Int] = []
        func appendUnique(_ value: Int) {
            if !ordered.contains(value) { ordered.append(value) }
        }

        let active = runtime.activeSceneDescriptorOffset(candidates: sceneDescriptors)
        if let active {
            appendUnique(active)
            for descriptor in sceneDescriptors
                .sorted(by: { abs($0 - active) < abs($1 - active) })
                .prefix(10) {
                appendUnique(descriptor)
            }
        }

        appendUnique(ALFPSceneData.firstSceneDescriptorOffset)
        for descriptor in sceneDescriptors.prefix(8) { appendUnique(descriptor) }

        var best: FieldMatch?
        for descriptor in ordered.prefix(14) {
            guard let decoded = decodedScene(descriptor, rom: rom),
                  let image = runtime.colorizedSceneImage(decoded) else { continue }

            let estimate = initialCameraEstimate(scene: decoded, runtime: runtime)
            guard let match = matchedCameraPosition(
                runtime,
                scene: decoded,
                sceneImage: image,
                estimateX: estimate.x,
                estimateY: estimate.y,
                radius: descriptor == active ? 128 : 80,
                allowGlobalSearch: true
            ) else { continue }

            let candidate = FieldMatch(
                descriptor: descriptor,
                scene: decoded,
                image: image,
                x: match.x,
                y: match.y,
                score: match.score
            )
            if best == nil || candidate.score < best!.score { best = candidate }
            if candidate.score <= 34 { break }
        }

        guard let best, best.score <= fieldAcceptScore else { return false }
        currentSceneDescriptor = best.descriptor
        currentScene = best.scene
        currentSceneImage = best.image
        cameraTopLeftX = best.x
        cameraTopLeftY = best.y
        lastScroll = preferredScroll(runtime.backgroundOffsets())
        return true
    }

    private func decodedScene(_ descriptor: Int, rom: ROMImage) -> ALFPSceneData.IndexedScene? {
        if let cached = sceneCache[descriptor] { return cached }
        guard let decoded = try? ALFPSceneData.decodeScene(in: rom, at: descriptor) else { return nil }
        sceneCache[descriptor] = decoded
        return decoded
    }

    private func initialCameraEstimate(
        scene: ALFPSceneData.IndexedScene,
        runtime: NativeBridgeRuntime
    ) -> (x: Double, y: Double) {
        guard let player = runtime.playerSpriteCandidate() else {
            return (Double(scene.spawnX - 120), Double(scene.spawnY - 80))
        }
        let playerCenterX = Double(player.screenX) + Double(player.width) * 0.5
        let playerFootY = Double(player.screenY + player.height - 2)
        return (
            Double(scene.spawnX) - playerCenterX,
            Double(scene.spawnY) - playerFootY
        )
    }

    private func verifyCurrentField(_ runtime: NativeBridgeRuntime) -> Bool {
        guard let scene = currentScene,
              let image = currentSceneImage,
              let x = cameraTopLeftX,
              let y = cameraTopLeftY,
              let match = matchedCameraPosition(
                runtime,
                scene: scene,
                sceneImage: image,
                estimateX: x,
                estimateY: y,
                radius: 20,
                allowGlobalSearch: false
              ) else { return false }

        if match.score <= fieldDropScore {
            cameraTopLeftX = match.x
            cameraTopLeftY = match.y
            return true
        }
        return false
    }

    private func matchedCameraPosition(
        _ runtime: NativeBridgeRuntime,
        scene: ALFPSceneData.IndexedScene,
        sceneImage: CGImage,
        estimateX: Double,
        estimateY: Double,
        radius: Int,
        allowGlobalSearch: Bool
    ) -> (x: Double, y: Double, score: Int64)? {
        guard let frame = runtime.framebufferImage(),
              let scenePixels = rgbaPixels(sceneImage),
              let framePixels = rgbaPixels(frame) else { return nil }

        let maxX = max(0, scene.width - 240)
        let maxY = max(0, scene.height - 160)
        let baseX = min(max(Int(estimateX.rounded()), 0), maxX)
        let baseY = min(max(Int(estimateY.rounded()), 0), maxY)

        func score(_ x0: Int, _ y0: Int, stride sampleStride: Int) -> Int64 {
            var total: Int64 = 0
            var samples: Int64 = 0

            for sy in Swift.stride(from: 34, to: 142, by: sampleStride) {
                for sx in Swift.stride(from: 5, to: 235, by: sampleStride) {
                    if sx >= 82 && sx <= 158 && sy >= 48 && sy <= 132 { continue }
                    let fi = (sy * 240 + sx) * 4
                    let si = ((y0 + sy) * scene.width + (x0 + sx)) * 4
                    total += Int64(abs(Int(framePixels[fi]) - Int(scenePixels[si])))
                    total += Int64(abs(Int(framePixels[fi + 1]) - Int(scenePixels[si + 1])))
                    total += Int64(abs(Int(framePixels[fi + 2]) - Int(scenePixels[si + 2])))
                    samples += 1
                }
            }
            return samples > 0 ? total / samples : Int64.max
        }

        var bestX = baseX
        var bestY = baseY
        var bestScore = Int64.max

        let minX = max(0, baseX - radius)
        let maxSearchX = min(maxX, baseX + radius)
        let minY = max(0, baseY - radius)
        let maxSearchY = min(maxY, baseY + radius)
        for y in Swift.stride(from: minY, through: maxSearchY, by: 12) {
            for x in Swift.stride(from: minX, through: maxSearchX, by: 12) {
                let candidate = score(x, y, stride: 12)
                if candidate < bestScore { bestScore = candidate; bestX = x; bestY = y }
            }
        }

        if allowGlobalSearch && bestScore > fieldAcceptScore {
            for y in Swift.stride(from: 0, through: maxY, by: 48) {
                for x in Swift.stride(from: 0, through: maxX, by: 48) {
                    let candidate = score(x, y, stride: 16)
                    if candidate < bestScore { bestScore = candidate; bestX = x; bestY = y }
                }
            }
        }

        let refineRadius = 12
        for y in max(0, bestY - refineRadius)...min(maxY, bestY + refineRadius) {
            for x in max(0, bestX - refineRadius)...min(maxX, bestX + refineRadius) {
                let candidate = score(x, y, stride: 8)
                if candidate < bestScore { bestScore = candidate; bestX = x; bestY = y }
            }
        }

        return (Double(bestX), Double(bestY), bestScore)
    }

    // MARK: - Native field presentation

    private func updateFieldCamera(_ runtime: NativeBridgeRuntime) {
        guard cameraTopLeftX != nil, cameraTopLeftY != nil else { return }
        let scroll = preferredScroll(runtime.backgroundOffsets())
        if let scroll, let previous = lastScroll, scroll.index == previous.index {
            cameraTopLeftX! += Double(wrappedDelta(from: previous.x, to: scroll.x, modulus: 512))
            cameraTopLeftY! += Double(wrappedDelta(from: previous.y, to: scroll.y, modulus: 512))
        }
        lastScroll = scroll

        if frameCounter % 18 == 0,
           let scene = currentScene,
           let image = currentSceneImage,
           let x = cameraTopLeftX,
           let y = cameraTopLeftY,
           let match = matchedCameraPosition(
                runtime,
                scene: scene,
                sceneImage: image,
                estimateX: x,
                estimateY: y,
                radius: 10,
                allowGlobalSearch: false
           ), match.score <= fieldDropScore {
            cameraTopLeftX = match.x
            cameraTopLeftY = match.y
        }
    }

    private func preferredScroll(_ offsets: [NativeBridgeRuntime.BackgroundOffset]) -> NativeBridgeRuntime.BackgroundOffset? {
        offsets.first(where: { $0.index == 2 })
            ?? offsets.first(where: { $0.index == 1 })
            ?? offsets.first(where: { $0.index == 3 })
            ?? offsets.first
    }

    private func refreshFieldBackground(_ runtime: NativeBridgeRuntime) {
        if frameCounter % 180 == 0, let scene = currentScene {
            currentSceneImage = runtime.colorizedSceneImage(scene)
        }

        guard let scene = currentScene,
              let image = currentSceneImage,
              let cameraX = cameraTopLeftX,
              let cameraY = cameraTopLeftY else { return }

        let maxX = max(0, scene.width - 240)
        let maxY = max(0, scene.height - portraitHeight)
        let cropX = min(max(Int(cameraX.rounded()), 0), maxX)
        let portraitTop = Int(cameraY.rounded()) - verticalExtension
        let cropY = min(max(portraitTop, 0), maxY)

        guard let crop = image.cropping(to: CGRect(x: cropX, y: cropY, width: 240, height: portraitHeight)) else {
            return
        }
        let texture = SKTexture(cgImage: crop)
        texture.filteringMode = .nearest
        fieldNode.texture = texture
    }

    private func refreshActors(_ runtime: NativeBridgeRuntime) {
        actorLayer.removeAllChildren()
        for sprite in runtime.spriteFrames() {
            if sprite.screenY >= 0 && sprite.screenY < 30 { continue }
            if sprite.screenY < -40 || sprite.screenY > 188 { continue }

            let targetTopY = sprite.screenY + verticalExtension
            let centerX = CGFloat(sprite.screenX) + CGFloat(sprite.width) * 0.5
            let centerYFromTop = CGFloat(targetTopY) + CGFloat(sprite.height) * 0.5
            let y = CGFloat(portraitHeight) - centerYFromTop
            if centerX < -40 || centerX > 280 || y < -80 || y > 600 { continue }

            let texture = SKTexture(cgImage: sprite.image)
            texture.filteringMode = .nearest
            let node = SKSpriteNode(texture: texture, size: CGSize(width: sprite.width, height: sprite.height))
            node.position = CGPoint(x: centerX, y: y)
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

        if looksLikeHUD(frame), let hud = frame.cropping(to: CGRect(x: 0, y: 0, width: 240, height: 38)) {
            let texture = SKTexture(cgImage: hud)
            texture.filteringMode = .nearest
            hudNode.texture = texture
            hudNode.size = CGSize(width: 216, height: 34)
            hudNode.position = CGPoint(x: 8, y: portraitHeight - 42)
            hudNode.isHidden = false
        } else {
            hudNode.isHidden = true
        }

        if let rect = dialogueRect(in: frame), let dialogue = frame.cropping(to: rect) {
            let texture = SKTexture(cgImage: dialogue)
            texture.filteringMode = .nearest
            dialogueNode.texture = texture
            let aspect = CGFloat(dialogue.width) / CGFloat(max(dialogue.height, 1))
            let width: CGFloat = 178
            let height = min(62, max(34, width / max(aspect, 0.01)))
            dialogueNode.size = CGSize(width: width, height: height)
            dialogueNode.position = CGPoint(x: 120, y: 78)
            dialogueNode.isHidden = false
        } else {
            dialogueNode.isHidden = true
        }
    }

    private func looksLikeHUD(_ image: CGImage) -> Bool {
        let stats = pixelStats(image, rect: CGRect(x: 0, y: 0, width: 180, height: 38))
        return stats.darkRatio > 0.28 && stats.brightRatio > 0.014
    }

    private func dialogueRect(in image: CGImage) -> CGRect? {
        guard image.width == 240, image.height == originalViewportHeight,
              let pixels = rgbaPixels(image) else { return nil }

        var rows: [Int] = []
        for y in 48..<159 {
            var bright = 0
            var dark = 0
            for x in 4..<236 {
                let i = (y * 240 + x) * 4
                let sum = Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2])
                if sum > 620 { bright += 1 }
                if sum < 110 { dark += 1 }
            }
            if bright >= 58 && dark >= 48 { rows.append(y) }
        }

        if let first = rows.first, let last = rows.last, last - first >= 12 {
            let top = max(42, first - 3)
            let bottom = min(160, last + 4)
            if bottom - top <= 82 {
                return CGRect(x: 8, y: top, width: 224, height: bottom - top)
            }
        }

        let fallback = CGRect(x: 10, y: 88, width: 220, height: 66)
        let stats = pixelStats(image, rect: fallback)
        return stats.darkRatio > 0.50 && stats.brightRatio > 0.024 ? fallback : nil
    }

    // MARK: - Portrait menus / splashes / cutscenes

    private enum PortraitFrameKind {
        case whiteSplash
        case purpleTitle
        case purpleMenu
        case darkCutscene
        case generic
    }

    private func showCinematic(_ runtime: NativeBridgeRuntime) {
        fieldNode.isHidden = true
        actorLayer.isHidden = true
        hudNode.isHidden = true
        dialogueNode.isHidden = true
        cinematicNode.isHidden = false

        guard let frame = runtime.framebufferImage(),
              let portrait = makePortraitPresentation(from: frame) else { return }
        let texture = SKTexture(cgImage: portrait)
        texture.filteringMode = .nearest
        cinematicNode.texture = texture
        cinematicNode.size = CGSize(width: 240, height: portraitHeight)
    }

    private func makePortraitPresentation(from frame: CGImage) -> CGImage? {
        guard let source = rgbaPixels(frame) else { return nil }
        let kind = classifyFrame(source, width: frame.width, height: frame.height)
        var output = [UInt8](repeating: 0, count: 240 * portraitHeight * 4)

        switch kind {
        case .whiteSplash:
            fill(&output, color: (248, 248, 248))
            let bounds = nonWhiteContentBounds(source, width: 240, height: 160) ?? (20, 35, 200, 90)
            let target = fittedRect(sourceW: bounds.w, sourceH: bounds.h, maxW: 206, maxH: 150, centerX: 120, centerY: 250)
            blitNearest(source, sourceWidth: 240, sourceHeight: 160, sourceRect: bounds, into: &output, destinationWidth: 240, destinationHeight: portraitHeight, destinationRect: target)

        case .purpleTitle:
            let bg = cornerAverage(source, width: 240, height: 160, darken: 0.78)
            fillVerticalGradient(&output, top: darkened(bg, factor: 0.60), bottom: bg)
            // Logo and menu become two intentionally placed portrait elements.
            blitNearest(source, sourceWidth: 240, sourceHeight: 160, sourceRect: (0, 8, 240, 104), into: &output, destinationWidth: 240, destinationHeight: portraitHeight, destinationRect: (5, 96, 230, 100))
            blitNearest(source, sourceWidth: 240, sourceHeight: 160, sourceRect: (34, 91, 172, 68), into: &output, destinationWidth: 240, destinationHeight: portraitHeight, destinationRect: (27, 260, 186, 74))

        case .purpleMenu:
            let bg = cornerAverage(source, width: 240, height: 160, darken: 0.80)
            fillVerticalGradient(&output, top: darkened(bg, factor: 0.62), bottom: bg)
            // Reflow the GBA's four compressed rows down the portrait screen.
            blitNearest(source, sourceWidth: 240, sourceHeight: 160, sourceRect: (0, 0, 240, 31), into: &output, destinationWidth: 240, destinationHeight: portraitHeight, destinationRect: (7, 62, 226, 29))
            let sourceRows = [(0, 29, 240, 32), (0, 61, 240, 32), (0, 93, 240, 32), (0, 125, 240, 34)]
            let destinationY = [128, 198, 268, 338]
            for (index, row) in sourceRows.enumerated() {
                blitNearest(source, sourceWidth: 240, sourceHeight: 160, sourceRect: row, into: &output, destinationWidth: 240, destinationHeight: portraitHeight, destinationRect: (8, destinationY[index], 224, 31))
            }

        case .darkCutscene:
            fill(&output, color: (0, 0, 0))
            let bounds = visibleContentBounds(source, width: 240, height: 160) ?? (0, 0, 240, 160)
            let target = fittedRect(sourceW: bounds.w, sourceH: bounds.h, maxW: 228, maxH: 250, centerX: 120, centerY: 245)
            blitNearest(source, sourceWidth: 240, sourceHeight: 160, sourceRect: bounds, into: &output, destinationWidth: 240, destinationHeight: portraitHeight, destinationRect: target)

        case .generic:
            let bg = cornerAverage(source, width: 240, height: 160, darken: 0.70)
            fillVerticalGradient(&output, top: darkened(bg, factor: 0.55), bottom: bg)
            let target = fittedRect(sourceW: 240, sourceH: 160, maxW: 232, maxH: 180, centerX: 120, centerY: 245)
            blitNearest(source, sourceWidth: 240, sourceHeight: 160, sourceRect: (0, 0, 240, 160), into: &output, destinationWidth: 240, destinationHeight: portraitHeight, destinationRect: target)
        }

        return makeRGBAImage(output, width: 240, height: portraitHeight)
    }

    private func classifyFrame(_ pixels: [UInt8], width: Int, height: Int) -> PortraitFrameKind {
        var white = 0, dark = 0, purple = 0, red = 0, yellow = 0, samples = 0
        for y in Swift.stride(from: 0, to: height, by: 2) {
            for x in Swift.stride(from: 0, to: width, by: 2) {
                let i = (y * width + x) * 4
                let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
                let maxC = max(r, max(g, b)), minC = min(r, min(g, b))
                if r > 225 && g > 225 && b > 225 { white += 1 }
                if r + g + b < 120 { dark += 1 }
                if r > 55 && b > 70 && b > g * 5 / 4 && r > g { purple += 1 }
                if r > 145 && r > g * 3 / 2 && r > b * 3 / 2 { red += 1 }
                if r > 170 && g > 135 && b < 95 && maxC - minC > 80 { yellow += 1 }
                samples += 1
            }
        }
        let count = Double(max(samples, 1))
        let whiteRatio = Double(white) / count
        let darkRatio = Double(dark) / count
        let purpleRatio = Double(purple) / count
        let redRatio = Double(red) / count
        let yellowRatio = Double(yellow) / count

        if whiteRatio > 0.46 { return .whiteSplash }
        if purpleRatio > 0.20 && redRatio > 0.028 && yellowRatio > 0.012 { return .purpleTitle }
        if purpleRatio > 0.22 { return .purpleMenu }
        if darkRatio > 0.56 { return .darkCutscene }
        return .generic
    }

    private func fittedRect(
        sourceW: Int,
        sourceH: Int,
        maxW: Int,
        maxH: Int,
        centerX: Int,
        centerY: Int
    ) -> (x: Int, y: Int, w: Int, h: Int) {
        let scale = min(Double(maxW) / Double(max(sourceW, 1)), Double(maxH) / Double(max(sourceH, 1)))
        let w = max(1, Int(Double(sourceW) * scale))
        let h = max(1, Int(Double(sourceH) * scale))
        return (centerX - w / 2, centerY - h / 2, w, h)
    }

    private func nonWhiteContentBounds(_ pixels: [UInt8], width: Int, height: Int) -> (x: Int, y: Int, w: Int, h: Int)? {
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
                if r > 232 && g > 232 && b > 232 { continue }
                minX = min(minX, x); minY = min(minY, y)
                maxX = max(maxX, x); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let pad = 5
        let x = max(0, minX - pad), y = max(0, minY - pad)
        let right = min(width, maxX + pad + 1), bottom = min(height, maxY + pad + 1)
        return (x, y, right - x, bottom - y)
    }

    private func visibleContentBounds(_ pixels: [UInt8], width: Int, height: Int) -> (x: Int, y: Int, w: Int, h: Int)? {
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let sum = Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2])
                if sum < 48 { continue }
                minX = min(minX, x); minY = min(minY, y)
                maxX = max(maxX, x); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let pad = 5
        let x = max(0, minX - pad), y = max(0, minY - pad)
        let right = min(width, maxX + pad + 1), bottom = min(height, maxY + pad + 1)
        return (x, y, right - x, bottom - y)
    }

    private func cornerAverage(
        _ pixels: [UInt8],
        width: Int,
        height: Int,
        darken: Double
    ) -> (UInt8, UInt8, UInt8) {
        let points = [(4, 4), (width - 5, 4), (4, height - 5), (width - 5, height - 5)]
        var r = 0, g = 0, b = 0
        for (x, y) in points {
            let i = (y * width + x) * 4
            r += Int(pixels[i]); g += Int(pixels[i + 1]); b += Int(pixels[i + 2])
        }
        return (
            UInt8(max(0, min(255, Int(Double(r / points.count) * darken)))),
            UInt8(max(0, min(255, Int(Double(g / points.count) * darken)))),
            UInt8(max(0, min(255, Int(Double(b / points.count) * darken))))
        )
    }

    private func darkened(_ color: (UInt8, UInt8, UInt8), factor: Double) -> (UInt8, UInt8, UInt8) {
        (
            UInt8(Double(color.0) * factor),
            UInt8(Double(color.1) * factor),
            UInt8(Double(color.2) * factor)
        )
    }

    private func fill(_ pixels: inout [UInt8], color: (UInt8, UInt8, UInt8)) {
        for p in 0..<(pixels.count / 4) {
            let i = p * 4
            pixels[i] = color.0; pixels[i + 1] = color.1; pixels[i + 2] = color.2; pixels[i + 3] = 255
        }
    }

    private func fillVerticalGradient(
        _ pixels: inout [UInt8],
        top: (UInt8, UInt8, UInt8),
        bottom: (UInt8, UInt8, UInt8)
    ) {
        for y in 0..<portraitHeight {
            let t = Double(y) / Double(max(1, portraitHeight - 1))
            let r = UInt8(Double(top.0) * (1 - t) + Double(bottom.0) * t)
            let g = UInt8(Double(top.1) * (1 - t) + Double(bottom.1) * t)
            let b = UInt8(Double(top.2) * (1 - t) + Double(bottom.2) * t)
            for x in 0..<240 {
                let i = (y * 240 + x) * 4
                pixels[i] = r; pixels[i + 1] = g; pixels[i + 2] = b; pixels[i + 3] = 255
            }
        }
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
            let y = destinationRect.y + dy
            guard y >= 0 && y < destinationHeight else { continue }
            let sy = sourceRect.y + min(sourceRect.h - 1, dy * sourceRect.h / destinationRect.h)
            guard sy >= 0 && sy < sourceHeight else { continue }
            for dx in 0..<destinationRect.w {
                let x = destinationRect.x + dx
                guard x >= 0 && x < destinationWidth else { continue }
                let sx = sourceRect.x + min(sourceRect.w - 1, dx * sourceRect.w / destinationRect.w)
                guard sx >= 0 && sx < sourceWidth else { continue }
                let si = (sy * sourceWidth + sx) * 4
                let di = (y * destinationWidth + x) * 4
                destination[di] = source[si]
                destination[di + 1] = source[si + 1]
                destination[di + 2] = source[si + 2]
                destination[di + 3] = 255
            }
        }
    }

    // MARK: - Pixel helpers

    private func pixelStats(_ image: CGImage, rect: CGRect) -> (darkRatio: Double, brightRatio: Double) {
        guard let pixels = rgbaPixels(image) else { return (0, 0) }
        let minX = max(0, Int(rect.minX)), maxX = min(image.width, Int(rect.maxX))
        let minY = max(0, Int(rect.minY)), maxY = min(image.height, Int(rect.maxY))
        var dark = 0, bright = 0, samples = 0
        for y in minY..<maxY {
            for x in Swift.stride(from: minX, to: maxX, by: 2) {
                let i = (y * image.width + x) * 4
                let sum = Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2])
                if sum < 120 { dark += 1 }
                if sum > 620 { bright += 1 }
                samples += 1
            }
        }
        let count = Double(max(samples, 1))
        return (Double(dark) / count, Double(bright) / count)
    }

    private func rgbaPixels(_ image: CGImage) -> [UInt8]? {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .none
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels
    }

    private func makeRGBAImage(_ pixels: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
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

    private func wrappedDelta(from old: Int, to new: Int, modulus: Int) -> Int {
        var delta = new - old
        let half = modulus / 2
        if delta > half { delta -= modulus }
        if delta < -half { delta += modulus }
        return delta
    }

    private func installFailureWorld(message: String) {
        removeAllChildren()
        backgroundColor = .black
        let title = SKLabelNode(fontNamed: "AvenirNext-Bold")
        title.text = "PORT ERROR"
        title.fontSize = 12
        title.position = CGPoint(x: 120, y: 278)
        addChild(title)
        let detail = SKLabelNode(fontNamed: "AvenirNext-Regular")
        detail.text = String(message.prefix(90))
        detail.fontSize = 5
        detail.position = CGPoint(x: 120, y: 250)
        addChild(detail)
    }
}
