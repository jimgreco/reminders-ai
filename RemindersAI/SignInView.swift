import AuthenticationServices
import GoogleSignIn
import SwiftUI

struct SignInView: View {
    @Environment(Session.self) private var session

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "checklist")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            VStack(spacing: 8) {
                Text("Task Sidekick").font(.largeTitle.bold())
                Text("Your Apple Reminders, with an assistant that can work any item: it researches, asks you what it needs to know, and helps you finish.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            SignInWithAppleButton(.signIn) { request in
                request.requestedScopes = [.email]
            } onCompletion: { result in
                switch result {
                case .success(let authorization):
                    guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else { return }
                    Task { await session.signIn(with: credential) }
                case .failure(let error):
                    if (error as? ASAuthorizationError)?.code != .canceled {
                        session.lastError = error.localizedDescription
                    }
                }
            }
            .signInWithAppleButtonStyle(.whiteOutline)
            .frame(height: 50)

            Button(action: googleSignIn) {
                HStack(spacing: 8) {
                    Text("G").font(.title3.bold()).foregroundStyle(.blue)
                    Text("Sign in with Google").font(.title3.weight(.medium))
                }
                .frame(maxWidth: .infinity, minHeight: 50)
                .foregroundStyle(.primary)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.primary, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Sign in with Google")

            #if DEBUG
            Button("Local dev sign in") {
                Task { await session.devSignIn() }
            }
            .font(.footnote)
            #endif

            if let error = session.lastError {
                Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
            }
        }
        .padding(32)
    }

    private func googleSignIn() {
        guard GoogleConfig.clientID != nil else {
            session.lastError = "Google sign-in isn't set up in this build yet."
            return
        }
        guard let presenter = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .rootViewController else {
            session.lastError = "Couldn't show Google sign-in."
            return
        }
        GIDSignIn.sharedInstance.signIn(withPresenting: presenter) { result, error in
            Task { @MainActor in
                if let error {
                    if (error as NSError).code != GIDSignInError.canceled.rawValue {
                        session.lastError = error.localizedDescription
                    }
                    return
                }
                guard let token = result?.user.idToken?.tokenString else {
                    session.lastError = "Google didn't return a sign-in token. Try again."
                    return
                }
                await session.signInWithGoogle(idToken: token)
            }
        }
    }
}
