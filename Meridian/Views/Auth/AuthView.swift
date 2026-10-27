import SwiftUI
import CoreImage.CIFilterBuiltins

// MARK: - QR rendering

/// Turns a `challenge_url` into QR modules with CoreImage. Local generation
/// (no network round-trip to a QR web service) keeps the challenge URL
/// private and works offline. `OnboardingQRCode` draws the modules.
enum QRCodeRenderer {
    /// Dark/light modules, row by row from the top, without the quiet zone
    /// CoreImage adds (the card's white margin is the quiet zone).
    static func modules(for string: String) -> [[Bool]]? {
        // CIFilter / CIContext are not Sendable, so they are created per call
        // (once per code, about every 30 s).
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }

        // One pixel per module at scale 1; read it back as 8-bit grey.
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 255, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        let grid = (0..<height).map { y in (0..<width).map { x in pixels[y * width + x] < 128 } }
        guard let top = grid.firstIndex(where: { $0.contains(true) }),
              let bottom = grid.lastIndex(where: { $0.contains(true) }),
              let left = (0..<width).first(where: { x in grid.contains { $0[x] } }),
              let right = (0..<width).last(where: { x in grid.contains { $0[x] } }) else { return nil }
        return grid[top...bottom].map { Array($0[left...right]) }
    }
}

// MARK: - Setup Sheet

/// Multi-step onboarding card that appears after bootstrap.
///
/// Steps: Welcome → Connect Meridian to Steam (Meridian's QR) → Sign in to Steam
/// (Steam's own sign-in, once; `OnlinePlayStepContent`) → API Key (if
/// needed) → Complete
///
/// "Connect Meridian to Steam" drives `SteamCredentialAuth`, Meridian's own
/// IAuthenticationService client: Valve returns a `persistence: 1`
/// refresh_token that DepotDownloader installs and the library use. Nothing
/// is written into Steam's own files (`makeSignInHandler`).
private let setupLog = MeridianLog(category: "SetupSheet")

struct SetupSheet: View {
    @Environment(SteamAuthService.self) private var steamAuth
    @Environment(SteamLibraryStore.self) private var library
    @Environment(SteamSession.self) private var session
    @Environment(WineEngine.self) private var engine

    /// Meridian's QR session, started on Welcome so the code is ready before
    /// "Connect Meridian to Steam" slides in.
    @State private var credentialAuth = SteamCredentialAuth()

    /// Closes the onboarding card (ContentView owns its presentation).
    var onFinish: () -> Void = {}

    private enum Step { case welcome, steamLogin, onlinePlay, apiKey, complete }
    @State private var step: Step = .welcome

    /// Steps shown in the page dots (Welcome has none).
    private var dotSteps: [Step] {
        [.steamLogin, .onlinePlay] + (steamAuth.needsAPIKey ? [.apiKey] : []) + [.complete]
    }

    private var afterOnlinePlay: Step { steamAuth.needsAPIKey ? .apiKey : .complete }

    private static let bottomInset: CGFloat = 28

    var body: some View {
        ZStack {
            Group {
                switch step {
                case .welcome:
                    welcomeStep
                case .steamLogin:
                    SteamLoginStepContent(
                        credentialAuth: credentialAuth,
                        onSkip: {
                            // User chose to skip sign-in — they can still browse with an API key.
                            step = afterOnlinePlay
                        },
                        onSignedIn: {
                            // Always offer Steam's own sign-in next. If Steam is
                            // already signed in, Connect finishes with no window.
                            step = .onlinePlay
                        }
                    )
                case .onlinePlay:
                    OnlinePlayStepContent(
                        onDone: { step = afterOnlinePlay },
                        onSkip: { step = afterOnlinePlay }
                    )
                case .apiKey:
                    APIKeyStepContent(onDone: { step = .complete })
                case .complete:
                    completeStep
                }
            }
            .padding(.horizontal, 40)
            .padding(.top, 40)
            .padding(.bottom, Self.bottomInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // One unit while sliding: content arriving mid-transition must
            // not animate apart from its page.
            .geometryGroup()
            .id(step)
            .transition(.asymmetric(
                insertion: .push(from: .trailing),
                removal: .push(from: .trailing).combined(with: .opacity)
            ))
        }
        // Page dots sit centred in the action bar, between the buttons.
        .overlay(alignment: .bottom) {
            if let index = dotSteps.firstIndex(of: step) {
                OnboardingStepDots(count: dotSteps.count, current: index)
                    .frame(height: OnboardingMetrics.actionBarHeight)
                    .padding(.bottom, Self.bottomInset)
                    .transition(.opacity)
            }
        }
        // 600 pt tall; shrinks to fit shorter windows (pages use spacers).
        .frame(width: 580)
        .frame(minHeight: 460, maxHeight: 600)
        .clipped()
        .animation(.smooth(duration: 0.45), value: step)
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
                credentialAuth.authenticateWithQR(onAuthenticated: makeSignInHandler(auth: steamAuth) {
                    step = .onlinePlay
                })
            }
        }
        .onDisappear { credentialAuth.cancel() }
    }

    // MARK: - Complete

    private var completeStep: some View {
        OnboardingPage("You're all set", subtitle: "Your library is loading. Pick a game and press Play.") {
            OnboardingCompleteHero()
        } content: {
            EmptyView()
        } actions: {
            Spacer()
            Button("Go to Library") {
                steamAuth.apiKeyPromptDismissed = true
                onFinish()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Welcome

    private var welcomeStep: some View {
        OnboardingPage("Welcome to Meridian",
                       subtitle: "Your Steam games, on your Mac. Setup takes three steps: two quick scans with the Steam Mobile App, then a Web API key.") {
            OnboardingLogoHero()
        } content: {
            EmptyView()
        } actions: {
            Spacer()
            Button("Get Started") { step = .steamLogin }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
    }
}

// MARK: - Steam Login step

private struct SteamLoginStepContent: View {
    /// Owned by `SetupSheet`, which starts the QR session on Welcome so the
    /// code is ready before this step slides in.
    let credentialAuth: SteamCredentialAuth
    let onSkip: () -> Void
    let onSignedIn: () -> Void

    @Environment(SteamSession.self) private var session
    @Environment(WineEngine.self) private var engine
    @Environment(SteamAuthService.self) private var steamAuth

    @State private var username = ""
    @State private var password = ""
    @State private var guardCode = ""
    @State private var isSigningIn = false
    @State private var errorMessage: String?

    /// QR is the primary, seamless path (scan + approve — no typing, no Steam
    /// window). Password is the fallback for users who prefer it or whose
    /// account can't use QR. Starts in QR mode.
    private enum Mode { case qr, password }
    @State private var mode: Mode = .qr

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

    /// The QR session ended without signing in (poll timeout, expired
    /// session, network error). The card offers a new code.
    private var qrEnded: Bool {
        credentialAuth.qrChallengeURL == nil && credentialAuth.step == .idle && credentialAuth.errorMessage != nil
    }

    private var instruction: String {
        switch mode {
        case .qr:
            if qrEnded, let error = credentialAuth.errorMessage { return error }
            return credentialAuth.qrScanned
                ? "Approve the sign-in in the Steam Mobile App."
                : "Meridian downloads your games straight from Steam. Scan the code with the Steam Mobile App."
        case .password:
            return "Your password is encrypted for Steam before it leaves your Mac, and kept in your Keychain."
        }
    }

    var body: some View {
        OnboardingPage("Connect Meridian to Steam", subtitle: instruction) {
            EmptyView()
        } content: {
            if mode == .qr {
                VStack(spacing: 18) {
                    OnboardingQRCard(
                        payload: credentialAuth.qrChallengeURL,
                        scanned: credentialAuth.qrScanned,
                        ended: qrEnded,
                        onNewCode: beginQRSignIn
                    )
                    Button("Sign in with password instead") {
                        credentialAuth.cancel()
                        mode = .password
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 13))
                }
                .transition(.opacity)
            } else {
                passwordContent
                    .transition(.opacity)
            }
        } actions: {
            actions
        }
        .animation(.smooth(duration: 0.3), value: credentialAuth.qrScanned)
        .animation(.smooth(duration: 0.3), value: qrEnded)
        .animation(.smooth(duration: 0.3), value: mode)
        .onAppear {
            let savedUsername = AppSettings.shared.steamCredentialAccountName
            if !savedUsername.isEmpty { username = savedUsername }
            if let saved = steamAuth.loadSteamPassword(), !saved.isEmpty { password = saved }
            // Normally already running (SetupSheet starts it on Welcome);
            // restarts a session that timed out while Welcome was showing.
            if mode == .qr { beginQRSignIn() }
        }
        .onDisappear {
            credentialAuth.cancel()
        }
    }

    // MARK: - Password content

    private var passwordContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !isSigningIn {
                credentialFields
            } else if awaitingTypedCode {
                guardCodeFields
            } else {
                signingInView
            }

            if let error = errorMessage ?? credentialAuth.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button("Use a QR code instead") {
                credentialAuth.cancel()
                isSigningIn = false
                mode = .qr
                beginQRSignIn()
            }
            .buttonStyle(.link)
            .font(.system(size: 13))
            .frame(maxWidth: .infinity)
        }
        .frame(width: 320)
    }

    // MARK: - Actions

    @ViewBuilder
    private var actions: some View {
        Button("Skip for now") {
            credentialAuth.cancel()
            isSigningIn = false
            onSkip()
        }
        .controlSize(.large)
        .keyboardShortcut(.cancelAction)

        Spacer()

        if mode == .password {
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
                .controlSize(.large)
            }
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

    /// Starts (or restarts) the QR sign-in session and wires the same
    /// post-auth handler the password flow uses. Idempotent — the underlying
    /// `authenticateWithQR` no-ops if a task is already running.
    private func beginQRSignIn() {
        errorMessage = nil
        credentialAuth.authenticateWithQR(onAuthenticated: makeOnAuthenticated())
    }

    private func beginSignIn() {
        errorMessage = nil
        isSigningIn = true

        // Persist password to Keychain so explicit re-auth flows (after a
        // refresh_token rotation, for example) can pre-fill the field.
        steamAuth.saveSteamPassword(password)

        let usr = username.trimmingCharacters(in: .whitespaces).lowercased()
        let pwd = password

        credentialAuth.authenticate(username: usr, password: pwd, onAuthenticated: makeOnAuthenticated())
    }

    /// The shared post-authentication handler used by BOTH the QR and password
    /// flows. Both yield the same `(steamID, accountName, refreshToken)` triple
    /// (QR guarantees `persistence: 1`; password uses `platform_type=1` for the
    /// same), so the downstream persistence + notification-prefs + advance is
    /// identical. Does NOT start steam.exe (Phase A: Steam is lazy; see the
    /// step 4 comment below and HANDOFF-2026-06-20).
    private func makeOnAuthenticated() -> @MainActor (String, String, String) async -> Void {
        makeSignInHandler(auth: steamAuth) {
            isSigningIn = false
            onSignedIn()
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

    var body: some View {
        OnboardingPage("Add your Web API key",
                       subtitle: "Your library, friends and achievements come from Steam's Web API, which needs a key from your account. It's free, takes about 30 seconds to get, and stays in your Keychain.") {
            EmptyView()
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                SecureField("Paste your API key", text: $apiKeyInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .controlSize(.large)
                    .onSubmit { Task { await save() } }
                if let url = URL(string: "https://steamcommunity.com/dev/apikey") {
                    Link("Get your key at steamcommunity.com/dev/apikey", destination: url)
                        .font(.system(size: 12))
                }
                if let error = validationError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: 340)
        } actions: {
            Button("Skip for now") {
                steamAuth.dismissAPIKeyPrompt()
                onDone()
            }
            .controlSize(.large)
            .keyboardShortcut(.cancelAction)

            Spacer()

            Button {
                Task { await save() }
            } label: {
                HStack(spacing: 6) {
                    if isValidating { ProgressView().controlSize(.small) }
                    Text(isValidating ? "Checking…" : "Save and Continue")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isValidating)
        }
        .animation(.smooth(duration: 0.2), value: validationError)
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
            validationError = "Couldn't verify the key. Check it's correct and your profile is public."
        }
    }
}

// MARK: - Sign-in handler

/// The post-authentication handler shared by the QR and password flows (and
/// by `SetupSheet`, which starts the QR session early). Both flows yield the
/// same `(steamID, accountName, refreshToken)` triple.
@MainActor
private func makeSignInHandler(
    auth: SteamAuthService,
    onDone: @escaping @MainActor () -> Void
) -> @MainActor (String, String, String) async -> Void {
    return { steamID, accountName, refreshToken in
        // 1. Persist the session: DepotDownloader installs and the
        //    library use it.
        let settings = AppSettings.shared
        settings.steamCredentialSteamID = steamID
        settings.steamCredentialAccountName = accountName
        settings.steamCredentialRefreshToken = refreshToken

        // 2. Nothing is written into Steam's own files (loginusers.vdf,
        //    local.vdf). Steam rejects a session Meridian creates (Pattern
        //    36), and a Meridian-written loginusers.vdf made
        //    hasSteamLoginSession() report a Steam session that didn't
        //    exist, so onboarding skipped Steam's own sign-in. Steam's
        //    session comes only from its own sign-in (Online Play step).

        // 3. Do NOT start steam.exe here. Starting steam.exe -silent at
        //    sign-in popped the Steam login/UI window AND poisoned the
        //    freshly-minted refresh token (CLI-verified Jun 20 2026,
        //    HANDOFF-2026-06-20). Steam is now lazy: it starts only for
        //    an Online-mode game launch (Phase A3), and the framed QR
        //    onboarding (Phase A1) is the one place Steam authenticates
        //    itself. Installs run headlessly via DepotDownloader on the
        //    persisted refresh_token, and DRM-free launches go direct —
        //    neither needs a running steam.exe.

        // 4. Update SteamAuthService → triggers SetupSheet advance.
        auth.setAuthenticatedFromCredentialFlow(steamID: steamID, accountName: accountName)
        setupLog.info("[signIn] ✅ steamID=\(steamID) needsAPIKey=\(auth.needsAPIKey)")
        onDone()
    }
}
