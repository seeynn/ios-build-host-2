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
    private var frameCounter = 0
    private var fieldConfidence = 0

    private let portraitHeight = 520
    private let verticalExtension = 180

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

        cinematicNode.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        cinematicNode.position = CGPoint(x: 120, y: portraitHeight * 0.5)
        cinematicNode.zPosition = -900
        addChild(cinematicNode)

        actorLayer.zPosition = 100
        addChild(actorLayer)

        hudNode.anchorPoint = CGPoint(x: 0, y: 0)
        hudNode.position = CGPoint(x: 7, y: portraitHeight - 41)
        hudNode.zPosition = 4000
        hudNode.isHidden = true
        addChild(hudNode)

        dialogueNode.anchorPoint = CGPoint(x: 0.5, y: 0)
        dialogueNode.position = CGPoint(x: 120, y: 66)
        dialogueNode.zPosition = 4100
        dialogueNode.isHidden = true
        addChild(dialogueNode)

        do {
            let bridge = try NativeBridgeRuntime()
            try bridge.start(romURL: romURL, saveURL: saveURL)
            runtime = bridge
            showNonField(bridge)
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
        if runtime.isLikelyFieldFrame(),
           let portrait = runtime.authoredPortraitBackgroundImage(height: portraitHeight),
           let frame = runtime.framebufferImage(),
           fieldMatchesHardware(portrait: portrait, hardware: frame) {
            fieldConfidence = min(4, fieldConfidence + 1)
            if fieldConfidence >= 2 || controlMode == .gameplay {
                showField(runtime, portrait: portrait)
                return
            }
        } else {
            fieldConfidence = 0
        }

        showNonField(runtime)
    }

    // MARK: - Gameplay

    private func showField(_ runtime: NativeBridgeRuntime, portrait: CGImage) {
        cinematicNode.isHidden = true
        fieldNode.isHidden = false
        actorLayer.isHidden = false
        if controlMode != .gameplay { controlMode = .gameplay }

        let texture = SKTexture(cgImage: portrait)
        texture.filteringMode = .nearest
        fieldNode.texture = texture

        refreshActors(runtime)
        refreshOriginalUI(runtime)
    }

    private func refreshActors(_ runtime: NativeBridgeRuntime) {
        actorLayer.removeAllChildren()

        for sprite in runtime.spriteFrames() {
            // The original top-left HUD is represented separately at the real
            // portrait top. Do not duplicate those OAM tiles in the world.
            if sprite.screenY >= 0 && sprite.screenY < 30 && sprite.screenX < 105 { continue }
            if sprite.screenY < -40 || sprite.screenY > 190 { continue }

            let top = sprite.screenY + verticalExtension
            let centerX = CGFloat(sprite.screenX) + CGFloat(sprite.width) * 0.5
            let centerYFromTop = CGFloat(top) + CGFloat(sprite.height) * 0.5
            let y = CGFloat(portraitHeight) - centerYFromTop

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

        if looksLikeHUD(frame), let hud = frame.cropping(to: CGRect(x: 0, y: 0, width: 240, height: 37)) {
            let texture = SKTexture(cgImage: hud)
            texture.filteringMode = .nearest
            hudNode.texture = texture
            hudNode.size = CGSize(width: 224, height: 35)
            hudNode.isHidden = false
        } else {
            hudNode.isHidden = true
        }

        if let rect = dialogueRect(in: frame), let dialogue = frame.cropping(to: rect) {
            let texture = SKTexture(cgImage: dialogue)
            texture.filteringMode = .nearest
            dialogueNode.texture = texture
            let aspect = CGFloat(dialogue.width) / CGFloat(max(dialogue.height, 1))
            let width: CGFloat = 224
            dialogueNode.size = CGSize(width: width, height: min(78, max(36, width / max(aspect, 0.01))))
            dialogueNode.isHidden = false
        } else {
            dialogueNode.isHidden = true
        }
    }

    /// The extended world is never shown merely because a map decoder returned
    /// pixels. Its central 240x160 background must agree with the real hardware
    /// frame first. This rejects wrong chunks, wrong scroll pages and wrong
    /// palettes before they can become visible on the phone.
    private func fieldMatchesHardware(portrait: CGImage, hardware: CGImage) -> Bool {
        guard let p = rgbaPixels(portrait), let h = framebufferPixels(hardware) else { return false }
        var good = 0
        var tested = 0

        for sy in stride(from: 38, to: 146, by: 4) {
            let py = sy + verticalExtension
            for x in stride(from: 4, to: 236, by: 4) {
                // Most player/NPC OAM lives near the middle. Background agreement
                // is tested around it so actors do not cause false rejection.
                if x >= 60 && x <= 180 && sy >= 48 && sy <= 138 { continue }
                let hi = (sy * 240 + x) * 4
                let pi = (py * 240 + x) * 4
                let diff = abs(Int(h[hi]) - Int(p[pi]))
                    + abs(Int(h[hi + 1]) - Int(p[pi + 1]))
                    + abs(Int(h[hi + 2]) - Int(p[pi + 2]))
                if diff <= 54 { good += 1 }
                tested += 1
            }
        }
        return tested > 0 && Double(good) / Double(tested) >= 0.58
    }

    // MARK: - Menus / logos / cutscenes

    private func showNonField(_ runtime: NativeBridgeRuntime) {
        fieldNode.isHidden = true
        actorLayer.isHidden = true
        hudNode.isHidden = true
        dialogueNode.isHidden = true
        cinematicNode.isHidden = false
        fieldConfidence = 0

        guard let frame = runtime.framebufferImage() else { return }
        let kind = classify(frame)
        switch kind {
        case .purpleMenu:
            if controlMode != .menu { controlMode = .menu }
        default:
            if controlMode != .cinematic { controlMode = .cinematic }
        }

        let texture = SKTexture(cgImage: frame)
        texture.filteringMode = .nearest
        cinematicNode.texture = texture

        // Preserve the source art exactly. No strips, mirroring or aspect warp.
        // A 240px-wide source already spans the full logical iPhone width.
        switch kind {
        case .darkCutscene:
            if let bounds = visibleBounds(frame),
               let crop = frame.cropping(to: bounds) {
                let cropTexture = SKTexture(cgImage: crop)
                cropTexture.filteringMode = .nearest
                cinematicNode.texture = cropTexture
                let scale = min(232 / CGFloat(max(crop.width, 1)), 280 / CGFloat(max(crop.height, 1)))
                cinematicNode.size = CGSize(width: CGFloat(crop.width) * scale, height: CGFloat(crop.height) * scale)
                backgroundColor = .black
            } else {
                cinematicNode.size = CGSize(width: 240, height: 160)
                backgroundColor = .black
            }
        case .whiteSplash:
            cinematicNode.size = CGSize(width: 240, height: 160)
            backgroundColor = .white
        case .purpleMenu:
            cinematicNode.size = CGSize(width: 240, height: 160)
            backgroundColor = sampledEdgeColor(frame)
        case .generic:
            cinematicNode.size = CGSize(width: 240, height: 160)
            backgroundColor = sampledEdgeColor(frame)
        }
    }

    private enum FrameKind { case whiteSplash, purpleMenu, darkCutscene, generic }

    private func classify(_ frame: CGImage) -> FrameKind {
        guard let pixels = framebufferPixels(frame) else { return .generic }
        var white = 0, dark = 0, purple = 0, samples = 0
        for y in stride(from: 0, to: 160, by: 3) {
            for x in stride(from: 0, to: 240, by: 3) {
                let i = (y * 240 + x) * 4
                let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
                if r > 225 && g > 225 && b > 225 { white += 1 }
                if r + g + b < 120 { dark += 1 }
                if r > 50 && b > 70 && r > g && b > g * 5 / 4 { purple += 1 }
                samples += 1
            }
        }
        let n = Double(max(samples, 1))
        if Double(white) / n > 0.46 { return .whiteSplash }
        if Double(dark) / n > 0.58 { return .darkCutscene }
        if Double(purple) / n > 0.20 { return .purpleMenu }
        return .generic
    }

    private func visibleBounds(_ image: CGImage) -> CGRect? {
        guard let pixels = framebufferPixels(image) else { return nil }
        var minX = 240, minY = 160, maxX = -1, maxY = -1
        for y in 0..<160 {
            for x in 0..<240 {
                let i = (y * 240 + x) * 4
                if Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2]) <= 48 { continue }
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let pad = 4
        let x = max(0, minX - pad), y = max(0, minY - pad)
        let right = min(240, maxX + pad + 1), bottom = min(160, maxY + pad + 1)
        return CGRect(x: x, y: y, width: right - x, height: bottom - y)
    }

    private func sampledEdgeColor(_ frame: CGImage) -> SKColor {
        guard let p = framebufferPixels(frame) else { return .black }
        let points = [(3,3), (120,3), (236,3), (3,156), (120,156), (236,156)]
        var r = 0, g = 0, b = 0
        for (x,y) in points {
            let i = (y * 240 + x) * 4
            r += Int(p[i]); g += Int(p[i + 1]); b += Int(p[i + 2])
        }
        let n = CGFloat(points.count * 255)
        return SKColor(red: CGFloat(r) / n, green: CGFloat(g) / n, blue: CGFloat(b) / n, alpha: 1)
    }

    // MARK: - UI detection / pixel access

    private func looksLikeHUD(_ image: CGImage) -> Bool {
        guard let pixels = framebufferPixels(image) else { return false }
        var dark = 0, bright = 0, samples = 0
        for y in 0..<38 {
            for x in stride(from: 0, to: 190, by: 2) {
                let i = (y * 240 + x) * 4
                let sum = Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2])
                if sum < 120 { dark += 1 }
                if sum > 620 { bright += 1 }
                samples += 1
            }
        }
        return Double(dark) / Double(max(samples, 1)) > 0.24 && bright > 18
    }

    private func dialogueRect(in image: CGImage) -> CGRect? {
        guard let pixels = framebufferPixels(image) else { return nil }
        var rows: [Int] = []
        for y in 42..<159 {
            var bright = 0, dark = 0
            for x in 4..<236 {
                let i = (y * 240 + x) * 4
                let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
                if r > 205 && g > 205 && b > 205 { bright += 1 }
                if r + g + b < 150 { dark += 1 }
            }
            if bright >= 110 && dark >= 20 { rows.append(y) }
        }

        for top in rows {
            if let bottom = rows.first(where: { $0 >= top + 16 && $0 <= top + 78 }) {
                let y = max(0, top - 2)
                return CGRect(x: 4, y: y, width: 232, height: min(160, bottom + 3) - y)
            }
        }
        return nil
    }

    private func framebufferPixels(_ image: CGImage) -> [UInt8]? {
        guard image.width == 240, image.height == 160,
              let provider = image.dataProvider,
              let data = provider.data,
              let bytes = CFDataGetBytePtr(data),
              CFDataGetLength(data) >= 240 * 160 * 4 else { return nil }
        var rgba = [UInt8](repeating: 0, count: 240 * 160 * 4)
        for pixel in 0..<(240 * 160) {
            let i = pixel * 4
            rgba[i] = bytes[i + 2]
            rgba[i + 1] = bytes[i + 1]
            rgba[i + 2] = bytes[i]
            rgba[i + 3] = 255
        }
        return rgba
    }

    private func rgbaPixels(_ image: CGImage) -> [UInt8]? {
        guard let provider = image.dataProvider,
              let data = provider.data,
              let bytes = CFDataGetBytePtr(data),
              CFDataGetLength(data) >= image.width * image.height * 4 else { return nil }
        return Array(UnsafeBufferPointer(start: bytes, count: image.width * image.height * 4))
    }

    private func installFailureWorld(message: String) {
        controlMode = .cinematic
        backgroundColor = .black
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
