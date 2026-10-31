import AVFAudio
import Foundation
import OSLog
import Speech

private let dictationLogger = Logger(subsystem: "com.joshpalmer.AgentKeyring.Phone", category: "Dictation")

@MainActor
final class PhoneReplyDictation {
    private var session: PhoneDictationSession?

    func transcript() -> AsyncThrowingStream<String, any Error> {
        stop()
        let session = PhoneDictationSession()
        self.session = session
        return session.transcript()
    }

    func stop() {
        session?.finish()
        session = nil
    }
}

@MainActor
private final class PhoneDictationSession {
    private let engine = AVAudioEngine()
    private var continuation: AsyncThrowingStream<String, any Error>.Continuation?
    private var startup: Task<Void, Never>?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognition: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    private var hasInputTap = false
    private var audioSessionActive = false
    private var interruptionObserver: (any NSObjectProtocol)?

    func transcript() -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            self.continuation = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.finish() }
            }
            startup = Task { [weak self] in
                do { try await self?.start() }
                catch is CancellationError { self?.finish() }
                catch { self?.finish(error: error) }
            }
        }
    }

    private func start() async throws {
        dictationLogger.notice("Requesting speech permission")
        let authorization = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        try Task.checkCancellation()
        guard authorization == .authorized else { throw DictationFailure.speechPermission }
        dictationLogger.notice("Requesting microphone permission")
        let microphoneAllowed = await AVAudioApplication.requestRecordPermission()
        try Task.checkCancellation()
        guard microphoneAllowed else { throw DictationFailure.microphonePermission }
        let locale = Locale(identifier: Locale.preferredLanguages.first ?? Locale.current.identifier)
        guard let recognizer = SFSpeechRecognizer(locale: locale),
              recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            throw DictationFailure.onDeviceUnavailable
        }
        self.recognizer = recognizer

        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audioSession.setActive(true)
        audioSessionActive = true
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: audioSession, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in self?.finish(error: DictationFailure.interrupted) }
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        self.request = request
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw DictationFailure.microphoneUnavailable }
        Self.installInputTap(input, format: format, request: request)
        hasInputTap = true
        guard let continuation else { throw CancellationError() }
        recognition = Self.recognize(recognizer, request: request, continuation: continuation) { [weak self] error in
            Task { @MainActor in self?.finish(error: error) }
        }
        engine.prepare()
        try engine.start()
        dictationLogger.notice("On-device dictation started")
    }

    // Audio and recognition callbacks run outside the main actor. Only text and
    // completion cross back; the audio buffer goes straight to Apple's request.
    nonisolated private static func installInputTap(
        _ input: AVAudioInputNode, format: AVAudioFormat, request: SFSpeechAudioBufferRecognitionRequest
    ) {
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
    }

    nonisolated private static func recognize(
        _ recognizer: SFSpeechRecognizer, request: SFSpeechAudioBufferRecognitionRequest,
        continuation: AsyncThrowingStream<String, any Error>.Continuation,
        finished: @escaping @Sendable ((any Error)?) -> Void
    ) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            if let result { continuation.yield(result.bestTranscription.formattedString) }
            if let error { finished(error) }
            else if result?.isFinal == true { finished(nil) }
        }
    }

    func finish(error: (any Error)? = nil) {
        guard let continuation else { return }
        self.continuation = nil
        startup?.cancel()
        startup = nil
        engine.stop()
        if hasInputTap { engine.inputNode.removeTap(onBus: 0); hasInputTap = false }
        request?.endAudio()
        recognition?.cancel()
        recognition = nil
        request = nil
        recognizer = nil
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        interruptionObserver = nil
        if audioSessionActive {
            do { try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
            catch { dictationLogger.error("Audio session release failed [\((error as NSError).domain, privacy: .public):\((error as NSError).code, privacy: .public)]") }
            audioSessionActive = false
        }
        if let error {
            dictationLogger.error("Dictation stopped [\((error as NSError).domain, privacy: .public):\((error as NSError).code, privacy: .public)]")
            continuation.finish(throwing: error is DictationFailure ? error : DictationFailure.recognitionFailed)
        } else {
            dictationLogger.notice("Dictation stopped")
            continuation.finish()
        }
    }
}

private enum DictationFailure: LocalizedError {
    case onDeviceUnavailable, speechPermission, microphonePermission, microphoneUnavailable, interrupted, recognitionFailed

    var errorDescription: String? {
        switch self {
        case .onDeviceUnavailable: "On-device dictation isn't available for this iPhone's language. You can type your reply."
        case .speechPermission: "Allow Speech Recognition for Agent Keyring in Settings to dictate a reply. You can still type."
        case .microphonePermission: "Allow Microphone access for Agent Keyring in Settings to dictate a reply. You can still type."
        case .microphoneUnavailable: "The microphone isn't available. You can type your reply."
        case .interrupted: "Dictation was interrupted. Your words are kept; tap the microphone to continue."
        case .recognitionFailed: "Dictation couldn't continue on this iPhone. Your words are kept; you can type or try again."
        }
    }
}
