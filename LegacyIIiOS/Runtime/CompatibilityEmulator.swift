import CoreGraphics
import EclipseKit
import Foundation
import QuartzCore
import mGBAEclipseCore

@MainActor
final class CompatibilityEmulator: NSObject, ObservableObject {
    enum State: Equatable { case idle, starting, running, paused, failed(String) }
    @Published private(set) var state: State = .idle
    @Published private(set) var frame: CGImage?

    private let library: ROMLibrary
    private var core: mGBAEclipseCore?
    private var bridge: EmulatorBridge?
    private var frameBuffer: UnsafeMutableBufferPointer<UInt8>?
    private var displayLink: CADisplayLink?
    private var dpadUp = false
    private var dpadDown = false
    private var dpadLeft = false
    private var dpadRight = false

    init(library: ROMLibrary = .shared) {
        self.library = library
        super.init()
    }

    deinit {
        displayLink?.invalidate()
        frameBuffer?.deallocate()
    }

    func start() {
        guard state != .running, state != .starting else { return }
        library.refresh()
        guard let romURL = library.installedROMURL else {
            state = .failed("No supported cartridge is installed.")
            return
        }
        tearDownCore()
        state = .starting
        do {
            let audioBridge = EmulatorBridge()
            bridge = audioBridge
            let settings = CoreResolvedSettings(settings: mGBAEclipseCoreSettings(), resolvedFiles: [:])
            let newCore = try mGBAEclipseCore(system: .gba, settings: settings, bridge: audioBridge)
            let descriptor = newCore.getVideoDescriptor()
            let byteCount = Int(descriptor.width) * Int(descriptor.height) * Int(descriptor.pixelFormat.bytesPerPixel)
            let buffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: byteCount)
            buffer.baseAddress?.initialize(repeating: 0, count: byteCount)
            frameBuffer = buffer
            newCore.setFrameBuffer(to: buffer)
            try newCore.start(romPath: romURL, savePath: library.saveURL)
            newCore.playerConnected(to: 0)
            core = newCore
            installDisplayLink()
            state = .running
        } catch {
            tearDownCore()
            state = .failed(String(describing: error))
        }
    }

    func stop() { core?.stop(); tearDownCore(); state = .idle }
    func pause() {
        guard state == .running else { return }
        displayLink?.isPaused = true
        core?.pause()
        bridge?.pauseAudio()
        state = .paused
    }
    func resume() {
        guard state == .paused else { return }
        core?.play()
        bridge?.resumeAudio()
        displayLink?.isPaused = false
        state = .running
    }
    func reset() { core?.reset(); bridge?.resetAudioQueue() }

    func quickSave() {
        do { try core?.saveState(to: library.quickSaveURL) }
        catch { state = .failed("Quick Save failed: \(error)") }
    }

    func quickLoad() {
        guard FileManager.default.fileExists(atPath: library.quickSaveURL.path) else { return }
        do { try core?.loadState(from: library.quickSaveURL); bridge?.resetAudioQueue() }
        catch { state = .failed("Quick Load failed: \(error)") }
    }

    func setA(_ pressed: Bool) { sendButton(.faceButtonRight, pressed: pressed) }
    func setB(_ pressed: Bool) { sendButton(.faceButtonDown, pressed: pressed) }
    func setL(_ pressed: Bool) { sendButton(.leftShoulder, pressed: pressed) }
    func setR(_ pressed: Bool) { sendButton(.rightShoulder, pressed: pressed) }
    func setStart(_ pressed: Bool) { sendButton(.start, pressed: pressed) }
    func setSelect(_ pressed: Bool) { sendButton(.select, pressed: pressed) }
    func setUp(_ pressed: Bool) { dpadUp = pressed; sendDPad() }
    func setDown(_ pressed: Bool) { dpadDown = pressed; sendDPad() }
    func setLeft(_ pressed: Bool) { dpadLeft = pressed; sendDPad() }
    func setRight(_ pressed: Bool) { dpadRight = pressed; sendDPad() }

    private func sendButton(_ input: CoreInput, pressed: Bool) {
        guard let runningCore = core else { return }
        runningCore.writeInput(CoreInputDelta(input: input, pressed: pressed, timestamp: CACurrentMediaTime()), for: 0)
    }

    private func sendDPad() {
        guard let runningCore = core else { return }
        let horizontal: Float32 = dpadLeft == dpadRight ? 0 : (dpadLeft ? -1 : 1)
        let vertical: Float32 = dpadUp == dpadDown ? 0 : (dpadUp ? 1 : -1)
        runningCore.writeInput(CoreInputDelta(input: .dpad, x: horizontal, y: vertical, timestamp: CACurrentMediaTime()), for: 0)
    }

    private func installDisplayLink() {
        displayLink?.invalidate()
        let link = CADisplayLink(target: self, selector: #selector(displayLinkFired(_:)))
        if #available(iOS 15.0, *) { link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60) }
        else { link.preferredFramesPerSecond = 60 }
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func displayLinkFired(_ link: CADisplayLink) {
        guard state == .running, let runningCore = core else { return }
        runningCore.step(timestamp: link.timestamp, willRender: true)
        publishFrame()
    }

    private func publishFrame() {
        guard let buffer = frameBuffer, let base = buffer.baseAddress else { return }
        let width = 240, height = 160
        let copied = Data(bytes: base, count: width * height * 4)
        guard let provider = CGDataProvider(data: copied as CFData) else { return }
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue))
        frame = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmapInfo, provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    private func tearDownCore() {
        displayLink?.invalidate(); displayLink = nil
        bridge?.pauseAudio(); bridge = nil
        core = nil
        if let buffer = frameBuffer { buffer.deallocate(); frameBuffer = nil }
        frame = nil
        dpadUp = false; dpadDown = false; dpadLeft = false; dpadRight = false
    }
}
