// Written by AI on 2026.11.20 by model Claude Opus 5.5.
//
// The microphone beside the reply box: one tap to speak, one to stop, the
// words written into the box as they are heard. Apple's own on-device
// transcription (SpeechAnalyzer with SpeechTranscriber); nothing leaves the
// iPhone and nothing of ours is trained or shipped. The language's speech
// model is fetched during setup (`PhoneSpeechModel.prepare()`), so the first
// tap works. When it cannot listen, it says why in one line; it never moves to
// the keyboard without a word. Every step is logged.

#if os(iOS)
import AVFAudio
import Foundation
import Observation
import Speech

/// The speech model for this iPhone's language: one for the app, fetched once.
@MainActor @Observable
public final class PhoneSpeechModel {
    public enum State: Equatable {
        case unknown
        case downloading(percent: Int)
        case ready(Locale)
        /// No on-device model for this language.
        case unsupported(language: String)
        case failed(String)
    }

    public static let shared = PhoneSpeechModel()
    /// Where log lines go: the app points this at its own log.
    public static var log: (_ event: String, _ fields: [String: String]) -> Void = { _, _ in }

    public private(set) var state = State.unknown
    private var fetching: Task<Void, Never>?

    /// Fetches the model if it is missing. Called during setup and again before listening.
    public func prepare() {
        guard fetching == nil else { return }
        if case .ready = state { return }
        fetching = Task { await fetch(); fetching = nil }
    }

    func waitUntilSettled() async { await fetching?.value }

    private func fetch() async {
        let language = Locale.current.identifier
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) else {
            Self.log("unsupported", ["locale": language])
            state = .unsupported(language: Locale.current.localizedString(forLanguageCode: Locale.current.language.languageCode?.identifier ?? "") ?? language)
            return
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        if await AssetInventory.status(forModules: [transcriber]) == .installed {
            state = .ready(locale)
            Self.log("ready", ["locale": locale.identifier])
            return
        }
        do {
            guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
                state = .ready(locale)
                return
            }
            Self.log("downloading", ["locale": locale.identifier])
            state = .downloading(percent: 0)
            let progress = request.progress
            let watching = Task { @MainActor in
                while !Task.isCancelled {
                    state = .downloading(percent: Int(progress.fractionCompleted * 100))
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
            defer { watching.cancel() }
            try await request.downloadAndInstall()
            state = .ready(locale)
            Self.log("ready", ["locale": locale.identifier])
        } catch {
            state = .failed("\(error)")
            Self.log("download failed", ["error": "\(error)"])
        }
    }
}

@MainActor @Observable
final class PhoneDictation {
    enum State: Equatable {
        case idle
        case starting
        /// Words heard so far: `settled` will not change, `tentative` may.
        case listening(settled: String, tentative: String)
        /// It cannot listen, and says why.
        case cannotListen(Reason)
    }

    enum Reason: Equatable {
        case microphoneOff
        case gettingReady(percent: Int)
        case unsupported(language: String)
        case failed
    }

    private(set) var state = State.idle
    private var engine: AVAudioEngine?
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var reading: Task<Void, Never>?
    private let log = PhoneSpeechModel.log

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
        if isListening { return }
        state = .starting
        log("tapped", [:])
        guard await AVAudioApplication.requestRecordPermission() else { return cannotListen(.microphoneOff) }
        let model = PhoneSpeechModel.shared
        model.prepare()
        if case .downloading = model.state {} else { await model.waitUntilSettled() }
        switch model.state {
        case let .downloading(percent): return cannotListen(.gettingReady(percent: percent))
        case let .unsupported(language): return cannotListen(.unsupported(language: language))
        case .failed, .unknown: return cannotListen(.failed)
        case let .ready(locale): await listen(locale)
        }
    }

    private func listen(_ locale: Locale) async {
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        do {
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                log("no audio format", [:]); return cannotListen(.failed)
            }
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            try await analyzer.start(inputSequence: stream)
            let engine = AVAudioEngine()
            let node = engine.inputNode
            let natural = node.outputFormat(forBus: 0)
            guard let converter = AVAudioConverter(from: natural, to: format) else {
                log("no audio converter", [:]); return cannotListen(.failed)
            }
            node.installTap(onBus: 0, bufferSize: 4096, format: natural, block: Self.feed(converter, to: format, into: continuation))
            try engine.start()
            self.engine = engine; self.analyzer = analyzer; self.input = continuation
            state = .listening(settled: "", tentative: "")
            log("listening", ["locale": locale.identifier])
            reading = Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        guard let self, case let .listening(settled, _) = self.state else { return }
                        let text = String(result.text.characters)
                        self.state = result.isFinal ? .listening(settled: settled + text, tentative: "") : .listening(settled: settled, tentative: text)
                    }
                } catch { self?.log("transcription ended", ["error": "\(error)"]) }
            }
        } catch {
            log("could not listen", ["error": "\(error)"])
            cannotListen(.failed)
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
        guard isListening else { return }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        input?.finish()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        await reading?.value
        engine = nil; analyzer = nil; input = nil; reading = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        state = .idle
        log("stopped", [:])
    }

    private func cannotListen(_ reason: Reason) {
        engine?.stop(); engine = nil; analyzer = nil; input?.finish(); input = nil
        state = .cannotListen(reason)
        log("cannot listen", ["reason": "\(reason)"])
    }
}
#endif
