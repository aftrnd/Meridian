import SwiftUI
import AppKit

struct SettingsView: View {
    @Environment(SteamAuthService.self) private var steamAuth
    @Environment(WineEngine.self) private var engine
    @Environment(SteamWindowSuppressor.self) private var suppressor
    @Environment(AppUpdateChecker.self) private var updateChecker

    var body: some View {
        TabView {
            SteamSettingsTab()
                .tabItem { Label("Steam", systemImage: "person.badge.key") }

            EngineSettingsTab()
                .tabItem { Label("Engine", systemImage: "gearshape.2") }

            PermissionsSettingsTab()
                .tabItem { Label("Permissions", systemImage: "hand.raised") }

            UpdatesSettingsTab()
                .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
        }
        .frame(width: 520)
        .padding(24)
    }
}

// MARK: - Steam tab

private struct SteamSettingsTab: View {
    @Environment(SteamAuthService.self) private var steamAuth
    @Environment(SteamLibraryStore.self) private var library
    @State private var apiKeyInput: String = ""
    @State private var isValidating = false
    @State private var validationMessage: String?
    @State private var validationSuccess = false

    var body: some View {
        Form {
            Section("Account") {
                if steamAuth.isAuthenticated {
                    HStack {
                        AsyncImage(url: steamAuth.avatarURL) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Image(systemName: "person.circle.fill").foregroundStyle(.secondary)
                        }
                        .frame(width: 36, height: 36)
                        .clipShape(Circle())

                        VStack(alignment: .leading, spacing: 2) {
                            Text(steamAuth.displayName)
                                .fontWeight(.medium)
                            Text("ID: \(steamAuth.steamID)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button("Sign Out", role: .destructive) {
                            steamAuth.signOut()
                        }
                        .buttonStyle(.bordered)
                    }
                } else {
                    Text("Not signed in.")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Library") {
                @Bindable var library = library
                Toggle("Show Hidden Games", isOn: $library.showHiddenGames)
                Text("Hidden games are still tracked — they just won't appear in your library.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                SecureField("Paste your Steam Web API key", text: $apiKeyInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onAppear { apiKeyInput = steamAuth.apiKey }

                HStack {
                    Link("Get a key at steamcommunity.com/dev/apikey",
                         destination: URL(string: "https://steamcommunity.com/dev/apikey")!)
                        .font(.caption)

                    Spacer()

                    Button {
                        Task { await validateAndSave() }
                    } label: {
                        HStack(spacing: 5) {
                            if isValidating { ProgressView().scaleEffect(0.7) }
                            Text(isValidating ? "Checking…" : "Save")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(
                        apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isValidating
                    )
                }

                if let msg = validationMessage {
                    Label(msg, systemImage: validationSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(validationSuccess ? .green : .red)
                }
            } header: {
                Text("Steam Web API Key")
            } footer: {
                Text("Required to load your game library. Stored securely in Keychain.")
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
    }

    private func validateAndSave() async {
        let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, steamAuth.isAuthenticated else { return }

        isValidating = true
        validationMessage = nil
        defer { isValidating = false }

        do {
            _ = try await SteamAPIService.shared.fetchPlayerSummary(
                steamID: steamAuth.steamID, apiKey: key
            )
            steamAuth.apiKey = key
            await steamAuth.refreshProfile(steamID: steamAuth.steamID)
            validationSuccess = true
            validationMessage = "Key verified — library will refresh automatically."
        } catch {
            validationSuccess = false
            validationMessage = "Couldn't verify key. Check it's correct and your profile is public."
        }
    }
}

// MARK: - Engine tab

private struct EngineSettingsTab: View {
    @Environment(WineEngine.self) private var engine
    @Environment(WineSteamManager.self) private var steamManager
    private let settings = AppSettings.shared
    @State private var showAdvanced = false
    @State private var showResetConfirm = false

    var body: some View {
        Form {
            Section {
                EngineStatusRow(engine: engine)
            } header: {
                Text("Runtime")
            } footer: {
                Text("Open-source components: Wine (LGPL), DXMT, MoltenVK. No third-party apps required.")
                    .font(.caption)
            }

            Section("Display") {
                Toggle("Metal Performance HUD", isOn: Binding(
                    get: { settings.metalHUD },
                    set: { settings.metalHUD = $0 }
                ))
                Text("Shows GPU frame rate and statistics overlay during gameplay.")
                    .font(.caption).foregroundStyle(.secondary)

                Toggle("Force Virtual Desktop", isOn: Binding(
                    get: { settings.useVirtualDesktop },
                    set: { settings.useVirtualDesktop = $0 }
                ))
                Text("Run games inside a Wine virtual desktop at a fixed resolution instead of native windowed mode.")
                    .font(.caption).foregroundStyle(.secondary)

                if settings.useVirtualDesktop {
                    HStack {
                        TextField("Width", value: Binding(
                            get: { settings.virtualDesktopWidth },
                            set: { settings.virtualDesktopWidth = $0 }
                        ), format: .number)
                        .frame(width: 80)
                        Text("x")
                        TextField("Height", value: Binding(
                            get: { settings.virtualDesktopHeight },
                            set: { settings.virtualDesktopHeight = $0 }
                        ), format: .number)
                        .frame(width: 80)
                    }
                    .textFieldStyle(.roundedBorder)
                }
            }

            Section {
                DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("Engine repo slug", text: Binding(
                            get: { settings.engineRepoSlug },
                            set: { settings.engineRepoSlug = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        Text("Format: owner/repo. GitHub repository for Wine runtime releases.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                }
            }

            Section {
                Button("Reset Meridian…", role: .destructive) {
                    showResetConfirm = true
                }
                .buttonStyle(.bordered)
            } header: {
                Text("Troubleshooting")
            } footer: {
                Text("Removes the Wine engine and Steam prefix. The next launch will download a fresh engine and reinstall Steam automatically.")
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Reset Meridian?",
            isPresented: $showResetConfirm,
            titleVisibility: .visible
        ) {
            Button("Reset Everything", role: .destructive) {
                let prefix = WinePrefix.defaultPrefix
                steamManager.killAll(engine: engine, prefix: prefix)
                prefix.reset()
                engine.resetEngine()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will delete the Wine engine and Steam installation. All settings are preserved. The next app launch will download a fresh engine and reinstall Steam.")
        }
    }
}

// MARK: - Permissions tab

private struct PermissionsSettingsTab: View {
    @Environment(SteamWindowSuppressor.self) private var suppressor

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: suppressor.isPermissionGranted
                          ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                        .font(.title2)
                        .foregroundStyle(suppressor.isPermissionGranted ? .green : .orange)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Accessibility")
                            .fontWeight(.medium)
                        Text(suppressor.isPermissionGranted
                             ? "Granted — Steam windows will be suppressed automatically."
                             : "Not granted — Steam UI may appear during installs and launches.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if suppressor.isPermissionGranted {
                        Label("Granted", systemImage: "checkmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(.green)
                    } else {
                        Button("Grant Access") {
                            suppressor.requestPermission()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
            } header: {
                Text("macOS Permissions")
            } footer: {
                Text("Accessibility permission allows Meridian to minimize Steam's windows automatically, keeping Steam running silently in the background. If the prompt does not appear, open System Settings → Privacy & Security → Accessibility and enable Meridian manually.")
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Updates tab

private struct UpdatesSettingsTab: View {
    @Environment(WineEngine.self) private var engine
    @Environment(AppUpdateChecker.self) private var updateChecker
    @Environment(EngineDownloader.self) private var engineDownloader
    private let settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                LabeledContent("Meridian") {
                    Text(fullVersionString)
                        .foregroundStyle(.secondary)
                        .font(.system(.body, design: .monospaced))
                }
                LabeledContent("Wine Engine") {
                    Text(engineVersionString)
                        .foregroundStyle(.secondary)
                        .font(.system(.body, design: .monospaced))
                }
            } header: {
                Text("Installed")
            }

            Section {
                HStack(alignment: .center) {
                    updateStatusLabel
                    Spacer()
                    Button(updateChecker.state == .checking ? "Checking…" : "Check for Updates") {
                        updateChecker.installedEngineTag = engine.engineVersion
                        updateChecker.checkNow()
                    }
                    .disabled(updateChecker.state == .checking)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if let last = settings.lastUpdateCheck {
                    Text("Last checked \(last.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Updates")
            } footer: {
                Text("Updates include the latest Wine engine — no separate engine download needed.")
                    .font(.caption)
            }

            // App update section
            if case .updateAvailable(let version) = updateChecker.state {
                Section {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.blue)

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Meridian \(cleanTag(version))")
                                .fontWeight(.semibold)

                            if let notes = updateChecker.releaseNotes, !notes.isEmpty {
                                Text(String(notes.prefix(500)) + (notes.count > 500 ? "…" : ""))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(8)
                            }
                        }

                        Spacer()
                    }

                    appUpdateButton(version: version)
                } header: {
                    Text("New App Version")
                }
            }

            // Engine update section — shown independently of app updates
            if let engineTag = updateChecker.availableEngineTag {
                EngineUpdateSection(
                    engineTag: engineTag,
                    engineDownloader: engineDownloader,
                    engine: engine
                )
            }

            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Diagnostic Log")
                            .fontWeight(.medium)
                        Text(LogFileWriter.currentLogURL.path(percentEncoded: false))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Button("Open Log") {
                        NSWorkspace.shared.open(LogFileWriter.currentLogURL)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Button("Open Previous Session Log") {
                    NSWorkspace.shared.open(LogFileWriter.previousLogURL)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .font(.caption)
                .disabled(!FileManager.default.fileExists(atPath: LogFileWriter.previousLogURL.path(percentEncoded: false)))
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("Logs are written to Application Support and rotate each launch. Share these files when reporting issues.")
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Helpers

    private var fullVersionString: String {
        let v = AppUpdateChecker.currentVersion
        let b = AppUpdateChecker.currentBuild
        return "\(v) (Build \(b))"
    }

    private var engineVersionString: String {
        if let v = engine.engineVersion { return v }
        return engine.isReady ? engine.backendName : "Not installed"
    }

    @ViewBuilder
    private var updateStatusLabel: some View {
        switch updateChecker.state {
        case .idle:
            EmptyView()
        case .checking:
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.7)
                Text("Checking…").foregroundStyle(.secondary)
            }
        case .upToDate:
            let label = updateChecker.hasEngineUpdate ? "App is up to date" : "Up to date"
            Label(label, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .updateAvailable(let version):
            Label("\(cleanTag(version)) available", systemImage: "arrow.down.circle.fill")
                .foregroundStyle(.blue)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.caption)
                .lineLimit(2)
        }
    }

    @ViewBuilder
    private func appUpdateButton(version: String) -> some View {
        switch updateChecker.appUpdateState {
        case .downloading(let progress):
            VStack(spacing: 6) {
                ProgressView(value: progress)
                Text("Downloading Meridian… \(Int(progress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .installing:
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.7)
                Text("Installing update…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .readyToRelaunch:
            Label("Relaunching…", systemImage: "arrow.clockwise")
                .font(.caption)
                .foregroundStyle(.secondary)

        case .failed(let msg):
            VStack(alignment: .leading, spacing: 6) {
                Label(msg, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
                HStack {
                    Button {
                        updateChecker.downloadAndInstallUpdate()
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Open in Browser") {
                        updateChecker.openReleasePage()
                    }
                    .buttonStyle(.bordered)
                }
            }

        case .idle:
            if updateChecker.dmgDownloadURL != nil {
                Button {
                    updateChecker.downloadAndInstallUpdate()
                } label: {
                    Label("Download & Install \(cleanTag(version))", systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button {
                    updateChecker.openReleasePage()
                } label: {
                    Label("Download Meridian \(cleanTag(version))", systemImage: "safari")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func cleanTag(_ tag: String) -> String {
        tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }
}

// MARK: - Engine update section

private struct EngineUpdateSection: View {
    let engineTag: String
    let engineDownloader: EngineDownloader
    let engine: WineEngine
    @Environment(AppUpdateChecker.self) private var updateChecker

    var body: some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "cpu.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Wine Engine \(cleanTag(engineTag))")
                        .fontWeight(.semibold)
                    Text("A newer Wine runtime is available. The update improves game compatibility, performance, and DirectX support.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            engineDownloadButton
        } header: {
            Text("New Engine Version")
        }
    }

    @ViewBuilder
    private var engineDownloadButton: some View {
        switch engineDownloader.state {
        case .downloading(let progress):
            VStack(spacing: 6) {
                ProgressView(value: progress)
                Text("Downloading engine… \(Int(progress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .extracting:
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.7)
                Text("Installing engine…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .failed(let msg):
            VStack(alignment: .leading, spacing: 6) {
                Label(msg, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)

                Button {
                    engineDownloader.download {
                        engine.detect()
                        updateChecker.clearEngineUpdate(newTag: engine.engineVersion)
                    }
                } label: {
                    Label("Retry Download", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }

        default:
            Button {
                engineDownloader.download {
                    engine.detect()
                    updateChecker.clearEngineUpdate(newTag: engine.engineVersion)
                }
            } label: {
                Label("Download Engine \(cleanTag(engineTag))", systemImage: "arrow.down.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
        }
    }

    private func cleanTag(_ tag: String) -> String {
        var t = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        if t.hasSuffix("-engine") { t = String(t.dropLast(7)) }
        return t
    }
}

// MARK: - Engine status row

private struct EngineStatusRow: View {
    let engine: WineEngine
    @State private var showSetup = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(engine.isReady ? "Wine Runtime" : "Not installed")
                    .fontWeight(.medium)
                if engine.isReady {
                    Text("Backend: \(engine.backendName)")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    Text("Download the open-source Wine engine to play games.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if engine.isReady {
                Button("Re-detect") {
                    engine.detect()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                Button("Download…") {
                    showSetup = true
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .sheet(isPresented: $showSetup) {
            EngineSetupView()
                .environment(engine)
        }
    }
}
