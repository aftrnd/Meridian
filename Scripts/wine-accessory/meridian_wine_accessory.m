/*
 * meridian_wine_accessory.m — DYLD_INSERT_LIBRARIES payload that demotes
 * every Wine process Meridian launches to `NSApplicationActivationPolicyAccessory`.
 *
 * ## What "accessory" means
 *
 * macOS has three activation policies for Cocoa apps:
 *   - `.regular`    → Dock tile, menu bar, can activate/steal focus.
 *   - `.accessory`  → NO Dock tile, NO menu bar, cannot activate itself.
 *                    Windows still render normally; the app just never
 *                    appears in the Dock or foregrounds unexpectedly.
 *   - `.prohibited` → No Dock tile AND no windows allowed. Steam needs
 *                    windows (headless IPC only goes so far) so this is
 *                    too restrictive — breaks the client.
 *
 * ## Why inject via DYLD
 *
 * `NSApplication.setActivationPolicy(_:)` can ONLY be called on the current
 * process. There is no public API to change another process's activation
 * policy (Carbon `TransformProcessType` works but depends on deprecated
 * `GetProcessForPID`, removed from the Swift SDK and heading for removal
 * from the C ABI too — Apple has been clear this is a dead end).
 *
 * Injecting this dylib via `DYLD_INSERT_LIBRARIES` causes it to load inside
 * every Wine subprocess's dyld image list. Its `__attribute__((constructor))`
 * runs before `main()` and applies the accessory policy from inside the
 * process, where `setActivationPolicy` is authoritative.
 *
 * ## Hardened runtime requirement
 *
 * macOS's hardened runtime strips `DYLD_INSERT_LIBRARIES` unless the target
 * binary has the `com.apple.security.cs.allow-dyld-environment-variables`
 * entitlement. CrossOver's `wine64` ships with hardened runtime + library
 * validation disabled, but NOT the allow-dyld entitlement. Meridian adds
 * it at engine-install time via `WineEngine.ensureDyldEntitlement()` —
 * re-signs `wine64` ad-hoc with the combined entitlement set (preserving
 * CrossOver's existing entitlements + adding the dyld-env permission).
 *
 * ## Where this is injected
 *
 * Only from `WineEngine.steamCMDEnvironment(for:)` — the env used for
 * every Steam-related Wine call (bootstrap, persistent steam.exe, IPC
 * forwarders, registry writes). NOT injected from `environment(for:)`
 * which is used for actual game launches, where the game's window DOES
 * want to appear normally in the Dock + menu bar.
 */

#import <AppKit/AppKit.h>

__attribute__((constructor))
static void meridian_wine_accessory_init(void) {
    // NSApplication is thread-safe to access via sharedApplication from the
    // dyld constructor (which is always the main thread at load time), but
    // Wine's winemac driver spawns threads later that may touch NSApp. To
    // be safe, force main-thread execution if we're ever called elsewhere.
    dispatch_block_t apply = ^{
        [[NSApplication sharedApplication]
            setActivationPolicy:NSApplicationActivationPolicyAccessory];
    };
    if ([NSThread isMainThread]) {
        apply();
    } else {
        dispatch_sync(dispatch_get_main_queue(), apply);
    }

    // Wine's `winemac.drv` initialises NSApp later and may reset the
    // activation policy to `.regular`. Re-assert accessory on the
    // `NSApplicationDidFinishLaunching` notification — by that point
    // winemac.drv has finished its own NSApp setup.
    [[NSNotificationCenter defaultCenter]
        addObserverForName:NSApplicationDidFinishLaunchingNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification * _Nonnull note) {
        [[NSApplication sharedApplication]
            setActivationPolicy:NSApplicationActivationPolicyAccessory];
    }];
}
