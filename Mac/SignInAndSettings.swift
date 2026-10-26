import AuthenticationServices
import SwiftUI
import UserNotifications

struct MacSignInView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var colorScheme
    @State private var nonce = ""
    @State private var isWorking = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "bookmark.fill")
                .font(.system(size: 48))
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text("PickUp")
                    .font(.largeTitle.bold())
                Text("Kaldığın yeri hiç kaybetme.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            if !store.isConfigured {
                Text("Sunucu adresi ayarlı değil. Bu sürüm giriş yapamaz.")
                    .foregroundStyle(.red)
            }
            SignInWithAppleButton(.signIn) { request in
                nonce = AppleNonce.random()
                request.requestedScopes = [.fullName, .email]
                request.nonce = AppleNonce.sha256(nonce)
            } onCompletion: { result in
                handle(result)
            }
            .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
            .frame(width: 260, height: 44)
            .disabled(isWorking || !store.isConfigured)
            Text("iPhone'daki hesabınla giriş yap; görevlerin aynı.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if isWorking { ProgressView() }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert(
            "Giriş yapılamadı",
            isPresented: Binding(
                get: { store.errorMessage != nil },
                set: { if !$0 { store.errorMessage = nil } }
            )
        ) {
            Button("Tamam", role: .cancel) {}
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    private func handle(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let data = credential.identityToken,
                  let token = String(data: data, encoding: .utf8)
            else {
                store.errorMessage = "Apple kimliği alınamadı."
                return
            }
            let rawNonce = nonce
            isWorking = true
            Task {
                await store.signIn(identityToken: token, nonce: rawNonce)
                isWorking = false
            }
        case .failure(let error):
            if (error as? ASAuthorizationError)?.code == .canceled { return }
            store.errorMessage = error.localizedDescription
        }
    }
}

/// PickUp → Ayarlar (⌘,).
struct MacSettingsView: View {
    @Environment(AppStore.self) private var store
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    @State private var testsSent = 0

    var body: some View {
        Form {
            Section("Bağlantılar") {
                LabeledContent("Bildirimler") {
                    switch notificationStatus {
                    case .authorized, .provisional:
                        Button(testsSent == 0 ? "Deneme bildirimi gönder" : "5 saniye içinde gelecek") {
                            Task {
                                await Reminders.sendTest()
                                testsSent += 1
                            }
                        }
                    case .denied:
                        Text("Sistem Ayarları → Bildirimler'den aç")
                            .foregroundStyle(.secondary)
                    default:
                        Button("İzin ver") {
                            Task {
                                await Reminders.requestPermission()
                                notificationStatus = await Reminders.status()
                                store.tasksChanged()
                            }
                        }
                    }
                }
                Toggle("Apple Takvim ile eşitle", isOn: Binding(
                    get: { store.calendarSyncEnabled },
                    set: { on in
                        if on {
                            Task { await store.enableCalendarSync() }
                        } else {
                            store.calendarSyncEnabled = false
                        }
                    }
                ))
            }
            Section("Hesap") {
                if store.isSignedIn {
                    Button("Çıkış yap") { Task { await store.signOut() } }
                } else {
                    Text("Giriş yapılmadı").foregroundStyle(.secondary)
                }
            }
            ConnectionTestSection()

            Section {
                LabeledContent("Sürüm", value: version)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .task { notificationStatus = await Reminders.status() }
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
