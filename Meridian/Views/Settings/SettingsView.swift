import SwiftUI

struct SettingsView: View {
    @Environment(SteamAuthService.self) private var steamAuth
    @Environment(VMManager.self) private var vmManager

    private let settings = AppSettings.shared

    var body: some View {
        TabView {
            SteamSettingsTab()
                .tabItem { Label("Steam", systemImage: "person.badge.key") }

            VMSettingsTab()
                .tabItem { Label("Virtual Machine", systemImage: "server.rack") }

            AdvancedSettingsTab()
                .tabItem { Label("Advanced", systemImage: "gearshape.2") }
        }
        .frame(width: 520)
        .padding(24)
    }
}

// MARK: - Steam tab

private struct SteamSettingsTab: View {
    @Environment(SteamAuthService.self) private var steamAuth
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
                Text("Required to load your game library. Stored securely in Keychain — never transmitted except directly to Steam's own servers.")
                    .font(.caption)
            }

            Section {
                VMCredentialsSection()
            } header: {
                Text("VM Auto-Login Fallback")
            } footer: {
                Text("Used only if Steam for Mac is not installed on this machine. Meridian prefers copying your existing macOS Steam session into the VM.")
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
            // Refresh displayed profile now that the key is valid
            await steamAuth.refreshProfile(steamID: steamAuth.steamID)
            validationSuccess = true
            validationMessage = "Key verified — library will refresh automatically."
        } catch {
            validationSuccess = false
            validationMessage = "Couldn't verify key. Check it's correct and your profile is public."
        }
    }
}

// MARK: - VM Credentials Section

private struct VMCredentialsSection: View {
    @Environment(SteamAuthService.self) private var steamAuth
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var saved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Steam username", text: $username)
                .textFieldStyle(.roundedBorder)

            SecureField("Steam password", text: $password)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Save Credentials") {
                    steamAuth.vmUsername = username
                    steamAuth.vmPassword = password
                    saved = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { saved = false }
                }
                .buttonStyle(.bordered)
                .disabled(username.isEmpty || password.isEmpty)
            }

            if saved {
                Label("Saved to Keychain.", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
        .onAppear {
            username = steamAuth.vmUsername
            password = steamAuth.vmPassword
        }
    }
}

// MARK: - VM tab

private struct VMSettingsTab: View {
    @Environment(VMManager.self) private var vmManager
    private let settings = AppSettings.shared
    @State private var cpuCount: Double = 0
    @State private var memGiB: Double = 4
    @State private var diskGiB: Double = 64

    var body: some View {
        Form {
            Section("Resources") {
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent("CPU Cores: \(Int(cpuCount))") {
                        Slider(value: $cpuCount,
                               in: 1...Double(ProcessInfo.processInfo.processorCount),
                               step: 1)
                    }
                    Text("Host has \(ProcessInfo.processInfo.processorCount) cores")
                        .font(.caption).foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent("Memory: \(Int(memGiB)) GB") {
                        Slider(value: $memGiB, in: 2...Double(maxRAMGiB()), step: 2)
                    }
                    Text("System has \(hostRAMGiB()) GB total")
                        .font(.caption).foregroundStyle(.secondary)
                }

                LabeledContent("Game Disk: \(Int(diskGiB)) GB") {
                    Slider(value: $diskGiB, in: 16...512, step: 16)
                }
            }

            Section("Behaviour") {
                Toggle("Keep VM running between sessions", isOn: Binding(
                    get: { settings.keepVMRunning },
                    set: { settings.keepVMRunning = $0 }
                ))
                Text("Speeds up subsequent game launches but uses more memory.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Image") {
                VMImageStatusRow(vmManager: vmManager)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            cpuCount = Double(settings.vmCPUCount)
            memGiB   = Double(settings.vmMemoryGiB)
            diskGiB  = Double(settings.vmDiskGiB)
        }
        .onChange(of: cpuCount) { settings.vmCPUCount  = Int(cpuCount) }
        .onChange(of: memGiB)   { settings.vmMemoryGiB = Int(memGiB)   }
        .onChange(of: diskGiB)  { settings.vmDiskGiB   = Int(diskGiB)  }
    }

    private func hostRAMGiB() -> Int { Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) }
    private func maxRAMGiB() -> Int  { max(4, hostRAMGiB() - 4) }
}

// MARK: - Image status row

private struct VMImageStatusRow: View {
    let vmManager: VMManager
    @State private var isChecking = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(vmManager.imageProvider.isImageReady ? "Meridian Base Image" : "No image installed")
                    .fontWeight(.medium)
                if let tag = vmManager.imageProvider.cachedTag {
                    Text("Version: \(tag)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if isChecking {
                ProgressView().scaleEffect(0.8)
            } else {
                Button("Check for Update") {
                    isChecking = true
                    Task {
                        let _ = await vmManager.imageProvider.checkForUpdate()
                        isChecking = false
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }
}

// MARK: - Advanced tab

private struct AdvancedSettingsTab: View {
    private let settings = AppSettings.shared

    var body: some View {
        Form {
            Section("Image Repository") {
                TextField("GitHub repo slug", text: Binding(
                    get: { settings.imageRepoSlug },
                    set: { settings.imageRepoSlug = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                Text("Format: owner/repo. Change this to use your own fork or self-hosted images.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
