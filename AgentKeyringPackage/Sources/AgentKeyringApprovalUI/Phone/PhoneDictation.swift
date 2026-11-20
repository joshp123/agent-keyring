// Written by AI on 2026.11.20 by model Claude Opus 5.5.
//
// The microphone beside the reply box: one tap to speak, one to stop, the
// words written into the box as they are heard. Apple's own on-device
// transcription (SpeechAnalyzer with SpeechTranscriber); nothing leaves the
// iPhone and nothing of ours is trained or shipped. If the microphone is
// refused or the language is not on the iPhone, the box takes the keyboard,
// whose dictation key still works, so a reply never waits on this.

#if os(iOS)
import AVFAudio
import Foundation
import Observation
import Speech

@MainActor @Observable
final class PhoneDictation {
    enum State: Equatable {
        case idle
        case starting
        /// Words heard so far: `settled` will not change, `tentative` may.
        case listening(settled: String, tentative: String)
        /// Refused, or no on-device model for this language: the keyboard instead.
        case unavailable
    }

    private(set) var state = State.idle
    private var engine: AVAudioEngine?
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var reading: Task<Void, Never>?

    var isListening: Bool { if case .listening = state { true } else { state == .starting } }

    /// What has been heard, for the reply box.
    var heard: String {
        guard case let .listening(settled, tentative) = state else { return "" }
        return (settled + tentative).trimmingCharacters(in: .whitespaces)
    }

    func toggle() async {
        if isListening { await stop() } else { await start() }
    }

    func start() async {
        guard state == .idle || state == .unavailable else { return }
        state = .starting
        guard await AVAudioApplication.requestRecordPermission(),
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) else { return fallBack() }
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        do {
            if await AssetInventory.status(forModules: [transcriber]) != .installed {
                // The language's model downloads in the background; this time the keyboard is used.
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    Task.detached { try? await request.downloadAndInstall() }
                }
                return fallBack()
            }
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { return fallBack() }
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            try await analyzer.start(inputSequence: stream)
            let engine = AVAudioEngine()
            let node = engine.inputNode
            let natural = node.outputFormat(forBus: 0)
            guard let converter = AVAudioConverter(from: natural, to: format) else { return fallBack() }
            node.installTap(onBus: 0, bufferSize: 4096, format: natural, block: Self.feed(converter, to: format, into: continuation))
            try engine.start()
            self.engine = engine; self.analyzer = analyzer; self.input = continuation
            state = .listening(settled: "", tentative: "")
            reading = Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        guard let self, case let .listening(settled, _) = self.state else { return }
                        let text = String(result.text.characters)
                        self.state = result.isFinal ? .listening(settled: settled + text, tentative: "") : .listening(settled: settled, tentative: text)
                    }
                } catch {}
            }
        } catch {
            fallBack()
        }
    }

    /// The microphone's tap, which runs on the audio thread: it converts each buffer for the analyzer.
    nonisolated private static func feed(_ converter: AVAudioConverter, to format: AVAudioFormat,
                                         into continuation: AsyncStream<AnalyzerInput>.Continuation) -> AVAudioNodeTapBlock {
        nonisolated(unsafe) let converter = converter
        return { buffer, _ in
            let ratio = format.sampleRate / buffer.format.sampleRate
            guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1)
            else { return }
            nonisolated(unsafe) var fed = false
            converter.convert(to: converted, error: nil) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true; status.pointee = .haveData; return buffer
            }
            continuation.yield(AnalyzerInput(buffer: converted))
        }
    }

    /// Stops listening; the words heard stay in the box.
    func stop() async {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        input?.finish()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        await reading?.value
        engine = nil; analyzer = nil; input = nil; reading = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        state = .idle
    }

    private func fallBack() {
        engine?.stop(); engine = nil; analyzer = nil; input?.finish(); input = nil
        state = .unavailable
    }
}
#endif
