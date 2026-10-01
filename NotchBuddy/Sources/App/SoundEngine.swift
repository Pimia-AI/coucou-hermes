import AVFoundation
import AppKit

/// Preloaded WAV players with near-zero latency.
/// Volume default 0.12 (matches prototype: gain ×6 then vol=0.12).
@MainActor
final class SoundEngine {
    static let shared = SoundEngine()

    var enabled: Bool = true
    var volume: Float = 0.12 {
        didSet { players.values.forEach { $0.forEach { $0.volume = volume } } }
    }

    // Pool of 3 players per sound to allow overlapping playback
    private var players: [String: [AVAudioPlayer]] = [:]

    private init() {
        preload()
    }

    private func preload() {
        let names = ["peek","open","close","hover","blip","slap","annoyed","dizzy","greet",
                     "work","finish","error","approval","question","approve","gulp","tick",
                     "send","love","pop","proud","wink","yawn","attach","think","search",
                     "rate","sleep"]
        for name in names {
            guard let url = Bundle.main.url(forResource: name, withExtension: "wav", subdirectory: "sounds") else { continue }
            var pool: [AVAudioPlayer] = []
            for _ in 0..<3 {
                if let p = try? AVAudioPlayer(contentsOf: url) {
                    p.volume = volume
                    p.prepareToPlay()
                    pool.append(p)
                }
            }
            if !pool.isEmpty { players[name] = pool }
        }
    }

    func play(_ name: String) {
        guard enabled && AppState.shared.soundEnabled else { return }
        guard let pool = players[name] else { return }
        // Find a player that is not currently playing
        let player = pool.first { !$0.isPlaying } ?? pool[0]
        player.currentTime = 0
        player.volume = volume
        player.play()
    }
}

// MARK: - Voice
//
// Lives here rather than in its own file because the Xcode project enumerates
// sources by hand (no synchronized groups) and CLAUDE.md forbids editing the
// .xcodeproj; a new file would need xcodegen, which is not installed.
//
// Speaking goes through the local Coucou TTS sidecar
// (~/.hermes/coucou-bridge/tts-service.py), which uses Hermes' own engine and
// the voice set in ~/.hermes/config.yaml. Hermes' gateway exposes no audio
// routes, so there is nothing to call there directly.
//
// Listening is macOS' own on-device recogniser: no round trip, no API key, and
// it stops cleanly when the user releases the button.

import Speech

@MainActor
final class VoiceEngine: NSObject, ObservableObject {
    static let shared = VoiceEngine()

    private let ttsURL = URL(string: "http://127.0.0.1:8643/speak")!
    private var player: AVAudioPlayer?

    /// Set from the island's speaker toggle; off means neither speak nor listen.
    @Published var voiceEnabled: Bool = false
    @Published var isSpeaking: Bool = false
    @Published var isListening: Bool = false
    @Published var partialTranscript: String = ""
    /// Hands-free loop: listen -> send -> speak -> listen again.
    @Published var conversationMode: Bool = false

    /// How long a pause ends your turn, once you have actually started talking.
    /// Short enough not to feel sluggish, long enough to think mid-sentence.
    private let silenceEndsTurn: TimeInterval = 1.8
    /// Much longer before the first word: the old code armed the 1.8s timer the
    /// moment the mic opened, so taking a breath before speaking ended the turn
    /// empty — and an empty turn used to kill the whole conversation.
    private let silenceBeforeFirstWord: TimeInterval = 10
    /// True once this turn has heard anything at all.
    private var heardSomething = false
    private var silenceTimer: Timer?
    private var sendTranscript: ((String) -> Void)?

    // MARK: Speaking

    /// Speak one reply. Silently does nothing when the sidecar is down — voice
    /// is a convenience, never a reason for the island to show an error.
    func speak(_ text: String) {
        guard voiceEnabled, !text.isEmpty else { return }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }

        Task { @MainActor in
            var request = URLRequest(url: ttsURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["text": clean])
            request.timeoutInterval = 30
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200, !data.isEmpty else { return }
                stopSpeaking()
                player = try AVAudioPlayer(data: data)
                player?.delegate = self
                isSpeaking = true
                player?.play()
            } catch {
                vlog("TTS failed: \(error.localizedDescription)")
            }
        }
    }

    func stopSpeaking() {
        player?.stop()
        player = nil
        isSpeaking = false
    }

    /// NSLog from this app does not reach the unified log, so voice diagnostics
    /// go where the hook events already go and where we can actually read them.
    func vlog(_ message: String) {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/NotchBuddy")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let line = "\(f.string(from: Date())) VOICE \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        let url = dir.appendingPathComponent("nb.log")
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd(); try? h.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    /// Voice failures used to be invisible: the button turned on and nothing
    /// happened. Say it in the island instead.
    private func surface(_ message: String) {
        conversationMode = false
        AppState.shared.noteMessage = message
        AppState.shared.view = .note
    }

    // MARK: Listening

    /// es-ES first, then whatever the Mac is set to, then en-US. A locale whose
    /// model macOS has not downloaded yields a recogniser that is nil or simply
    /// unavailable, and the old code returned from the guard without a word.
    private lazy var recognizer: SFSpeechRecognizer? = {
        let candidates = ["es-ES", Locale.current.identifier, "en-US"]
        for id in candidates {
            if let r = SFSpeechRecognizer(locale: Locale(identifier: id)), r.isAvailable {
                VoiceEngine.shared.vlog("recogniser \(id) on-device=\(r.supportsOnDeviceRecognition)")
                return r
            }
        }
        VoiceEngine.shared.vlog("NO recogniser for \(candidates)")
        return nil
    }()
    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    /// Ask once; the prompts only appear on first use, attached to a tap the
    /// user just made rather than to app launch.
    func requestPermissions(_ done: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            guard status == .authorized else {
                Task { @MainActor in
                    VoiceEngine.shared.vlog("speech NOT authorized (status \(status.rawValue))")
                    done(false)
                }
                return
            }
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in
                    VoiceEngine.shared.vlog("permissions speech=ok mic=\(granted)")
                    done(granted)
                }
            }
        }
    }

    /// Start dictation. `onFinal` fires once, with the full transcript.
    func startListening(onFinal: @escaping (String) -> Void) {
        if isListening { return }
        guard let recognizer else {
            vlog("cannot listen: no recogniser")
            surface("No speech recogniser. Enable dictation in System Settings → Keyboard.")
            return
        }
        guard recognizer.isAvailable else {
            vlog("cannot listen: recogniser unavailable")
            surface("Speech recognition unavailable right now.")
            return
        }
        vlog("startListening called")
        // Speaking and listening at once would just feed Elvira back to herself.
        stopSpeaking()

        let engine = AVAudioEngine()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        audioEngine = engine
        recognitionRequest = request
        partialTranscript = ""

        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
            request.append(buffer)
        }
        engine.prepare()
        do { try engine.start() } catch {
            vlog("engine.start FAILED: \(error.localizedDescription)")
            cleanupListening()
            return
        }
        isListening = true
        vlog("microphone live")

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    let heard = result.bestTranscription.formattedString
                    if heard != self.partialTranscript {
                        self.partialTranscript = heard
                        self.heardSomething = true
                        // Still talking: push the end of the turn further out.
                        self.armSilenceTimer()
                    }
                    if result.isFinal {
                        self.finishTurn(self.partialTranscript, reason: "final", onFinal: onFinal)
                    }
                } else if let error {
                    // A transcript captured before the error is still worth sending.
                    // macOS also ends a recognition task on its own after about a
                    // minute, which arrives here as an error, not as isFinal.
                    self.finishTurn(self.partialTranscript,
                                    reason: "error: \(error.localizedDescription)",
                                    onFinal: onFinal)
                }
            }
        }
    }

    /// End one turn. An empty one used to stop everything: nothing was sent, so
    /// no reply arrived, so the player never finished, so the loop never
    /// re-armed the mic. That is the "it switches itself off" symptom.
    private func finishTurn(_ transcript: String, reason: String, onFinal: @escaping (String) -> Void) {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        vlog("turn ended (\(reason)) text=\(text.isEmpty ? "<empty>" : "\(text.count) chars")")
        let wasConversation = conversationMode
        cleanupListening()
        if !text.isEmpty {
            onFinal(text)
            return
        }
        guard wasConversation else { return }
        // Nothing said: just listen again rather than ending the conversation.
        // A short delay keeps a failing recogniser from spinning.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            VoiceEngine.shared.resumeAfterSpeaking()
        }
    }

    /// In conversation mode nobody taps to end a turn, so a pause does it.
    private func armSilenceTimer() {
        silenceTimer?.invalidate()
        guard conversationMode else { return }
        let wait = heardSomething ? silenceEndsTurn : silenceBeforeFirstWord
        silenceTimer = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { _ in
            Task { @MainActor in
                let engine = VoiceEngine.shared
                engine.vlog(engine.heardSomething ? "turn ended by pause" : "nothing heard, re-arming")
                engine.stopListening()
            }
        }
    }

    /// Start the hands-free loop. Spoken replies are implied — a conversation
    /// where only one side talks is just dictation.
    func startConversation(send: @escaping (String) -> Void) {
        vlog("startConversation")
        guard !conversationMode else { vlog("already in conversation"); return }
        conversationMode = true
        voiceEnabled = true
        sendTranscript = send
        listenForTurn()
    }

    func stopConversation() {
        conversationMode = false
        sendTranscript = nil
        silenceTimer?.invalidate()
        silenceTimer = nil
        stopListening()
        stopSpeaking()
        partialTranscript = ""
    }

    /// One turn of the loop. Never starts while Elvira is still talking —
    /// overlapping a reply with the next question queues two runs at once.
    private func listenForTurn() {
        guard conversationMode, !isSpeaking else { return }
        heardSomething = false
        startListening { [weak self] transcript in
            guard let self, self.conversationMode else { return }
            self.sendTranscript?(transcript)
        }
        armSilenceTimer()
    }

    /// Called by the audio delegate once a spoken reply ends.
    func resumeAfterSpeaking() { listenForTurn() }

    /// Stop capturing and let the recogniser deliver its final result.
    func stopListening() {
        guard isListening else { return }
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        recognitionRequest?.endAudio()
        isListening = false
    }

    private func cleanupListening() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        isListening = false
    }
}

extension VoiceEngine: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            let engine = VoiceEngine.shared
            engine.isSpeaking = false
            // Elvira has finished: it is the user's turn again.
            if engine.conversationMode { engine.resumeAfterSpeaking() }
        }
    }
}
