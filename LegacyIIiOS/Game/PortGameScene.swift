import CoreGraphics
import Foundation
import SpriteKit

final class PortGameScene: SKScene {
    private let romURL: URL
    private let saveURL: URL
    private let worldNode = SKNode()
    private let actorLayer = SKNode()
    private let cameraNode = SKCameraNode()
    private var fieldNode: SKSpriteNode?
    private var runtime: NativeBridgeRuntime?
    private var decodedScene: ALFPSceneData.IndexedScene?
    private var portraitCamera = PortraitCamera(centerX: 120, centerY: 260, worldBounds: IntRect(x: 0, y: 0, width: 1024, height: 1024))
    private var playerPosition = CGPoint(x: 454, y: 479)
    private var paletteFingerprint: UInt64 = 0
    private var frameCounter = 0

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

        addChild(worldNode)
        worldNode.addChild(actorLayer)
        addChild(cameraNode)
        camera = cameraNode

        do {
            let data = try Data(contentsOf: romURL, options: .mappedIfSafe)
            let rom = try ROMImage(data: data)
            let scene = try ALFPSceneData.decodeFirstScene(in: rom)
            decodedScene = scene
            installField(scene, palette: nil)

            playerPosition = CGPoint(x: scene.spawnX, y: scene.height - scene.spawnY)
            portraitCamera.worldBounds = IntRect(x: 0, y: 0, width: scene.width, height: scene.height)
            portraitCamera.follow(x: playerPosition.x, y: playerPosition.y)
            cameraNode.position = CGPoint(x: portraitCamera.centerX, y: portraitCamera.centerY)

            let bridge = try NativeBridgeRuntime()
            try bridge.start(romURL: romURL, saveURL: saveURL)
            runtime = bridge
        } catch {
            installFailureWorld(message: error.localizedDescription)
        }
    }

    private func installField(_ scene: ALFPSceneData.IndexedScene, palette: [UInt8]?) {
        guard let image = makeFieldImage(scene, palette: palette) else { return }
        let texture = SKTexture(cgImage: image)
        texture.filteringMode = .nearest

        if let fieldNode {
            fieldNode.texture = texture
            return
        }

        let field = SKSpriteNode(texture: texture, size: CGSize(width: scene.width, height: scene.height))
        field.anchorPoint = CGPoint(x: 0, y: 0)
        field.position = .zero
        field.zPosition = -100
        worldNode.addChild(field)
        fieldNode = field
    }

    private func refreshPaletteIfNeeded() {
        guard let runtime, let scene = decodedScene else { return }
        let palette = runtime.backgroundPaletteRGBA()
        var fingerprint: UInt64 = 1469598103934665603
        for byte in palette {
            fingerprint ^= UInt64(byte)
            fingerprint &*= 1099511628211
        }
        guard fingerprint != paletteFingerprint else { return }
        paletteFingerprint = fingerprint
        installField(scene, palette: palette)
    }

    private func refreshActors() {
        guard let runtime else { return }
        actorLayer.removeAllChildren()

        for sprite in runtime.spriteFrames() {
            // Top-screen OAM in the original 240x160 view is primarily the HUD.
            // Keep the original field actors, but don't paint the old HUD into the world.
            if sprite.screenY < 38 { continue }

            let screenCenterX = CGFloat(sprite.screenX) + CGFloat(sprite.width) * 0.5
            let screenCenterY = CGFloat(sprite.screenY) + CGFloat(sprite.height) * 0.5
            let worldX = playerPosition.x + (screenCenterX - 120)
            let worldY = playerPosition.y - (screenCenterY - 80)

            let texture = SKTexture(cgImage: sprite.image)
            texture.filteringMode = .nearest
            let node = SKSpriteNode(texture: texture, size: CGSize(width: sprite.width, height: sprite.height))
            node.position = CGPoint(x: worldX, y: worldY)
            node.zPosition = 1000 - worldY + CGFloat(3 - sprite.priority) * 0.01
            actorLayer.addChild(node)
        }
    }

    private func makeFieldImage(_ scene: ALFPSceneData.IndexedScene, palette: [UInt8]?) -> CGImage? {
        var rgba = [UInt8](repeating: 0, count: scene.width * scene.height * 4)
        for (pixelIndex, sourceIndex) in scene.pixels.enumerated() {
            let out = pixelIndex * 4
            if let palette, palette.count >= 1024 {
                let source = Int(sourceIndex) * 4
                rgba[out] = palette[source]
                rgba[out + 1] = palette[source + 1]
                rgba[out + 2] = palette[source + 2]
                rgba[out + 3] = 255
            } else {
                let luminance = UInt8(16 + (Int(sourceIndex) * 239 / 255))
                rgba[out] = luminance
                rgba[out + 1] = luminance
                rgba[out + 2] = luminance
                rgba[out + 3] = 255
            }
        }

        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(
            width: scene.width,
            height: scene.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: scene.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    private func collisionMarked(worldX: CGFloat, spriteKitY: CGFloat, in scene: ALFPSceneData.IndexedScene) -> Bool {
        let x = Int(floor(worldX))
        let topDownY = scene.height - 1 - Int(floor(spriteKitY))
        guard x >= 0, x < scene.width, topDownY >= 0, topDownY < scene.height else { return true }
        return scene.attributeB[topDownY * scene.width + x] != 0
    }

    private func canOccupy(_ position: CGPoint, in scene: ALFPSceneData.IndexedScene) -> Bool {
        let probes = [
            CGPoint(x: -4, y: -7), CGPoint(x: 0, y: -7), CGPoint(x: 4, y: -7),
            CGPoint(x: -3, y: -4), CGPoint(x: 3, y: -4)
        ]
        return !probes.contains { probe in
            collisionMarked(worldX: position.x + probe.x, spriteKitY: position.y + probe.y, in: scene)
        }
    }

    override func update(_ currentTime: TimeInterval) {
        guard let scene = decodedScene else { return }
        runtime?.runFrame(input: input)
        frameCounter &+= 1

        if frameCounter == 2 || frameCounter % 60 == 0 { refreshPaletteIfNeeded() }
        if frameCounter % 2 == 0 { refreshActors() }

        // Native portrait movement keeps the tall camera independent from the original
        // 240x160 framebuffer. The hidden core receives the exact same input in parallel.
        let speed: CGFloat = 1.8
        var dx: CGFloat = 0
        var dy: CGFloat = 0
        if input.left { dx -= speed }
        if input.right { dx += speed }
        if input.up { dy += speed }
        if input.down { dy -= speed }
        if dx != 0 && dy != 0 { dx *= 0.70710678; dy *= 0.70710678 }

        if dx != 0 {
            var proposed = playerPosition
            proposed.x = min(max(proposed.x + dx, 6), CGFloat(scene.width) - 6)
            if canOccupy(proposed, in: scene) { playerPosition.x = proposed.x }
        }
        if dy != 0 {
            var proposed = playerPosition
            proposed.y = min(max(proposed.y + dy, 8), CGFloat(scene.height) - 8)
            if canOccupy(proposed, in: scene) { playerPosition.y = proposed.y }
        }

        portraitCamera.follow(x: playerPosition.x, y: playerPosition.y)
        cameraNode.position = CGPoint(x: portraitCamera.centerX, y: portraitCamera.centerY)
    }

    private func installFailureWorld(message: String) {
        let label = SKLabelNode(text: "Native portrait renderer failed")
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
        cameraNode.position = CGPoint(x: 120, y: 260)
    }
}
