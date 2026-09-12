import Foundation
import SpriteKit

final class PortGameScene: SKScene {
    private let romURL: URL
    private let saveURL: URL
    private let backgroundNode = SKSpriteNode()
    private let actorLayer = SKNode()
    private var runtime: NativeBridgeRuntime?
    private var frameCounter = 0
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
        view.ignoresSiblingOrder = true
        view.isMultipleTouchEnabled = true

        backgroundNode.anchorPoint = CGPoint(x: 0, y: 0)
        backgroundNode.position = .zero
        backgroundNode.size = CGSize(width: 240, height: portraitHeight)
        backgroundNode.zPosition = -1000
        addChild(backgroundNode)

        actorLayer.zPosition = 0
        addChild(actorLayer)

        do {
            let bridge = try NativeBridgeRuntime()
            try bridge.start(romURL: romURL, saveURL: saveURL)
            runtime = bridge
        } catch {
            installFailureWorld(message: error.localizedDescription)
        }
    }

    override func update(_ currentTime: TimeInterval) {
        guard let runtime else { return }
        runtime.runFrame(input: input)
        frameCounter &+= 1

        // Rebuild the extended live tilemap at 30 Hz; input/game logic stays at 60 Hz.
        if frameCounter == 1 || frameCounter % 2 == 0 {
            refreshBackground(runtime)
            refreshActors(runtime)
        }
    }

    private func refreshBackground(_ runtime: NativeBridgeRuntime) {
        guard let image = runtime.portraitBackgroundImage(height: portraitHeight) else { return }
        let texture = SKTexture(cgImage: image)
        texture.filteringMode = .nearest
        backgroundNode.texture = texture
    }

    private func refreshActors(_ runtime: NativeBridgeRuntime) {
        actorLayer.removeAllChildren()

        for sprite in runtime.spriteFrames() {
            // Skip the original top-of-GBA HUD objects. Native HUD work can be layered
            // at the true top of the portrait screen without pinning gameplay to 240x160.
            if sprite.screenY >= 0 && sprite.screenY < 38 { continue }

            let targetTopY = sprite.screenY + verticalExtension
            let centerX = CGFloat(sprite.screenX) + CGFloat(sprite.width) * 0.5
            let centerYFromTop = CGFloat(targetTopY) + CGFloat(sprite.height) * 0.5
            let spriteKitY = CGFloat(portraitHeight) - centerYFromTop

            let texture = SKTexture(cgImage: sprite.image)
            texture.filteringMode = .nearest
            let node = SKSpriteNode(texture: texture, size: CGSize(width: sprite.width, height: sprite.height))
            node.position = CGPoint(x: centerX, y: spriteKitY)
            node.zPosition = CGFloat(100 - sprite.priority)
            actorLayer.addChild(node)
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
