import AVFoundation
import Speech

/// Turns the microphone into text with Apple's speech recognition, on-device when the Mac supports it.
/// Reports the words as they're recognised and the input level for the waveform.
@MainActor
final class SpeechListener {
    enum Failure: Error, Equatable {
        case microphoneDenied, speechDenied, unavailable, noInput

        var message: String {
            switch self {
            case .microphoneDenied: return "Cove can't use the microphone. Allow it in System Settings → Privacy & Security → Microphone."
            case .speechDenied: return "Cove can't use speech recognition. Allow it in System Settings → Privacy & Security → Speech Recognition."
            case .unavailable: return "Speech recognition isn't available right now."
            case .noInput: return "No microphone found."
            }
        }
    }

    var onTranscript: ((String) -> Void)?
    var onLevel: ((Double) -> Void)?
    private(set) var transcript = ""
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var finish: ((String) -> Void)?
    private var running = false

    /// Asks for the microphone and speech recognition the first time; afterwards it returns at once.
    static func authorize() async -> Failure? {
        let microphone: Bool = await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
        }
        guard microphone else { return .microphoneDenied }
        let speech: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        return speech == .authorized ? nil : .speechDenied
    }

    func start() throws {
        cancel()
        guard let recognizer = SFSpeechRecognizer() ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable else { throw Failure.unavailable }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw Failure.noInput }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format,
                         block: Self.tap(request: request, level: { [weak self] level in
                             Task { @MainActor in self?.onLevel?(level) }
                         }))
        self.request = request
        transcript = ""
        task = recognizer.recognitionTask(with: request, resultHandler: Self.results { [weak self] text, final, failed in
            Task { @MainActor in self?.receive(text: text, final: final, failed: failed) }
        })
        engine.prepare()
        do {
            try engine.start()
        } catch {
            cancel()
            throw Failure.noInput
        }
        running = true
    }

    /// Stops listening and hands back the words: the final recognition, or what was heard so far if
    /// that doesn't come within a moment.
    func stop(_ done: @escaping (String) -> Void) {
        guard running || task != nil else { done(transcript); return }
        stopAudio()
        request?.endAudio()
        finish = done
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            MainActor.assumeIsolated { self?.complete() }
        }
    }

    func cancel() {
        stopAudio()
        task?.cancel()
        task = nil
        request = nil
        finish = nil
    }

    private func stopAudio() {
        guard running else { return }
        running = false
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
    }

    private func receive(text: String?, final: Bool, failed: Bool) {
        if let text, !text.isEmpty {
            transcript = text
            onTranscript?(text)
        }
        if final || failed { complete() }
    }

    private func complete() {
        guard let done = finish else { return }
        finish = nil
        task?.finish()
        task = nil
        request = nil
        done(transcript)
    }

    // The audio tap and the recognition callback run on background queues. They're built here, outside
    // the main actor, so neither closure is treated as main-actor code.

    nonisolated private static func tap(request: SFSpeechAudioBufferRecognitionRequest,
                                        level: @escaping @Sendable (Double) -> Void) -> AVAudioNodeTapBlock {
        { buffer, _ in
            request.append(buffer)
            level(Self.level(of: buffer))
        }
    }

    nonisolated private static func results(_ forward: @escaping @Sendable (String?, Bool, Bool) -> Void)
        -> (SFSpeechRecognitionResult?, Error?) -> Void {
        { result, error in
            forward(result?.bestTranscription.formattedString, result?.isFinal ?? false, error != nil)
        }
    }

    /// 0…1 from the buffer's loudness: -50 dB and below is silence, 0 dB is full.
    nonisolated static func level(of buffer: AVAudioPCMBuffer) -> Double {
        guard let samples = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<count { sum += samples[i] * samples[i] }
        let rms = (sum / Float(count)).squareRoot()
        let decibels = 20 * log10(max(rms, 0.000_001))
        return Double(min(max((decibels + 50) / 50, 0), 1))
    }
}
