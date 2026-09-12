import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @StateObject private var library = ROMLibrary.shared
    @State private var importing = false
    @State private var importError: String?

    var body: some View {
        Group {
            if library.installedROMURL != nil {
                GameContainerView(library: library)
            } else {
                importView
            }
        }
        .preferredColorScheme(.dark)
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            do {
                guard let url = try result.get().first else { return }
                try library.importROM(from: url)
            } catch {
                importError = error.localizedDescription
            }
        }
        .alert("Couldn’t Import ROM", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("OK", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "Unknown import error")
        }
    }

    private var importView: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 18) {
                Spacer()
                Text("LEGACY II")
                    .font(.system(size: 26, weight: .black, design: .rounded))
                    .tracking(4)
                    .foregroundStyle(.white.opacity(0.88))
                Text("NATIVE PORTRAIT iPHONE PORT")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .tracking(2.2)
                    .foregroundStyle(.white.opacity(0.24))
                Spacer().frame(height: 18)
                Text("Import your European Legacy of Goku II ROM once. The game world is rendered natively for the tall iPhone screen; the original game runtime stays hidden underneath for live game state, sprites, audio and saves.")
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.42))
                    .frame(maxWidth: 300)
                    .lineSpacing(3)
                Button { importing = true } label: {
                    Text("IMPORT ALFP ROM")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .tracking(1.2)
                        .foregroundStyle(.black.opacity(0.82))
                        .padding(.horizontal, 24)
                        .frame(height: 46)
                        .background(.white.opacity(0.88), in: Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
                if let validationError = library.validationError {
                    Text(validationError)
                        .font(.system(size: 10, design: .rounded))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.28))
                        .frame(maxWidth: 280)
                }
                Spacer()
            }
            .padding(.horizontal, 24)
        }
    }
}
