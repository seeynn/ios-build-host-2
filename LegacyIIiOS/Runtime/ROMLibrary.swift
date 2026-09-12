import Foundation
import CryptoKit

@MainActor
final class ROMLibrary: ObservableObject {
    static let shared = ROMLibrary()
    @Published private(set) var installedROMURL: URL?
    @Published private(set) var validationError: String?

    private let fm = FileManager.default
    private let expectedCode = "ALFP"
    private let expectedSize = 8_388_608

    private init() { refresh() }

    private var support: URL {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("LOG2-IPHONE", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    var romDestinationURL: URL { support.appendingPathComponent("game.gba") }
    var saveURL: URL { support.appendingPathComponent("game.sav") }
    var quickSaveURL: URL { support.appendingPathComponent("quick.ss") }

    func refresh() {
        validationError = nil
        guard fm.fileExists(atPath: romDestinationURL.path) else {
            installedROMURL = nil
            return
        }
        do {
            try validateROM(at: romDestinationURL)
            installedROMURL = romDestinationURL
        } catch {
            installedROMURL = nil
            validationError = error.localizedDescription
        }
    }

    func importROM(from sourceURL: URL) throws {
        let scoped = sourceURL.startAccessingSecurityScopedResource()
        defer { if scoped { sourceURL.stopAccessingSecurityScopedResource() } }
        try validateROM(at: sourceURL)
        if fm.fileExists(atPath: romDestinationURL.path) { try fm.removeItem(at: romDestinationURL) }
        try fm.copyItem(at: sourceURL, to: romDestinationURL)
        installedROMURL = romDestinationURL
        validationError = nil
    }

    func validateROM(at url: URL) throws {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count == expectedSize else { throw ROMValidationError.wrongSize(data.count) }
        let image = try ROMImage(data: data)
        guard image.gameCode == expectedCode else { throw ROMValidationError.wrongGameCode(image.gameCode) }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(digest, forKey: "InstalledROM_SHA256")
    }
}

enum ROMValidationError: LocalizedError {
    case wrongSize(Int)
    case wrongGameCode(String)
    var errorDescription: String? {
        switch self {
        case .wrongSize(let size): return "Unsupported cartridge size: \(size) bytes."
        case .wrongGameCode(let code): return "Unsupported cartridge code: \(code)."
        }
    }
}
