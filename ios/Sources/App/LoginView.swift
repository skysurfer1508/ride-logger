import SwiftUI

struct LoginView: View {
    @ObservedObject var auth: AuthService
    @State private var busy = false

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            HStack(spacing: 0) {
                Text("RIDE").foregroundStyle(Theme.text)
                Text("LOG").foregroundStyle(Theme.accent)
            }
            .font(.system(size: 46, weight: .bold).width(.condensed))
            .tracking(4)
            Text("Your rides, on your own server.").foregroundStyle(Theme.muted)
            Spacer()
            if let message = auth.error {
                Text(message).font(.footnote).foregroundStyle(Theme.danger).multilineTextAlignment(.center)
            }
            Button {
                busy = true
                Task {
                    await auth.signIn()
                    busy = false
                }
            } label: {
                Text(busy ? "Signing in…" : "Sign in").frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(busy)
            Text("You sign in with the same account as the website.").font(.caption).foregroundStyle(Theme.muted)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg.ignoresSafeArea())
    }
}
