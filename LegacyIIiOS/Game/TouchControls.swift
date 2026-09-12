import SwiftUI
import UIKit

struct TouchControls: View {
    let scene: PortGameScene

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            let bottom = max(12, geo.safeAreaInsets.bottom)

            ZStack(alignment: .topLeading) {
                dPad
                    .position(x: 78, y: height - bottom - 130)

                // Agreed phone layout: four semantic action buttons rather than
                // exposing GBA shoulder labels to the player.
                actionButton(icon: "hand.raised.fill", title: "ATTACK", diameter: 60) { scene.input.a = $0 }
                    .position(x: width - 118, y: height - bottom - 182)

                actionButton(icon: "sparkles", title: "KI BLAST", diameter: 60) { scene.input.b = $0 }
                    .position(x: width - 54, y: height - bottom - 226)

                actionButton(icon: "shield.fill", title: "BLOCK", diameter: 56) { scene.input.r = $0 }
                    .position(x: width - 124, y: height - bottom - 106)

                actionButton(icon: "bolt.fill", title: "TRANSFORM", diameter: 56) { scene.input.l = $0 }
                    .position(x: width - 56, y: height - bottom - 132)

                capsule("SELECT") { scene.input.select = $0 }
                    .position(x: width * 0.5 - 42, y: height - bottom - 24)

                capsule("START") { scene.input.start = $0 }
                    .position(x: width * 0.5 + 42, y: height - bottom - 24)
            }
            .frame(width: width, height: height)
        }
        .ignoresSafeArea(.all)
    }

    private var dPad: some View {
        ZStack {
            Circle()
                .fill(.black.opacity(0.25))
                .overlay(Circle().stroke(.white.opacity(0.22), lineWidth: 1))

            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(.black.opacity(0.25))
                .frame(width: 34, height: 104)

            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(.black.opacity(0.25))
                .frame(width: 104, height: 34)

            VStack {
                Image(systemName: "triangle.fill")
                Spacer()
                Image(systemName: "triangle.fill").rotationEffect(.degrees(180))
            }
            .padding(.vertical, 16)

            HStack {
                Image(systemName: "triangle.fill").rotationEffect(.degrees(-90))
                Spacer()
                Image(systemName: "triangle.fill").rotationEffect(.degrees(90))
            }
            .padding(.horizontal, 16)
        }
        .font(.system(size: 10, weight: .black))
        .foregroundStyle(.white.opacity(0.52))
        .frame(width: 124, height: 124)
        .padding(10)
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
        icon: String,
        title: String,
        diameter: CGFloat,
        changed: @escaping (Bool) -> Void
    ) -> some View {
        ZStack {
            Circle()
                .fill(.black.opacity(0.30))
                .overlay(Circle().stroke(.white.opacity(0.21), lineWidth: 1))

            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .bold))
                Text(title)
                    .font(.system(size: 6.4, weight: .black, design: .rounded))
                    .tracking(0.35)
            }
            .foregroundStyle(.white.opacity(0.64))
        }
        .frame(width: diameter, height: diameter)
        // The capture surface is substantially larger than the art. Touches fire
        // on touch-down immediately; no long or forceful press is required.
        .padding(12)
        .overlay { InstantHoldCapture(changed: changed) }
    }

    private func capsule(_ label: String, changed: @escaping (Bool) -> Void) -> some View {
        ZStack {
            Capsule()
                .fill(.black.opacity(0.23))
                .overlay(Capsule().stroke(.white.opacity(0.17), lineWidth: 1))
            Text(label)
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .tracking(0.8)
                .foregroundStyle(.white.opacity(0.42))
        }
        .frame(width: 66, height: 27)
        .padding(9)
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
        UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.12)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        // Keep the button held while a thumb naturally drifts inside its large cell.
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { finishPress() }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { finishPress() }

    private func finishPress() {
        guard pressed else { return }
        pressed = false
        let token = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.045) { [weak self] in
            guard let self, self.generation == token, !self.pressed else { return }
            self.changed(false)
        }
    }

    func cancelImmediately() {
        generation &+= 1
        pressed = false
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
        UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.10)
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
        let deadZone = min(bounds.width, bounds.height) * 0.09
        guard radius > deadZone else { release(); return }

        let angle = atan2(dy, dx)
        let horizontal = abs(cos(angle))
        let vertical = abs(sin(angle))
        let gate: CGFloat = 0.41
        changed(
            dy < 0 && vertical > gate,
            dy > 0 && vertical > gate,
            dx < 0 && horizontal > gate,
            dx > 0 && horizontal > gate
        )
    }

    func release() {
        changed(false, false, false, false)
    }
}
