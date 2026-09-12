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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea(.all)
                .background(.black)

            TouchControls(scene: scene)
                .ignoresSafeArea(.all)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.all)
        .background(.black)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
    }
}
