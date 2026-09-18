// Meridian mouse probe — injected into wine64 via DYLD_INSERT_LIBRARIES for A/B only.
// Env switches (any combination):
//   MERIDIAN_MP_CLIP=1        on hideCursor → -[WineApplicationController startClippingCursor:screen]
//                             (NOT relative in the interior — winemac only sends relative moves when the
//                             cursor is PINNED at the clip boundary, cocoa_app.m handleMouseMove:)
//   MERIDIAN_MP_PIN=1         on hideCursor → clip to a 1×1 rect at the cursor: the cursor can never move,
//                             so EVERY event is MOUSE_MOVED_RELATIVE built from [NSEvent deltaX/deltaY] —
//                             the same values native games read. Needs the game in raw-input mode
//                             (Source: m_rawinput 1, the Anniversary default). Retries until the Wine
//                             window exists (the confinement handler needs frontWineWindow).
//   MERIDIAN_MP_NOCOALESCE=1  [NSEvent setMouseCoalescingEnabled:NO]
//   MERIDIAN_MP_DISASSOC=1    CGAssociateMouseAndMouseCursorPosition(false) while the cursor is hidden
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <stdlib.h>

@interface NSObject (MeridianWineACProbe)
- (BOOL)startClippingCursor:(CGRect)rect;
- (void)stopClippingCursor;
- (void)hideCursor;
- (void)unhideCursor;
- (void)meridian_hideCursor;
- (void)meridian_unhideCursor;
@end

static BOOL optClip, optPin, optNoCoalesce, optDisassoc;
static BOOL installed, cursorHidden, pinned;
static dispatch_source_t pinRetry;

static CGRect screenRectCG(void) { return CGDisplayBounds(CGMainDisplayID()); }

static CGRect pinRectCG(void) {
    CGEventRef e = CGEventCreate(NULL);
    CGPoint p = CGEventGetLocation(e);
    if (e) CFRelease(e);
    return CGRectMake(floor(p.x), floor(p.y), 1, 1);
}

static void tryPin(id controller) {
    if (!cursorHidden || pinned) return;
    CGRect r = pinRectCG();
    pinned = [controller startClippingCursor:r];
    NSLog(@"[mouse-probe] pin attempt at (%.0f,%.0f) -> %d", r.origin.x, r.origin.y, pinned);
    if (pinned && pinRetry) { dispatch_source_cancel(pinRetry); pinRetry = nil; }
}

static void schedulePinRetries(id controller) {
    if (pinRetry) return;
    pinRetry = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(pinRetry, dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC), 250 * NSEC_PER_MSEC, 50 * NSEC_PER_MSEC);
    __block int ticks = 0;
    dispatch_source_set_event_handler(pinRetry, ^{
        tryPin(controller);
        if (pinned || !cursorHidden || ++ticks > 120) { dispatch_source_cancel(pinRetry); pinRetry = nil; }
    });
    dispatch_resume(pinRetry);
}

@interface MeridianMouseProbe : NSObject @end
@implementation MeridianMouseProbe
- (void)meridian_hideCursor {
    [self meridian_hideCursor]; // swapped: original implementation
    cursorHidden = YES;
    if (optClip) {
        CGRect r = screenRectCG();
        BOOL ok = [self startClippingCursor:r];
        NSLog(@"[mouse-probe] hideCursor -> startClippingCursor(%.0fx%.0f) = %d", r.size.width, r.size.height, ok);
    }
    if (optPin) {
        tryPin(self);
        if (!pinned) schedulePinRetries(self);
    }
    if (optDisassoc) {
        CGAssociateMouseAndMouseCursorPosition(false);
        NSLog(@"[mouse-probe] hideCursor -> cursor disassociated");
    }
}
- (void)meridian_unhideCursor {
    cursorHidden = NO;
    if (optClip) { [self stopClippingCursor]; NSLog(@"[mouse-probe] unhideCursor -> stopClippingCursor"); }
    if (optPin && pinned) { [self stopClippingCursor]; pinned = NO; NSLog(@"[mouse-probe] unhideCursor -> unpinned"); }
    if (optDisassoc) { CGAssociateMouseAndMouseCursorPosition(true); NSLog(@"[mouse-probe] unhideCursor -> cursor re-associated"); }
    [self meridian_unhideCursor]; // swapped: original implementation
}
@end

static BOOL swap(Class target, SEL orig, SEL mine) {
    Method o = class_getInstanceMethod(target, orig);
    Method m = class_getInstanceMethod([MeridianMouseProbe class], mine);
    if (!o || !m) return NO;
    // Add our IMP under the probe selector on the target class, then exchange.
    if (!class_addMethod(target, mine, method_getImplementation(m), method_getTypeEncoding(m))) return NO;
    Method added = class_getInstanceMethod(target, mine);
    method_exchangeImplementations(o, added);
    return YES;
}

static void tryInstall(void) {
    if (installed) return;
    Class ac = NSClassFromString(@"WineApplicationController");
    if (!ac) return;
    installed = YES;
    if (optNoCoalesce) {
        [NSEvent setMouseCoalescingEnabled:NO];
        NSLog(@"[mouse-probe] mouse coalescing disabled");
    }
    if (optClip || optPin || optDisassoc) {
        BOOL a = swap(ac, @selector(hideCursor), @selector(meridian_hideCursor));
        BOOL b = swap(ac, @selector(unhideCursor), @selector(meridian_unhideCursor));
        NSLog(@"[mouse-probe] swizzled hideCursor=%d unhideCursor=%d", a, b);
    }
    NSLog(@"[mouse-probe] installed clip=%d pin=%d nocoalesce=%d disassoc=%d", optClip, optPin, optNoCoalesce, optDisassoc);
}

__attribute__((constructor))
static void meridian_mouse_probe_init(void) {
    optClip       = getenv("MERIDIAN_MP_CLIP") != NULL;
    optPin        = getenv("MERIDIAN_MP_PIN") != NULL;
    optNoCoalesce = getenv("MERIDIAN_MP_NOCOALESCE") != NULL;
    optDisassoc   = getenv("MERIDIAN_MP_DISASSOC") != NULL;
    if (!(optClip || optPin || optNoCoalesce || optDisassoc)) return;
    NSLog(@"[mouse-probe] loaded pid=%d clip=%d pin=%d nocoalesce=%d disassoc=%d", getpid(), optClip, optPin, optNoCoalesce, optDisassoc);
    // winemac.so (and its Cocoa classes) load after us; poll on the main queue until they exist.
    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC), 200 * NSEC_PER_MSEC, 50 * NSEC_PER_MSEC);
    __block int ticks = 0;
    dispatch_source_set_event_handler(t, ^{
        tryInstall();
        if (installed || ++ticks > 600) dispatch_source_cancel(t);
    });
    dispatch_resume(t);
}
