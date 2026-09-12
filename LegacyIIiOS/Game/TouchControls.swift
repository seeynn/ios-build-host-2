import SwiftUI
import UIKit

struct TouchControls: View {
    let scene: PortGameScene

    var body: some View {
        GeometryReader { geo in
            ZStack {
                HStack {
                    shoulder(label: "L") { scene.input.l = $0 }
                    Spacer()
                    shoulder(label: "R") { scene.input.r = $0 }
                }
                .padding(.horizontal, 12)
                .padding(.top, max(56, geo.safeAreaInsets.top + 42))
                .frame(maxHeight: .infinity, alignment: .top)

                VStack {
                    Spacer()
                    HStack(alignment: .bottom) {
                        dPad
                        Spacer()
                        actionCluster
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, max(78, geo.safeAreaInsets.bottom + 58))

                    HStack(spacing: 14) {
                        holdCapsule("SELECT") { scene.input.select = $0 }
                        holdCapsule("START") { scene.input.start = $0 }
                    }
                    .padding(.bottom, max(10, geo.safeAreaInsets.bottom + 4))
                }
            }
        }
        .ignoresSafeArea()
    }

    private var dPad: some View {
        ZStack {
            Circle()
                .fill(.black.opacity(0.22))
                .frame(width: 128, height: 128)
                .overlay(Circle().stroke(.white.opacity(0.12), lineWidth: 1))

            VStack(spacing: 4) {
                holdSquare("▲") { scene.input.up = $0 }
                HStack(spacing: 4) {
                    holdSquare("◀") { scene.input.left = $0 }
                    Color.clear.frame(width: 40, height: 40)
                    holdSquare("▶") { scene.input.right = $0 }
                }
                holdSquare("▼") { scene.input.down = $0 }
            }
        }
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
                .foregroundStyle(.white.opacity(pressed ? 0.72 : 0.30))
                .frame(width: 58, height: 34)
                .background(.black.opacity(pressed ? 0.38 : 0.20), in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(pressed ? 0.30 : 0.12), lineWidth: 1))
        }
    }

    private func holdSquare(_ symbol: String, changed: @escaping (Bool) -> Void) -> some View {
        HoldSurface(shape: AnyShape(RoundedRectangle(cornerRadius: 10)), changed: changed) { pressed in
            Text(symbol)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white.opacity(pressed ? 0.74 : 0.38))
                .frame(width: 40, height: 40)
                .background(.white.opacity(pressed ? 0.16 : 0.07), in: RoundedRectangle(cornerRadius: 10))
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
            .foregroundStyle(.white.opacity(pressed ? 0.78 : 0.42))
            .frame(width: 68, height: 68)
            .background(.black.opacity(pressed ? 0.42 : 0.26), in: Circle())
            .overlay(Circle().stroke(.white.opacity(pressed ? 0.34 : 0.15), lineWidth: 1))
        }
    }

    private func holdCapsule(_ label: String, changed: @escaping (Bool) -> Void) -> some View {
        HoldSurface(shape: AnyShape(Capsule()), changed: changed) { pressed in
            Text(label)
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .tracking(0.8)
                .foregroundStyle(.white.opacity(pressed ? 0.68 : 0.28))
                .frame(width: 62, height: 25)
                .background(.black.opacity(pressed ? 0.38 : 0.20), in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(pressed ? 0.28 : 0.10), lineWidth: 1))
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
