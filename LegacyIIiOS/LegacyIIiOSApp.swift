import SwiftUI
import UIKit

@main
struct LegacyIIiOSApp: App {
    var body: some Scene {
        WindowGroup {
            FullscreenRootController()
                .ignoresSafeArea(.all)
        }
    }
}

private struct FullscreenRootController: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        let controller = FullscreenHostingController(rootView: RootView())
        controller.view.backgroundColor = .black
        controller.modalPresentationCapturesStatusBarAppearance = true
        return controller
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        uiViewController.setNeedsStatusBarAppearanceUpdate()
        uiViewController.setNeedsUpdateOfHomeIndicatorAutoHidden()
        uiViewController.setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
    }
}

private final class FullscreenHostingController<Content: View>: UIHostingController<Content> {
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        setNeedsStatusBarAppearanceUpdate()
        setNeedsUpdateOfHomeIndicatorAutoHidden()
        setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
    }
}
