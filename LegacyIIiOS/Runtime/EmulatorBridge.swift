import AVFoundation
import Darwin
import EclipseKit

final class EmulatorBridge: CoreBridgeProtocol {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 32_768, channels: 2, interleaved: true)!
    private(set) var saveGeneration: UInt64 = 0

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
        try? session.setPreferredSampleRate(32_768)
        try? session.setActive(true)
        try? engine.start()
        player.play()
    }

    @discardableResult
    func writeAudioSamples(samples: UnsafeRawBufferPointer) -> Int {
        guard samples.count >= 4 else { return 0 }
        let frameCount = samples.count / 4
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else { return 0 }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        let audioBufferList = buffer.mutableAudioBufferList
        guard let destination = audioBufferList.pointee.mBuffers.mData, let source = samples.baseAddress else { return 0 }
        memcpy(destination, source, samples.count)
        if !player.isPlaying { player.play() }
        player.scheduleBuffer(buffer, completionHandler: nil)
        return frameCount
    }

    func didSave() { saveGeneration &+= 1 }
    func pauseAudio() { player.pause() }
    func resumeAudio() {
        if !engine.isRunning { try? engine.start() }
        if !player.isPlaying { player.play() }
    }
    func resetAudioQueue() { player.stop(); player.play() }
}
