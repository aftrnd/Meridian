import SwiftUI

struct SettingsView: View {
    @Environment(SteamAuthService.self) private var steamAuth
    @Environment(WineEngine.self) private var engine
    @Environment(SteamWindowSuppressor.self) private var suppressor

    var body: some View {
        TabView {
            SteamSettingsTab()
                .tabItem { Label("Steam", systemImage: "person.badge.key") }

            EngineSettingsTab()
                .tabItem { Label("Engine", systemImage: "gearshape.2") }

            PermissionsSettingsTab()
                .tabItem { Label("Permissions", systemImage: "hand.raised") }
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
    private let settings = AppSettings.shared
    @State private var showAdvanced = false

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
        }
        .formStyle(.grouped)
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
