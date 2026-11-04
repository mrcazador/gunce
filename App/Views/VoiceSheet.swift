import AVFoundation
import Speech
import SwiftUI

/// Writes the microphone to an .m4a file (AAC) while Apple's recogniser shows a live preview.
/// The audio thread writes, the main actor closes; a lock keeps them apart.
final class AudioSink: @unchecked Sendable {
    let url: URL
    private let lock = NSLock()
    private var file: AVAudioFile?

    init?(format: AVAudioFormat) {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderBitRateKey: 64000,
        ]
        guard let file = try? AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false) else {
            return nil
        }
        self.file = file
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        try? file?.write(from: buffer)
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        file?.close()
        file = nil
    }

    func discard() {
        close()
        try? FileManager.default.removeItem(at: url)
    }
}

/// Listens in Turkish. The recording goes to the server's speech to text (ElevenLabs Scribe)
/// when the note is finished; Apple's recogniser only shows a live preview while you talk, and
/// stands in when the server's speech to text is not available. The file is deleted afterwards.
@MainActor
@Observable
final class Dictation {
    enum Phase: Equatable {
        case idle, listening, finished
        case failed(String)
    }

    var phase: Phase = .idle
    var text = ""

    @ObservationIgnored private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "tr-TR"))
    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var sink: AudioSink?

    func start() async {
        guard phase != .listening else { return }
        guard await AVAudioApplication.requestRecordPermission() else {
            phase = .failed("Mikrofon izni gerekiyor. Ayarlar'dan PickUp için açabilirsin.")
            return
        }
        // The live preview is a nicety: without speech recognition the recording still works.
        let preview = await Self.speechAuthorized()
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            var request: SFSpeechAudioBufferRecognitionRequest?
            if preview, let recognizer, recognizer.isAvailable {
                let r = SFSpeechAudioBufferRecognitionRequest()
                r.shouldReportPartialResults = true
                r.addsPunctuation = true
                if recognizer.supportsOnDeviceRecognition { r.requiresOnDeviceRecognition = true }
                request = r
            }
            self.request = request

            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            let sink = AudioSink(format: format)
            self.sink = sink
            guard request != nil || sink != nil else {
                phase = .failed("Kayıt başlatılamadı.")
                return
            }
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.tap(request, sink))
            engine.prepare()
            try engine.start()
            text = ""
            phase = .listening
            if let request, let recognizer {
                task = recognizer.recognitionTask(with: request, resultHandler: Self.handler { [weak self] text, _ in
                    Task { @MainActor in
                        guard let self, let text, self.phase == .listening else { return }
                        self.text = text
                    }
                })
            }
        } catch {
            stopAudio()
            sink?.discard()
            sink = nil
            phase = .failed("Kayıt başlatılamadı.")
        }
    }

    /// Stops listening. Returns the live preview and the finished recording, if any; the
    /// caller deletes the file with `discardRecording()` once it has been sent.
    func finish() async -> (preview: String, recording: URL?) {
        request?.endAudio()
        stopAudio()
        sink?.close()
        try? await Task.sleep(for: .milliseconds(500))
        task?.finish()
        task = nil
        phase = .finished
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), sink?.url)
    }

    func discardRecording() {
        sink?.discard()
        sink = nil
    }

    func cancel() {
        task?.cancel()
        task = nil
        request?.endAudio()
        stopAudio()
        discardRecording()
        if phase == .listening { phase = .idle }
    }

    /// Screenshot runs have no microphone: show a sample note instead.
    func showSample(_ sample: String) {
        text = sample
        phase = .listening
    }

    private func stopAudio() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // Built outside the main actor: the audio and recognition callbacks run on their own queues.
    nonisolated private static func tap(_ request: SFSpeechAudioBufferRecognitionRequest?, _ sink: AudioSink?) -> AVAudioNodeTapBlock {
        { buffer, _ in
            request?.append(buffer)
            sink?.write(buffer)
        }
    }

    nonisolated private static func handler(
        _ update: @escaping @Sendable (String?, Bool) -> Void
    ) -> @Sendable (SFSpeechRecognitionResult?, (any Error)?) -> Void {
        { result, error in
            update(result?.bestTranscription.formattedString, error != nil || (result?.isFinal ?? false))
        }
    }

    nonisolated private static func speechAuthorized() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        return speech == .authorized
    }
}

/// "Söyle": talk about what you did, where you left off or what came to mind; PickUp turns it
/// into tasks, steps, notes and reminders. Opens listening; one button finishes.
struct VoiceSheet: View {
    @Environment(AppStore.self) private var store
    /// The task the note is about, when opened from a task.
    var taskID: String? = nil
    /// Opened from the task's note: what is said rewrites that note.
    var noteOnly = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dictation = Dictation()
    @State private var working = false
    @State private var workingLabel = "Notun işleniyor…"
    @State private var failure: String?
    /// What was said, kept when the server could not read it, so nothing is lost.
    @State private var spoken = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                transcript
                Spacer(minLength: 0)
                if let failure {
                    Text(failure)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if spoken.isEmpty {
                        ActionButton(title: "Kapat", symbol: "xmark", prominent: true) { dismiss() }
                    } else {
                        VStack(spacing: 10) {
                            ActionButton(title: "Görev olarak ekle", symbol: "tray.and.arrow.down", prominent: true) {
                                Task {
                                    await store.capture(spoken)
                                    dismiss()
                                }
                            }
                            ActionButton(title: "Tekrar dene", symbol: "arrow.clockwise") { Task { await send(spoken) } }
                        }
                    }
                } else if working {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(workingLabel)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 56)
                } else {
                    ActionButton(title: "Bitti", symbol: "checkmark", prominent: true) { Task { await done() } }
                        .accessibilityIdentifier("voice-done")
                        .disabled(dictation.phase != .listening)
                    Text("Kaydın yazıya dökülmesi için ElevenLabs'e gönderilir, yazı da görevlerini düzenlemek için Claude'a. PickUp sesi saklamaz.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.themeBackground)
            .navigationTitle(noteOnly ? "Kaldığın yer" : taskID.flatMap { store.tasks[$0]?.title } ?? "Söyle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Vazgeç") {
                        dictation.cancel()
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task {
            if store.isDemo {
                dictation.showSample("Sunumun grafiklerini bitirdim, metinler kaldı. Yarın sabah finansa rakamları sormayı hatırlat.")
            } else {
                await dictation.start()
            }
        }
        .onDisappear { dictation.cancel() }
    }

    @ViewBuilder
    private var transcript: some View {
        switch dictation.phase {
        case .failed(let message):
            Label(message, systemImage: "mic.slash")
                .foregroundStyle(.secondary)
        default:
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "waveform")
                    .font(.title2)
                    .foregroundStyle(Color.themeBrick)
                    .symbolEffect(.variableColor.iterative, isActive: dictation.phase == .listening && !reduceMotion)
                    .accessibilityHidden(true)
                Text(dictation.text.isEmpty ? (noteOnly ? "Dinliyorum… Nerede olduğunu, sırada ne olduğunu söyle." : "Dinliyorum… Ne yaptığını, nerede kaldığını ya da aklına geleni söyle.") : dictation.text)
                    .font(.title3)
                    .foregroundStyle(dictation.text.isEmpty ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(dictation.text.isEmpty ? "Dinliyorum" : dictation.text)
            }
        }
    }

    private func done() async {
        let (preview, recording) = await dictation.finish()
        var text = preview
        if let recording, let audio = try? Data(contentsOf: recording), !audio.isEmpty {
            workingLabel = "Yazıya dökülüyor…"
            working = true
            do {
                // Scribe's text replaces the preview; without it the preview stands in.
                if let heard = try await store.transcribeVoice(audio), !heard.isEmpty {
                    text = heard
                    dictation.text = heard
                }
            } catch {
                if preview.isEmpty {
                    working = false
                    dictation.discardRecording()
                    failure = (error as? LocalizedError)?.errorDescription ?? "Ses yazıya dökülemedi."
                    return
                }
            }
            working = false
        }
        dictation.discardRecording()
        guard !text.isEmpty else {
            dismiss()
            return
        }
        await send(text)
    }

    private func send(_ text: String) async {
        spoken = text
        failure = nil
        workingLabel = "Notun işleniyor…"
        working = true
        do {
            let plan = try await store.interpretVoice(text, taskID: taskID, noteOnly: noteOnly)
            await store.apply(plan)
            working = false
            dismiss()
        } catch {
            working = false
            failure = (error as? LocalizedError)?.errorDescription ?? "Not işlenemedi."
        }
    }
}

/// The mic on a task's "Kaldığın yer" note: say where you are and the note is rewritten
/// from it (a step, a date or finishing said out loud are applied too).
struct NoteVoiceButton: View {
    @Environment(AppStore.self) private var store
    let task: TaskItem

    var body: some View {
        Button {
            store.voiceRequest = VoiceRequest(taskID: task.id, noteOnly: true)
        } label: {
            Image(systemName: "mic.fill")
                .foregroundStyle(Color.themeBrick)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Kaldığın yeri sesle yaz")
    }
}

/// "Sesli not · what changed · Geri al" for a few seconds after a voice note.
struct VoiceBanner: View {
    @Environment(AppStore.self) private var store
    let undo: VoiceUndo

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform")
                .foregroundStyle(Color.themeBrick)
                .accessibilityHidden(true)
            Text(undo.summary)
                .font(.subheadline)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if !undo.isEmpty {
                Button("Geri al") {
                    Task { await store.undoVoice() }
                }
                .font(.subheadline.weight(.semibold))
                .frame(minHeight: 44)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
        .task(id: undo.id) {
            try? await Task.sleep(for: .seconds(10))
            if store.lastVoice?.id == undo.id { store.lastVoice = nil }
        }
    }
}
