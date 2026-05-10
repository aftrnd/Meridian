import SwiftUI

// MARK: - Setup Sheet (Post-bootstrap onboarding)

/// Multi-step sheet that appears after the bootstrap pipeline completes.
///
/// Shown when:
///   • First launch — user has never signed into Wine Steam (isSteamLoggedIn = false)
///   • Re-auth     — Wine session expired after extended use
///   • API key missing — user skipped it previously
///
/// Steps (in order):
///   1. Welcome   — branding + "Get Started" (only for first-time users)
///   2. Steam Login — native credential auth via IAuthenticationService
///   3. API Key   — syncs the game library
private let setupLog = MeridianLog(category: "SetupSheet")

struct SetupSheet: View {
    @Environment(SteamAuthService.self)      private var steamAuth
    @Environment(SteamLibraryStore.self)     private var library
    @Environment(WineSteamManager.self)      private var steamManager
    @Environment(WineEngine.self)            private var engine
    @Environment(SteamWindowSuppressor.self) private var suppressor
    @Environment(\.dismiss)                 private var dismiss

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
                        // Skipping login means we can't launch games, but the user
                        // may still want to browse their library with an API key.
                        // Only mark login as done — do NOT dismiss the API key step.
                        steamManager.isSteamLoggedIn = true
                        step = steamAuth.needsAPIKey ? .apiKey : .complete
                    },
                    onSignedIn: {
                        if steamAuth.needsAPIKey {
                            step = .apiKey
                        } else {
                            step = .complete
                        }
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
            // Returning users who just need re-auth skip the welcome screen.
            // First-time users (!isAuthenticated) always see the welcome.
            if steamAuth.isAuthenticated && !steamManager.isSteamLoggedIn {
                step = .steamLogin
            } else if steamAuth.isAuthenticated && steamManager.isSteamLoggedIn {
                step = .apiKey
            } else {
                step = .welcome
            }
        }
        // Primary step-advancement driver: when isSteamLoggedIn transitions to
        // true, advance from steamLogin → apiKey (or complete if key already set).
        // This is more reliable than a closure captured in an async callback,
        // because SwiftUI evaluates it within its own render cycle with fully
        // settled state — no timing or stale-capture issues.
        .onChange(of: steamManager.isSteamLoggedIn) { _, loggedIn in
            guard loggedIn, step == .steamLogin else { return }
            let needs = steamAuth.needsAPIKey
            setupLog.info("[onboarding] isSteamLoggedIn→true | needsAPIKey=\(needs) → step=\(needs ? "apiKey" : "complete")")
            step = needs ? .apiKey : .complete
        }
    }

    // MARK: - Complete step

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
                steamManager.isSteamLoggedIn = true
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

    // MARK: - Welcome step

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

            // Quick-glance feature bullets — centered within the content column
            VStack(alignment: .leading, spacing: 12) {
                featureBullet(icon: "gamecontroller.fill",
                              text: "Browse and launch your full Steam library")
                featureBullet(icon: "lock.shield.fill",
                              text: "Authenticate directly with Steam — your password is never stored here")
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

    @Environment(WineSteamManager.self)  private var steamManager
    @Environment(WineEngine.self)        private var engine
    @Environment(SteamAuthService.self)  private var steamAuth

    @State private var signIn    = SteamExeSignIn()
    @State private var username  = ""
    @State private var password  = ""

    private var canSignIn: Bool {
        !username.trimmingCharacters(in: .whitespaces).isEmpty
            && !password.isEmpty
            && signIn.step == .idle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Header
            VStack(alignment: .leading, spacing: 8) {
                Text("Sign in to Steam")
                    .font(.title2).fontWeight(.bold)
                Text("Meridian passes your credentials directly to Steam's own client running silently in the background. Your password is saved to Keychain for seamless re-authentication.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Adaptive content based on auth step
            switch signIn.step {
            case .idle:
                credentialFields

            case .startingSteam:
                centeredStatus(icon: "gear", message: "Preparing Steam…")

            case .sendingCredentials:
                centeredStatus(icon: "lock.rotation", message: "Signing in to Steam…")

            case .awaitingResult:
                awaitingResultView

            case .done:
                EmptyView()
            }

            // Error
            if let error = signIn.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Action row
            HStack {
                Button("Skip for now") {
                    signIn.cancel()
                    onSkip()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                switch signIn.step {
                case .idle:
                    Button("Sign In") { beginSignIn() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canSignIn)

                default:
                    Button("Cancel") { signIn.cancel() }
                }
            }
        }
        .padding(28)
        .frame(width: 460)
        .onAppear {
            // Pre-fill credentials from previous session (Pattern 8 — seamless re-auth)
            let savedUsername = AppSettings.shared.steamCredentialAccountName
            if !savedUsername.isEmpty { username = savedUsername }
            if let saved = steamAuth.loadSteamPassword(), !saved.isEmpty { password = saved }
        }
        .onDisappear { signIn.cancel() }
    }

    // MARK: - Credential fields

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

    // MARK: - Awaiting result view

    /// Shown while steam.exe is performing the CM auth handshake.
    /// For Mobile Confirmation accounts: Valve pushes an approval to the
    /// Steam Mobile app; user taps Approve; `[Logged On, ` arrives. No
    /// typed codes needed — Steam handles it silently.
    private var awaitingResultView: some View {
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

    // MARK: - Centered status

    private func centeredStatus(icon: String, message: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().scaleEffect(0.85)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 6)
    }

    // MARK: - Sign-in action

    private func beginSignIn() {
        signIn.reset()
        let prefix  = WinePrefix.defaultPrefix
        let eng     = engine
        let mgr     = steamManager
        let auth_   = steamAuth
        let advance = onSignedIn

        // Persist credentials for seamless re-auth on prefix reset / ssfn expiry.
        auth_.saveSteamPassword(password)

        signIn.authenticate(
            username: username,
            password: password,
            engine: eng,
            prefix: prefix,
            steamManager: mgr
        ) { steamID, accountName in
            // steam.exe -login has completed and is still running. Write loginusers.vdf
            // with AllowAutoLogin=1 + RememberPassword=1 NOW so the next -silent launch
            // finds these flags and auto-logins via the ssfn token Steam just wrote.
            try? prefix.writeLoginUsers(steamID: steamID, accountName: accountName, personaName: accountName)

            AppSettings.shared.steamCredentialSteamID      = steamID
            AppSettings.shared.steamCredentialAccountName  = accountName
            // Clear the stale JWT refresh token — auth is now ssfn-based.
            AppSettings.shared.steamCredentialRefreshToken  = ""
            AppSettings.shared.steamSelfManagedSession      = true

            auth_.setAuthenticatedFromCredentialFlow(steamID: steamID, accountName: accountName)
            mgr.isSteamLoggedIn = true
            let needs = auth_.needsAPIKey
            setupLog.info("[beginSignIn] ✅ signed in via steam.exe -login | steamID=\(steamID) needsAPIKey=\(needs)")
            advance()
        }
    }
}

// MARK: - API Key step

struct APIKeyStepContent: View {
    let onDone: () -> Void

    @Environment(SteamAuthService.self)   private var steamAuth
    @Environment(SteamLibraryStore.self)  private var library

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
                    Button {
                        showingWhyInfo.toggle()
                    } label: {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.tint)
                    }
                    .buttonStyle(.plain)
                    .help("Why is an API key needed?")
                }
            }

            if showingWhyInfo {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Why an API key?", systemImage: "questionmark.circle.fill")
                        .font(.subheadline.weight(.semibold))

                    Text("Steam's sign-in proves who you are — it doesn't grant access to your game library. Valve requires a separate Web API key for that. It's free, takes about 30 seconds to get, and is stored only in your Mac's Keychain.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 8))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Steam Web API Key")
                    .font(.caption)
                    .foregroundStyle(.secondary)

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
                    .font(.caption)
                    .foregroundStyle(.red)
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
            _ = try await SteamAPIService.shared.fetchPlayerSummary(
                steamID: steamAuth.steamID, apiKey: key
            )
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
