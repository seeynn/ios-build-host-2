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

    private var runtime: NativeBridgeRuntime?
    private var frameCounter = 0

    private let portraitHeight = 520
    private let originalViewportHeight = 160
    private let hudHeight = 40
    private let dialogueHeight = 72

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

        backgroundNode.anchorPoint = CGPoint(x: 0, y: 0)
        backgroundNode.position = .zero
        backgroundNode.size = CGSize(width: 240, height: portraitHeight)
        backgroundNode.zPosition = -1000
        addChild(backgroundNode)

        actorLayer.zPosition = 100
        addChild(actorLayer)

        hudNode.anchorPoint = CGPoint(x: 0, y: 0)
        hudNode.position = CGPoint(x: 0, y: portraitHeight - hudHeight)
        hudNode.size = CGSize(width: 240, height: hudHeight)
        hudNode.zPosition = 5000
        hudNode.isHidden = true
        addChild(hudNode)

        dialogueNode.anchorPoint = CGPoint(x: 0, y: 0)
        dialogueNode.position = CGPoint(x: 0, y: 82)
        dialogueNode.size = CGSize(width: 240, height: dialogueHeight)
        dialogueNode.zPosition = 5100
        dialogueNode.isHidden = true
        addChild(dialogueNode)

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

        // Cartridge timing and input remain 60 Hz. Rebuild the heavier native
        // portrait presentation at 30 Hz so gameplay timing is never slowed down.
        if frameCounter == 1 || frameCounter % 2 == 0 {
            refreshPresentation(runtime)
        }
    }

    private func refreshPresentation(_ runtime: NativeBridgeRuntime) {
        if let source = runtime.portraitBackgroundImage(height: portraitHeight),
           let repaired = repairPortraitBackground(source) {
            let texture = SKTexture(cgImage: repaired)
            texture.filteringMode = .nearest
            backgroundNode.texture = texture
        }

        refreshActors(runtime)
        refreshOriginalUI(runtime)
    }

    /// The original engine streams a rolling tilemap around a 240x160 hardware
    /// viewport. The extra portrait rows can temporarily expose unpopulated rows.
    /// Replace only those empty rows with the nearest valid authored row instead of
    /// exposing full-width black bands to the player.
    private func repairPortraitBackground(_ image: CGImage) -> CGImage? {
        guard image.width == 240,
              image.height == portraitHeight,
              let providerData = image.dataProvider?.data,
              let source = CFDataGetBytePtr(providerData) else {
            return image
        }

        let width = image.width
        let height = image.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var rgba = [UInt8](repeating: 0, count: bytesPerRow * height)
        let byteCount = rgba.count
        rgba.withUnsafeMutableBytes { destination in
            destination.copyBytes(from: UnsafeRawBufferPointer(start: source, count: byteCount))
        }

        let centerStart = verticalExtension
        let centerEnd = centerStart + originalViewportHeight

        func rowLooksEmpty(_ y: Int) -> Bool {
            let row = y * bytesPerRow
            var dark = 0
            var nearFirst = 0
            let r0 = Int(rgba[row])
            let g0 = Int(rgba[row + 1])
            let b0 = Int(rgba[row + 2])

            for x in 0..<width {
                let offset = row + x * 4
                let r = Int(rgba[offset])
                let g = Int(rgba[offset + 1])
                let b = Int(rgba[offset + 2])
                if r + g + b < 30 { dark += 1 }
                if abs(r - r0) + abs(g - g0) + abs(b - b0) < 8 { nearFirst += 1 }
            }

            return dark > Int(Double(width) * 0.72) || nearFirst > Int(Double(width) * 0.95)
        }

        func copyRow(from sourceY: Int, to destinationY: Int) {
            let sourceStart = sourceY * bytesPerRow
            let destinationStart = destinationY * bytesPerRow
            let rowCopy = Array(rgba[sourceStart..<(sourceStart + bytesPerRow)])
            rgba.replaceSubrange(
                destinationStart..<(destinationStart + bytesPerRow),
                with: rowCopy
            )
        }

        // Repair upwards from the known-live hardware viewport.
        if centerStart > 0 {
            for y in stride(from: centerStart - 1, through: 0, by: -1) {
                if rowLooksEmpty(y) { copyRow(from: y + 1, to: y) }
            }
        }

        // Repair downwards from the known-live hardware viewport.
        if centerEnd < height {
            for y in centerEnd..<height {
                if rowLooksEmpty(y) { copyRow(from: y - 1, to: y) }
            }
        }

        return makeRGBAImage(rgba, width: width, height: height)
    }

    private func refreshActors(_ runtime: NativeBridgeRuntime) {
        actorLayer.removeAllChildren()

        for sprite in runtime.spriteFrames() {
            // The original HUD uses OAM at the top of the 160px hardware viewport.
            // Suppress only those HUD objects; keep the player/NPC/enemy OAM visible.
            if sprite.screenY >= 0 && sprite.screenY < 38 { continue }

            let targetTopY = sprite.screenY + verticalExtension
            let centerX = CGFloat(sprite.screenX) + CGFloat(sprite.width) * 0.5
            let centerYFromTop = CGFloat(targetTopY) + CGFloat(sprite.height) * 0.5
            let spriteKitY = CGFloat(portraitHeight) - centerYFromTop

            if centerYFromTop + CGFloat(sprite.height) < 0 || centerYFromTop > CGFloat(portraitHeight) {
                continue
            }

            let texture = SKTexture(cgImage: sprite.image)
            texture.filteringMode = .nearest
            let node = SKSpriteNode(texture: texture, size: CGSize(width: sprite.width, height: sprite.height))
            node.position = CGPoint(x: centerX, y: spriteKitY)
            node.zPosition = CGFloat(100 - sprite.priority)
            actorLayer.addChild(node)
        }
    }

    /// Restore cartridge-native UI/text on top of the native tall world. The old
    /// emulator viewport never becomes visible: only the UI strips are cropped.
    private func refreshOriginalUI(_ runtime: NativeBridgeRuntime) {
        guard let frame = runtime.framebufferImage() else { return }

        if let hud = crop(frame, x: 0, y: 0, width: 240, height: hudHeight) {
            let texture = SKTexture(cgImage: hud)
            texture.filteringMode = .nearest
            hudNode.texture = texture
            hudNode.isHidden = false
        }

        let showDialogue = looksLikeDialogue(frame)
        dialogueNode.isHidden = !showDialogue
        if showDialogue,
           let dialogue = crop(
                frame,
                x: 0,
                y: originalViewportHeight - dialogueHeight,
                width: 240,
                height: dialogueHeight
           ) {
            let texture = SKTexture(cgImage: dialogue)
            texture.filteringMode = .nearest
            dialogueNode.texture = texture
        }
    }

    private func looksLikeDialogue(_ image: CGImage) -> Bool {
        guard let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data),
              image.width == 240,
              image.height == originalViewportHeight else { return false }

        let startY = originalViewportHeight - dialogueHeight
        let rowBytes = image.bytesPerRow
        let pixelStride = max(4, image.bitsPerPixel / 8)
        var dark = 0
        var bright = 0
        var samples = 0

        for y in startY..<originalViewportHeight {
            for x in stride(from: 0, to: 240, by: 2) {
                let offset = y * rowBytes + x * pixelStride
                let c0 = Int(bytes[offset])
                let c1 = Int(bytes[offset + 1])
                let c2 = Int(bytes[offset + 2])
                let sum = c0 + c1 + c2
                if sum < 120 { dark += 1 }
                if sum > 650 { bright += 1 }
                samples += 1
            }
        }

        let darkRatio = Double(dark) / Double(max(samples, 1))
        let brightRatio = Double(bright) / Double(max(samples, 1))
        return darkRatio > 0.28 && brightRatio > 0.015
    }

    private func crop(_ image: CGImage, x: Int, y: Int, width: Int, height: Int) -> CGImage? {
        image.cropping(to: CGRect(x: x, y: y, width: width, height: height))
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
