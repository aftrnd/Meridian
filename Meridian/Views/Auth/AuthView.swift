import SwiftUI

// MARK: - Setup Sheet

/// Multi-step onboarding sheet that appears after bootstrap.
///
/// Steps: Welcome → Steam Login → API Key → Complete
///
/// The Steam Login step drives SteamSession.signIn() — the ONLY place -login
/// is ever sent to steam.exe. The user expects to see 2FA here. Nowhere else.
private let setupLog = MeridianLog(category: "SetupSheet")

struct SetupSheet: View {
    @Environment(SteamAuthService.self) private var steamAuth
    @Environment(SteamLibraryStore.self) private var library
    @Environment(SteamSession.self) private var session
    @Environment(WineEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss

    private enum Step { case welcome, steamLogin, apiKey, complete }
    @State private var step: Step = .welcome

    var body: some View {
        Group {
            switch step {
            case .welcome:
                welcomeStep
            case .steamLogin:
                SteamLoginStepContent(
                    onSkip: {
                        // User chose to skip sign-in — they can still browse with an API key.
                        step = steamAuth.needsAPIKey ? .apiKey : .complete
                    },
                    onSignedIn: {
                        step = steamAuth.needsAPIKey ? .apiKey : .complete
                    }
                )
            case .apiKey:
                APIKeyStepContent(onDone: { step = .complete })
            case .complete:
                completeStep
            }
        }
        .animation(.easeInOut(duration: 0.25), value: step)
        .onAppear {
            if steamAuth.isAuthenticated && !session.isReady {
                step = .steamLogin
            } else if steamAuth.isAuthenticated && session.isReady {
                step = steamAuth.needsAPIKey ? .apiKey : .complete
            } else {
                step = .welcome
            }
        }
        .onChange(of: session.isReady) { _, ready in
            guard ready, step == .steamLogin else { return }
            let needs = steamAuth.needsAPIKey
            setupLog.info("[onboarding] session.isReady→true | needsAPIKey=\(needs)")
            step = needs ? .apiKey : .complete
        }
    }

    // MARK: - Complete

    private var completeStep: some View {
        VStack(spacing: 24) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 52))
                .foregroundStyle(.green)
                .symbolRenderingMode(.hierarchical)

            VStack(spacing: 8) {
                Text("You're ready to play.")
                    .font(.title2).fontWeight(.bold)
                Text("Your Steam library is syncing in the background.\nHead to your library to start playing.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button("Go to Library") {
                steamAuth.apiKeyPromptDismissed = true
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .keyboardShortcut(.defaultAction)
        }
        .padding(28)
        .frame(width: 460)
    }

    // MARK: - Welcome

    private var welcomeStep: some View {
        VStack(spacing: 28) {
            VStack(spacing: 14) {
                Image("MeridianLogo")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 100)
                    .foregroundStyle(.primary)

                Text("Welcome to Meridian")
                    .font(.title2).fontWeight(.bold)

                Text("Your full Steam library, natively on Mac.\nLet's get you set up in a few quick steps.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 12) {
                featureBullet(icon: "gamecontroller.fill",
                              text: "Browse and launch your full Steam library")
                featureBullet(icon: "lock.shield.fill",
                              text: "Authenticate directly with Steam — your password is saved to Keychain")
                featureBullet(icon: "bolt.fill",
                              text: "DirectX → Metal via DXMT for smooth, native-feeling performance")
            }
            .frame(maxWidth: 340)

            Button("Get Started") { step = .steamLogin }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .keyboardShortcut(.defaultAction)
        }
        .padding(28)
        .frame(width: 460)
    }

    private func featureBullet(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(.tint)
                .frame(width: 24, alignment: .center)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Steam Login step

private struct SteamLoginStepContent: View {
    let onSkip: () -> Void
    let onSignedIn: () -> Void

    @Environment(SteamSession.self) private var session
    @Environment(WineEngine.self) private var engine
    @Environment(SteamAuthService.self) private var steamAuth

    @State private var username = ""
    @State private var password = ""
    @State private var signInTask: Task<Void, Never>?
    @State private var isSigningIn = false
    @State private var errorMessage: String?

    private var canSignIn: Bool {
        !username.trimmingCharacters(in: .whitespaces).isEmpty
            && !password.isEmpty
            && !isSigningIn
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Sign in to Steam")
                    .font(.title2).fontWeight(.bold)
                Text("Meridian passes your credentials directly to Steam's own client running silently in the background. Your password is saved to Keychain for seamless re-authentication.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Adaptive content
            if !isSigningIn {
                credentialFields
            } else {
                signingInView
            }

            if let error = errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Skip for now") {
                    signInTask?.cancel()
                    isSigningIn = false
                    onSkip()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                if !isSigningIn {
                    Button("Sign In") { beginSignIn() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canSignIn)
                } else {
                    Button("Cancel") {
                        signInTask?.cancel()
                        isSigningIn = false
                    }
                }
            }
        }
        .padding(28)
        .frame(width: 460)
        .onAppear {
            let savedUsername = AppSettings.shared.steamCredentialAccountName
            if !savedUsername.isEmpty { username = savedUsername }
            if let saved = steamAuth.loadSteamPassword(), !saved.isEmpty { password = saved }
        }
        .onDisappear {
            signInTask?.cancel()
        }
    }

    private var credentialFields: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Username")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Steam username", text: $username)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.username)
                    .autocorrectionDisabled()
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Password")
                    .font(.caption).foregroundStyle(.secondary)
                SecureField("Steam password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.password)
                    .onSubmit { if canSignIn { beginSignIn() } }
            }
        }
    }

    /// Shown while steam.exe is doing the CM auth handshake.
    /// For Mobile Authenticator: Valve pushes an approval to the phone;
    /// user taps Approve; [Logged On,] arrives. No typed codes needed.
    private var signingInView: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "iphone.gen3")
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Check Steam Mobile")
                        .font(.callout).fontWeight(.semibold)
                    Text("If your account uses Steam Guard Mobile, open the Steam app on your phone and tap Approve.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.8)
                Text("Authenticating with Steam…")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
        }
    }

    private func beginSignIn() {
        errorMessage = nil
        isSigningIn = true

        // Persist password for seamless re-auth on prefix reset / ssfn expiry.
        steamAuth.saveSteamPassword(password)

        let usr = username.trimmingCharacters(in: .whitespaces).lowercased()
        let pwd = password
        let eng = engine
        let auth = steamAuth
        let advance = onSignedIn

        signInTask = Task {
            do {
                try await session.signIn(
                    username: usr,
                    password: pwd,
                    engine: eng
                ) { steamID, accountName in
                    // Write loginusers.vdf with AllowAutoLogin=1 so the next
                    // -silent cold start finds these flags and uses the ssfn token.
                    try? WinePrefix.defaultPrefix.writeLoginUsers(
                        steamID: steamID,
                        accountName: accountName,
                        personaName: accountName
                    )
                    auth.setAuthenticatedFromCredentialFlow(steamID: steamID, accountName: accountName)
                    setupLog.info("[signIn] ✅ steamID=\(steamID) needsAPIKey=\(auth.needsAPIKey)")
                    advance()
                }
            } catch is CancellationError {
                await MainActor.run { isSigningIn = false }
            } catch {
                await MainActor.run {
                    isSigningIn = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - API Key step

struct APIKeyStepContent: View {
    let onDone: () -> Void

    @Environment(SteamAuthService.self) private var steamAuth
    @Environment(SteamLibraryStore.self) private var library

    @State private var apiKeyInput    = ""
    @State private var isValidating   = false
    @State private var validationError: String?
    @State private var showingWhyInfo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Connect your library")
                    .font(.title2).fontWeight(.bold)

                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("Meridian needs your Steam Web API key to sync your game library.")
                        .foregroundStyle(.secondary)
                    Button { showingWhyInfo.toggle() } label: {
                        Image(systemName: "info.circle").foregroundStyle(.tint)
                    }
                    .buttonStyle(.plain)
                }
            }

            if showingWhyInfo {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Why an API key?", systemImage: "questionmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                    Text("Steam's sign-in proves who you are — it doesn't grant access to your game library. Valve requires a separate Web API key for that. It's free, takes about 30 seconds to get, and is stored only in your Mac's Keychain.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 8))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Steam Web API Key")
                    .font(.caption).foregroundStyle(.secondary)
                SecureField("Paste your API key here", text: $apiKeyInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                if let url = URL(string: "https://steamcommunity.com/dev/apikey") {
                    Link("Get your key at steamcommunity.com/dev/apikey →", destination: url)
                        .font(.caption)
                }
            }

            if let error = validationError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
            }

            HStack {
                Button("Skip for now") {
                    steamAuth.dismissAPIKeyPrompt()
                    onDone()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button {
                    Task { await save() }
                } label: {
                    HStack(spacing: 6) {
                        if isValidating { ProgressView().scaleEffect(0.7) }
                        Text(isValidating ? "Checking…" : "Save & Load Library")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isValidating)
            }
        }
        .padding(28)
        .frame(width: 460)
        .animation(.easeInOut(duration: 0.2), value: showingWhyInfo)
    }

    private func save() async {
        let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        isValidating = true
        validationError = nil
        defer { isValidating = false }
        do {
            _ = try await SteamAPIService.shared.fetchPlayerSummary(steamID: steamAuth.steamID, apiKey: key)
            steamAuth.apiKey = key
            await steamAuth.refreshProfile(steamID: steamAuth.steamID)
            await library.refresh(steamID: steamAuth.steamID, apiKey: key)
            steamAuth.apiKeyPromptDismissed = true
            onDone()
        } catch {
            validationError = "Couldn't verify the key — check it's correct and your profile is public."
        }
    }
}
