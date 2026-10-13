import AuthenticationServices
import SwiftUI

struct SignInView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var colorScheme
    @State private var nonce = ""
    @State private var isWorking = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "bookmark.fill")
                .font(.system(size: 56))
                .accessibilityHidden(true)
            VStack(spacing: 8) {
                Text("PickUp")
                    .font(.largeTitle.bold())
                Text("Kaldığın yeri hiç kaybetme.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            Spacer()

            if !store.isConfigured {
                Text("Sunucu adresi ayarlı değil. Bu sürüm giriş yapamaz.")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            SignInWithAppleButton(.signIn) { request in
                nonce = AppleNonce.random()
                request.requestedScopes = []
                request.nonce = AppleNonce.sha256(nonce)
            } onCompletion: { result in
                handle(result)
            }
            .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
            .frame(height: 50)
            .disabled(isWorking || !store.isConfigured)

            if isWorking {
                ProgressView()
            }
        }
        .padding(24)
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
            if (error as? ASAuthorizationError)?.code != .canceled {
                store.errorMessage = error.localizedDescription
            }
        }
    }
}
