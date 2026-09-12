import SpriteKit
import SwiftUI
import UIKit

struct GameContainerView: View {
    @State private var scene: PortGameScene

    init(library: ROMLibrary) {
        let romURL = library.installedROMURL ?? library.romDestinationURL
        _scene = State(initialValue: PortGameScene(
            size: CGSize(width: PortraitCamera.logicalWidth, height: PortraitCamera.logicalHeight),
            romURL: romURL,
            saveURL: library.saveURL
        ))
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                NativeSKView(scene: scene)
                    .frame(width: proxy.size.width, height: proxy.size.height)

                TouchControls(scene: scene)
                    .frame(width: proxy.size.width, height: proxy.size.height)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .ignoresSafeArea(.all)
        .background(Color.black.ignoresSafeArea(.all))
    }
}

private struct NativeSKView: UIViewRepresentable {
    let scene: PortGameScene

    func makeUIView(context: Context) -> SKView {
        let view = SKView(frame: .zero)
        view.backgroundColor = .black
        view.isOpaque = true
        view.isMultipleTouchEnabled = true
        view.ignoresSiblingOrder = true
        view.contentMode = .scaleAspectFill
        scene.scaleMode = .aspectFill
        view.presentScene(scene)
        return view
    }

    func updateUIView(_ uiView: SKView, context: Context) {
        if uiView.scene !== scene {
            uiView.presentScene(scene)
        }
    }
}
