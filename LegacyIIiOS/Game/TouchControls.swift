import SwiftUI
import UIKit

struct TouchControls: View {
    let scene: PortGameScene

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            let bottom = max(20, geo.safeAreaInsets.bottom)

            ZStack(alignment: .topLeading) {
                dPad
                    .position(x: 76, y: height - bottom - 126)

                actionButton("A", subtitle: "ATTACK", diameter: 68) { scene.input.a = $0 }
                    .position(x: width - 128, y: height - bottom - 158)

                actionButton("B", subtitle: "KI", diameter: 64) { scene.input.b = $0 }
                    .position(x: width - 62, y: height - bottom - 210)

                actionButton("L", subtitle: nil, diameter: 56) { scene.input.l = $0 }
                    .position(x: width - 140, y: height - bottom - 86)

                actionButton("R", subtitle: nil, diameter: 56) { scene.input.r = $0 }
                    .position(x: width - 64, y: height - bottom - 104)

                capsule("SELECT") { scene.input.select = $0 }
                    .position(x: width * 0.5 - 42, y: height - bottom - 27)

                capsule("START") { scene.input.start = $0 }
                    .position(x: width * 0.5 + 42, y: height - bottom - 27)
            }
            .frame(width: width, height: height)
        }
        .ignoresSafeArea(.all)
    }

    private var dPad: some View {
        ZStack {
            Circle()
                .fill(.black.opacity(0.24))
                .overlay(Circle().stroke(.white.opacity(0.22), lineWidth: 1))

            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.black.opacity(0.24))
                .frame(width: 32, height: 98)

            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.black.opacity(0.24))
                .frame(width: 98, height: 32)

            VStack {
                Image(systemName: "triangle.fill")
                Spacer()
                Image(systemName: "triangle.fill").rotationEffect(.degrees(180))
            }
            .padding(.vertical, 15)

            HStack {
                Image(systemName: "triangle.fill").rotationEffect(.degrees(-90))
                Spacer()
                Image(systemName: "triangle.fill").rotationEffect(.degrees(90))
            }
            .padding(.horizontal, 15)
        }
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(.white.opacity(0.48))
        .frame(width: 118, height: 118)
        .overlay {
            DPadCapture { up, down, left, right in
                scene.input.up = up
                scene.input.down = down
                scene.input.left = left
                scene.input.right = right
            }
        }
    }

    private func actionButton(
        _ label: String,
        subtitle: String?,
        diameter: CGFloat,
        changed: @escaping (Bool) -> Void
    ) -> some View {
        ZStack {
            Circle()
                .fill(.black.opacity(0.28))
                .overlay(Circle().stroke(.white.opacity(0.22), lineWidth: 1))

            VStack(spacing: 1) {
                Text(label)
                    .font(.system(size: label.count == 1 ? 21 : 16, weight: .black, design: .rounded))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 7, weight: .bold, design: .rounded))
                        .tracking(0.6)
                }
            }
            .foregroundStyle(.white.opacity(0.58))
        }
        .frame(width: diameter, height: diameter)
        // The hit target is deliberately larger than the artwork. UIKit receives
        // touch-down immediately, so taps no longer need a long/firm press.
        .padding(9)
        .overlay { InstantHoldCapture(changed: changed) }
    }

    private func capsule(_ label: String, changed: @escaping (Bool) -> Void) -> some View {
        ZStack {
            Capsule()
                .fill(.black.opacity(0.24))
                .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 1))
            Text(label)
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .tracking(0.8)
                .foregroundStyle(.white.opacity(0.42))
        }
        .frame(width: 66, height: 28)
        .padding(7)
        .overlay { InstantHoldCapture(changed: changed) }
    }
}

private struct InstantHoldCapture: UIViewRepresentable {
    let changed: (Bool) -> Void

    func makeUIView(context: Context) -> HoldCaptureView {
        let view = HoldCaptureView()
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = false
        view.changed = changed
        return view
    }

    func updateUIView(_ uiView: HoldCaptureView, context: Context) {
        uiView.changed = changed
    }

    static func dismantleUIView(_ uiView: HoldCaptureView, coordinator: ()) {
        uiView.cancelImmediately()
    }
}

private final class HoldCaptureView: UIView {
    var changed: (Bool) -> Void = { _ in }
    private var pressed = false
    private var generation = 0

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        generation &+= 1
        guard !pressed else { return }
        pressed = true
        changed(true)
        UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.16)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        // Deliberately keep the button held while the thumb drifts. Mobile action
        // buttons should not drop input because the finger moved a few pixels.
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { finishPress() }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { finishPress() }

    private func finishPress() {
        guard pressed else { return }
        pressed = false
        let token = generation
        // Guarantee several 60 Hz game frames even for a very fast tap.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.055) { [weak self] in
            guard let self, self.generation == token, !self.pressed else { return }
            self.changed(false)
        }
    }

    func cancelImmediately() {
        generation &+= 1
        if pressed { pressed = false }
        changed(false)
    }
}

private struct DPadCapture: UIViewRepresentable {
    let changed: (_ up: Bool, _ down: Bool, _ left: Bool, _ right: Bool) -> Void

    func makeUIView(context: Context) -> DPadCaptureView {
        let view = DPadCaptureView()
        view.backgroundColor = .clear
        view.changed = changed
        return view
    }

    func updateUIView(_ uiView: DPadCaptureView, context: Context) {
        uiView.changed = changed
    }

    static func dismantleUIView(_ uiView: DPadCaptureView, coordinator: ()) {
        uiView.release()
    }
}

private final class DPadCaptureView: UIView {
    var changed: (Bool, Bool, Bool, Bool) -> Void = { _, _, _, _ in }
    private var activeTouch: UITouch?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard activeTouch == nil, let touch = touches.first else { return }
        activeTouch = touch
        update(touch.location(in: self))
        UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.12)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let activeTouch, touches.contains(activeTouch) else { return }
        update(activeTouch.location(in: self))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let activeTouch, touches.contains(activeTouch) else { return }
        self.activeTouch = nil
        release()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        self.activeTouch = nil
        release()
    }

    private func update(_ point: CGPoint) {
        let dx = point.x - bounds.midX
        let dy = point.y - bounds.midY
        let radius = hypot(dx, dy)
        let deadZone = min(bounds.width, bounds.height) * 0.13
        guard radius > deadZone else { release(); return }

        let angle = atan2(dy, dx)
        let horizontal = abs(cos(angle))
        let vertical = abs(sin(angle))
        let gate: CGFloat = 0.43
        let left = dx < 0 && horizontal > gate
        let right = dx > 0 && horizontal > gate
        let up = dy < 0 && vertical > gate
        let down = dy > 0 && vertical > gate
        changed(up, down, left, right)
    }

    func release() {
        changed(false, false, false, false)
    }
}
