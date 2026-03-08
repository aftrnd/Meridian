import SwiftUI
import AuthenticationServices

/// Shown before the user has signed in.
struct AuthView: View {
    @Environment(SteamAuthService.self) private var steamAuth

    var body: some View {
        VStack(spacing: 40) {
            Spacer()

            VStack(spacing: 16) {
                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: 64, weight: .thin))
                    .foregroundStyle(.tint)
                    .symbolRenderingMode(.hierarchical)

                Text("Meridian")
                    .font(.system(size: 44, weight: .bold, design: .rounded))

                Text("Play your Windows games natively on Mac\nvia Proton — no compromises.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 12) {
                Button {
                    Task { await steamAuth.signIn() }
                } label: {
                    HStack(spacing: 10) {
                        if steamAuth.isAuthenticating {
                            ProgressView().scaleEffect(0.8)
                        } else {
                            Image(systemName: "person.badge.key.fill")
                        }
                        Text(steamAuth.isAuthenticating ? "Opening Steam…" : "Sign in with Steam")
                            .fontWeight(.semibold)
                    }
                    .frame(width: 260)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(steamAuth.isAuthenticating)

                if let error = steamAuth.authError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                Text("Sign in once to access your library and play games.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text("Meridian uses Steam OpenID — your password is never entered here.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - API Key Setup Sheet

/// Shown once after the user has signed in and no API key is stored yet.
/// Attached to ContentView's authenticated branch — never to AuthView —
/// so SwiftUI never tries to present it on a view that is being removed.
struct APIKeySetupSheet: View {
    @Environment(SteamAuthService.self) private var steamAuth
    @Environment(SteamLibraryStore.self) private var library

    @State private var apiKeyInput: String = ""
    @State private var isValidating = false
    @State private var validationError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {

            VStack(alignment: .leading, spacing: 8) {
                Text("One more thing…")
                    .font(.title2).fontWeight(.bold)

                Text("Meridian needs your Steam Web API key to load your library. This is a one-time step — the key is stored securely in your Mac's Keychain.")
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Steam Web API Key")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                SecureField("Paste your API key here", text: $apiKeyInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))

                if let url = URL(string: "https://steamcommunity.com/dev/apikey") {
                    Link("Get your key at steamcommunity.com/dev/apikey", destination: url)
                        .font(.caption)
                }
            }

            if let error = validationError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Skip for now") {
                    steamAuth.dismissAPIKeyPrompt()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Spacer()

                Button {
                    Task { await save() }
                } label: {
                    HStack(spacing: 6) {
                        if isValidating { ProgressView().scaleEffect(0.7) }
                        Text(isValidating ? "Checking…" : "Save & Load Library")
                            .fontWeight(.semibold)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isValidating)
            }
        }
        .padding(28)
        .frame(width: 440)
    }

    private func save() async {
        let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }

        isValidating = true
        validationError = nil
        defer { isValidating = false }

        do {
            _ = try await SteamAPIService.shared.fetchPlayerSummary(
                steamID: steamAuth.steamID, apiKey: key
            )
            steamAuth.apiKey = key
            await steamAuth.refreshProfile(steamID: steamAuth.steamID)
            await library.refresh(steamID: steamAuth.steamID, apiKey: key)
            steamAuth.apiKeyPromptDismissed = true
        } catch {
            validationError = "Couldn't verify the key — check it's correct and your profile is public."
        }
    }
}

#Preview {
    AuthView()
        .environment(SteamAuthService())
        .frame(width: 640, height: 500)
}
