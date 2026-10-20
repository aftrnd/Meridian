import SwiftUI

// MARK: - LicenseRequiredSheet

/// Presented from Play or Install once the trial has ended, or when a stored
/// key no longer verifies. Built from onboarding's parts (`OnboardingPage`,
/// its heroes, entrance and action bar), so paying for Meridian looks and
/// moves like setting it up.
///
/// Three pages, forward only, pushed in like onboarding steps:
/// - **Offer:** buying is the way on. Buy Meridian opens checkout in the
///   browser and moves to the key page, where the emailed key goes.
/// - **Key:** a key that verifies activates as soon as it's pasted. Activate
///   explains one that doesn't, and the field shakes.
/// - **Licensed:** a thank-you, then the action that raised the sheet.
struct LicenseRequiredSheet: View {
    /// What the player pressed when the sheet came up.
    enum Action { case play, install }

    let action: Action
    /// The player chose to carry on with `action`. The sheet dismisses itself
    /// right after; the caller acts once it has closed.
    let onContinue: () -> Void

    @Environment(LicenseManager.self) private var licenseManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private enum Page { case offer, key, licensed }
    @State private var page: Page = .offer
    /// Checkout was opened from here, so the key is on its way by email.
    @State private var openedCheckout = false

    @State private var keyInput = ""
    @State private var errorMessage: String?
    /// Counts rejected keys; each one shakes the field.
    @State private var rejections = 0
    @FocusState private var keyFieldFocused: Bool

    var body: some View {
        ZStack {
            Group {
                switch page {
                case .offer: offerPage
                case .key: keyPage
                case .licensed: licensedPage
                }
            }
            .padding(.horizontal, 40)
            .padding(.top, 40)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // One unit while sliding, as in `SetupSheet`.
            .geometryGroup()
            .id(page)
            .transition(.asymmetric(
                insertion: .push(from: .trailing),
                removal: .push(from: .trailing).combined(with: .opacity)
            ))
        }
        .frame(width: 520, height: 460)
        .clipped()
        .animation(.smooth(duration: 0.45), value: page)
    }

    // MARK: - Offer

    private var offerPage: some View {
        OnboardingPage(offerTitle, subtitle: offerMessage) {
            OnboardingLogoHero()
        } content: {
            Button("I already have a license key") { page = .key }
                .buttonStyle(.link)
                .font(.system(size: 13))
        } actions: {
            Button("Not Now") { dismiss() }
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button("Buy Meridian", action: buy)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
    }

    /// Set when a stored key stopped verifying (`.invalid`); otherwise the
    /// trial has ended.
    private var invalidReason: String? {
        if case .invalid(let reason) = licenseManager.status { return reason }
        return nil
    }

    private var offerTitle: String {
        invalidReason == nil ? "Your trial has ended" : "Meridian can't use your license"
    }

    /// Every subtitle here is two lines broken at a phrase: at onboarding's
    /// 400pt width, plain wrapping strands a word or splits a sentence.
    private var offerMessage: String {
        if let invalidReason {
            return "\(invalidReason)\nEnter another key, or buy Meridian to keep playing."
        }
        return "Thanks for trying Meridian. Buy it once to keep playing.\nYour games and saves stay right where they are."
    }

    // MARK: - Key

    private var keyPage: some View {
        OnboardingPage("Enter your license key", subtitle: keyMessage) {
            EmptyView()
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                TextField("MRDN1.…", text: $keyInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .controlSize(.large)
                    .autocorrectionDisabled()
                    .focused($keyFieldFocused)
                    .onSubmit(activate)
                    .modifier(RejectionShake(trigger: rejections))
                    .onChange(of: keyInput) {
                        errorMessage = nil
                        // A whole key that verifies needs no button press.
                        if licenseManager.accepts(key: keyInput) { activate() }
                    }
                Button(openedCheckout ? "Open checkout again" : "Don't have a key? Buy Meridian", action: buy)
                    .buttonStyle(.link)
                    .font(.system(size: 12))
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: 340)
        } actions: {
            Button("Not Now") { dismiss() }
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button("Activate", action: activate)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedKey.isEmpty)
        }
        .animation(.smooth(duration: 0.2), value: errorMessage)
        .onAppear { keyFieldFocused = true }
    }

    private var keyMessage: String {
        openedCheckout
            ? "Finish checking out in your browser.\nYour key arrives by email, and it goes here."
            : "It's in the email you got when you bought Meridian,\nand it starts with MRDN1."
    }

    // MARK: - Licensed

    private var licensedPage: some View {
        OnboardingPage("Thank you", subtitle: licensedMessage) {
            OnboardingCompleteHero()
        } content: {
            EmptyView()
        } actions: {
            Button("Close") { dismiss() }
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button {
                onContinue()
                dismiss()
            } label: {
                switch action {
                case .play: Label("Play", systemImage: "play.fill")
                case .install: Label("Install", systemImage: "arrow.down.circle.fill")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
    }

    private var licensedMessage: String {
        guard let email = licenseManager.license?.email else { return "Meridian is licensed on this Mac." }
        return "Meridian is licensed to \(email).\nEvery game is ready to play."
    }

    // MARK: - Actions

    private var trimmedKey: String {
        keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Checkout opens in the browser; the sheet waits on the key page for the
    /// key it emails.
    private func buy() {
        openURL(LicenseManager.purchaseURL)
        openedCheckout = true
        page = .key
    }

    private func activate() {
        guard page == .key, !trimmedKey.isEmpty else { return }
        if let error = licenseManager.activate(key: trimmedKey) {
            errorMessage = LicenseManager.describe(error)
            rejections += 1
        } else {
            page = .licensed
        }
    }
}

// MARK: - Rejection shake

/// The Mac's "no": a short shake, as the login window gives a wrong
/// password. Still under Reduce Motion, where the error line says it alone.
private struct RejectionShake: ViewModifier {
    let trigger: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let still = reduceMotion
        return content.keyframeAnimator(initialValue: CGFloat.zero, trigger: trigger) { view, x in
            view.offset(x: still ? 0 : x)
        } keyframes: { _ in
            KeyframeTrack {
                CubicKeyframe(9, duration: 0.06)
                CubicKeyframe(-7, duration: 0.08)
                CubicKeyframe(5, duration: 0.08)
                CubicKeyframe(-3, duration: 0.08)
                CubicKeyframe(0, duration: 0.08)
            }
        }
    }
}
