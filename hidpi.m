// HiDPI: sharp (2x) scaled resolutions above what macOS offers on the built-in display.
// Two ways, picked per width:
//   native:   the display's own 2x mode, if macOS has one. Full height including the strip beside the notch,
//             no extra process. macOS only has these after the override file is installed (--override).
//   mirrored: otherwise, a virtual HiDPI display that the built-in screen mirrors. Always 16:10, below the notch.
//
// build:  ./build.sh   (makes HiDPI.app and installs it to ~/Applications)
// app:    open HiDPI.app, pick a resolution from the menu bar icon. Normal or Quit reverts.
//         The choice is remembered. The menu also has Custom, Toggle (Ctrl-Opt-Cmd-H) and Start at login.
// cli:    HiDPI --sizes         (self-check: which menu sizes are native and which would be mirrored)
//         HiDPI --override <dir>  (writes the override file that makes the menu sizes native, and how to install it)
//         HiDPI 2048            (mirrors at 2048 x 1280 until Ctrl-C)
//         HiDPI --child 2048    (what the app runs for a mirrored size: as above, but exits when the app dies)
//         HiDPI --probe 2048    (self-check for mirroring: creates the virtual display without mirroring, then
//                               exits; the 2x check itself only runs on a real switch)
//         HiDPI --login on|off|status   (Start at login for the installed app)
//         HiDPI --icon <dir>    (writes the app icon as an iconset; build.sh uses it)
#import <Cocoa/Cocoa.h>
#import <Carbon/Carbon.h>
#import <IOKit/graphics/IOGraphicsTypes.h>
#import <ServiceManagement/ServiceManagement.h>

// Private CoreGraphics API, undocumented. May break on a macOS update; --probe tells you.
@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(NSUInteger)w height:(NSUInteger)h refreshRate:(CGFloat)hz;
@end
@interface CGVirtualDisplaySettings : NSObject
@property(nonatomic) unsigned int hiDPI;
@property(retain, nonatomic) NSArray<CGVirtualDisplayMode *> *modes;
@end
@interface CGVirtualDisplayDescriptor : NSObject
@property(retain, nonatomic) dispatch_queue_t queue;
@property(retain, nonatomic) NSString *name;
@property(nonatomic) NSUInteger maxPixelsWide, maxPixelsHigh;
@property(nonatomic) CGSize sizeInMillimeters;
@property(nonatomic) unsigned int vendorID, productID, serialNum;
@property(nonatomic) CGPoint redPrimary, greenPrimary, bluePrimary, whitePoint;
@end
@interface CGVirtualDisplay : NSObject
@property(readonly, nonatomic) CGDirectDisplayID displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)d;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)s;
@end

static const size_t kWidths[] = {1920, 2048, 2294, 2560};  // menu presets
static CGVirtualDisplay *gDisplay;                          // kept alive for the life of the process

// Only CoreGraphics calls here: NSScreen does not refresh while a menu action is spinning the run loop.
static size_t pixelWidth(CGDirectDisplayID d) {
  CGDisplayModeRef m = CGDisplayCopyDisplayMode(d);  // NULL for our own virtual display, fine for the built-in
  size_t w = m ? CGDisplayModeGetPixelWidth(m) : 0;
  CGDisplayModeRelease(m);
  return w;
}

static BOOL waitFor(BOOL (^cond)(void)) {
  for (int i = 0; i < 30; i++) {
    if (cond()) return YES;  // conditions may have side effects, so call each at most once per try
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
  }
  return NO;
}

static CGDirectDisplayID builtinDisplay(void) {
  CGDirectDisplayID ids[16];
  uint32_t n = 0;
  CGGetOnlineDisplayList(16, ids, &n);
  for (uint32_t i = 0; i < n; i++)
    if (CGDisplayIsBuiltin(ids[i])) return ids[i];
  return kCGNullDirectDisplay;
}

static NSArray *modesOf(CGDirectDisplayID d) {
  return CFBridgingRelease(CGDisplayCopyAllDisplayModes(d, (__bridge CFDictionaryRef) @{(__bridge id)kCGDisplayShowDuplicateLowResolutionModes : @YES}));
}

// The built-in display's own 2x mode for a width, or NULL if macOS has none (then the width is mirrored).
// Of several, the tallest (the whole panel, including the strip beside the notch) at the highest refresh rate.
// The caller releases it.
static CGDisplayModeRef nativeMode(size_t w) {
  CGDirectDisplayID b = builtinDisplay();
  CGDisplayModeRef best = NULL;
  for (id o in b ? modesOf(b) : @[]) {
    CGDisplayModeRef m = (__bridge CGDisplayModeRef)o;
    if (CGDisplayModeGetWidth(m) != w || CGDisplayModeGetPixelWidth(m) != 2 * w) continue;
    size_t h = CGDisplayModeGetHeight(m), bh = best ? CGDisplayModeGetHeight(best) : 0;
    if (h > bh || (h == bh && CGDisplayModeGetRefreshRate(m) > CGDisplayModeGetRefreshRate(best))) best = m;
  }
  return best ? CGDisplayModeRetain(best) : NULL;
}

// A mirrored picture is always 16:10: macOS shows it in the 16:10 area below the notch and never in the strip
// beside it (a virtual display has no notch), so any other shape only adds bars or gets squashed.
static size_t mirroredHeight(size_t w) { return w * 10 / 16; }

// The height a pick of this width gives.
static size_t heightFor(size_t w) {
  CGDisplayModeRef m = nativeMode(w);
  size_t h = m ? CGDisplayModeGetHeight(m) : mirroredHeight(w);
  CGDisplayModeRelease(m);
  return h;
}

// Switches the built-in display to one of its own modes. AppOnly, like mirror() below: it lasts while this
// process runs and reverts by itself when it exits.
static CGError setMode(CGDisplayModeRef m) {
  CGDisplayConfigRef cfg;
  CGBeginDisplayConfiguration(&cfg);
  CGConfigureDisplayWithDisplayMode(cfg, builtinDisplay(), m, NULL);
  return CGCompleteDisplayConfiguration(cfg, kCGConfigureForAppOnly);
}

// AppOnly: the configuration also reverts by itself when this process exits.
static CGError mirror(CGDirectDisplayID display, CGDirectDisplayID master) {
  CGDisplayConfigRef cfg;
  CGBeginDisplayConfiguration(&cfg);
  CGConfigureDisplayMirrorOfDisplay(cfg, display, master);
  return CGCompleteDisplayConfiguration(cfg, kCGConfigureForAppOnly);
}

// Puts the built-in screen at w x h, rendered at 2x, until this process exits.
// Returns nil on success, otherwise what went wrong (and the screen is left at normal).
// Call it once per process: after one mirror, CoreGraphics in the same process no longer sees a
// newly created virtual display, so switching resolution means starting a fresh process.
static NSString *apply(size_t w, size_t h, BOOL doMirror, unsigned serial) {
  CGDirectDisplayID builtin = builtinDisplay();
  if (!builtin) return @"No built-in display found (is the lid closed?).";

  CGVirtualDisplayDescriptor *desc = [CGVirtualDisplayDescriptor new];
  desc.queue = dispatch_get_main_queue();
  desc.name = @"HiDPI";
  desc.maxPixelsWide = w * 2;
  desc.maxPixelsHigh = h * 2;
  desc.sizeInMillimeters = CGDisplayScreenSize(builtin);
  desc.vendorID = 0x1d1d;
  desc.productID = 0x0001;
  desc.serialNum = serial;
  desc.redPrimary = CGPointMake(0.680, 0.320);  // Display P3 / D65, like the built-in panel
  desc.greenPrimary = CGPointMake(0.265, 0.690);
  desc.bluePrimary = CGPointMake(0.150, 0.060);
  desc.whitePoint = CGPointMake(0.3127, 0.3290);
  // Creation fails now and then just after another mirrored virtual display was removed, so retry for 3 s.
  __block CGVirtualDisplay *vd;
  if (!waitFor(^BOOL { return (vd = [[CGVirtualDisplay alloc] initWithDescriptor:desc]) != nil; }))
    return @"Could not create the virtual display.";

  // With hiDPI set, a WxH mode comes up as WxH points backed by 2Wx2H pixels, and is the default mode.
  // Same refresh rate as the panel (120 Hz here) so ProMotion survives; fall back to 60 if it will not come up.
  CGDisplayModeRef bm = CGDisplayCopyDisplayMode(builtin);
  double hz = bm ? CGDisplayModeGetRefreshRate(bm) : 0;
  CGDisplayModeRelease(bm);
  if (hz <= 0) hz = 60;
  CGDirectDisplayID v = vd.displayID;
  BOOL up = NO;
  double rates[2] = {hz, 60};
  for (int i = 0; i < 2 && !up; i++) {
    CGVirtualDisplaySettings *s = [CGVirtualDisplaySettings new];
    s.hiDPI = 1;
    s.modes = @[ [[CGVirtualDisplayMode alloc] initWithWidth:w height:h refreshRate:rates[i]] ];
    up = [vd applySettings:s] && waitFor(^BOOL { return CGDisplayIsOnline(v) && CGDisplayPixelsWide(v) == w; });
  }
  if (!up) return @"The virtual display did not come up. A macOS update may have changed the private API.";

  // The built-in screen mirrors the virtual one, so macOS renders at 2x and scales down to the panel.
  if (doMirror) {
    CGError e = mirror(builtin, v);
    if (e != kCGErrorSuccess) return [NSString stringWithFormat:@"Display configuration failed (CGError %d).", e];
    if (!waitFor(^BOOL { return pixelWidth(builtin) == 2 * w; })) {
      mirror(builtin, kCGNullDirectDisplay);
      return @"The screen switched but not at 2x, so it would be blurry. A macOS update may have changed the private API.";
    }
  }
  gDisplay = vd;
  return nil;
}

@interface App : NSObject <NSApplicationDelegate, NSMenuDelegate>
@property(strong) NSStatusItem *item;
@property(strong) NSTask *helper;  // a mirrored size: this same binary in --child mode, holding it
@property(nonatomic) BOOL native;  // a native size: the display is on one of its own modes, nothing else runs
@property(strong) NSDate *started;
@property(strong) NSMenuItem *customItem;  // the saved custom width, hidden when it is a preset or unset
@property(nonatomic) NSInteger wanted;  // width the user wants; 0 = Normal. reconcile makes reality match.
@property(nonatomic) int restarts;
@end

static BOOL setLogin(BOOL on, NSError **e) {
  SMAppService *s = [SMAppService mainAppService];
  return on ? [s registerAndReturnError:e] : [s unregisterAndReturnError:e];
}

static NSUserDefaults *prefs(void) { return NSUserDefaults.standardUserDefaults; }

static OSStatus hotKeyPressed(EventHandlerCallRef next, EventRef event, void *app);

@implementation App
- (void)applicationDidFinishLaunching:(NSNotification *)note {
  self.item = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
  self.item.button.image = [NSImage imageWithSystemSymbolName:@"display" accessibilityDescription:@"HiDPI"];
  self.item.button.imagePosition = NSImageLeft;
  NSMenu *menu = [NSMenu new];
  menu.delegate = self;
  [self addTo:menu title:@"Normal" action:@selector(pick:) tag:0];
  for (size_t i = 0; i < sizeof kWidths / sizeof *kWidths; i++) [self addTo:menu title:@"" action:@selector(pick:) tag:(NSInteger)kWidths[i]];
  self.customItem = [self addTo:menu title:@"" action:@selector(pick:) tag:0];
  [self addTo:menu title:@"Custom…" action:@selector(custom) tag:0];
  [menu addItem:NSMenuItem.separatorItem];
  NSMenuItem *t = [self addTo:menu title:@"Toggle on/off" action:@selector(toggle) tag:0];
  t.keyEquivalent = @"h";
  t.keyEquivalentModifierMask = NSEventModifierFlagControl | NSEventModifierFlagOption | NSEventModifierFlagCommand;
  [self addTo:menu title:@"Start at login" action:@selector(toggleLogin) tag:0];
  [menu addItem:NSMenuItem.separatorItem];
  [menu addItemWithTitle:@"Quit HiDPI" action:@selector(terminate:) keyEquivalent:@"q"];
  self.item.menu = menu;

  // ponytail: fixed Ctrl-Opt-Cmd-H, not configurable. Carbon hotkeys need no permission, unlike NSEvent monitors.
  EventTypeSpec press = {kEventClassKeyboard, kEventHotKeyPressed};
  InstallApplicationEventHandler(hotKeyPressed, 1, &press, (__bridge void *)self, NULL);
  EventHotKeyRef ref;
  OSStatus st = RegisterEventHotKey(kVK_ANSI_H, controlKey | optionKey | cmdKey, (EventHotKeyID){'hidp', 1}, GetApplicationEventTarget(), 0, &ref);
  if (st != noErr) NSLog(@"HiDPI: could not register Ctrl-Opt-Cmd-H (%d)", (int)st);

  NSNotificationCenter *ws = NSWorkspace.sharedWorkspace.notificationCenter;
  for (NSString *n in @[ NSWorkspaceScreensDidWakeNotification, NSWorkspaceDidWakeNotification ])
    [ws addObserver:self selector:@selector(reconcileSoon) name:n object:nil];
  [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reconcileSoon) name:NSApplicationDidChangeScreenParametersNotification object:nil];

  self.wanted = [prefs() integerForKey:@"width"];
  [self refresh];
  [self reconcile];
}

- (NSMenuItem *)addTo:(NSMenu *)menu title:(NSString *)title action:(SEL)action tag:(NSInteger)tag {
  NSMenuItem *i = [menu addItemWithTitle:title action:action keyEquivalent:@""];
  i.target = self;
  i.tag = tag;  // for pick: the tag is the width; 0 is Normal
  return i;
}

// Titles, ticks and the status item all follow from the state, so every change just calls this.
- (void)refresh {
  NSInteger custom = [prefs() integerForKey:@"customWidth"];
  BOOL preset = NO;
  for (size_t i = 0; i < sizeof kWidths / sizeof *kWidths; i++) preset |= (NSInteger)kWidths[i] == custom;
  self.customItem.tag = custom;
  self.customItem.hidden = !custom || preset;
  for (NSMenuItem *i in self.item.menu.itemArray) {
    if (i.action == @selector(pick:)) {
      size_t w = (size_t)i.tag;
      if (w) i.title = [NSString stringWithFormat:@"%@%zu × %zu", i == self.customItem ? @"Custom: " : @"", w, heightFor(w)];
      i.state = (NSInteger)w == self.wanted && !i.hidden;
    } else if (i.action == @selector(toggleLogin)) {
      i.state = [SMAppService mainAppService].status == SMAppServiceStatusEnabled;
    }
  }
  self.item.button.title = self.wanted ? @(self.wanted).stringValue : @"";
}

- (void)menuNeedsUpdate:(NSMenu *)menu { [self refresh]; }

// Back to the resolution set in System Settings, whichever way we left it.
- (void)revert {
  NSTask *t = self.helper;
  self.helper = nil;  // cleared first, so the termination handler knows we stopped it
  [t terminate];  // the screen reverts when the helper dies
  [t waitUntilExit];
  // The mirror takes a moment to dissolve, and until then the display is in a transient mode.
  for (int i = 0; t && i < 30 && CGDisplayIsInMirrorSet(builtinDisplay()); i++) usleep(100000);
  if (self.native) CGRestorePermanentDisplayConfiguration();
  self.native = NO;
}

- (BOOL)healthy {
  CGDirectDisplayID b = builtinDisplay();
  // A mirrored size is in a mirror set and a native one is not. "In a mirror set", not "mirrors X":
  // while the display sleeps, CGDisplayMirrorsDisplay reports 0 for an intact mirror.
  return b && !CGDisplayIsInMirrorSet(b) == self.native && (NSInteger)pixelWidth(b) == 2 * self.wanted;
}

// Every non-zero width is also what Toggle comes back to, however it was chosen (menu, launch or shortcut).
- (void)setWanted:(NSInteger)w {
  _wanted = w;
  if (w) [prefs() setInteger:w forKey:@"lastWidth"];
}

// Makes reality match `wanted`. Safe to call at any time and as often as you like.
- (void)reconcile {
  if (!self.wanted || !builtinDisplay()) return [self revert];  // lid closed or display asleep is not an error: a later event retries
  BOOL on = self.helper || self.native;
  if (on && [self healthy]) return;
  if (on && -self.started.timeIntervalSinceNow < 5) return [self reconcileSoon];  // still settling
  [self revert];
  // ponytail: no backoff beyond the 2 s debounce; three quick restarts and it gives up for the session.
  // Restarts only count when they follow each other closely, so sleeping and waking all week is fine.
  if (-self.started.timeIntervalSinceNow > 120) self.restarts = 0;
  if (self.restarts >= 3) {
    self.wanted = 0;  // for this session only: the saved width stays
    [self refresh];
    return [self alert:@"HiDPI could not keep the resolution" text:@"The resolution was lost several times after the display changed, so HiDPI went back to Normal."];
  }
  self.restarts++;
  [self start];
}

- (void)reconcileSoon {
  [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(reconcile) object:nil];
  [self performSelector:@selector(reconcile) withObject:nil afterDelay:2];
}

- (void)start {
  self.started = NSDate.date;
  CGDisplayModeRef m = nativeMode((size_t)self.wanted);
  if (m) {
    CGError e = setMode(m);
    CGDisplayModeRelease(m);
    self.native = e == kCGErrorSuccess;
    if (!self.native) [self failed:[NSString stringWithFormat:@"Display configuration failed (CGError %d).", e]];
    return;
  }
  NSTask *t = [NSTask new];
  t.executableURL = NSBundle.mainBundle.executableURL;
  t.arguments = @[ @"--child", @(self.wanted).stringValue ];
  NSPipe *errPipe = [NSPipe pipe];
  t.standardError = errPipe;
  t.terminationHandler = ^(NSTask *done) {
    NSData *d = [errPipe.fileHandleForReading readDataToEndOfFile];
    NSString *why = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    dispatch_async(dispatch_get_main_queue(), ^{
      if (done != self.helper) return;  // we stopped it ourselves
      self.helper = nil;
      if (done.terminationReason == NSTaskTerminationReasonExit && done.terminationStatus != 0) {
        if (builtinDisplay()) [self failed:why];  // gave up for a real reason; with the screen off, wait for the next event
      } else {
        [self reconcileSoon];  // killed or lost: put it back
      }
    });
  };
  NSError *e;
  self.helper = t;
  if (![t launchAndReturnError:&e]) [self failed:e.localizedDescription];
}

// The user picked a width (0 = Normal). Applies at once and is remembered.
- (void)select:(NSInteger)w {
  if (w != self.wanted) [self revert];
  self.wanted = w;
  [prefs() setInteger:w forKey:@"width"];
  self.restarts = -1;  // a pick's own start is not a restart
  [self reconcile];
  [self refresh];
}

- (void)pick:(NSMenuItem *)sender { [self select:sender.tag]; }

// Takes the width from the Custom dialog. Returns nil, or a message for the user.
- (NSString *)useCustomWidth:(NSInteger)w {
  if (w < 1024 || w > 3840) return @"Enter a width from 1024 to 3840.";
  [prefs() setInteger:w forKey:@"customWidth"];
  [self select:w];
  return nil;
}

- (void)custom {
  NSAlert *a = [NSAlert new];
  a.messageText = @"Custom width";
  a.informativeText = @"Width in points, 1024 to 3840. Sizes the display has as its own modes use the full height; others are mirrored at 16:10.";
  [a addButtonWithTitle:@"Apply"];
  [a addButtonWithTitle:@"Cancel"];
  NSTextField *f = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 200, 24)];
  a.accessoryView = f;
  a.window.initialFirstResponder = f;
  [NSApp activate];
  if ([a runModal] != NSAlertFirstButtonReturn) return;
  NSString *err = [self useCustomWidth:f.stringValue.integerValue];
  if (err) [self alert:@"Custom width" text:err];
}

- (void)toggle {
  [self select:self.wanted ? 0 : ([prefs() integerForKey:@"lastWidth"] ?: 2048)];
}

- (void)toggleLogin {
  NSError *e;
  if (!setLogin([SMAppService mainAppService].status != SMAppServiceStatusEnabled, &e)) [self alert:@"Could not change Start at login" text:e.localizedDescription];
  [self refresh];
}

- (void)alert:(NSString *)title text:(NSString *)text {
  NSLog(@"%@: %@", title, text);
  NSAlert *alert = [NSAlert new];
  alert.messageText = title;
  alert.informativeText = text ?: @"";
  [NSApp activate];
  [alert runModal];
}

- (void)failed:(NSString *)why {
  self.helper = nil;
  self.native = NO;
  self.wanted = 0;
  [prefs() setInteger:0 forKey:@"width"];
  [self refresh];
  [self alert:@"HiDPI could not switch resolution" text:why];
}

- (void)applicationWillTerminate:(NSNotification *)note {
  [self revert];
}
@end

static OSStatus hotKeyPressed(EventHandlerCallRef next, EventRef event, void *app) {
  [(__bridge App *)app toggle];
  return noErr;
}

static int cli(int argc, char **argv) {
  BOOL child = !strcmp(argv[1], "--child");  // passed by the app: die with it, even on a force-quit
  if (child) { argc--; argv++; }
  BOOL probe = argc > 1 && !strcmp(argv[1], "--probe");
  int a = probe ? 2 : 1;
  size_t w = argc > a ? (size_t)atoi(argv[a]) : 0;
  size_t h = mirroredHeight(w);
  if (w < 1024 || w > 3840) {
    fprintf(stderr, "usage: HiDPI [--child] [--probe] <width 1024-3840>\n");
    return 2;
  }
  static dispatch_source_t parentWatch;  // static so ARC keeps it alive
  if (child) {
    pid_t parent = getppid();
    if (parent == 1) return 0;
    parentWatch = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, parent, DISPATCH_PROC_EXIT, dispatch_get_main_queue());
    dispatch_source_set_event_handler(parentWatch, ^{ exit(0); });
    dispatch_resume(parentWatch);
    if (getppid() != parent) return 0;  // parent died before the watch was armed
  }
  // Different serial for the probe, so it can run while a real helper holds its display.
  NSString *err = apply(w, h, !probe, probe ? 2 : 1);
  if (err) {
    fprintf(stderr, "%s\n", err.UTF8String);
    return 1;
  }
  printf("virtual display %u online at %zux%zu\n", gDisplay.displayID, w, h);
  if (probe) return 0;
  printf("built-in display now at %zux%zu, %zu pixels wide. Ctrl-C to revert.\n", w, h, w * 2);
  fflush(stdout);
  CFRunLoopRun();
  return 0;
}

static int loginCli(const char *arg) {
  BOOL on = arg && !strcmp(arg, "on"), off = arg && !strcmp(arg, "off");
  if (!on && !off && !(arg && !strcmp(arg, "status"))) {  // anything else must not change the login item
    fprintf(stderr, "usage: HiDPI --login on|off|status\n");
    return 2;
  }
  NSError *e;
  if ((on || off) && !setLogin(on, &e)) {
    fprintf(stderr, "%s\n", e.description.UTF8String);
    return 1;
  }
  const char *names[] = {"not registered", "enabled", "requires approval", "not found"};
  printf("start at login: %s\n", names[[SMAppService mainAppService].status]);
  return 0;
}

// Self-check for the native path: what each menu width would give right now.
static int listSizes(void) {
  if (!builtinDisplay()) return fprintf(stderr, "No built-in display found (is the lid closed?).\n"), 1;
  for (size_t i = 0; i < sizeof kWidths / sizeof *kWidths; i++) {
    CGDisplayModeRef m = nativeMode(kWidths[i]);
    printf("%zu x %zu  %s\n", kWidths[i], heightFor(kWidths[i]), m ? "native" : "mirrored (no native mode; see --override)");
    CGDisplayModeRelease(m);
  }
  return 0;
}

// Writes a display override that makes the menu widths native 2x sizes of the built-in display, and prints how
// to install it. macOS builds a display's list of scaled sizes from "scale-resolutions" in such a file and reads
// it only at startup. Format as in Apple's own files and the display-scale project (github.com/utsavsingh899/display-scale).
static int writeOverride(NSString *dir) {
  CGDirectDisplayID b = builtinDisplay();
  if (!b) return fprintf(stderr, "No built-in display found (is the lid closed?).\n"), 1;
  size_t nw = 0, nh = 0;  // the panel itself: its largest native-flagged mode (scaled modes can have more pixels)
  for (id o in modesOf(b)) {
    CGDisplayModeRef m = (__bridge CGDisplayModeRef)o;
    if ((CGDisplayModeGetIOFlags(m) & kDisplayModeNativeFlag) && CGDisplayModeGetPixelWidth(m) > nw) { nw = CGDisplayModeGetPixelWidth(m); nh = CGDisplayModeGetPixelHeight(m); }
  }
  if (!nw) return fprintf(stderr, "Could not find the panel's native size.\n"), 1;
  NSString *rel = [NSString stringWithFormat:@"Displays/Contents/Resources/Overrides/DisplayVendorID-%x", CGDisplayVendorNumber(b)];
  NSString *name = [NSString stringWithFormat:@"DisplayProductID-%x", CGDisplayModelNumber(b)];
  // Start from Apple's own file for this panel, so nothing it defines is lost if ours replaces it.
  NSString *apple = [NSString stringWithFormat:@"/System/Library/%@/%@", rel, name];
  NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:apple] ?: [NSMutableDictionary dictionary];
  d[@"DisplayVendorID"] = @(CGDisplayVendorNumber(b));
  d[@"DisplayProductID"] = @(CGDisplayModelNumber(b));
  NSMutableArray *list = [NSMutableArray arrayWithArray:d[@"scale-resolutions"] ?: @[]];
  for (size_t i = 0; i < sizeof kWidths / sizeof *kWidths; i++) {
    if (kWidths[i] > nw) continue;  // rendered at 2x, and the display scales down by at most 2x
    // Rendered size: 2x, in the panel's own shape so it includes the strip beside the notch.
    uint32_t w = htonl((uint32_t)kWidths[i] * 2), h = htonl((uint32_t)lround((double)kWidths[i] * nh / nw) * 2);
    uint32_t plain[2] = {w, h}, flagged[4] = {w, h, htonl(0x00000009), htonl(0x00200000)};  // the flags mark a HiDPI size
    for (NSData *e in @[ [NSData dataWithBytes:plain length:8], [NSData dataWithBytes:flagged length:16] ])
      if (![list containsObject:e]) [list addObject:e];
  }
  d[@"scale-resolutions"] = list;
  NSString *file = [dir stringByAppendingPathComponent:name];
  [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
  NSData *xml = [NSPropertyListSerialization dataWithPropertyList:d format:NSPropertyListXMLFormat_v1_0 options:0 error:nil];
  if (![xml writeToFile:file atomically:YES]) return fprintf(stderr, "Could not write %s\n", file.UTF8String), 1;
  printf("Wrote %s\n\nInstall (asks for your password), then restart the Mac:\n"
         "  sudo mkdir -p /Library/%s\n  sudo install -o root -g wheel -m 0644 '%s' /Library/%s/\n\n"
         "Check after the restart:\n  HiDPI --sizes\n\nUndo, then restart:\n  sudo rm /Library/%s/%s\n",
         file.UTF8String, rel.UTF8String, file.UTF8String, rel.UTF8String, rel.UTF8String, name.UTF8String);
  return 0;
}

// Draws the iconset PNGs off-screen: a dark rounded square with a white display symbol.
static int writeIcons(NSString *dir) {
  NSImageSymbolConfiguration *white = [NSImageSymbolConfiguration configurationWithPaletteColors:@[ NSColor.whiteColor, [NSColor.whiteColor colorWithAlphaComponent:0.15] ]];
  [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
  const int sizes[] = {16, 32, 128, 256, 512};
  for (int k = 0; k < 5; k++)
    for (int scale = 1; scale <= 2; scale++) {
      int size = sizes[k];
      int px = size * scale;
      NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:px pixelsHigh:px bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
      [NSGraphicsContext saveGraphicsState];
      NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
      NSRect r = NSInsetRect(NSMakeRect(0, 0, px, px), px * 0.08, px * 0.08);  // the usual margin around macOS icons
      NSBezierPath *shape = [NSBezierPath bezierPathWithRoundedRect:r xRadius:r.size.width * 0.225 yRadius:r.size.width * 0.225];
      [[[NSGradient alloc] initWithStartingColor:[NSColor colorWithRed:0.20 green:0.24 blue:0.34 alpha:1] endingColor:[NSColor colorWithRed:0.04 green:0.05 blue:0.10 alpha:1]] drawInBezierPath:shape angle:-90];
      NSImage *sym = [[NSImage imageWithSystemSymbolName:@"display" accessibilityDescription:nil] imageWithSymbolConfiguration:[[NSImageSymbolConfiguration configurationWithPointSize:px * 0.45 weight:NSFontWeightRegular] configurationByApplyingConfiguration:white]];
      [sym drawInRect:NSMakeRect((px - sym.size.width) / 2, (px - sym.size.height) / 2, sym.size.width, sym.size.height)];
      [NSGraphicsContext restoreGraphicsState];
      NSString *name = [NSString stringWithFormat:@"icon_%dx%d%@.png", size, size, scale == 2 ? @"@2x" : @""];
      if (![[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:[dir stringByAppendingPathComponent:name] atomically:YES]) return 1;
    }
  return 0;
}

int main(int argc, char **argv) {
  @autoreleasepool {
    if (argc > 1 && !strcmp(argv[1], "--login")) return loginCli(argv[2]);
    if (argc > 2 && !strcmp(argv[1], "--icon")) return writeIcons(@(argv[2]));
    if (argc > 1 && !strcmp(argv[1], "--sizes")) return listSizes();
    if (argc > 2 && !strcmp(argv[1], "--override")) return writeOverride(@(argv[2]));
    if (argc > 1) return cli(argc, argv);
    App *delegate = [App new];
    NSApplication.sharedApplication.delegate = delegate;
    [NSApp run];
  }
  return 0;
}
