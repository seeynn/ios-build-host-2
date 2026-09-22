import Combine
import Foundation
import SpriteKit

final class PortGameScene: SKScene, ObservableObject {
    enum ControlMode {
        case gameplay
        case menu
        case cinematic
    }
    private let romURL: URL
    private let saveURL: URL
    private let backgroundNode = SKSpriteNode()
    private let actorLayer = SKNode()
    private let hudLayer = SKNode()
    private var runtime: NativeBridgeRuntime?
    private var frameCounter = 0
    private let portraitHeight = 520
    private let verticalExtension = 180

    var input = InputState()
    @Published private(set) var controlMode: ControlMode = .menu

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
        backgroundNode.size = CGSize(width: 240, height: CGFloat(portraitHeight))
        backgroundNode.zPosition = -1000
        addChild(backgroundNode)
        actorLayer.zPosition = 0
        addChild(actorLayer)
        hudLayer.zPosition = 5000
        addChild(hudLayer)
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
        let nextMode: ControlMode = runtime.isFieldGameplay() ? .gameplay : .menu
        if nextMode != controlMode { controlMode = nextMode }
        frameCounter &+= 1
        if frameCounter == 1 || frameCounter % 2 == 0 { refreshPresentation(runtime) }
    }

    private func refreshPresentation(_ runtime: NativeBridgeRuntime) {
        guard let image = runtime.portraitBackgroundImage(height: portraitHeight) else { return }
        let texture = SKTexture(cgImage: image)
        texture.filteringMode = .nearest
        backgroundNode.texture = texture
        guard runtime.isFieldGameplay() else {
            actorLayer.removeAllChildren()
            hudLayer.removeAllChildren()
            return
        }
        refreshFieldSprites(runtime)
    }

    private func refreshFieldSprites(_ runtime: NativeBridgeRuntime) {
        actorLayer.removeAllChildren()
        hudLayer.removeAllChildren()
        let liveSprites = runtime.spriteFrames()
        for sprite in liveSprites {
            let texture = SKTexture(cgImage: sprite.image)
            texture.filteringMode = .nearest
            let node = SKSpriteNode(texture: texture, size: CGSize(width: CGFloat(sprite.width), height: CGFloat(sprite.height)))
            let centerX = CGFloat(sprite.screenX) + CGFloat(sprite.width) * 0.5
            let targetTopY = sprite.isHUD ? sprite.screenY : sprite.screenY + verticalExtension
            let centerYFromTop = CGFloat(targetTopY) + CGFloat(sprite.height) * 0.5
            node.position = CGPoint(x: centerX, y: CGFloat(portraitHeight) - centerYFromTop)
            if sprite.isHUD {
                node.zPosition = CGFloat(1000 - sprite.oamIndex)
                hudLayer.addChild(node)
            } else {
                node.zPosition = CGFloat(100 - sprite.priority)
                actorLayer.addChild(node)
            }
        }
        let expanded = runtime.expandedFieldActorFrames(liveSprites: liveSprites, portraitHeight: portraitHeight)
        for actor in expanded {
            let texture = SKTexture(cgImage: actor.image)
            texture.filteringMode = .nearest
            let node = SKSpriteNode(texture: texture, size: CGSize(width: CGFloat(actor.width), height: CGFloat(actor.height)))
            let targetTopY = actor.screenY + verticalExtension
            let centerX = CGFloat(actor.screenX) + CGFloat(actor.width) * 0.5
            let centerYFromTop = CGFloat(targetTopY) + CGFloat(actor.height) * 0.5
            node.position = CGPoint(x: centerX, y: CGFloat(portraitHeight) - centerYFromTop)
            node.zPosition = 40 + CGFloat(actor.screenY) * 0.001
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
