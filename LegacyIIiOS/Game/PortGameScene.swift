import Combine
import CoreGraphics
import Foundation
import SpriteKit

final class PortGameScene: SKScene, ObservableObject {
    enum ControlMode: Equatable {
        case gameplay
        case menu
        case cinematic
    }

    @Published private(set) var controlMode: ControlMode = .cinematic

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

    // A field is only allowed onto the screen after the active scene descriptor
    // from game RAM agrees with the live 240x160 hardware frame. There is no
    // nearest-scene/global fallback anymore: a failed proof stays in safe frame mode.
    private let fieldAcceptScore: Int64 = 58
    private let fieldDropScore: Int64 = 78

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
        dialogueNode.position = CGPoint(x: 120, y: 70)
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

            if frameCounter % 90 == 0 {
                if verifyCurrentField(runtime) {
                    failedFieldChecks = 0
                } else {
                    failedFieldChecks += 1
                }
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
        if controlMode != .gameplay { controlMode = .gameplay }

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

    // MARK: - Strict authored field selection

    private func resolveVerifiedField(_ runtime: NativeBridgeRuntime) -> Bool {
        guard let rom,
              !sceneDescriptors.isEmpty,
              let active = runtime.activeSceneDescriptorOffset(candidates: sceneDescriptors),
              let decoded = decodedScene(active, rom: rom),
              let image = runtime.colorizedSceneImage(decoded) else {
            return false
        }

        let estimate = initialCameraEstimate(scene: decoded, runtime: runtime)
        guard let match = matchedCameraPosition(
            runtime,
            scene: decoded,
            sceneImage: image,
            estimateX: estimate.x,
            estimateY: estimate.y,
            radius: 180
        ), match.score <= fieldAcceptScore else {
            return false
        }

        currentSceneDescriptor = active
        currentScene = decoded
        currentSceneImage = image
        cameraTopLeftX = match.x
        cameraTopLeftY = match.y
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
        guard let active = runtime.activeSceneDescriptorOffset(candidates: sceneDescriptors),
              active == currentSceneDescriptor,
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
                radius: 22
              ) else { return false }

        guard match.score <= fieldDropScore else { return false }
        cameraTopLeftX = match.x
        cameraTopLeftY = match.y
        return true
    }

    private func matchedCameraPosition(
        _ runtime: NativeBridgeRuntime,
        scene: ALFPSceneData.IndexedScene,
        sceneImage: CGImage,
        estimateX: Double,
        estimateY: Double,
        radius: Int
    ) -> (x: Double, y: Double, score: Int64)? {
        guard let frame = runtime.framebufferImage(),
              let scenePixels = rgbaPixels(sceneImage),
              let framePixels = rawFramebufferRGBA(frame) else { return nil }

        let maxX = max(0, scene.width - 240)
        let maxY = max(0, scene.height - 160)
        let baseX = min(max(Int(estimateX.rounded()), 0), maxX)
        let baseY = min(max(Int(estimateY.rounded()), 0), maxY)

        func score(_ x0: Int, _ y0: Int, stride sampleStride: Int) -> Int64 {
            var total: Int64 = 0
            var samples: Int64 = 0

            // Ignore the HUD, the very bottom text area, and the player/OAM center.
            for sy in Swift.stride(from: 38, to: 145, by: sampleStride) {
                for sx in Swift.stride(from: 4, to: 236, by: sampleStride) {
                    if sx >= 74 && sx <= 166 && sy >= 46 && sy <= 136 { continue }
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

        for y in Swift.stride(from: minY, through: maxSearchY, by: 8) {
            for x in Swift.stride(from: minX, through: maxSearchX, by: 8) {
                let candidate = score(x, y, stride: 10)
                if candidate < bestScore {
                    bestScore = candidate
                    bestX = x
                    bestY = y
                }
            }
        }

        let refine = 10
        for y in max(0, bestY - refine)...min(maxY, bestY + refine) {
            for x in max(0, bestX - refine)...min(maxX, bestX + refine) {
                let candidate = score(x, y, stride: 7)
                if candidate < bestScore {
                    bestScore = candidate
                    bestX = x
                    bestY = y
                }
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
                radius: 12
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
        if frameCounter % 120 == 0, let scene = currentScene {
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
            hudNode.size = CGSize(width: 220, height: 35)
            hudNode.position = CGPoint(x: 10, y: portraitHeight - 43)
            hudNode.isHidden = false
        } else {
            hudNode.isHidden = true
        }

        if let rect = dialogueRect(in: frame), let dialogue = frame.cropping(to: rect) {
            let texture = SKTexture(cgImage: dialogue)
            texture.filteringMode = .nearest
            dialogueNode.texture = texture
            let aspect = CGFloat(dialogue.width) / CGFloat(max(dialogue.height, 1))
            let width: CGFloat = 214
            let height = min(72, max(36, width / max(aspect, 0.01)))
            dialogueNode.size = CGSize(width: width, height: height)
            dialogueNode.position = CGPoint(x: 120, y: 66)
            dialogueNode.isHidden = false
        } else {
            dialogueNode.isHidden = true
        }
    }

    private func looksLikeHUD(_ image: CGImage) -> Bool {
        let stats = pixelStats(image, rect: CGRect(x: 0, y: 0, width: 190, height: 40))
        return stats.darkRatio > 0.24 && stats.brightRatio > 0.010
    }

    private func dialogueRect(in image: CGImage) -> CGRect? {
        guard image.width == 240, image.height == originalViewportHeight,
              let pixels = rawFramebufferRGBA(image) else { return nil }

        var borderRows: [Int] = []
        for y in 42..<160 {
            var bright = 0
            var dark = 0
            for x in 4..<236 {
                let i = (y * 240 + x) * 4
                let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
                if r > 205 && g > 205 && b > 205 { bright += 1 }
                if r + g + b < 150 { dark += 1 }
            }
            if bright >= 120 && dark >= 20 { borderRows.append(y) }
        }

        if borderRows.count >= 2 {
            for top in borderRows {
                if let bottom = borderRows.first(where: { $0 >= top + 16 && $0 <= top + 78 }) {
                    let y = max(0, top - 2)
                    return CGRect(x: 4, y: y, width: 232, height: min(160, bottom + 3) - y)
                }
            }
        }

        let fallback = CGRect(x: 8, y: 88, width: 224, height: 68)
        let stats = pixelStats(image, rect: fallback)
        return stats.darkRatio > 0.48 && stats.brightRatio > 0.020 ? fallback : nil
    }

    // MARK: - Portrait menus, splashes, and cutscenes

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
              let source = rawFramebufferRGBA(frame) else { return }

        let kind = classifyFrame(source, width: 240, height: 160)
        switch kind {
        case .purpleTitle, .purpleMenu:
            if controlMode != .menu { controlMode = .menu }
        case .whiteSplash, .darkCutscene, .generic:
            if controlMode != .cinematic { controlMode = .cinematic }
        }

        guard let portrait = makePortraitPresentation(source: source, kind: kind) else { return }
        let texture = SKTexture(cgImage: portrait)
        texture.filteringMode = .nearest
        cinematicNode.texture = texture
        cinematicNode.size = CGSize(width: 240, height: portraitHeight)
    }

    private func makePortraitPresentation(source: [UInt8], kind: PortraitFrameKind) -> CGImage? {
        var output = [UInt8](repeating: 0, count: 240 * portraitHeight * 4)

        switch kind {
        case .whiteSplash:
            fill(&output, color: (248, 248, 248))
            let bounds = nonWhiteContentBounds(source, width: 240, height: 160) ?? (20, 30, 200, 100)
            let crop = cropRGBA(source, sourceWidth: 240, sourceHeight: 160, rect: bounds)
            let target = fittedRect(sourceW: bounds.w, sourceH: bounds.h, maxW: 214, maxH: 170, centerX: 120, centerY: 226)
            blitNearest(crop, sourceWidth: bounds.w, sourceHeight: bounds.h, sourceRect: (0, 0, bounds.w, bounds.h), into: &output, destinationWidth: 240, destinationHeight: portraitHeight, destinationRect: target)

        case .darkCutscene:
            fill(&output, color: (0, 0, 0))
            let bounds = visibleContentBounds(source, width: 240, height: 160) ?? (0, 0, 240, 160)
            let crop = cropRGBA(source, sourceWidth: 240, sourceHeight: 160, rect: bounds)
            let target = fittedRect(sourceW: bounds.w, sourceH: bounds.h, maxW: 232, maxH: 270, centerX: 120, centerY: 216)
            blitNearest(crop, sourceWidth: bounds.w, sourceHeight: bounds.h, sourceRect: (0, 0, bounds.w, bounds.h), into: &output, destinationWidth: 240, destinationHeight: portraitHeight, destinationRect: target)

        case .purpleMenu:
            tilePurpleBackdrop(source, into: &output)
            let title = (0, 0, 240, 31)
            let rows = [(0, 31, 240, 43), (0, 74, 240, 43), (0, 117, 240, 43)]
            blitNearest(source, sourceWidth: 240, sourceHeight: 160, sourceRect: title, into: &output, destinationWidth: 240, destinationHeight: portraitHeight, destinationRect: (0, 58, 240, 31))
            let ys = [124, 214, 304]
            for (index, row) in rows.enumerated() {
                blitNearest(source, sourceWidth: 240, sourceHeight: 160, sourceRect: row, into: &output, destinationWidth: 240, destinationHeight: portraitHeight, destinationRect: (0, ys[index], 240, 43))
            }

        case .purpleTitle:
            tilePurpleBackdrop(source, into: &output)
            blitNearest(source, sourceWidth: 240, sourceHeight: 160, sourceRect: (0, 0, 240, 160), into: &output, destinationWidth: 240, destinationHeight: portraitHeight, destinationRect: (0, 112, 240, 160))

        case .generic:
            let background = edgeAverage(source, width: 240, height: 160)
            fill(&output, color: background)
            blitNearest(source, sourceWidth: 240, sourceHeight: 160, sourceRect: (0, 0, 240, 160), into: &output, destinationWidth: 240, destinationHeight: portraitHeight, destinationRect: (0, 112, 240, 160))
        }

        return makeRGBAImage(output, width: 240, height: portraitHeight)
    }

    private func classifyFrame(_ pixels: [UInt8], width: Int, height: Int) -> PortraitFrameKind {
        var white = 0, dark = 0, purple = 0, red = 0, yellow = 0, cyan = 0, samples = 0
        for y in Swift.stride(from: 0, to: height, by: 2) {
            for x in Swift.stride(from: 0, to: width, by: 2) {
                let i = (y * width + x) * 4
                let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
                if r > 225 && g > 225 && b > 225 { white += 1 }
                if r + g + b < 120 { dark += 1 }
                if r > 52 && b > 70 && b > g * 5 / 4 && r > g { purple += 1 }
                if r > 145 && r > g * 3 / 2 && r > b * 3 / 2 { red += 1 }
                if r > 170 && g > 135 && b < 105 { yellow += 1 }
                if b > 150 && g > 120 && r < 110 { cyan += 1 }
                samples += 1
            }
        }
        let count = Double(max(samples, 1))
        let whiteRatio = Double(white) / count
        let darkRatio = Double(dark) / count
        let purpleRatio = Double(purple) / count
        let redRatio = Double(red) / count
        let yellowRatio = Double(yellow) / count
        let cyanRatio = Double(cyan) / count

        if whiteRatio > 0.46 { return .whiteSplash }
        if darkRatio > 0.58 { return .darkCutscene }
        if purpleRatio > 0.24 {
            if redRatio > 0.020 || yellowRatio > 0.018 || cyanRatio > 0.022 { return .purpleTitle }
            return .purpleMenu
        }
        return .generic
    }

    private func tilePurpleBackdrop(_ source: [UInt8], into output: inout [UInt8]) {
        let patch = bestPurplePatch(source, width: 240, height: 160, patchSize: 24)
        let crop = cropRGBA(source, sourceWidth: 240, sourceHeight: 160, rect: patch)
        for y in stride(from: 0, to: portraitHeight, by: patch.h) {
            for x in stride(from: 0, to: 240, by: patch.w) {
                let w = min(patch.w, 240 - x)
                let h = min(patch.h, portraitHeight - y)
                blitNearest(crop, sourceWidth: patch.w, sourceHeight: patch.h, sourceRect: (0, 0, w, h), into: &output, destinationWidth: 240, destinationHeight: portraitHeight, destinationRect: (x, y, w, h))
            }
        }
    }

    private func bestPurplePatch(_ source: [UInt8], width: Int, height: Int, patchSize: Int) -> (x: Int, y: Int, w: Int, h: Int) {
        var best = (x: 104, y: 48, w: patchSize, h: patchSize)
        var bestScore = Int.min
        guard width >= patchSize, height >= patchSize else { return (0, 0, width, height) }

        for y in stride(from: 0, through: height - patchSize, by: 8) {
            for x in stride(from: 0, through: width - patchSize, by: 8) {
                var purple = 0, bright = 0, yellow = 0, red = 0, dark = 0
                for py in stride(from: 0, to: patchSize, by: 2) {
                    for px in stride(from: 0, to: patchSize, by: 2) {
                        let i = ((y + py) * width + (x + px)) * 4
                        let r = Int(source[i]), g = Int(source[i + 1]), b = Int(source[i + 2])
                        if r > 52 && b > 70 && b > g * 5 / 4 && r > g { purple += 1 }
                        if r > 215 && g > 215 && b > 215 { bright += 1 }
                        if r > 170 && g > 135 && b < 105 { yellow += 1 }
                        if r > 150 && r > g * 3 / 2 && r > b * 3 / 2 { red += 1 }
                        if r + g + b < 105 { dark += 1 }
                    }
                }
                let score = purple * 5 - bright * 4 - yellow * 7 - red * 5 - dark * 2
                if score > bestScore {
                    bestScore = score
                    best = (x, y, patchSize, patchSize)
                }
            }
        }
        return best
    }

    private func fittedRect(sourceW: Int, sourceH: Int, maxW: Int, maxH: Int, centerX: Int, centerY: Int) -> (x: Int, y: Int, w: Int, h: Int) {
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
        let pad = 4
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
                if sum < 52 { continue }
                minX = min(minX, x); minY = min(minY, y)
                maxX = max(maxX, x); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let pad = 4
        let x = max(0, minX - pad), y = max(0, minY - pad)
        let right = min(width, maxX + pad + 1), bottom = min(height, maxY + pad + 1)
        return (x, y, right - x, bottom - y)
    }

    private func edgeAverage(_ pixels: [UInt8], width: Int, height: Int) -> (UInt8, UInt8, UInt8) {
        let points = [
            (4, 4), (width / 2, 4), (width - 5, 4),
            (4, height / 2), (width - 5, height / 2),
            (4, height - 5), (width / 2, height - 5), (width - 5, height - 5)
        ]
        var r = 0, g = 0, b = 0
        for (x, y) in points {
            let i = (y * width + x) * 4
            r += Int(pixels[i]); g += Int(pixels[i + 1]); b += Int(pixels[i + 2])
        }
        let count = max(1, points.count)
        return (UInt8(r / count), UInt8(g / count), UInt8(b / count))
    }

    private func fill(_ pixels: inout [UInt8], color: (UInt8, UInt8, UInt8)) {
        for p in 0..<(pixels.count / 4) {
            let i = p * 4
            pixels[i] = color.0
            pixels[i + 1] = color.1
            pixels[i + 2] = color.2
            pixels[i + 3] = 255
        }
    }

    private func cropRGBA(_ source: [UInt8], sourceWidth: Int, sourceHeight: Int, rect: (x: Int, y: Int, w: Int, h: Int)) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: rect.w * rect.h * 4)
        for y in 0..<rect.h {
            let sy = rect.y + y
            guard sy >= 0 && sy < sourceHeight else { continue }
            for x in 0..<rect.w {
                let sx = rect.x + x
                guard sx >= 0 && sx < sourceWidth else { continue }
                let si = (sy * sourceWidth + sx) * 4
                let di = (y * rect.w + x) * 4
                output[di] = source[si]
                output[di + 1] = source[si + 1]
                output[di + 2] = source[si + 2]
                output[di + 3] = 255
            }
        }
        return output
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
        guard let pixels = rawFramebufferRGBA(image) else { return (0, 0) }
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

    private func rawFramebufferRGBA(_ image: CGImage) -> [UInt8]? {
        guard image.width == 240, image.height == 160,
              let provider = image.dataProvider,
              let data = provider.data else { return rgbaPixels(image) }
        let bytes = CFDataGetBytePtr(data)
        let count = CFDataGetLength(data)
        guard let bytes, count >= image.width * image.height * 4 else { return rgbaPixels(image) }

        var rgba = [UInt8](repeating: 0, count: image.width * image.height * 4)
        for pixel in 0..<(image.width * image.height) {
            let s = pixel * 4
            rgba[s] = bytes[s + 2]
            rgba[s + 1] = bytes[s + 1]
            rgba[s + 2] = bytes[s]
            rgba[s + 3] = 255
        }
        return rgba
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
        if delta > modulus / 2 { delta -= modulus }
        if delta < -(modulus / 2) { delta += modulus }
        return delta
    }

    private func installFailureWorld(message: String) {
        controlMode = .cinematic
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
