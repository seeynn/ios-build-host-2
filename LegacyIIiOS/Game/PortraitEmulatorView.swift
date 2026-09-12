import SwiftUI

struct PortraitEmulatorView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.displayScale) private var displayScale
    @StateObject private var emulator: CompatibilityEmulator

    init(library: ROMLibrary) {
        _emulator = StateObject(wrappedValue: CompatibilityEmulator(library: library))
    }

    var body: some View {
        GeometryReader { geo in
            let availableWidth = max(240, geo.size.width - 14)
            let screenWidth = pixelPerfectWidth(available: availableWidth)
            ZStack {
                Color.black.ignoresSafeArea()
                VStack(spacing: 0) {
                    gameScreen
                        .frame(width: screenWidth, height: screenWidth * (2.0 / 3.0))
                        .padding(.top, max(6, geo.safeAreaInsets.top + 2))
                    utilityBar.padding(.top, 7)
                    PortraitEmulatorControls(emulator: emulator)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .persistentSystemOverlays(.hidden)
        .onAppear { emulator.start() }
        .onDisappear { emulator.stop() }
        .onChange(of: scenePhase) { newPhase in
            switch newPhase {
            case .active:
                if emulator.state == .paused { emulator.resume() }
            case .inactive, .background:
                emulator.pause()
            @unknown default: break
            }
        }
    }

    private func pixelPerfectWidth(available: CGFloat) -> CGFloat {
        guard displayScale > 0 else { return min(available, 400) }
        let sourceWidth: CGFloat = 240
        let physicalPixels = available * displayScale
        let integerScale = max(CGFloat(1), (physicalPixels / sourceWidth).rounded(.down))
        return min(available, sourceWidth * integerScale / displayScale)
    }

    @ViewBuilder
    private var gameScreen: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.black)
            if let frame = emulator.frame {
                Image(decorative: frame, scale: 1, orientation: .up)
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(3.0 / 2.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            } else {
                startupStatus
            }
        }
        .aspectRatio(3.0 / 2.0, contentMode: .fit)
    }

    @ViewBuilder
    private var startupStatus: some View {
        switch emulator.state {
        case .idle, .starting:
            ProgressView().tint(.white.opacity(0.45))
        case .failed(let message):
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.55))
                Text(message)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.48))
                    .padding(.horizontal, 18)
            }
        case .running, .paused:
            EmptyView()
        }
    }

    private var utilityBar: some View {
        HStack(spacing: 18) {
            Button(action: emulator.quickSave) { Image(systemName: "square.and.arrow.down") }
                .accessibilityLabel("Quick Save")
            Button(action: emulator.quickLoad) { Image(systemName: "square.and.arrow.up") }
                .accessibilityLabel("Quick Load")
            Button {
                if emulator.state == .paused { emulator.resume() } else { emulator.pause() }
            } label: {
                Image(systemName: emulator.state == .paused ? "play.fill" : "pause.fill")
            }
            .accessibilityLabel(emulator.state == .paused ? "Resume" : "Pause")
            Button(action: emulator.reset) { Image(systemName: "arrow.counterclockwise") }
                .accessibilityLabel("Reset")
        }
        .buttonStyle(.plain)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.white.opacity(0.22))
        .frame(height: 24)
    }
}
