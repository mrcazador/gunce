import AVFoundation
import Speech
import SwiftUI

/// Speech to text in Turkish. Nothing is recorded: recognition runs on the phone where it
/// supports Turkish on-device (otherwise through Apple's speech service), and only the text
/// is used afterwards.
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

    func start() async {
        guard phase != .listening else { return }
        guard await Self.authorize() else {
            phase = .failed("Mikrofon ve konuşma tanıma izni gerekiyor. Ayarlar'dan PickUp için açabilirsin.")
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            phase = .failed("Konuşma tanıma şu an kullanılamıyor. Biraz sonra yeniden dene.")
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.addsPunctuation = true
            if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
            self.request = request

            let input = engine.inputNode
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0), block: Self.tap(request))
            engine.prepare()
            try engine.start()
            text = ""
            phase = .listening
            task = recognizer.recognitionTask(with: request, resultHandler: Self.handler { [weak self] text, done in
                Task { @MainActor in
                    guard let self else { return }
                    if let text { self.text = text }
                    if done, self.phase == .listening { self.stopAudio() }
                }
            })
        } catch {
            stopAudio()
            phase = .failed("Kayıt başlatılamadı.")
        }
    }

    /// Stops listening and waits a moment for the last words to come through.
    func finish() async -> String {
        request?.endAudio()
        stopAudio()
        try? await Task.sleep(for: .milliseconds(700))
        task?.finish()
        task = nil
        phase = .finished
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cancel() {
        task?.cancel()
        task = nil
        request?.endAudio()
        stopAudio()
        phase = .idle
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
    nonisolated private static func tap(_ request: SFSpeechAudioBufferRecognitionRequest) -> AVAudioNodeTapBlock {
        { buffer, _ in request.append(buffer) }
    }

    nonisolated private static func handler(
        _ update: @escaping @Sendable (String?, Bool) -> Void
    ) -> @Sendable (SFSpeechRecognitionResult?, (any Error)?) -> Void {
        { result, error in
            update(result?.bestTranscription.formattedString, error != nil || (result?.isFinal ?? false))
        }
    }

    nonisolated private static func authorize() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard speech == .authorized else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }
}

/// "Söyle": talk about what you did, where you left off or what came to mind; PickUp turns it
/// into tasks, steps, notes and reminders. Opens listening; one button finishes.
struct VoiceSheet: View {
    @Environment(AppStore.self) private var store
    /// The task the note is about, when opened from a task.
    var taskID: String? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dictation = Dictation()
    @State private var working = false
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
                    VStack(spacing: 10) {
                        ActionButton(title: "Görev olarak ekle", symbol: "tray.and.arrow.down", prominent: true) {
                            Task {
                                await store.capture(spoken)
                                dismiss()
                            }
                        }
                        ActionButton(title: "Tekrar dene", symbol: "arrow.clockwise") { Task { await send(spoken) } }
                    }
                } else if working {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Notun işleniyor…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 56)
                } else {
                    ActionButton(title: "Bitti", symbol: "checkmark", prominent: true) { Task { await done() } }
                        .accessibilityIdentifier("voice-done")
                        .disabled(dictation.text.isEmpty && dictation.phase == .listening)
                    Text("Ses kaydedilmez; yazıya dökülür. Görevlerini düzenlemek için yalnızca bu yazı Claude'a gönderilir.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.themeBackground)
            .navigationTitle(taskID.flatMap { store.tasks[$0]?.title } ?? "Söyle")
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
                Text(dictation.text.isEmpty ? "Dinliyorum… Ne yaptığını, nerede kaldığını ya da aklına geleni söyle." : dictation.text)
                    .font(.title3)
                    .foregroundStyle(dictation.text.isEmpty ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(dictation.text.isEmpty ? "Dinliyorum" : dictation.text)
            }
        }
    }

    private func done() async {
        let text = await dictation.finish()
        guard !text.isEmpty else {
            dismiss()
            return
        }
        await send(text)
    }

    private func send(_ text: String) async {
        spoken = text
        failure = nil
        working = true
        do {
            let plan = try await store.interpretVoice(text, taskID: taskID)
            await store.apply(plan)
            working = false
            dismiss()
        } catch {
            working = false
            failure = (error as? LocalizedError)?.errorDescription ?? "Not işlenemedi."
        }
    }
}

/// A mic that opens a voice note about one task: say the next steps, where you are, a date.
struct TaskVoiceButton: View {
    @Environment(AppStore.self) private var store
    let task: TaskItem

    var body: some View {
        Button {
            store.voiceRequest = VoiceRequest(taskID: task.id)
        } label: {
            Image(systemName: "mic.fill")
                .foregroundStyle(Color.themeBrick)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Bu göreve sesli not")
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
