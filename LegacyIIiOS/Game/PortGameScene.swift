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
        hudNode.position = CGPoint(x: 0, y: portraitHeight - hudHeight - 8)
        hudNode.size = CGSize(width: 240, height: hudHeight)
        hudNode.zPosition = 5000
        hudNode.isHidden = true
        addChild(hudNode)

        dialogueNode.anchorPoint = CGPoint(x: 0.5, y: 0)
        dialogueNode.position = CGPoint(x: 120, y: 64)
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

        // Keep game logic/input at 60 Hz. Rendering the authored 1024x1024 scene
        // at 30 Hz is enough for the pixel art while keeping the hidden core smooth.
        guard frameCounter == 1 || frameCounter % 2 == 0 else { return }
        refreshPresentation(runtime)
    }

    private func refreshPresentation(_ runtime: NativeBridgeRuntime) {
        let fieldNow = runtime.isLikelyFieldFrame()
        if fieldNow {
            fieldConfidence = min(6, fieldConfidence + 1)
            cinematicConfidence = 0
        } else {
            cinematicConfidence = min(6, cinematicConfidence + 1)
            fieldConfidence = 0
        }

        if !fieldPresentationActive && fieldConfidence >= 2 {
            fieldPresentationActive = true
            resetFieldCalibration()
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

    private func showField(_ runtime: NativeBridgeRuntime) {
        cinematicNode.isHidden = true
        backgroundNode.isHidden = false
        actorLayer.isHidden = false

        // Resolve the live authored scene periodically by its resource pointer in
        // work RAM. If the current build of the game does not expose that pointer,
        // the first field remains a safe fallback rather than showing corrupt VRAM.
        if frameCounter % 30 == 0 || currentScene == nil {
            resolveCurrentScene(runtime)
        }

        updateFieldCamera(runtime)
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

        if let image = runtime.cinematicPortraitImage(height: portraitHeight) {
            let texture = SKTexture(cgImage: image)
            texture.filteringMode = .nearest
            cinematicNode.texture = texture
        }
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
            if let cached = sceneCache[descriptor] {
                decoded = cached
            } else {
                decoded = try ALFPSceneData.decodeScene(in: rom, at: descriptor)
                sceneCache[descriptor] = decoded
            }
            currentSceneDescriptor = descriptor
            currentScene = decoded
            currentSceneImage = runtime.colorizedSceneImage(decoded)
            resetFieldCalibration(keepScene: true)
        } catch {
            // A false-positive live pointer must never destroy a working field view.
            if currentScene == nil,
               let fallback = try? ALFPSceneData.decodeFirstScene(in: rom) {
                currentSceneDescriptor = fallback.descriptorOffset
                currentScene = fallback
                sceneCache[fallback.descriptorOffset] = fallback
                currentSceneImage = runtime.colorizedSceneImage(fallback)
            }
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

    private func refreshFieldBackground(_ runtime: NativeBridgeRuntime) {
        if frameCounter % 240 == 0, let scene = currentScene {
            // Palette changes (lighting, scripted scenes) should recolor the authored
            // map without rebuilding/decompressing it every presentation frame.
            currentSceneImage = runtime.colorizedSceneImage(scene)
        }

        guard let scene = currentScene,
              let image = currentSceneImage,
              let cameraX = cameraTopLeftX,
              let cameraY = cameraTopLeftY else {
            if let fallback = runtime.portraitBackgroundImage(height: portraitHeight) {
                installBackgroundTexture(fallback)
            }
            return
        }

        let maxX = max(0, scene.width - 240)
        let maxY = max(0, scene.height - portraitHeight)
        let cropX = min(max(Int(cameraX.rounded()), 0), maxX)
        let portraitTop = Int(cameraY.rounded()) - verticalExtension
        let cropY = min(max(portraitTop, 0), maxY)

        if let crop = image.cropping(to: CGRect(x: cropX, y: cropY, width: 240, height: portraitHeight)) {
            installBackgroundTexture(crop)
        } else if let fallback = runtime.portraitBackgroundImage(height: portraitHeight) {
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
            // Ignore OAM objects that belong to the original top HUD. The iPhone
            // HUD is composited separately from the authentic framebuffer below.
            if sprite.screenY >= 0 && sprite.screenY < 34 { continue }
            // Only live hardware-visible actors are authoritative. Old OAM slots
            // outside this range are stale and caused phantom characters/bands.
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

        if looksLikeHUD(frame),
           let hud = crop(frame, x: 0, y: 0, width: 240, height: hudHeight) {
            let texture = SKTexture(cgImage: hud)
            texture.filteringMode = .nearest
            hudNode.texture = texture
            hudNode.isHidden = false
        } else {
            hudNode.isHidden = true
        }

        if let rect = dialogueRect(in: frame),
           let dialogue = frame.cropping(to: rect) {
            let texture = SKTexture(cgImage: dialogue)
            texture.filteringMode = .nearest
            dialogueNode.texture = texture
            let aspect = CGFloat(dialogue.width) / CGFloat(max(dialogue.height, 1))
            let targetWidth: CGFloat = 216
            let targetHeight = min(112, max(40, targetWidth / aspect))
            dialogueNode.size = CGSize(width: targetWidth, height: targetHeight)
            dialogueNode.position = CGPoint(x: 120, y: 48)
            dialogueNode.isHidden = false
        } else {
            dialogueNode.isHidden = true
        }
    }

    private func looksLikeHUD(_ image: CGImage) -> Bool {
        let stats = pixelStats(image, rect: CGRect(x: 0, y: 0, width: 240, height: hudHeight))
        // A real LoG II HUD contains a large dark frame plus bright text/bars.
        // Ordinary terrain at the top of the GBA view should not pass this.
        return stats.darkRatio > 0.34 && stats.brightRatio > 0.018
    }

    /// Find the actual dialogue box instead of assuming it lives in the bottom
    /// 72 pixels. The old assumption is why text appeared only after the R-button
    /// changed the cartridge UI position.
    private func dialogueRect(in image: CGImage) -> CGRect? {
        guard let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data),
              image.width == 240,
              image.height == originalViewportHeight else { return nil }

        let rowBytes = image.bytesPerRow
        let strideBytes = max(4, image.bitsPerPixel / 8)
        var borderRows: [Int] = []

        for y in 38..<159 {
            var bright = 0
            var dark = 0
            for x in 0..<240 {
                let offset = y * rowBytes + x * strideBytes
                let sum = Int(bytes[offset]) + Int(bytes[offset + 1]) + Int(bytes[offset + 2])
                if sum > 620 { bright += 1 }
                if sum < 105 { dark += 1 }
            }
            if bright >= 72 && dark >= 52 { borderRows.append(y) }
        }

        if let first = borderRows.first,
           let last = borderRows.last,
           last - first >= 15,
           last - first <= 108 {
            let top = max(30, first - 4)
            let bottom = min(160, last + 5)
            return CGRect(x: 6, y: top, width: 228, height: bottom - top)
        }

        // Some dialogue skins do not have a full white border. Fall back to a
        // broad lower-screen text signature, but never key this to L/R state.
        let fallback = CGRect(x: 12, y: 72, width: 216, height: 84)
        let stats = pixelStats(image, rect: fallback)
        if stats.darkRatio > 0.46 && stats.brightRatio > 0.025 {
            return fallback
        }
        return nil
    }

    private func pixelStats(_ image: CGImage, rect: CGRect) -> (darkRatio: Double, brightRatio: Double) {
        guard let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return (0, 0) }
        let rowBytes = image.bytesPerRow
        let strideBytes = max(4, image.bitsPerPixel / 8)
        let minX = max(0, Int(rect.minX))
        let maxX = min(image.width, Int(rect.maxX))
        let minY = max(0, Int(rect.minY))
        let maxY = min(image.height, Int(rect.maxY))
        var dark = 0
        var bright = 0
        var samples = 0
        for y in minY..<maxY {
            for x in stride(from: minX, to: maxX, by: 2) {
                let offset = y * rowBytes + x * strideBytes
                let sum = Int(bytes[offset]) + Int(bytes[offset + 1]) + Int(bytes[offset + 2])
                if sum < 120 { dark += 1 }
                if sum > 620 { bright += 1 }
                samples += 1
            }
        }
        let count = Double(max(samples, 1))
        return (Double(dark) / count, Double(bright) / count)
    }

    private func crop(_ image: CGImage, x: Int, y: Int, width: Int, height: Int) -> CGImage? {
        image.cropping(to: CGRect(x: x, y: y, width: width, height: height))
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
        if !keepScene {
            currentScene = nil
            currentSceneImage = nil
            currentSceneDescriptor = nil
        }
    }

    private func installFailureWorld(message: String) {
        backgroundNode.isHidden = true
        cinematicNode.isHidden = true
        actorLayer.isHidden = true

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
