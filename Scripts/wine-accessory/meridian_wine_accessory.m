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
 * entitlement. If the engine's `wine64` was signed without it, Meridian adds
 * it at engine-install time via `WineEngine.ensureDyldEntitlement()` —
 * re-signs `wine64` ad-hoc with the combined entitlement set (preserving
 * its existing entitlements + adding the dyld-env permission).
 *
 * ## Where this is injected
 *
 * Only from `WineEngine.steamCMDEnvironment(for:)` — the env used for
 * every Steam-related Wine call (bootstrap, persistent steam.exe, IPC
 * forwarders, registry writes). Games launch through that steam.exe and
 * inherit its environment, so the dylib loads into them too; it leaves a
 * game alone (`meridian_is_game_process`), which keeps its Dock icon, menu
 * bar and Cmd-Tab.
 */

#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <crt_externs.h>
#import <objc/runtime.h>
#import <os/log.h>
#import <string.h>
#import <unistd.h>

/*
 * A game: its Windows executable sits in a Steam library (`…\steamapps\…`).
 * Wine starts every process with that path as argv[1], already in place when
 * this dylib loads (CLI-verified Oct 12 2026: `C:\windows\system32\services.exe`,
 * `C:\Program Files (x86)\Steam\steamapps\common\<game>\<game>.exe`).
 * Steam itself, its helpers and Wine's services are not, and neither are the
 * redistributables Steam's install scripts run from a game's folder
 * (`…\<game>\_CommonRedist\vcredist\2022\VC_redist.x64.exe`), which the
 * steamapps match alone took for the game ("game process, activation policy
 * left alone", The Baby in Yellow, Oct 12 2026).
 */
static BOOL meridian_is_game_process(void) {
    static BOOL is_game;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *exe = *_NSGetArgc() > 1 ? (*_NSGetArgv())[1] : NULL;
        is_game = exe && (strcasestr(exe, "\\steamapps\\") || strcasestr(exe, "/steamapps/"))
            && !strcasestr(exe, "\\_CommonRedist\\") && !strcasestr(exe, "/_CommonRedist/");
    });
    return is_game;
}

/*
 * Category that swizzles `-[NSApplication setActivationPolicy:]` to force
 * every call — regardless of argument — to apply `.accessory`. Wine's
 * `winemac.drv` calls `setActivationPolicy:NSApplicationActivationPolicyRegular`
 * during its init to get a Dock tile, which would undo the single
 * `.accessory` call we make at load time. Swizzling means even winemac.drv's
 * call gets rewritten to `.accessory`, so the Dock tile never appears.
 *
 * Applied to every Wine subprocess this dylib loads into except games, which
 * keep winemac.drv's regular policy.
 */
@interface NSApplication (MeridianAccessoryOverride)
@end

@implementation NSApplication (MeridianAccessoryOverride)

- (BOOL)meridian_forceAccessorySetActivationPolicy:(NSApplicationActivationPolicy)policy {
    // Swizzled selector; `self` really is NSApplication. Forward to the
    // original implementation (now at this selector via method_exchangeImplementations)
    // with the accessory constant — NOT whatever winemac.drv passed.
    return [self meridian_forceAccessorySetActivationPolicy:
             NSApplicationActivationPolicyAccessory];
}

+ (void)load {
    if (meridian_is_game_process()) return;
    Method original  = class_getInstanceMethod(self, @selector(setActivationPolicy:));
    Method swizzled  = class_getInstanceMethod(self, @selector(meridian_forceAccessorySetActivationPolicy:));
    if (original && swizzled) {
        method_exchangeImplementations(original, swizzled);
    }
}

@end

/// Single os_log handle for the dylib. Subsystem matches `MeridianLog`'s
/// so the dylib's lines appear alongside the Swift app's in `log stream`
/// and Console.app filters. Stream:
///
///     log stream --predicate 'subsystem == "com.meridian.app"
///                              AND category == "WineAccessoryDylib"'
static os_log_t accessory_log(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        log = os_log_create("com.meridian.app", "WineAccessoryDylib");
    });
    return log;
}

/*
 * ## Hidden Steam windows stay hidden
 *
 * While Meridian manages Steam's windows (`MERIDIAN_HIDE_STEAM_WINDOWS=1`, set
 * when it has Accessibility access), it hides them by moving them off every
 * display (`SteamWindow`) and is the only one that brings one back, centred
 * over its own window, through Accessibility.
 *
 * Showing or focusing a window that is off every display makes Cocoa carry it
 * to the top-left of the main display (winemac `macdrv_give_cocoa_window_focus`:
 * "Cocoa will typically move it on-screen"), where it stayed until Meridian's
 * next pass moved it away. Told to quit, Steam shows its hidden library: on
 * screen at 0,30 for about half a second (webhelper.txt `SP Desktop_uid0-'Steam':
 * WasHidden 0`, meridian.log `hid … 'Steam' 1010×600 from 0,30`, Oct 12 2026).
 * Steam's own positions were still off-screen: it centred its Shutdown popup on
 * the library at -16000,-16000 px, and placed "Special Offers" at -15343,-15815,
 * which also showed at 0,30.
 *
 * So a window that was off every display before Wine orders or focuses it is
 * put back, with screen updates held so no frame shows it on screen.
 */
static BOOL meridian_hides_steam_windows(void) {
    static BOOL hides;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        hides = getenv("MERIDIAN_HIDE_STEAM_WINDOWS") != NULL;
    });
    return hides;
}

static BOOL meridian_is_on_screen(NSRect frame) {
    for (NSScreen *screen in NSScreen.screens) {
        if (NSIntersectsRect(frame, screen.frame)) return YES;
    }
    return NO;
}

/// Runs `show` (Wine ordering or focusing `window`) and keeps a hidden window
/// where it was.
static void meridian_keep_hidden(NSWindow *window, void (^show)(void)) {
    NSRect before = window.frame;
    if (meridian_is_on_screen(before)) {
        show();
        return;
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    NSDisableScreenUpdates();  // as winemac's own -orderBelow:orAbove:activate:
    show();
    if (meridian_is_on_screen(window.frame)) {
        [window setFrameOrigin:before.origin];
        os_log_info(accessory_log(), "[meridian-wine-accessory] kept hidden window '%{public}@' off-screen", window.title);
        NSLog(@"[meridian-wine-accessory] kept hidden window '%@' off-screen", window.title);
    }
    NSEnableScreenUpdates();
#pragma clang diagnostic pop
}

@interface NSWindow (MeridianKeepHidden)
@end

@implementation NSWindow (MeridianKeepHidden)

// Swizzled: each calls the original method. winemac shows a window with
// -orderFront: or -orderWindow:relativeTo: and focuses it with -makeKeyWindow,
// and its WineWindow overrides none of them.

- (void)meridian_orderFront:(id)sender {
    meridian_keep_hidden(self, ^{ [self meridian_orderFront:sender]; });
}

- (void)meridian_orderWindow:(NSWindowOrderingMode)place relativeTo:(NSInteger)otherWindowNumber {
    if (place == NSWindowOut) {
        [self meridian_orderWindow:place relativeTo:otherWindowNumber];
        return;
    }
    meridian_keep_hidden(self, ^{ [self meridian_orderWindow:place relativeTo:otherWindowNumber]; });
}

- (void)meridian_makeKeyWindow {
    meridian_keep_hidden(self, ^{ [self meridian_makeKeyWindow]; });
}

+ (void)load {
    if (meridian_is_game_process()) return;
    if (!meridian_hides_steam_windows()) return;
    const SEL pairs[][2] = {
        { @selector(orderFront:), @selector(meridian_orderFront:) },
        { @selector(orderWindow:relativeTo:), @selector(meridian_orderWindow:relativeTo:) },
        { @selector(makeKeyWindow), @selector(meridian_makeKeyWindow) },
    };
    for (size_t i = 0; i < sizeof(pairs) / sizeof(pairs[0]); i++) {
        Method original = class_getInstanceMethod(self, pairs[i][0]);
        Method swizzled = class_getInstanceMethod(self, pairs[i][1]);
        if (original && swizzled) {
            method_exchangeImplementations(original, swizzled);
        }
    }
}

@end

/*
 * ## Sign-in presentation
 *
 * When Meridian opens Steam's own sign-in (`MERIDIAN_STEAM_SIGNIN=1`, set only
 * for the interactive launch and inherited by steamwebhelper), Steam's sign-in
 * window gets macOS window chrome: continuous rounded corners, the system
 * shadow and a fade-in. winemac otherwise draws it as a square, shadowless
 * rectangle.
 *
 * - The rounding is a mask on the content layer, not `cornerRadius`: winemac
 *   keeps a window non-opaque only while `contentView.layer.mask` is set
 *   (`-needsTransparency`); `-checkTransparency` would otherwise make it opaque
 *   again and fill the corners. The mask is inset past the 1 pt frame Steam
 *   draws around its window, so the corners round through plain background.
 * - Steam's own ✕ is covered with its background colour, sampled live from the
 *   window's pixels (winemac sets the surface as `layer.contents`). Meridian
 *   offers Cancel instead.
 */
static const CGFloat kSignInCornerRadius = 16;
static const CGFloat kSteamFrameInset = 2;        // Steam's 1 pt border + 1 pt top highlight
static const NSRect kSteamCloseButtonCover = { { 34, 2 }, { 32, 30 } };  // from top-right; ✕ spans 12–23 × 10–21 pt
static const NSSize kSteamSignInSize = { 700, 440 };  // the cover is only for this window
static char kStyledKey;
static char kChromeKey;

/*
 * winemac re-applies `hasShadow` from the Win32 style on every feature update
 * (`-setWindowFeatures:`), and Steam's frameless popup maps to "no shadow".
 * Windows this dylib styled keep the system shadow.
 */
@interface NSWindow (MeridianSignInShadow)
@end

@implementation NSWindow (MeridianSignInShadow)

- (void)meridian_setHasShadow:(BOOL)hasShadow {
    // Swizzled: this calls the original -setHasShadow:.
    [self meridian_setHasShadow:(hasShadow || objc_getAssociatedObject(self, &kStyledKey) != nil)];
}

+ (void)load {
    if (meridian_is_game_process()) return;
    Method original = class_getInstanceMethod(self, @selector(setHasShadow:));
    Method swizzled = class_getInstanceMethod(self, @selector(meridian_setHasShadow:));
    if (original && swizzled) {
        method_exchangeImplementations(original, swizzled);
    }
}

@end

/// sRGB colour of one pixel (top-left based, in pixels) of winemac's surface
/// image. Sampled and returned in the same space so the cover matches exactly.
static CGColorRef meridian_copy_pixel_color(CGImageRef image, size_t x, size_t y) {
    if (!image || x >= CGImageGetWidth(image) || y >= CGImageGetHeight(image)) return NULL;
    uint8_t rgba[4] = { 0 };
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(rgba, 1, 1, 8, 4, space, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorRef color = NULL;
    if (context) {
        CGFloat height = CGImageGetHeight(image);
        CGContextDrawImage(context, CGRectMake(-(CGFloat)x, -(height - 1 - y), CGImageGetWidth(image), height), image);
        CGContextRelease(context);
        const CGFloat components[4] = { rgba[0] / 255.0, rgba[1] / 255.0, rgba[2] / 255.0, 1 };
        color = CGColorCreate(space, components);
    }
    CGColorSpaceRelease(space);
    return color;
}

/// Owns the sign-in window's chrome on its content layer: the rounded mask
/// and the ✕ cover. KVO keeps both in place — winemac replaces `layer.mask`
/// in `-setShape:` and republishes `layer.contents` on every draw, and the
/// cover is re-coloured from each new surface image.
@interface MeridianSignInChrome : NSObject
@property (nonatomic, weak) NSWindow *window;
@property (nonatomic, strong) CALayer *host;   // strong: observers are removed in -dealloc
@property (nonatomic, strong) CAShapeLayer *mask;
@property (nonatomic, strong) CALayer *cover;
@end

@implementation MeridianSignInChrome

- (instancetype)initWithWindow:(NSWindow *)window host:(CALayer *)host {
    if ((self = [super init])) {
        _window = window;
        _host = host;
        _mask = [CAShapeLayer layer];
        _cover = [CALayer layer];
        _cover.cornerRadius = 4;
        [host addSublayer:_cover];
        [host addObserver:self forKeyPath:@"mask" options:0 context:NULL];
        [host addObserver:self forKeyPath:@"bounds" options:0 context:NULL];
        [host addObserver:self forKeyPath:@"contents" options:NSKeyValueObservingOptionInitial context:NULL];
    }
    return self;
}

- (void)dealloc {
    [_host removeObserver:self forKeyPath:@"mask"];
    [_host removeObserver:self forKeyPath:@"bounds"];
    [_host removeObserver:self forKeyPath:@"contents"];
}

- (void)apply {
    CALayer *host = self.host;
    CGRect bounds = host.bounds;
    CGRect clip = CGRectInset(bounds, kSteamFrameInset, kSteamFrameInset);
    CGPathRef path = CGPathCreateWithRoundedRect(clip, kSignInCornerRadius, kSignInCornerRadius, NULL);

    CGRect cover = kSteamCloseButtonCover;
    cover.origin.x = CGRectGetMaxX(bounds) - cover.origin.x;
    if (!host.geometryFlipped) cover.origin.y = CGRectGetMaxY(bounds) - cover.origin.y - cover.size.height;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.mask.frame = bounds;
    self.mask.path = path;
    if (host.mask != self.mask) host.mask = self.mask;
    self.cover.frame = cover;
    // Rounded corners suit any Steam window this process later surfaces
    // (EULA, purchase); the ✕ cover is only correct on the sign-in window.
    self.cover.hidden = fabs(bounds.size.width - kSteamSignInSize.width) > 2
                     || fabs(bounds.size.height - kSteamSignInSize.height) > 2;
    [CATransaction commit];
    CGPathRelease(path);

    NSWindow *window = self.window;
    window.opaque = NO;
    window.backgroundColor = NSColor.clearColor;
    window.hasShadow = YES;
    [window invalidateShadow];
}

- (void)recolorCover {
    CALayer *host = self.host;
    id contents = host.contents;
    if (!contents || CFGetTypeID((__bridge CFTypeRef)contents) != CGImageGetTypeID()) return;
    CGFloat scale = host.contentsScale;
    CGFloat x = CGRectGetMaxX(host.bounds) - kSteamCloseButtonCover.origin.x - 6;  // just left of the cover
    CGColorRef color = meridian_copy_pixel_color((__bridge CGImageRef)contents, x * scale, 8 * scale);
    if (!color) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.cover.backgroundColor = color;
    [CATransaction commit];
    CGColorRelease(color);
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object
                        change:(NSDictionary *)change context:(void *)context {
    if ([keyPath isEqualToString:@"contents"]) {
        [self recolorCover];
    } else if (![keyPath isEqualToString:@"mask"] || self.host.mask != self.mask) {
        [self apply];
    }
}

@end

static void meridian_style_window_layer(NSWindow *window) {
    CALayer *layer = window.contentView.layer;
    if (!layer) return;
    MeridianSignInChrome *chrome = objc_getAssociatedObject(window, &kChromeKey);
    if (!chrome || chrome.host != layer) {
        chrome = [[MeridianSignInChrome alloc] initWithWindow:window host:layer];
        objc_setAssociatedObject(window, &kChromeKey, chrome, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [chrome apply];
}

/// Steam's sign-in: a titled, visible window of dialog size (same rule as
/// `SteamWindow.isSignInWindow`). Helper windows are untitled, hidden or tiny;
/// the library window that follows sign-in is larger than 900×700.
static BOOL meridian_is_signin_window(NSWindow *window) {
    NSSize size = window.frame.size;
    return window.isVisible && window.title.length > 0
        && size.width >= 300 && size.width <= 900 && size.height >= 200 && size.height <= 700;
}

static void meridian_style_signin_window(NSWindow *window) {
    if (!meridian_is_signin_window(window)) return;
    BOOL first = objc_getAssociatedObject(window, &kStyledKey) == nil;
    objc_setAssociatedObject(window, &kStyledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    meridian_style_window_layer(window);  // re-applied: mask and cover track the window size
    if (!first) return;

    window.alphaValue = 0;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.3;
        context.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
        window.animator.alphaValue = 1;
    }];
    os_log_info(accessory_log(), "[meridian-wine-accessory] styled sign-in window '%{public}@'", window.title);
}

static void meridian_observe_signin_windows(void) {
    // Only Steam's browser process draws the sign-in window; steam.exe's own
    // windows (updater) stay as Meridian's suppressor leaves them.
    if (![NSProcessInfo.processInfo.processName.lowercaseString containsString:@"steamwebhelper"]) return;

    NSArray<NSNotificationName> *names = @[
        NSWindowDidChangeOcclusionStateNotification,  // ordered on screen
        NSWindowDidBecomeKeyNotification,
        NSWindowDidResizeNotification,
    ];
    for (NSNotificationName name in names) {
        [[NSNotificationCenter defaultCenter] addObserverForName:name
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification * _Nonnull note) {
            meridian_style_signin_window(note.object);
        }];
    }
}

__attribute__((constructor))
static void meridian_wine_accessory_init(void) {
    // Diagnostic: confirm the dylib actually loaded into a Wine subprocess.
    // If the Dock icon ever reappears despite this dylib being on disk,
    // these lines tell us whether it was injected. Use both `os_log` (for
    // log stream/Console.app filtering) and `NSLog` (so it lands in the
    // Wine-process stderr that Meridian captures into meridian.log via
    // `[steam.exe:stderr]`).
    pid_t pid = getpid();
    pid_t ppid = getppid();
    os_log_info(accessory_log(),
        "[meridian-wine-accessory] loaded into pid=%{public}d ppid=%{public}d",
        pid, ppid);
    NSLog(@"[meridian-wine-accessory] dylib loaded pid=%d ppid=%d",
          pid, ppid);

    if (meridian_is_game_process()) {
        NSLog(@"[meridian-wine-accessory] game process, activation policy left alone");
        return;
    }

    // Do NOT touch `NSApp` here. winemac.drv creates its own NSApplication
    // subclass only when `NSApp` is still nil (`run_cocoa_app`: `if (!NSApp)
    // [WineApplication sharedApplication]`). Creating a plain NSApplication
    // first makes the Mac driver fail with "Failed to start Cocoa app main
    // loop", so steam.exe exits 152 before it can sign in. The swizzled
    // setter installed in +load already turns winemac's own
    // `setActivationPolicy:NSApplicationActivationPolicyRegular` into
    // `.accessory`.

    // Re-assert once the app has launched, in case something bypasses the
    // swizzled setter (e.g. a private API that mutates activation policy
    // without calling setActivationPolicy:).
    [[NSNotificationCenter defaultCenter]
        addObserverForName:NSApplicationDidFinishLaunchingNotification
                    object:nil
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification * _Nonnull note) {
        BOOL ok = [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        os_log_info(accessory_log(),
            "[meridian-wine-accessory] re-assert .accessory after launch = %{public}s",
            ok ? "YES" : "NO");
    }];

    if (getenv("MERIDIAN_STEAM_SIGNIN")) meridian_observe_signin_windows();
}
