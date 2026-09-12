import SwiftUI
import UIKit

struct TouchControls: View {
    let scene: PortGameScene
    @State private var dPadActive = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // L/R remain easy to hit but visually recess into the screen edges.
                HStack {
                    shoulder(label: "L") { scene.input.l = $0 }
                    Spacer()
                    shoulder(label: "R") { scene.input.r = $0 }
                }
                .padding(.horizontal, 10)
                .offset(y: geo.size.height * 0.34)

                VStack(spacing: 0) {
                    Spacer()

                    HStack(alignment: .bottom) {
                        dPad
                        Spacer(minLength: 28)
                        actionCluster
                    }
                    .padding(.horizontal, 18)

                    HStack(spacing: 12) {
                        holdCapsule("SELECT") { scene.input.select = $0 }
                        holdCapsule("START") { scene.input.start = $0 }
                    }
                    .padding(.top, 14)
                    .padding(.bottom, max(18, geo.safeAreaInsets.bottom + 8))
                }
            }
        }
        .ignoresSafeArea(.all)
    }

    private var dPad: some View {
        ZStack {
            Circle()
                .fill(.black.opacity(0.24))
                .overlay(Circle().stroke(.white.opacity(0.17), lineWidth: 0.8))

            Rectangle()
                .fill(.black.opacity(0.22))
                .frame(width: 30, height: 92)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            Rectangle()
                .fill(.black.opacity(0.22))
                .frame(width: 92, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack {
                Image(systemName: "triangle.fill")
                Spacer()
                Image(systemName: "triangle.fill")
                    .rotationEffect(.degrees(180))
            }
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white.opacity(0.46))
            .padding(.vertical, 15)

            HStack {
                Image(systemName: "triangle.fill")
                    .rotationEffect(.degrees(-90))
                Spacer()
                Image(systemName: "triangle.fill")
                    .rotationEffect(.degrees(90))
            }
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white.opacity(0.46))
            .padding(.horizontal, 15)
        }
        .frame(width: 112, height: 112)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    if !dPadActive {
                        dPadActive = true
                        UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.20)
                    }
                    updateDPad(at: value.location, size: 112)
                }
                .onEnded { _ in
                    dPadActive = false
                    clearDPad()
                }
        )
    }

    private func updateDPad(at location: CGPoint, size: CGFloat) {
        let center = size * 0.5
        let dx = location.x - center
        let dy = location.y - center
        let radius = sqrt(dx * dx + dy * dy)
        let deadZone: CGFloat = 11

        guard radius > deadZone else {
            clearDPad()
            return
        }

        // Use a slightly wider diagonal gate than the old independent-axis test.
        // This prevents accidental diagonal movement when a thumb is only a few
        // pixels off the intended cardinal direction.
        let angle = atan2(dy, dx)
        let horizontal = abs(cos(angle))
        let vertical = abs(sin(angle))
        let diagonalThreshold: CGFloat = 0.46

        scene.input.left = dx < 0 && horizontal > diagonalThreshold
        scene.input.right = dx > 0 && horizontal > diagonalThreshold
        scene.input.up = dy < 0 && vertical > diagonalThreshold
        scene.input.down = dy > 0 && vertical > diagonalThreshold
    }

    private func clearDPad() {
        scene.input.left = false
        scene.input.right = false
        scene.input.up = false
        scene.input.down = false
    }

    private var actionCluster: some View {
        HStack(spacing: 10) {
            holdCircle("B", subtitle: "KI") { scene.input.b = $0 }
                .offset(y: 10)
            holdCircle("A", subtitle: "ATTACK") { scene.input.a = $0 }
                .offset(y: -8)
        }
    }

    private func shoulder(label: String, changed: @escaping (Bool) -> Void) -> some View {
        HoldSurface(shape: AnyShape(Capsule()), changed: changed) { pressed in
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(pressed ? 0.76 : 0.30))
                .frame(width: 70, height: 30)
                .background(.black.opacity(pressed ? 0.34 : 0.16), in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(pressed ? 0.30 : 0.10), lineWidth: 0.8))
        }
    }

    private func holdCircle(_ label: String, subtitle: String, changed: @escaping (Bool) -> Void) -> some View {
        HoldSurface(shape: AnyShape(Circle()), changed: changed) { pressed in
            VStack(spacing: 1) {
                Text(label)
                    .font(.system(size: 19, weight: .black, design: .rounded))
                Text(subtitle)
                    .font(.system(size: 6.5, weight: .bold, design: .rounded))
                    .tracking(0.5)
            }
            .foregroundStyle(.white.opacity(pressed ? 0.84 : 0.46))
            .frame(width: 60, height: 60)
            .background(.black.opacity(pressed ? 0.40 : 0.23), in: Circle())
            .overlay(Circle().stroke(.white.opacity(pressed ? 0.34 : 0.14), lineWidth: 0.8))
        }
    }

    private func holdCapsule(_ label: String, changed: @escaping (Bool) -> Void) -> some View {
        HoldSurface(shape: AnyShape(Capsule()), changed: changed) { pressed in
            Text(label)
                .font(.system(size: 7.5, weight: .bold, design: .rounded))
                .tracking(0.7)
                .foregroundStyle(.white.opacity(pressed ? 0.70 : 0.30))
                .frame(width: 58, height: 24)
                .background(.black.opacity(pressed ? 0.35 : 0.16), in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(pressed ? 0.28 : 0.10), lineWidth: 0.8))
        }
    }
}

private struct HoldSurface<Content: View>: View {
    let shape: AnyShape
    let changed: (Bool) -> Void
    @ViewBuilder var content: (Bool) -> Content
    @State private var pressed = false

    var body: some View {
        content(pressed)
            .contentShape(shape)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !pressed else { return }
                        pressed = true
                        changed(true)
                        UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.22)
                    }
                    .onEnded { _ in
                        pressed = false
                        changed(false)
                    }
            )
            .onDisappear {
                if pressed {
                    pressed = false
                    changed(false)
                }
            }
    }
}

private struct AnyShape: Shape {
    private let pathBuilder: (CGRect) -> Path

    init<S: Shape>(_ shape: S) {
        pathBuilder = { rect in shape.path(in: rect) }
    }

    func path(in rect: CGRect) -> Path { pathBuilder(rect) }
}
