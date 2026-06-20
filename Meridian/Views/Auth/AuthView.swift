import SwiftUI

// MARK: - Setup Sheet

/// Multi-step onboarding sheet that appears after bootstrap.
///
/// Steps: Welcome → Steam Login → API Key → Complete
///
/// The Steam Login step drives `SteamCredentialAuth.authenticate()` — Meridian's
/// own IAuthenticationService client. Credentials go directly to Valve's REST API
/// over HTTPS; Valve returns a `refresh_token` with `persistence: 1`. Meridian then
/// DPAPI-injects that token into the prefix's `local.vdf` via the bundled
/// `meridian-dpapi.exe` Wine helper, and starts `steam.exe -silent` — Steam reads
/// the freshly-written `local.vdf`, decrypts it with the same Wine `crypt32.dll`
/// that wrote it, and silently auto-logs in.
///
/// `steam.exe -login USER PASS` is NOT used. CLI-verified May 19 2026: that path
/// produced `persistence: 0` access-only JWTs, which Steam refused to persist to
/// `local.vdf` → every cold start re-prompted for credentials. The OAuth +
/// `IAuthenticationService` path is the only one that yields `persistence: 1`.
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
            // Onboarding gates on IDENTITY only, never on steam.exe readiness.
            // Steam is lazy + DRM-only (Phase 3, HANDOFF-2026-06-19) and is not
            // started on boot, so `session.isReady` is normally false for an
            // already-authenticated returning user. Gating on it would wrongly
            // push such a user back to the Steam login step when the sheet
            // re-appears (e.g. to enter a Web API key). A user with a persisted
            // OAuth identity is past sign-in — send them straight to the API
            // key step or completion.
            if steamAuth.isAuthenticated {
                step = steamAuth.needsAPIKey ? .apiKey : .complete
            } else {
                step = .welcome
            }
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

    @State private var credentialAuth = SteamCredentialAuth()
    @State private var username = ""
    @State private var password = ""
    @State private var guardCode = ""
    @State private var isSigningIn = false
    @State private var errorMessage: String?

    private var canSignIn: Bool {
        !username.trimmingCharacters(in: .whitespaces).isEmpty
            && !password.isEmpty
            && !isSigningIn
    }

    /// True while Valve is waiting for the user to type a Steam Guard code
    /// (email Steam Guard, or a TOTP from the mobile authenticator app).
    private var awaitingTypedCode: Bool {
        if case .awaitingGuardCode(let t) = credentialAuth.step {
            return t == .emailCode || t == .deviceCode
        }
        return false
    }

    private var guardCodeType: SteamCredentialAuth.GuardType? {
        if case .awaitingGuardCode(let t) = credentialAuth.step { return t }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Sign in to Steam")
                    .font(.title2).fontWeight(.bold)
                Text("Meridian authenticates directly with Steam's servers. Your password is encrypted with Valve's public key in transit, then saved to Keychain for seamless re-authentication.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Adaptive content
            if !isSigningIn {
                credentialFields
            } else if awaitingTypedCode {
                guardCodeFields
            } else {
                signingInView
            }

            if let error = errorMessage ?? credentialAuth.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Skip for now") {
                    credentialAuth.cancel()
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
                } else if awaitingTypedCode {
                    Button("Submit") { submitGuardCode() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                        .disabled(guardCode.trimmingCharacters(in: .whitespaces).isEmpty)
                } else {
                    Button("Cancel") {
                        credentialAuth.cancel()
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
            credentialAuth.cancel()
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

    /// Shown while SteamCredentialAuth is polling Valve's auth servers.
    /// For Mobile Authenticator accounts: Valve pushes an approval to the phone;
    /// user taps Approve; polling picks up the new refresh_token. No typed codes.
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

    /// Shown when Valve demands a typed Steam Guard code instead of (or in
    /// addition to) a mobile-app push. emailCode = 5-digit email code;
    /// deviceCode = 5-digit TOTP from the Steam Mobile authenticator.
    private var guardCodeFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: guardCodeType == SteamCredentialAuth.GuardType.emailCode ? "envelope" : "key.horizontal")
                    .foregroundStyle(.tint)
                Text(guardCodeType == SteamCredentialAuth.GuardType.emailCode ? "Enter the code sent to your email" : "Enter the code from your Steam Mobile app")
                    .font(.callout).fontWeight(.semibold)
            }
            TextField("Steam Guard code", text: $guardCode)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .textContentType(.oneTimeCode)
                .autocorrectionDisabled()
                .onSubmit { submitGuardCode() }
        }
    }

    private func beginSignIn() {
        errorMessage = nil
        isSigningIn = true

        // Persist password to Keychain so explicit re-auth flows (after a
        // refresh_token rotation, for example) can pre-fill the field.
        steamAuth.saveSteamPassword(password)

        let usr = username.trimmingCharacters(in: .whitespaces).lowercased()
        let pwd = password
        let eng = engine
        let auth = steamAuth
        let advance = onSignedIn

        credentialAuth.authenticate(username: usr, password: pwd) { steamID, accountName, refreshToken in
            // 1. Persist tokens to UserDefaults — used by BootstrapManager to
            //    re-inject local.vdf on every subsequent cold start.
            let settings = AppSettings.shared
            settings.steamCredentialSteamID = steamID
            settings.steamCredentialAccountName = accountName
            settings.steamCredentialRefreshToken = refreshToken

            // 2. Write loginusers.vdf — AllowAutoLogin=1 + RememberPassword=1
            //    so Steam's own UI also auto-logs in if it ever appears.
            try? WinePrefix.defaultPrefix.writeLoginUsers(
                steamID: steamID,
                accountName: accountName,
                personaName: accountName
            )

            // 3. DPAPI-inject local.vdf using the refresh_token. This is the
            //    file Steam reads on startup for silent auto-login. See
            //    WinePrefix.writeSteamSessionLocalVdf for the encryption
            //    contract (Wine CryptProtectData, "BObfuscateBuffer", crc32
            //    key, accountName entropy).
            do {
                try await WinePrefix.defaultPrefix.writeSteamSessionLocalVdf(
                    engine: eng,
                    steamID: steamID,
                    accountName: accountName,
                    refreshToken: refreshToken
                )
                setupLog.info("[signIn] DPAPI local.vdf written ✓")
            } catch {
                await MainActor.run {
                    errorMessage = "Could not write Steam session: \(error.localizedDescription)"
                    isSigningIn = false
                }
                return
            }

            // 3b. Pre-write per-user webhelper notification toggles BEFORE
            //     Steam starts. Steam reads `userdata/<accountID>/config/
            //     localconfig.vdf` at post-login hydration and merges its
            //     in-memory state with the file on disk. Writing the
            //     suppression keys ahead of `steam.exe -silent` means the
            //     "X is installed" / "Download complete" toast burst that
            //     Steam fires immediately after a fresh sign-in is silenced
            //     before the first toast can render. Pairs with the
            //     `NotifyAvailableGames=0` HKCU registry key written by
            //     `SteamSession.configureSteamRegistry` for the native-UI
            //     side. Both layers are needed.
            do {
                try WinePrefix.defaultPrefix.writeUserNotificationPreferences(steamID64: steamID)
                setupLog.info("[signIn] notification preferences pre-written ✓")
            } catch {
                setupLog.warning("[signIn] could not pre-write notification prefs: \(error.localizedDescription)")
            }

            // 4. Snapshot the freshly-written local.vdf to AppSupport backup
            //    so prefix-reset survival works on next cold start.
            SteamSessionBackup.snapshot(prefix: WinePrefix.defaultPrefix)

            // 5. Kill any prior steam.exe (orphan or previous unauth attempt)
            //    and start a clean steam.exe -silent. Steam reads local.vdf
            //    and auto-logs in.
            await session.shutdown(engine: eng)
            await session.start(engine: eng)

            // 6. Update SteamAuthService → triggers SetupSheet advance.
            auth.setAuthenticatedFromCredentialFlow(steamID: steamID, accountName: accountName)
            setupLog.info("[signIn] ✅ steamID=\(steamID) needsAPIKey=\(auth.needsAPIKey)")
            isSigningIn = false
            advance()
        }
    }

    private func submitGuardCode() {
        let code = guardCode.trimmingCharacters(in: .whitespaces)
        guard !code.isEmpty else { return }
        credentialAuth.submitGuardCode(code)
        guardCode = ""
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
