import AuthenticationServices
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
                Text("Reminders AI").font(.largeTitle.bold())
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
}
