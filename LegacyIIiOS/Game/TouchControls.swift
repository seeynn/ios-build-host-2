import SwiftUI
import UIKit

struct TouchControls: View {
    let scene: PortGameScene
    @State private var dPadActive = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                HStack {
                    shoulder(label: "L") { scene.input.l = $0 }
                    Spacer()
                    shoulder(label: "R") { scene.input.r = $0 }
                }
                .padding(.horizontal, 12)
                .padding(.top, max(24, geo.safeAreaInsets.top + 8))
                .frame(maxHeight: .infinity, alignment: .top)

                VStack {
                    Spacer()
                    HStack(alignment: .bottom) {
                        dPad
                        Spacer()
                        actionCluster
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, max(74, geo.safeAreaInsets.bottom + 48))

                    HStack(spacing: 14) {
                        holdCapsule("SELECT") { scene.input.select = $0 }
                        holdCapsule("START") { scene.input.start = $0 }
                    }
                    .padding(.bottom, max(8, geo.safeAreaInsets.bottom + 2))
                }
            }
        }
        .ignoresSafeArea(.all)
    }

    private var dPad: some View {
        ZStack {
            Circle()
                .fill(.black.opacity(0.24))
                .overlay(Circle().stroke(.white.opacity(0.16), lineWidth: 1))

            Rectangle()
                .fill(.white.opacity(0.055))
                .frame(width: 34, height: 108)
                .clipShape(RoundedRectangle(cornerRadius: 10))

            Rectangle()
                .fill(.white.opacity(0.055))
                .frame(width: 108, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack {
                Text("▲")
                Spacer()
                Text("▼")
            }
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(.white.opacity(0.38))
            .padding(.vertical, 17)

            HStack {
                Text("◀")
                Spacer()
                Text("▶")
            }
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(.white.opacity(0.38))
            .padding(.horizontal, 17)
        }
        .frame(width: 132, height: 132)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if !dPadActive {
                        dPadActive = true
                        UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.24)
                    }
                    updateDPad(at: value.location, size: 132)
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
        let deadZone: CGFloat = 12

        scene.input.left = dx < -deadZone
        scene.input.right = dx > deadZone
        scene.input.up = dy < -deadZone
        scene.input.down = dy > deadZone
    }

    private func clearDPad() {
        scene.input.left = false
        scene.input.right = false
        scene.input.up = false
        scene.input.down = false
    }

    private var actionCluster: some View {
        HStack(spacing: 12) {
            holdCircle("B", subtitle: "KI") { scene.input.b = $0 }
                .offset(y: 12)
            holdCircle("A", subtitle: "ATTACK") { scene.input.a = $0 }
                .offset(y: -10)
        }
    }

    private func shoulder(label: String, changed: @escaping (Bool) -> Void) -> some View {
        HoldSurface(shape: AnyShape(RoundedRectangle(cornerRadius: 18)), changed: changed) { pressed in
            Text(label)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(pressed ? 0.78 : 0.34))
                .frame(width: 64, height: 36)
                .background(.black.opacity(pressed ? 0.40 : 0.22), in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(pressed ? 0.34 : 0.14), lineWidth: 1))
        }
    }

    private func holdCircle(_ label: String, subtitle: String, changed: @escaping (Bool) -> Void) -> some View {
        HoldSurface(shape: AnyShape(Circle()), changed: changed) { pressed in
            VStack(spacing: 1) {
                Text(label)
                    .font(.system(size: 21, weight: .black, design: .rounded))
                Text(subtitle)
                    .font(.system(size: 7, weight: .bold, design: .rounded))
                    .tracking(0.6)
            }
            .foregroundStyle(.white.opacity(pressed ? 0.82 : 0.46))
            .frame(width: 70, height: 70)
            .background(.black.opacity(pressed ? 0.44 : 0.28), in: Circle())
            .overlay(Circle().stroke(.white.opacity(pressed ? 0.36 : 0.16), lineWidth: 1))
        }
    }

    private func holdCapsule(_ label: String, changed: @escaping (Bool) -> Void) -> some View {
        HoldSurface(shape: AnyShape(Capsule()), changed: changed) { pressed in
            Text(label)
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .tracking(0.8)
                .foregroundStyle(.white.opacity(pressed ? 0.72 : 0.32))
                .frame(width: 64, height: 27)
                .background(.black.opacity(pressed ? 0.40 : 0.22), in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(pressed ? 0.30 : 0.12), lineWidth: 1))
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
                        UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.28)
                    }
                    .onEnded { _ in
                        pressed = false
                        changed(false)
                    }
            )
    }
}

private struct AnyShape: Shape {
    private let pathBuilder: (CGRect) -> Path

    init<S: Shape>(_ shape: S) {
        pathBuilder = { rect in shape.path(in: rect) }
    }

    func path(in rect: CGRect) -> Path { pathBuilder(rect) }
}
