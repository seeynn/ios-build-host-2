import SpriteKit
import SwiftUI

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
        ZStack {
            SpriteView(scene: scene, options: [.ignoresSiblingOrder])
                .ignoresSafeArea()
                .background(.black)
            TouchControls(scene: scene)
        }
        .background(.black)
        .persistentSystemOverlays(.hidden)
    }
}
