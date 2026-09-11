import SwiftUI

// MARK: - LicenseStatusView

/// Shared status + activation form used by Settings › License and the
/// trial-expired sheet raised from the Play button.
struct LicenseStatusView: View {
    @Environment(LicenseManager.self) private var licenseManager
    @Environment(\.openURL) private var openURL

    @State private var keyInput = ""
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                statusRow
            } header: {
                Text("Status")
            }

            if !licenseManager.isLicensed {
                Section {
                    TextField("MRDN1.…", text: $keyInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .onSubmit(activate)

                    HStack {
                        Button("Buy Meridian") {
                            openURL(LicenseManager.purchaseURL)
                        }
                        .buttonStyle(.link)
                        .font(.caption)

                        Spacer()

                        Button("Activate", action: activate)
                            .buttonStyle(.borderedProminent)
                            .disabled(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("License Key")
                } footer: {
                    Text("Your key was emailed to you after purchase. Activation is verified on this Mac — no account or internet connection is required.")
                        .font(.caption)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var statusRow: some View {
        switch licenseManager.status {
        case .licensed(let license):
            HStack(alignment: .top) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Licensed")
                        .fontWeight(.medium)
                    Text(license.email)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let exp = license.expiresAt {
                        Text("Valid until \(exp.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Deactivate", role: .destructive) {
                    licenseManager.deactivate()
                }
                .buttonStyle(.bordered)
            }

        case .trial(let days):
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Trial")
                        .fontWeight(.medium)
                    Text(days == 1 ? "1 day remaining" : "\(days) days remaining")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "clock")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }

        case .trialExpired:
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Trial ended")
                        .fontWeight(.medium)
                    Text("Enter a license key to keep playing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "lock.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
            }

        case .invalid(let reason):
            HStack(alignment: .top) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("License problem")
                            .fontWeight(.medium)
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title2)
                        .foregroundStyle(.red)
                }
                Spacer()
                Button("Remove") {
                    licenseManager.deactivate()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func activate() {
        errorMessage = nil
        if let error = licenseManager.activate(key: keyInput) {
            errorMessage = LicenseManager.describe(error)
        } else {
            keyInput = ""
        }
    }
}

// MARK: - LicenseRequiredSheet

/// Presented from Play/Install once the trial has ended.
struct LicenseRequiredSheet: View {
    @Environment(LicenseManager.self) private var licenseManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
                Text("Your Meridian trial has ended")
                    .font(.title2.weight(.semibold))
                Text("Thanks for trying Meridian. Enter a license key to keep playing your library.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 24)
            .padding(.horizontal, 24)

            LicenseStatusView()
                .frame(height: 240)

            HStack {
                Spacer()
                Button(licenseManager.isLicensed ? "Done" : "Not Now") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding([.horizontal, .bottom], 16)
        }
        .frame(width: 440)
        .onChange(of: licenseManager.isLicensed) { _, licensed in
            if licensed { dismiss() }
        }
    }
}
