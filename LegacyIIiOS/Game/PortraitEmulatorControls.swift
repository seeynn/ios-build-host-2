import SwiftUI
import UIKit

struct PortraitEmulatorControls: View {
    let emulator: CompatibilityEmulator

    var body: some View {
        GeometryReader { geo in
            ZStack {
                HStack(spacing: 0) {
                    EdgeHoldZone(label: "L", alignment: .leading, onChanged: emulator.setL)
                    Spacer(minLength: 0)
                    EdgeHoldZone(label: "R", alignment: .trailing, onChanged: emulator.setR)
                }
                .padding(.horizontal, 5)
                .padding(.top, 4)
                .frame(maxHeight: 150)

                VStack(spacing: 0) {
                    Spacer()
                    HStack(alignment: .center, spacing: 18) {
                        dPad
                        Spacer(minLength: 12)
                        HStack(alignment: .center, spacing: 16) {
                            HoldRoundButton(label: "B", size: 72, onChanged: emulator.setB).offset(y: 14)
                            HoldRoundButton(label: "A", size: 78, onChanged: emulator.setA).offset(y: -14)
                        }
                    }
                    .padding(.horizontal, 22)

                    HStack(spacing: 14) {
                        HoldCapsule(label: "SELECT", width: 62, onChanged: emulator.setSelect)
                        HoldCapsule(label: "START", width: 62, onChanged: emulator.setStart)
                    }
                    .padding(.top, 18)
                    .padding(.bottom, max(18, geo.safeAreaInsets.bottom + 6))
                }
            }
        }
    }

    private var dPad: some View {
        VStack(spacing: 3) {
            HoldPadButton(symbol: "▲", onChanged: emulator.setUp)
            HStack(spacing: 3) {
                HoldPadButton(symbol: "◀", onChanged: emulator.setLeft)
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.white.opacity(0.025)).frame(width: 54, height: 54)
                HoldPadButton(symbol: "▶", onChanged: emulator.setRight)
            }
            HoldPadButton(symbol: "▼", onChanged: emulator.setDown)
        }
    }
}

private struct HoldPadButton: View {
    let symbol: String
    let onChanged: (Bool) -> Void
    @State private var held = false
    var body: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(.white.opacity(held ? 0.15 : 0.045))
            .overlay { RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(held ? 0.26 : 0.08), lineWidth: 1) }
            .overlay { Text(symbol).font(.system(size: 17, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(held ? 0.68 : 0.28)) }
            .frame(width: 54, height: 54)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in guard !held else { return }; held = true; onChanged(true); UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.35) }
                .onEnded { _ in held = false; onChanged(false) })
    }
}

private struct HoldRoundButton: View {
    let label: String
    let size: CGFloat
    let onChanged: (Bool) -> Void
    @State private var held = false
    var body: some View {
        Circle()
            .fill(.white.opacity(held ? 0.16 : 0.055))
            .overlay { Circle().stroke(.white.opacity(held ? 0.28 : 0.10), lineWidth: 1) }
            .overlay { Text(label).font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(.white.opacity(held ? 0.70 : 0.30)) }
            .frame(width: size, height: size)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in guard !held else { return }; held = true; onChanged(true); UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.4) }
                .onEnded { _ in held = false; onChanged(false) })
    }
}

private struct HoldCapsule: View {
    let label: String
    let width: CGFloat
    let onChanged: (Bool) -> Void
    @State private var held = false
    var body: some View {
        Capsule(style: .continuous)
            .fill(.white.opacity(held ? 0.12 : 0.035))
            .overlay { Capsule().stroke(.white.opacity(held ? 0.24 : 0.08), lineWidth: 1) }
            .overlay { Text(label).font(.system(size: 9, weight: .semibold, design: .rounded)).tracking(0.8).foregroundStyle(.white.opacity(held ? 0.62 : 0.24)) }
            .frame(width: width, height: 27)
            .contentShape(Capsule())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in guard !held else { return }; held = true; onChanged(true) }
                .onEnded { _ in held = false; onChanged(false) })
    }
}

private struct EdgeHoldZone: View {
    let label: String
    let alignment: Alignment
    let onChanged: (Bool) -> Void
    @State private var held = false
    var body: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(.white.opacity(held ? 0.08 : 0.008))
            .overlay(alignment: alignment) { Text(label).font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(held ? 0.42 : 0.12)).padding(.horizontal, 13) }
            .frame(width: 88)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in guard !held else { return }; held = true; onChanged(true) }
                .onEnded { _ in held = false; onChanged(false) })
    }
}
