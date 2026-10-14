#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOKit/pwr_mgt/IOPMLib.h>
#import <Carbon/Carbon.h>
#import <dlfcn.h>
#import <signal.h>
#import "VDVirtualDisplay.h"
#import "YMDisplayTopology.h"
#import "LayoutPolicy.h"
#import "DiagnosticPrivacy.h"
#import "ControlUI.h"
#import "WindowRecovery.h"
#import "AppWorkspace.h"
#import "AppWorkspaceView.h"
#import "UpdateChecker.h"
#import "MenuBarIcon.h"
#import "PanelPresentation.h"
#import "YMControl.h" // fork: fork-features/control
#import "YMAgentClient.h" // fork: fork-features/agent

static NSString *YMAppVersion(void) {
    return [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"—";
}
static NSImage *YMBrandIcon(void) {
    NSURL *url = [NSBundle.mainBundle URLForResource:@"Yomado" withExtension:@"icns"];
    return url ? [[NSImage alloc] initWithContentsOfURL:url] : nil;
}

typedef CGError (*ADEnableFunction)(CGDisplayConfigRef, CGDirectDisplayID, bool);
static ADEnableFunction EnableAPI(void) {
    static ADEnableFunction fn;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *cg = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY);
        if (cg) fn = (ADEnableFunction)dlsym(cg, "CGSConfigureDisplayEnabled");
        if (!fn) {
            void *sl = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
            if (sl) fn = (ADEnableFunction)dlsym(sl, "SLSConfigureDisplayEnabled");
        }
    });
    return fn;
}
static BOOL ConfigureEnabled(NSArray<NSNumber *> *ids, BOOL enabled, NSString **message) {
    ADEnableFunction fn = EnableAPI();
    if (!fn) { if (message) *message = @"当前系统没有实体显示器开关接口。"; return NO; }
    CGDisplayConfigRef config = NULL;
    CGError err = CGBeginDisplayConfiguration(&config);
    if (err != kCGErrorSuccess || !config) {
        if (message) *message = [NSString stringWithFormat:@"无法开始显示设置（%d）。", err];
        return NO;
    }
    for (NSNumber *item in ids) {
        err = fn(config, item.unsignedIntValue, enabled);
        if (err != kCGErrorSuccess) {
            CGCancelDisplayConfiguration(config);
            if (message) *message = [NSString stringWithFormat:@"显示器 %@ 设置失败（%d）。", item, err];
            return NO;
        }
    }
    // This is never written into the permanent macOS display configuration.
    err = CGCompleteDisplayConfiguration(config, kCGConfigureForSession);
    if (err != kCGErrorSuccess && message) *message = [NSString stringWithFormat:@"显示设置未完成（%d）。", err];
    return err == kCGErrorSuccess;
}
static NSArray<NSDictionary *> *DisplaySnapshot(void) { return [VDVirtualDisplay onlineDisplays]; }
static BOOL ADDisplayActive(CGDirectDisplayID ident) {
    CGDirectDisplayID ids[64] = {0}; CGDisplayCount count = 0;
    if (!ident || CGGetActiveDisplayList(64, ids, &count) != kCGErrorSuccess) return NO;
    for (CGDisplayCount i = 0; i < count; i++) if (ids[i] == ident) return YES;
    return NO;
}
static BOOL ADDisplayOnline(CGDirectDisplayID ident) {
    CGDirectDisplayID ids[64] = {0}; CGDisplayCount count = 0;
    if (!ident || CGGetOnlineDisplayList(64, ids, &count) != kCGErrorSuccess) return NO;
    for (CGDisplayCount i = 0; i < count; i++) if (ids[i] == ident) return YES;
    return NO;
}
static BOOL WaitUntil(BOOL (^predicate)(void), NSTimeInterval seconds) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (!predicate() && deadline.timeIntervalSinceNow > 0) {
        @autoreleasepool {
            NSDate *step = [NSDate dateWithTimeIntervalSinceNow:0.05];
            NSEvent *event = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:step inMode:NSDefaultRunLoopMode dequeue:YES];
            if (event) [NSApp sendEvent:event];
            [[NSRunLoop currentRunLoop] runUntilDate:step];
        }
    }
    return predicate();
}
static NSString *JSONTextWithIdentifiers(id object, BOOL includeIdentifiers) {
    id report = includeIdentifiers ? object : YMRedactedDiagnostics(object);
    NSData *data = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"{}";
}
static NSString *JSONText(id object) { return JSONTextWithIdentifiers(object, NO); }

@interface ADTestView : NSView
@property NSInteger frameNumber;
@end
@implementation ADTestView
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    [[NSColor colorWithCalibratedRed:0.07 green:0.11 blue:0.20 alpha:1] setFill];
    NSRectFill(self.bounds);
    NSDictionary *attrs = @{NSFontAttributeName:[NSFont systemFontOfSize:28 weight:NSFontWeightSemibold],
                            NSForegroundColorAttributeName:NSColor.whiteColor};
    [[NSString stringWithFormat:@"Yomado · frame %ld", (long)self.frameNumber]
        drawAtPoint:NSMakePoint(28, 150) withAttributes:attrs];
    [[NSColor colorWithCalibratedRed:0.24 green:0.65 blue:0.93 alpha:1] setFill];
    NSRectFill(NSMakeRect(30 + self.frameNumber * 95, 35, 70, 70));
}
- (NSData *)PNGData {
    [self displayIfNeeded];
    NSBitmapImageRep *bitmap = [self bitmapImageRepForCachingDisplayInRect:self.bounds];
    [self cacheDisplayInRect:self.bounds toBitmapImageRep:bitmap];
    return [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
}
@end

// Names and dimensions are local user preferences. Display objects stay alive
// independently, so closing one workspace never removes a sibling display.
@interface YMManagedDisplay : NSObject
@property NSUInteger ordinal;
@property(copy) NSString *friendlyName;
@property NSUInteger width;
@property NSUInteger height;
@property BOOL hiDPI;
@property VDVirtualDisplay *display;
@property BOOL topologyVerified;
@end
@implementation YMManagedDisplay
@end

@interface ADController : NSObject <NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate>
@property NSWindow *window;
@property NSStatusItem *statusItem;
@property YMUpdateChecker *updateChecker;
@property NSButton *updateButton;
@property NSAlert *updateAlert;
@property NSTextField *statusLabel;
@property NSTextField *inventoryLabel;
@property NSTextField *detailLabel;
@property YMStatusPill *statusPill;
@property NSTextField *wechatStatusLabel;
@property NSTextField *wechatPermissionGuide;
@property(copy) NSString *wechatPermissionMessage;
@property NSButton *wechatMoveButton;
@property NSButton *wechatRestoreButton;
@property NSButton *wechatPermissionButton;
@property YMWindowRecovery *windowRecovery;
@property BOOL previewMode;
@property(copy) NSString *previewState;
@property(copy) NSArray<NSDictionary *> *previewSnapshot;
@property NSPopUpButton *physicalChoice;
@property NSButton *testButton;
@property NSButton *keepButton;
@property NSButton *restoreButton;
@property VDVirtualDisplay *virtualDisplay; // Selected target for the legacy guarded physical-output trial.
@property NSMutableArray<YMManagedDisplay *> *displayProfiles;
@property YMManagedDisplay *selectedProfile;
@property NSButton *addDisplayButton;
@property YMAppWorkspace *appWorkspace;
@property NSStackView *applicationCards;
@property NSView *permissionContainer;
@property NSMutableDictionary<NSNumber *, YMAppWorkspaceView *> *workspaceViews;
@property(copy) NSArray<NSNumber *> *workspaceViewIDs;
@property(copy) NSArray<NSString *> *workspaceLayoutSignature;
@property CGDirectDisplayID wechatDisplayID;
@property BOOL updatingInventory;
@property BOOL displayOperationInProgress;
@property(nonatomic) YMDisplayTopology *displayTopology;
@property YMDisplayTopologySnapshot *topologyRecoverySnapshot;
@property CGDirectDisplayID topologyRecoveryRemovedID;
@property(nonatomic) dispatch_queue_t topologyQueue;
@property BOOL terminationAfterTopologyRecovery;
@property BOOL appOperationInProgress;
@property NSArray<NSDictionary *> *originalLayout;
@property CGDirectDisplayID originalMain;
@property NSArray<NSNumber *> *targets;
@property NSTask *watchdog;
@property NSString *statePath;
@property NSTimer *heartbeatTimer;
@property BOOL armed;
@property BOOL preparing;
@property BOOL restoring;
@property BOOL recoveryRequested;
@property BOOL layoutChangedForTrial;
@property NSUInteger operationGeneration;
@property NSTimeInterval trialDeadline;
@property IOPMAssertionID systemAssertion;
@property IOPMAssertionID displayAssertion;
@property EventHotKeyRef hotkey;
@property EventHandlerRef keyHandler;
@property YMControlServer *controlServer; // fork: screen control CLI
@property BOOL controlRequestActive;       // fork: a CLI request owns error reporting; no alerts
- (void)restore:(id)sender;
- (void)buildWindow;
- (void)updateInventory;
@end
@interface ADController (YMControl) // fork: implemented at the end of this file
- (void)handleControlRequest:(YMControlRequest *)request reply:(YMControlReply)reply;
@end

static OSStatus RecoveryHotkey(EventHandlerCallRef next, EventRef event, void *data) {
    (void)next; (void)event;
    ADController *controller = (__bridge ADController *)data;
    [controller restore:nil];
    return noErr;
}
static NSTextField *Label(NSString *text, CGFloat size, NSFontWeight weight) {
    NSTextField *label = [NSTextField wrappingLabelWithString:text];
    label.font = [NSFont systemFontOfSize:size weight:weight];
    label.lineBreakMode = NSLineBreakByWordWrapping;
    return label;
}
static NSStackView *YMStack(NSUserInterfaceLayoutOrientation orientation, CGFloat spacing) {
    NSStackView *stack = [[NSStackView alloc] init];
    stack.orientation = orientation;
    stack.alignment = orientation == NSUserInterfaceLayoutOrientationVertical ? NSLayoutAttributeLeading : NSLayoutAttributeCenterY;
    stack.spacing = spacing;
    stack.distribution = NSStackViewDistributionFill;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.detachesHiddenViews = YES;
    return stack;
}
static void YMFillWidth(NSView *child, NSView *parent) {
    [child.widthAnchor constraintEqualToAnchor:parent.widthAnchor].active = YES;
}
static NSView *YMSpacer(void) {
    NSView *spacer = [[NSView alloc] init];
    [spacer setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    return spacer;
}
@interface YMDocumentView : NSView
@end
@implementation YMDocumentView
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    [[NSColor.windowBackgroundColor blendedColorWithFraction:0.035 ofColor:NSColor.labelColor] setFill];
    NSRectFill(self.bounds);
}
@end

@implementation ADController
- (YMDisplayTopology *)displayTopology {
    if (!_displayTopology) _displayTopology = [[YMDisplayTopology alloc] init];
    return _displayTopology;
}
- (BOOL)canMoveIntoProfile:(YMManagedDisplay *)profile {
    return profile && profile.topologyVerified && !self.displayOperationInProgress && !self.topologyRecoverySnapshot && profile.display.isCreated &&
        [self.displayTopology isExtendedTarget:profile.display.displayID width:profile.width height:profile.height hiDPI:profile.hiDPI];
}
- (void)reportTopologyError:(NSError *)error {
    self.statusLabel.stringValue = @"显示配置未通过检查";
    self.detailLabel.stringValue = error.localizedDescription ?: @"未能确认原有屏幕配置保持不变；已停止移入应用。";
    if (!self.previewMode && !self.controlRequestActive && self.window && !self.window.attachedSheet) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"工作屏未就绪";
        alert.informativeText = self.detailLabel.stringValue;
        [alert addButtonWithTitle:@"好"];
        [self showWindow:nil];
        [alert beginSheetModalForWindow:self.window completionHandler:nil];
    }
}
// CoreGraphics may not publish a new screen's mode to this process until
// AppKit handles its display-change event. Keep the normal main event loop free
// instead of recursively dispatching user input inside a configuration wait.
- (void)performTopologyOperation:(BOOL (^)(NSError **))operation completion:(void (^)(BOOL, NSError *))completion {
    if (!self.topologyQueue) self.topologyQueue = dispatch_queue_create("dev.chekusu.yomado.topology", DISPATCH_QUEUE_SERIAL);
    dispatch_async(self.topologyQueue, ^{
        @autoreleasepool {
            NSError *error = nil;
            BOOL result = operation(&error);
            dispatch_async(dispatch_get_main_queue(), ^{ completion(result, error); });
        }
    });
}
- (void)resumeTerminationAfterTopologyRecovery:(BOOL)recovered {
    BOOL requested = self.terminationAfterTopologyRecovery;
    self.terminationAfterTopologyRecovery = NO;
    if (requested && recovered) dispatch_async(dispatch_get_main_queue(), ^{ [NSApp terminate:nil]; });
}
- (void)recoverTopology:(YMDisplayTopologySnapshot *)snapshot removedID:(CGDirectDisplayID)removedID completion:(void (^)(BOOL, NSError *))completion {
    self.topologyRecoverySnapshot = snapshot;
    self.topologyRecoveryRemovedID = removedID;
    YMDisplayTopology *topology = self.displayTopology;
    [self performTopologyOperation:^BOOL(NSError **error) {
        return [topology restoreAndVerifySnapshot:snapshot excludingDisplayID:removedID error:error];
    } completion:^(BOOL restored, NSError *error) {
        if (restored) { self.topologyRecoverySnapshot = nil; self.topologyRecoveryRemovedID = 0; }
        completion(restored, error);
    }];
}
- (void)retryTopologyRecovery:(id)sender {
    (void)sender;
    if (!self.topologyRecoverySnapshot || self.displayOperationInProgress || self.appOperationInProgress) return;
    self.displayOperationInProgress = YES;
    [self recoverTopology:self.topologyRecoverySnapshot removedID:self.topologyRecoveryRemovedID completion:^(BOOL restored, NSError *error) {
        self.displayOperationInProgress = NO;
        if (!restored) [self reportTopologyError:error];
        [self updateInventory];
        [self resumeTerminationAfterTopologyRecovery:restored];
    }];
}
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    if (self.previewMode) return;
    (void)notification;
    [self loadDisplayProfiles];
    self.appWorkspace = [[YMAppWorkspace alloc] init];
    self.windowRecovery = [[YMWindowRecovery alloc] initWithCheckpointURL:nil];
    self.targets = @[];
    self.systemAssertion = kIOPMNullAssertionID;
    self.displayAssertion = kIOPMNullAssertionID;
    self.statePath = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"Yomado-%@.json", NSUUID.UUID.UUIDString]];
    [self buildMenu];
    NSMenu *main = [[NSMenu alloc] init];
    NSMenuItem *appItem = [[NSMenuItem alloc] initWithTitle:@"yomado" action:nil keyEquivalent:@""];
    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"yomado"];
    NSMenuItem *updateItem = [[NSMenuItem alloc] initWithTitle:@"检查更新…" action:@selector(checkForUpdates:) keyEquivalent:@""];
    updateItem.target = self;
    [appMenu addItem:updateItem];
    [appMenu addItem:NSMenuItem.separatorItem];
    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:@"退出 yomado" action:@selector(quit:) keyEquivalent:@"q"];
    quitItem.target = self;
    [appMenu addItem:quitItem];
    appItem.submenu = appMenu;
    [main addItem:appItem];
    NSApp.mainMenu = main;
    [self buildWindow];
    EventTypeSpec type = { kEventClassKeyboard, kEventHotKeyPressed };
    OSStatus handlerStatus = InstallEventHandler(GetApplicationEventTarget(), RecoveryHotkey, 1, &type,
                                                (__bridge void *)self, &_keyHandler);
    EventHotKeyID hotkeyID = { 'ADsp', 1 };
    OSStatus keyStatus = RegisterEventHotKey(kVK_ANSI_R, controlKey | optionKey | cmdKey,
                                            hotkeyID, GetApplicationEventTarget(), 0, &_hotkey);
    if (handlerStatus != noErr || keyStatus != noErr) {
        self.testButton.enabled = NO;
        self.detailLabel.stringValue = @"恢复快捷键注册失败；为保留恢复途径，实体屏关闭功能已停用。";
    }
    [self updateInventory];
    // fork: `Yomado screen ...` launches the app with --background; keep the panel hidden.
    if (![NSProcessInfo.processInfo.arguments containsObject:@"--background"]) [self showWindow:nil];
    NSError *controlError = nil;
    __weak ADController *weakSelf = self;
    self.controlServer = [[YMControlServer alloc] initWithHandler:^(YMControlRequest *request, YMControlReply reply) {
        ADController *controller = weakSelf;
        if (controller) [controller handleControlRequest:request reply:reply];
        else reply(YMControlFailure(@"yomado is shutting down"));
    } error:&controlError];
    if (!self.controlServer) NSLog(@"yomado: screen control CLI unavailable: %@", controlError.localizedDescription);
    self.heartbeatTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(tick:)
                                                       userInfo:nil repeats:YES];
    [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self selector:@selector(systemWillSleep:)
          name:NSWorkspaceWillSleepNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(displayParametersChanged:)
          name:NSApplicationDidChangeScreenParametersNotification object:nil];
}
- (NSArray<YMManagedDisplay *> *)activeProfiles {
    NSPredicate *active = [NSPredicate predicateWithBlock:^BOOL(YMManagedDisplay *profile, NSDictionary *bindings) {
        (void)bindings; return profile.display.isCreated;
    }];
    return [self.displayProfiles filteredArrayUsingPredicate:active];
}
- (NSString *)titleForProfile:(YMManagedDisplay *)profile {
    return [NSString stringWithFormat:@"虚拟屏 %lu · %@", (unsigned long)profile.ordinal, profile.friendlyName];
}
- (YMManagedDisplay *)profileForDisplayID:(CGDirectDisplayID)displayID {
    if (!displayID) return nil;
    for (YMManagedDisplay *profile in self.displayProfiles)
        if (profile.display.displayID == displayID) return profile;
    return nil;
}
- (YMManagedDisplay *)newProfileWithOrdinal:(NSUInteger)ordinal name:(NSString *)name width:(NSUInteger)width height:(NSUInteger)height hiDPI:(BOOL)hiDPI {
    YMManagedDisplay *profile = [[YMManagedDisplay alloc] init];
    profile.ordinal = ordinal;
    profile.friendlyName = name;
    profile.width = width; profile.height = height; profile.hiDPI = hiDPI;
    profile.display = [[VDVirtualDisplay alloc] initWithSerialNumber:(uint32_t)(0x594D0000 + ordinal)];
    return profile;
}
- (void)loadDisplayProfiles {
    self.displayProfiles = [NSMutableArray array];
    id saved = [NSUserDefaults.standardUserDefaults objectForKey:@"NamedDisplayProfiles"];
    NSMutableSet *ordinals = [NSMutableSet set];
    if ([saved isKindOfClass:NSArray.class]) {
        for (id value in saved) {
            if (![value isKindOfClass:NSDictionary.class]) continue;
            id rawOrdinal = value[@"ordinal"], rawName = value[@"name"];
            if (![rawOrdinal isKindOfClass:NSNumber.class] || ![rawName isKindOfClass:NSString.class]) continue;
            NSUInteger ordinal = [rawOrdinal unsignedIntegerValue];
            NSString *name = [rawName stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (!ordinal || ordinal > UINT16_MAX || [ordinals containsObject:@(ordinal)] || !name.length || name.length > 60) continue;
            BOOL wide = [value[@"width"] isKindOfClass:NSNumber.class] && [value[@"width"] unsignedIntegerValue] == 2560;
            BOOL hiDPI = [value[@"hiDPI"] isKindOfClass:NSNumber.class] && [value[@"hiDPI"] boolValue];
            [self.displayProfiles addObject:[self newProfileWithOrdinal:ordinal name:name width:wide ? 2560 : 1920 height:wide ? 1440 : 1080 hiDPI:hiDPI]];
            [ordinals addObject:@(ordinal)];
        }
    }
    if (!self.displayProfiles.count)
        [self.displayProfiles addObject:[self newProfileWithOrdinal:1 name:@"Codex" width:1920 height:1080 hiDPI:NO]];
    self.selectedProfile = self.displayProfiles.firstObject;
    self.virtualDisplay = self.selectedProfile.display;
}
- (void)saveDisplayProfiles {
    if (self.previewMode) return;
    NSMutableArray *saved = [NSMutableArray array];
    for (YMManagedDisplay *profile in self.displayProfiles)
        [saved addObject:@{@"ordinal":@(profile.ordinal), @"name":profile.friendlyName,
                          @"width":@(profile.width), @"hiDPI":@(profile.hiDPI)}];
    [NSUserDefaults.standardUserDefaults setObject:saved forKey:@"NamedDisplayProfiles"];
}
- (void)selectProfile:(YMManagedDisplay *)profile {
    if (!profile || self.armed || self.preparing || self.restoring || self.layoutChangedForTrial || self.displayOperationInProgress || self.appOperationInProgress) return;
    self.selectedProfile = profile;
    self.virtualDisplay = profile.display;
    [self updateInventory];
}
// fork: shared by the menu's 新增虚拟屏 and `Yomado screen create`.
- (YMManagedDisplay *)appendProfileNamed:(NSString *)name width:(NSUInteger)width hiDPI:(BOOL)hiDPI {
    NSUInteger ordinal = 1;
    for (YMManagedDisplay *profile in self.displayProfiles) ordinal = MAX(ordinal, profile.ordinal + 1);
    if (ordinal > UINT16_MAX) return nil;
    NSString *resolved = name ?: (ordinal == 2 ? @"GrokBot" : [NSString stringWithFormat:@"Agent %lu", (unsigned long)ordinal]);
    YMManagedDisplay *profile = [self newProfileWithOrdinal:ordinal name:resolved width:width
                                                     height:width == 2560 ? 1440 : 1080 hiDPI:hiDPI];
    [self.displayProfiles addObject:profile];
    [self saveDisplayProfiles];
    return profile;
}
- (void)addDisplay:(id)sender {
    (void)sender;
    if (self.previewMode || self.topologyRecoverySnapshot || self.armed || self.preparing || self.restoring || self.layoutChangedForTrial || self.displayOperationInProgress || self.appOperationInProgress) return;
    YMManagedDisplay *profile = [self appendProfileNamed:nil width:1920 hiDPI:NO];
    if (!profile) { self.detailLabel.stringValue = @"已达到可用的屏幕编号上限。"; return; }
    [self selectProfile:profile];
    [self create:nil];
}
- (void)buildMenu {
    if (self.previewMode) return;
    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.image = YMMenuBarIcon();
    self.statusItem.button.imageScaling = NSImageScaleProportionallyDown;
    self.statusItem.button.toolTip = @"yomado · 夜窗";
    [self.statusItem.button setAccessibilityLabel:@"yomado · 夜窗"];
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"yomado"];
    menu.delegate = self;
    self.statusItem.menu = menu;
    [self menuNeedsUpdate:menu];
}
- (NSMenuItem *)menuItem:(NSString *)title action:(SEL)action profile:(YMManagedDisplay *)profile {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:@""];
    item.target = self; item.representedObject = profile;
    return item;
}
- (void)menuNeedsUpdate:(NSMenu *)menu {
    if (self.previewMode || menu != self.statusItem.menu) return;
    [self updateInventory];
    [menu removeAllItems];
    [menu addItem:[self menuItem:@"打开控制面板" action:@selector(showWindow:) profile:nil]];
    [menu addItem:NSMenuItem.separatorItem];
    NSArray *active = [self activeProfiles];
    for (YMManagedDisplay *profile in active) {
        NSArray *rows = [self.appWorkspace rowsForDisplayID:profile.display.displayID];
        NSMenuItem *screen = [self menuItem:[NSString stringWithFormat:@"%@ · %lu 个应用", [self titleForProfile:profile], (unsigned long)rows.count] action:nil profile:profile];
        NSMenu *submenu = [[NSMenu alloc] initWithTitle:screen.title];
        for (NSDictionary *row in rows) {
            NSMenuItem *app = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"%@ · %@ 个窗口", row[@"appName"], row[@"windowCount"]] action:nil keyEquivalent:@""];
            NSImage *icon = [row[@"appIcon"] copy]; icon.size = NSMakeSize(16, 16); app.image = icon;
            [submenu addItem:app];
        }
        if (!rows.count) [submenu addItem:[[NSMenuItem alloc] initWithTitle:self.appWorkspace.accessibilityTrusted ? @"当前没有可见应用窗口" : @"开启辅助功能后查看应用" action:nil keyEquivalent:@""]];
        [submenu addItem:NSMenuItem.separatorItem];
        [submenu addItem:[self menuItem:@"在控制面板中管理…" action:@selector(showProfile:) profile:profile]];
        [submenu addItem:[self menuItem:@"关闭这个虚拟屏" action:@selector(closeProfile:) profile:profile]];
        screen.submenu = submenu; [menu addItem:screen];
    }
    if (!active.count) [menu addItem:[[NSMenuItem alloc] initWithTitle:@"尚无运行中的虚拟屏" action:nil keyEquivalent:@""]];
    NSMenuItem *add = [self menuItem:@"添加或启动虚拟屏…" action:nil profile:nil];
    add.submenu = [self addingDisplayMenu];
    [menu addItem:add];
    if (self.windowRecovery.needsRestoreBeforeRemovingVirtualDisplay)
        [menu addItem:[self menuItem:@"微信返回原显示器" action:@selector(wechatRestore:) profile:nil]];
    if (self.topologyRecoverySnapshot)
        [menu addItem:[self menuItem:@"重试恢复显示排列…" action:@selector(retryTopologyRecovery:) profile:nil]];
    if (self.armed || self.layoutChangedForTrial || self.recoveryRequested)
        [menu addItem:[self menuItem:@"恢复实体显示器" action:@selector(restore:) profile:nil]];
    [menu addItem:NSMenuItem.separatorItem];
    [menu addItem:[[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"yomado %@", YMAppVersion()] action:nil keyEquivalent:@""]];
    [menu addItem:[self menuItem:self.updateChecker.checking ? @"正在检查更新…" : @"检查更新…" action:@selector(checkForUpdates:) profile:nil]];
    [menu addItem:NSMenuItem.separatorItem];
    [menu addItem:[self menuItem:@"完全退出 yomado" action:@selector(quit:) profile:nil]];
}
- (BOOL)validateMenuItem:(NSMenuItem *)item {
    if (item.action == @selector(checkForUpdates:))
        return !self.previewMode && !self.updateChecker.checking && !self.updateAlert && !self.window.attachedSheet;
    return YES;
}
- (void)openWebsite:(id)sender {
    (void)sender;
    if (!self.previewMode) [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"https://yomado.app/"]];
}
- (void)openSource:(id)sender {
    (void)sender;
    if (!self.previewMode) [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"https://github.com/chekusu/yomado"]];
}
- (void)openLicense:(id)sender {
    (void)sender;
    if (!self.previewMode) [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"https://github.com/chekusu/yomado/blob/main/LICENSE"]];
}
- (NSButton *)footerLink:(NSString *)title action:(SEL)action tooltip:(NSString *)tooltip {
    NSButton *button = [NSButton buttonWithTitle:title target:self action:action];
    button.bordered = NO;
    button.font = [NSFont systemFontOfSize:11];
    button.contentTintColor = NSColor.secondaryLabelColor;
    button.toolTip = tooltip;
    [button setAccessibilityLabel:tooltip];
    [button setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    return button;
}
- (void)checkForUpdates:(id)sender {
    (void)sender;
    if (self.previewMode || self.updateChecker.checking || self.updateAlert || self.window.attachedSheet) return;
    if (!self.updateChecker) self.updateChecker = [[YMUpdateChecker alloc] initWithCurrentVersion:YMAppVersion()];
    self.updateButton.enabled = NO;
    self.updateButton.toolTip = @"正在检查更新…";
    [self.updateButton setAccessibilityLabel:@"正在检查更新"];
    __weak ADController *weakSelf = self;
    [self.updateChecker checkWithCompletion:^(YMUpdateResult *result, NSError *error) {
        ADController *controller = weakSelf;
        if (!controller) return;
        controller.updateButton.toolTip = @"检查更新";
        [controller.updateButton setAccessibilityLabel:@"检查更新"];
        NSAlert *alert = [[NSAlert alloc] init];
        controller.updateAlert = alert;
        BOOL available = !error && result.status == YMUpdateStatusAvailable;
        if (error) {
            alert.alertStyle = NSAlertStyleWarning;
            alert.messageText = @"暂时无法检查更新";
            alert.informativeText = error.localizedDescription;
            [alert addButtonWithTitle:@"重试"];
            [alert addButtonWithTitle:@"取消"];
        } else if (available) {
            alert.messageText = [NSString stringWithFormat:@"发现新版本 yomado %@", result.latestVersion];
            alert.informativeText = [NSString stringWithFormat:@"当前版本 %@%@。可前往 GitHub 查看版本说明并下载。请在退出旧版前保存工作、返回虚拟屏里的窗口。", result.currentVersion, result.prerelease ? @"，新版本为实验版" : @""];
            [alert addButtonWithTitle:@"查看更新"];
            [alert addButtonWithTitle:@"稍后"];
        } else {
            alert.messageText = @"已是最新版本";
            alert.informativeText = [NSString stringWithFormat:@"yomado %@ · 已检查正式版与实验版更新。", result.currentVersion];
            [alert addButtonWithTitle:@"好"];
        }
        [controller showWindow:nil];
        [alert beginSheetModalForWindow:controller.window completionHandler:^(NSModalResponse response) {
            ADController *owner = weakSelf;
            if (!owner) return;
            owner.updateAlert = nil;
            owner.updateButton.enabled = YES;
            if (response != NSAlertFirstButtonReturn) return;
            if (error) [owner checkForUpdates:nil];
            else if (available) [NSWorkspace.sharedWorkspace openURL:result.releaseURL];
        }];
    }];
}
- (void)showProfile:(NSMenuItem *)sender { [self selectProfile:sender.representedObject]; [self showWindow:nil]; }
- (void)closeProfile:(NSMenuItem *)sender {
    [self selectProfile:sender.representedObject];
    if (self.selectedProfile == sender.representedObject) [self stop:nil];
}
// Screen settings apply to saved profiles. Running displays are never silently
// recreated; close a display before changing its saved dimensions.
- (BOOL)canPerformScreenMenuActionForProfile:(YMManagedDisplay *)profile {
    return !self.previewMode && profile && [self.displayProfiles containsObject:profile]
        && !self.appOperationInProgress && !self.displayOperationInProgress
        && !self.armed && !self.preparing && !self.restoring
        && !self.layoutChangedForTrial && !self.recoveryRequested;
}
- (void)startManagedDisplayFromMenu:(NSMenuItem *)sender {
    YMManagedDisplay *profile = sender.representedObject;
    if (![profile isKindOfClass:YMManagedDisplay.class] || ![self canPerformScreenMenuActionForProfile:profile]
        || profile.display.isCreated) return;
    [self selectProfile:profile];
    if (self.selectedProfile == profile) [self create:nil];
}
- (void)closeManagedDisplayFromMenu:(NSMenuItem *)sender {
    YMManagedDisplay *profile = sender.representedObject;
    if (![profile isKindOfClass:YMManagedDisplay.class] || ![self canPerformScreenMenuActionForProfile:profile]
        || !profile.display.isCreated) return;
    [self selectProfile:profile];
    if (self.selectedProfile == profile) [self stop:nil];
}
- (void)renameManagedDisplayFromMenu:(NSMenuItem *)sender {
    YMManagedDisplay *profile = sender.representedObject;
    if (![profile isKindOfClass:YMManagedDisplay.class] || ![self canPerformScreenMenuActionForProfile:profile]
        || self.window.attachedSheet) return;
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"给虚拟屏命名";
    alert.informativeText = @"例如 Codex 或 GrokBot。名称会显示在屏幕和菜单栏中。";
    [alert addButtonWithTitle:@"保存"];
    [alert addButtonWithTitle:@"取消"];
    NSTextField *input = [NSTextField textFieldWithString:profile.friendlyName ?: @""];
    input.frame = NSMakeRect(0, 0, 300, 26);
    input.placeholderString = @"1–60 个字符";
    [input setAccessibilityLabel:@"虚拟屏名称"];
    alert.accessoryView = input;
    alert.window.initialFirstResponder = input;
    __weak ADController *weakSelf = self;
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        ADController *controller = weakSelf;
        if (response != NSAlertFirstButtonReturn || !controller
            || ![controller canPerformScreenMenuActionForProfile:profile]) return;
        NSString *name = [input.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!name.length || name.length > 60
            || [name rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) {
            controller.statusLabel.stringValue = @"名称未保存";
            controller.detailLabel.stringValue = @"请输入 1–60 个字符，且不含换行或控制字符。";
            return;
        }
        profile.friendlyName = name;
        [controller saveDisplayProfiles];
        [controller updateInventory];
        controller.statusLabel.stringValue = @"名称已保存";
        controller.detailLabel.stringValue = profile.display.isCreated
            ? @"界面中的名称已更新；系统显示器名称将在这块虚拟屏下次启动时更新。"
            : @"下次启动这块虚拟屏时会使用新名称。";
    }];
}
- (void)setManagedDisplayResolutionFromMenu:(NSMenuItem *)sender {
    NSDictionary *settings = sender.representedObject;
    if (![settings isKindOfClass:NSDictionary.class]) return;
    YMManagedDisplay *profile = settings[@"profile"];
    if (![profile isKindOfClass:YMManagedDisplay.class] || ![self canPerformScreenMenuActionForProfile:profile]
        || profile.display.isCreated) return;
    NSUInteger width = [settings[@"width"] unsignedIntegerValue];
    if (width != 1920 && width != 2560) return;
    profile.width = width;
    profile.height = width == 1920 ? 1080 : 1440;
    [self saveDisplayProfiles];
    [self updateInventory];
    self.statusLabel.stringValue = @"分辨率已保存";
    self.detailLabel.stringValue = @"启动这块虚拟屏时会使用新的分辨率。";
}
- (void)toggleManagedDisplayHiDPIFromMenu:(NSMenuItem *)sender {
    YMManagedDisplay *profile = sender.representedObject;
    if (![profile isKindOfClass:YMManagedDisplay.class] || ![self canPerformScreenMenuActionForProfile:profile]
        || profile.display.isCreated) return;
    profile.hiDPI = !profile.hiDPI;
    [self saveDisplayProfiles];
    [self updateInventory];
    self.statusLabel.stringValue = profile.hiDPI ? @"已启用 HiDPI" : @"已使用标准清晰度";
    self.detailLabel.stringValue = @"启动这块虚拟屏时生效。";
}
- (NSMenu *)screenActionMenuForProfile:(YMManagedDisplay *)profile {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:[self titleForProfile:profile]];
    menu.autoenablesItems = NO;
    BOOL available = [self canPerformScreenMenuActionForProfile:profile];
    BOOL running = profile.display.isCreated;
    NSMenuItem *rename = [self menuItem:@"重命名…" action:@selector(renameManagedDisplayFromMenu:) profile:profile];
    rename.enabled = available;
    [menu addItem:rename];

    NSMenuItem *resolution = [[NSMenuItem alloc] initWithTitle:@"分辨率" action:nil keyEquivalent:@""];
    NSMenu *sizes = [[NSMenu alloc] initWithTitle:@"分辨率"];
    sizes.autoenablesItems = NO;
    for (NSNumber *width in @[@1920, @2560]) {
        NSString *title = width.unsignedIntegerValue == 1920 ? @"1920 × 1080" : @"2560 × 1440";
        NSMenuItem *item = [self menuItem:title action:@selector(setManagedDisplayResolutionFromMenu:) profile:nil];
        item.representedObject = @{@"profile":profile, @"width":width};
        item.state = profile.width == width.unsignedIntegerValue ? NSControlStateValueOn : NSControlStateValueOff;
        item.enabled = available && !running;
        [sizes addItem:item];
    }
    if (running) {
        [sizes addItem:NSMenuItem.separatorItem];
        NSMenuItem *hint = [[NSMenuItem alloc] initWithTitle:@"关闭虚拟屏后可更改" action:nil keyEquivalent:@""];
        hint.enabled = NO; [sizes addItem:hint];
    }
    resolution.submenu = sizes;
    resolution.enabled = YES;
    [menu addItem:resolution];
    NSMenuItem *hiDPI = [self menuItem:@"HiDPI 更清晰" action:@selector(toggleManagedDisplayHiDPIFromMenu:) profile:profile];
    hiDPI.state = profile.hiDPI ? NSControlStateValueOn : NSControlStateValueOff;
    hiDPI.enabled = available && !running;
    [menu addItem:hiDPI];

    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *lifecycle = [self menuItem:running ? @"关闭这块虚拟屏" : @"启动这块虚拟屏"
        action:running ? @selector(closeManagedDisplayFromMenu:) : @selector(startManagedDisplayFromMenu:) profile:profile];
    lifecycle.enabled = available;
    [menu addItem:lifecycle];
    return menu;
}
- (void)manageDisplayID:(CGDirectDisplayID)displayID {
    YMManagedDisplay *profile = [self profileForDisplayID:displayID];
    if (self.previewMode || !profile) return; // Physical tiles have no ... button.
    NSView *anchor = self.workspaceViews[@(displayID)] ?: self.window.contentView;
    NSMenu *menu = [self screenActionMenuForProfile:profile];
    CGFloat bottom = [anchor isKindOfClass:YMAppWorkspaceView.class] ? anchor.bounds.size.width / ((YMAppWorkspaceView *)anchor).displayAspectRatio : 24;
    [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(MAX(18, anchor.bounds.size.width - 24), bottom) inView:anchor];
}
- (NSMenu *)addingDisplayMenu {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"添加虚拟屏"];
    menu.autoenablesItems = NO;
    for (YMManagedDisplay *profile in self.displayProfiles) {
        if (profile.display.isCreated) continue;
        NSMenuItem *saved = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"%@ · 已关闭", [self titleForProfile:profile]]
            action:nil keyEquivalent:@""];
        saved.submenu = [self screenActionMenuForProfile:profile];
        saved.enabled = YES;
        [menu addItem:saved];
    }
    if (menu.numberOfItems) [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *newDisplay = [self menuItem:@"新增虚拟屏" action:@selector(addDisplay:) profile:nil];
    newDisplay.enabled = !self.appOperationInProgress && !self.displayOperationInProgress
        && !self.armed && !self.preparing && !self.restoring && !self.layoutChangedForTrial && !self.recoveryRequested;
    [menu addItem:newDisplay];
    return menu;
}
- (void)addDisplayMenu:(id)sender {
    if (self.previewMode) return;
    NSView *anchor = [sender isKindOfClass:NSView.class] ? sender : self.addDisplayButton;
    NSPoint location = NSMakePoint(0, anchor.isFlipped ? NSHeight(anchor.bounds) + 4 : -4);
    [[self addingDisplayMenu] popUpMenuPositioningItem:nil atLocation:location inView:anchor];
}

- (void)buildWindow {
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1000, 410)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    self.window.contentView = [[YMDocumentView alloc] initWithFrame:NSMakeRect(0, 0, 1000, 410)];
    self.window.title = @"yomado";
    self.window.titlebarAppearsTransparent = YES;
    self.window.titleVisibility = NSWindowTitleHidden;
    self.window.contentMinSize = NSMakeSize(760, 370);
    self.window.delegate = self.previewMode ? nil : self;
    self.window.releasedWhenClosed = NO;
    if (!self.previewMode) [self.window center];
    NSStackView *stack = YMStack(NSUserInterfaceLayoutOrientationVertical, 16);
    [self.window.contentView addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:self.window.contentView.leadingAnchor constant:24],
        [stack.trailingAnchor constraintEqualToAnchor:self.window.contentView.trailingAnchor constant:-24],
        [stack.topAnchor constraintEqualToAnchor:self.window.contentView.topAnchor constant:14],
        [stack.bottomAnchor constraintEqualToAnchor:self.window.contentView.bottomAnchor constant:-18]
    ]];
    NSStackView *header = YMStack(NSUserInterfaceLayoutOrientationHorizontal, 10);
    NSImage *icon = YMBrandIcon();
    if (icon) {
        NSImageView *view = [NSImageView imageViewWithImage:icon];
        [view.widthAnchor constraintEqualToConstant:40].active = YES;
        [view.heightAnchor constraintEqualToConstant:40].active = YES;
        [header addArrangedSubview:view];
        if (!self.previewMode) NSApp.applicationIconImage = icon;
    }
    [header addArrangedSubview:Label(@"yomado", 23, NSFontWeightSemibold)];
    NSStackView *introduction = YMStack(NSUserInterfaceLayoutOrientationVertical, 3);
    [introduction addArrangedSubview:Label(@"夜窗", 14, NSFontWeightMedium)];
    NSTextField *tagline = Label(@"为视觉 Agent 留一块工作屏，让实体屏可以休息。", 11, NSFontWeightRegular);
    tagline.textColor = NSColor.secondaryLabelColor;
    [introduction addArrangedSubview:tagline];
    [header addArrangedSubview:introduction];
    [header addArrangedSubview:YMSpacer()];
    self.wechatPermissionButton = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"lock.open" accessibilityDescription:@"允许窗口控制"] target:self action:@selector(wechatPermission:)];
    self.wechatPermissionButton.bordered = NO;
    self.wechatPermissionButton.toolTip = @"打开系统设置，允许 yomado 控制应用窗口";
    [header addArrangedSubview:self.wechatPermissionButton];
    self.permissionContainer = self.wechatPermissionButton;
    self.wechatRestoreButton = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"arrow.uturn.backward" accessibilityDescription:@"微信返回原显示器"] target:self action:@selector(wechatRestore:)];
    self.wechatRestoreButton.bordered = NO;
    self.wechatRestoreButton.toolTip = @"微信返回原显示器";
    self.wechatRestoreButton.hidden = YES;
    [header addArrangedSubview:self.wechatRestoreButton];
    self.addDisplayButton = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"plus" accessibilityDescription:@"添加虚拟屏"] target:self action:@selector(addDisplayMenu:)];
    self.addDisplayButton.bezelStyle = NSBezelStyleAccessoryBarAction;
    self.addDisplayButton.toolTip = @"添加或启动虚拟屏";
    [header addArrangedSubview:self.addDisplayButton];
    [stack addArrangedSubview:header]; YMFillWidth(header, stack);
    NSScrollView *board = [[NSScrollView alloc] init];
    board.translatesAutoresizingMaskIntoConstraints = NO;
    board.drawsBackground = NO;
    board.hasHorizontalScroller = YES; board.hasVerticalScroller = YES;
    board.autohidesScrollers = YES;
    self.applicationCards = YMStack(NSUserInterfaceLayoutOrientationHorizontal, 14);
    self.applicationCards.alignment = NSLayoutAttributeTop;
    self.applicationCards.distribution = NSStackViewDistributionFill;
    self.workspaceViews = [NSMutableDictionary dictionary];
    board.documentView = self.applicationCards;
    NSLayoutConstraint *preferredBoardWidth = [self.applicationCards.widthAnchor constraintEqualToAnchor:board.contentView.widthAnchor];
    preferredBoardWidth.priority = NSLayoutPriorityDefaultHigh;
    preferredBoardWidth.active = YES;
    [NSLayoutConstraint activateConstraints:@[
        [self.applicationCards.leadingAnchor constraintEqualToAnchor:board.contentView.leadingAnchor],
        [self.applicationCards.topAnchor constraintEqualToAnchor:board.contentView.topAnchor],
        [self.applicationCards.widthAnchor constraintGreaterThanOrEqualToAnchor:board.contentView.widthAnchor],
        [self.applicationCards.heightAnchor constraintGreaterThanOrEqualToAnchor:board.contentView.heightAnchor],
        [board.heightAnchor constraintGreaterThanOrEqualToConstant:210]
    ]];
    [stack addArrangedSubview:board]; YMFillWidth(board, stack);
    [board setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationVertical];

    NSStackView *footer = YMStack(NSUserInterfaceLayoutOrientationHorizontal, 10);
    [footer addArrangedSubview:[self footerLink:@"yomado.app" action:@selector(openWebsite:) tooltip:@"官方网站 · https://yomado.app"]];
    NSTextField *version = [NSTextField labelWithString:[NSString stringWithFormat:@"v%@", YMAppVersion()]];
    version.font = [NSFont systemFontOfSize:11];
    version.textColor = NSColor.secondaryLabelColor;
    version.toolTip = [NSString stringWithFormat:@"版本 %@（构建 %@）", YMAppVersion(), [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"—"];
    [footer addArrangedSubview:version];
    self.updateButton = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"arrow.clockwise" accessibilityDescription:@"检查更新"] target:self action:@selector(checkForUpdates:)];
    self.updateButton.bordered = NO;
    self.updateButton.contentTintColor = NSColor.secondaryLabelColor;
    self.updateButton.toolTip = @"检查更新";
    [self.updateButton setAccessibilityLabel:@"检查更新"];
    [self.updateButton.widthAnchor constraintEqualToConstant:24].active = YES;
    [self.updateButton.heightAnchor constraintEqualToConstant:24].active = YES;
    [footer addArrangedSubview:self.updateButton];
    [footer addArrangedSubview:YMSpacer()];
    [footer addArrangedSubview:[self footerLink:@"GitHub" action:@selector(openSource:) tooltip:@"开源代码 · github.com/chekusu/yomado"]];
    [footer addArrangedSubview:[self footerLink:@"MIT" action:@selector(openLicense:) tooltip:@"MIT 开源许可证"]];
    [stack addArrangedSubview:footer]; YMFillWidth(footer, stack);

    // Status messages are retained for recovery diagnostics, not permanent UI.
    self.statusLabel = Label(@"", 12, NSFontWeightRegular);
    self.detailLabel = Label(@"", 11, NSFontWeightRegular);
}
- (void)displayParametersChanged:(NSNotification *)notification {
    (void)notification;
    [self updateInventory];
}
- (void)updateWeChatControls {
    if (self.previewMode || !self.windowRecovery) return;
    BOOL trusted = self.windowRecovery.accessibilityTrusted;
    self.wechatPermissionButton.hidden = trusted;
    self.wechatPermissionButton.enabled = !trusted;
    self.wechatPermissionGuide.hidden = trusted;
    self.permissionContainer.hidden = trusted;
    self.wechatRestoreButton.enabled = self.windowRecovery.canRestore;
    self.wechatRestoreButton.hidden = !self.windowRecovery.needsRestoreBeforeRemovingVirtualDisplay;
    self.wechatStatusLabel.stringValue = trusted
        ? (self.windowRecovery.needsRestoreBeforeRemovingVirtualDisplay ? self.windowRecovery.statusText : @"微信保留额外的登录提示恢复处理；位置记录不包含聊天或登录信息。")
        : self.wechatPermissionMessage ?: @"辅助功能未开启 · 开启后可查看并移动各屏幕中的应用窗口。";
    self.wechatStatusLabel.hidden = trusted && !self.windowRecovery.needsRestoreBeforeRemovingVirtualDisplay;
    self.wechatStatusLabel.textColor = trusted ? NSColor.secondaryLabelColor : NSColor.labelColor;
}
- (void)refreshRecoveryTargetWithSnapshot:(NSArray<NSDictionary *> *)snapshot {
    BOOL pending = self.windowRecovery.needsRestoreBeforeRemovingVirtualDisplay;
    if (!pending) self.wechatDisplayID = 0;
    CGDirectDisplayID target = pending && self.wechatDisplayID ? self.wechatDisplayID : self.virtualDisplay.displayID;
    [self.windowRecovery refreshWithVirtualDisplayID:target displaySnapshot:snapshot];
}
- (void)reportApplicationError:(NSError *)error fallback:(NSString *)fallback {
    self.detailLabel.stringValue = error.localizedDescription ?: fallback;
    self.statusLabel.stringValue = @"应用窗口操作未完成";
    if (!self.previewMode && !self.controlRequestActive && !self.window.attachedSheet) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"未能移动窗口";
        alert.informativeText = self.detailLabel.stringValue;
        [alert addButtonWithTitle:@"好"];
        [self showWindow:nil];
        [alert beginSheetModalForWindow:self.window completionHandler:nil];
    }
}
- (void)dropApplication:(NSDictionary *)payload targetDisplayID:(CGDirectDisplayID)targetID {
    if (self.previewMode || self.armed || self.preparing || self.restoring || self.displayOperationInProgress || self.appOperationInProgress) return;
    YMManagedDisplay *destinationProfile = [self profileForDisplayID:targetID];
    if (destinationProfile && ![self canMoveIntoProfile:destinationProfile]) {
        [self reportApplicationError:nil fallback:@"这个虚拟屏的扩展模式或显示配置尚未通过检查，未移动任何窗口。请先恢复显示排列。"];
        return;
    }
    self.appOperationInProgress = YES;
    @try {
        NSURL *URL = [payload[@"applicationURL"] isKindOfClass:NSURL.class] ? payload[@"applicationURL"] : nil;
        NSString *bundleID = [payload[@"bundleIdentifier"] isKindOfClass:NSString.class] ? payload[@"bundleIdentifier"] : nil;
        if (!bundleID.length && URL) bundleID = [NSBundle bundleWithURL:URL].bundleIdentifier;
        CGDirectDisplayID sourceID = [payload[@"sourceDisplayID"] unsignedIntValue];
        BOOL toVirtual = [self profileForDisplayID:targetID] != nil;
        BOOL fromVirtual = [self profileForDisplayID:sourceID] != nil;
        NSError *error = nil; BOOL succeeded = NO; BOOL wechatOriginal = NO;
        [self updateInventory];
        if ([bundleID isEqualToString:@"com.tencent.xinWeChat"]) {
            if (toVirtual) {
                if (fromVirtual || (self.windowRecovery.needsRestoreBeforeRemovingVirtualDisplay && self.wechatDisplayID != targetID)) {
                    [self reportApplicationError:nil fallback:@"微信请先返回原显示器，再移入另一块工作屏，以保留明确的恢复位置。"];
                    return;
                }
                self.wechatDisplayID = targetID;
                [self.windowRecovery refreshWithVirtualDisplayID:targetID displaySnapshot:DisplaySnapshot()];
                succeeded = [self.windowRecovery moveWeChatToVirtualFromDisplayID:sourceID error:&error];
            } else if (self.windowRecovery.needsRestoreBeforeRemovingVirtualDisplay && sourceID == self.wechatDisplayID) {
                succeeded = [self.windowRecovery restoreWeChat:&error]; wechatOriginal = succeeded;
            } else if (fromVirtual) {
                succeeded = targetID
                    ? [self.appWorkspace restoreApplicationWithBundleIdentifier:bundleID fromDisplayID:sourceID toPhysicalDisplayID:targetID error:&error]
                    : [self.appWorkspace restoreApplicationWithBundleIdentifier:bundleID fromDisplayID:sourceID error:&error];
            }
        } else if (toVirtual) {
            if (!URL && bundleID.length) URL = [NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:bundleID];
            if (URL && [payload[@"sourceDisplayID"] isKindOfClass:NSNumber.class])
                succeeded = [self.appWorkspace moveApplicationAtURL:URL fromDisplayID:sourceID toDisplayID:targetID error:&error];
            else if (URL) succeeded = [self.appWorkspace moveApplicationAtURL:URL toDisplayID:targetID error:&error];
        } else if (fromVirtual && bundleID.length) {
            succeeded = targetID
                ? [self.appWorkspace restoreApplicationWithBundleIdentifier:bundleID fromDisplayID:sourceID toPhysicalDisplayID:targetID error:&error]
                : [self.appWorkspace restoreApplicationWithBundleIdentifier:bundleID fromDisplayID:sourceID error:&error];
        }
        if (!succeeded) [self reportApplicationError:error fallback:@"可在实体屏与虚拟屏之间拖动应用，或在虚拟屏之间移动。实体屏之间请直接拖动应用窗口。"];
        else {
            self.statusLabel.stringValue = wechatOriginal ? @"微信已返回记录的原显示器" : toVirtual ? @"应用窗口已移入工作屏" : @"应用窗口已返回实体屏";
            self.detailLabel.stringValue = @"窗口位置已核对，应用图标随实际位置更新。";
        }
    } @finally {
        self.appOperationInProgress = NO;
        [self updateInventory];
    }
}
- (void)chooseApplicationMenuItem:(NSMenuItem *)item {
    NSDictionary *choice = item.representedObject;
    [self dropApplication:choice[@"payload"] targetDisplayID:[choice[@"targetID"] unsignedIntValue]];
}
- (void)chooseApplicationForDisplayID:(CGDirectDisplayID)displayID {
    if (self.previewMode || (displayID && ![self profileForDisplayID:displayID])) return;
    [self updateInventory];
    NSMenu *menu = [[NSMenu alloc] initWithTitle:displayID ? @"选择已打开的应用" : @"选择要移回的应用"];
    NSMutableArray<NSNumber *> *sources = [NSMutableArray array];
    if (displayID) [sources addObject:@0];
    for (YMManagedDisplay *profile in [self activeProfiles])
        if (profile.display.displayID != displayID) [sources addObject:@(profile.display.displayID)];
    for (NSNumber *source in sources) {
        YMManagedDisplay *profile = [self profileForDisplayID:source.unsignedIntValue];
        NSString *sourceName = profile ? [self titleForProfile:profile] : @"实体屏";
        for (NSDictionary *row in [self.appWorkspace rowsForDisplayID:source.unsignedIntValue]) {
            NSString *bundleID = row[@"bundleIdentifier"];
            if (!bundleID.length || [bundleID isEqualToString:NSBundle.mainBundle.bundleIdentifier]) continue;
            NSMutableDictionary *payload = [@{@"bundleIdentifier":bundleID, @"sourceDisplayID":source} mutableCopy];
            if (row[@"appURL"]) payload[@"applicationURL"] = row[@"appURL"];
            NSMenuItem *item = [self menuItem:[NSString stringWithFormat:@"%@ · %@", row[@"appName"], sourceName]
                                      action:@selector(chooseApplicationMenuItem:) profile:nil];
            item.representedObject = @{@"payload":payload, @"targetID":@(displayID)};
            NSImage *icon = [row[@"appIcon"] copy]; icon.size = NSMakeSize(16, 16); item.image = icon;
            [menu addItem:item];
        }
    }
    if (!menu.numberOfItems)
        [menu addItem:[[NSMenuItem alloc] initWithTitle:displayID ? @"请先打开一个有普通窗口的应用" : @"虚拟屏中没有可移回的应用" action:nil keyEquivalent:@""]];
    NSView *anchor = self.workspaceViews[@(displayID)] ?: self.window.contentView;
    CGFloat bottom = [anchor isKindOfClass:YMAppWorkspaceView.class] ? anchor.bounds.size.width / ((YMAppWorkspaceView *)anchor).displayAspectRatio : 44;
    [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(MAX(18, anchor.bounds.size.width - 54), bottom) inView:anchor];
}
- (void)updateApplicationCardsWithSnapshot:(NSArray<NSDictionary *> *)snapshot {
    if (!self.applicationCards || !self.workspaceViews) return;
    // Keep the native drag source and menu anchor alive until tracking ends.
    // Inventory/recovery may still run; the next tick reconciles the presentation.
    if ([YMAppWorkspaceView hasActiveInteraction]) return;
    NSMutableArray<NSDictionary *> *displays = [NSMutableArray array];
    for (NSDictionary *item in snapshot) {
        if (![item[@"isActive"] boolValue] || ![item[@"isOnline"] boolValue]) continue;
        if (![item[@"isVirtual"] boolValue] || self.previewMode || [self profileForDisplayID:[item[@"displayID"] unsignedIntValue]])
            [displays addObject:item];
    }
    [displays sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSComparisonResult result = [a[@"x"] compare:b[@"x"]];
        return result == NSOrderedSame ? [a[@"y"] compare:b[@"y"]] : result;
    }];
    NSArray<NSNumber *> *ids = [displays valueForKey:@"displayID"];
    NSMutableArray<NSString *> *layoutSignature = [NSMutableArray array];
    double logicalWidth = 0;
    for (NSDictionary *item in displays) {
        logicalWidth += [item[@"logicalWidth"] doubleValue];
        [layoutSignature addObject:[NSString stringWithFormat:@"%@:%@:%@:%@:%@", item[@"displayID"], item[@"logicalWidth"], item[@"logicalHeight"], item[@"x"], item[@"y"]]];
    }
    if (![self.workspaceLayoutSignature isEqualToArray:layoutSignature]) {
        for (NSView *view in self.applicationCards.arrangedSubviews.copy) {
            [self.applicationCards removeArrangedSubview:view]; [view removeFromSuperview];
        }
        [self.workspaceViews removeAllObjects];
        self.workspaceViewIDs = ids.copy;
        self.workspaceLayoutSignature = layoutSignature.copy;
        for (NSDictionary *item in displays) {
            CGDirectDisplayID displayID = [item[@"displayID"] unsignedIntValue];
            YMAppWorkspaceView *view = [[YMAppWorkspaceView alloc] initWithFrame:NSZeroRect];
            view.displayID = displayID;
            view.physicalDisplay = ![item[@"isVirtual"] boolValue];
            __weak ADController *weakSelf = self;
            view.onDropApplication = ^(NSDictionary *payload) { [weakSelf dropApplication:payload targetDisplayID:displayID]; };
            view.onChooseApplication = ^{ [weakSelf chooseApplicationForDisplayID:displayID]; };
            view.onManageDisplay = ^{ [weakSelf manageDisplayID:displayID]; };
            view.onRestoreBundleIdentifier = ^(NSString *identifier) {
                [weakSelf dropApplication:@{@"bundleIdentifier":identifier, @"sourceDisplayID":@(displayID)} targetDisplayID:0];
            };
            [self.applicationCards addArrangedSubview:view];
            CGFloat fraction = [item[@"logicalWidth"] doubleValue] / MAX(1, logicalWidth);
            [view.widthAnchor constraintEqualToAnchor:self.applicationCards.widthAnchor multiplier:fraction constant:-14.0 * (CGFloat)(displays.count - 1) * fraction].active = YES;
            [view.widthAnchor constraintGreaterThanOrEqualToConstant:140].active = YES;
            self.workspaceViews[@(displayID)] = view;
        }
    }
    for (NSDictionary *item in displays) {
        CGDirectDisplayID displayID = [item[@"displayID"] unsignedIntValue];
        YMAppWorkspaceView *view = self.workspaceViews[@(displayID)];
        YMManagedDisplay *profile = [self profileForDisplayID:displayID];
        view.displayName = profile ? [self titleForProfile:profile] : item[@"name"] ?: @"显示器";
        view.displayAspectRatio = [item[@"logicalWidth"] doubleValue] / MAX(1, [item[@"logicalHeight"] doubleValue]);
        view.displayDetail = [NSString stringWithFormat:@"%@ × %@%@", item[@"logicalWidth"], item[@"logicalHeight"], [item[@"isMain"] boolValue] ? @" · 主屏" : @""];
        NSArray *rows = self.previewMode ? @[] : [self.appWorkspace rowsForDisplayID:displayID];
        if (self.previewMode) {
            NSArray *names = displayID == 902 ? @[@"Blender", @"Unity"] : displayID == 903 ? @[@"Safari"] : displayID == 900 ? @[@"Finder", @"Notes"] : @[@"Mail"];
            NSDictionary *symbols = @{@"Blender":@"cube", @"Unity":@"gamecontroller", @"Safari":@"safari", @"Finder":@"face.smiling", @"Notes":@"note.text", @"Mail":@"envelope"};
            NSMutableArray *fixtures = [NSMutableArray array];
            for (NSString *name in names) [fixtures addObject:@{@"appName":name, @"bundleIdentifier":[@"example." stringByAppendingString:name], @"pid":@0, @"windowCount":@1, @"managedWindowCount":@1, @"appIcon":[NSImage imageWithSystemSymbolName:symbols[name] accessibilityDescription:name]}];
            rows = fixtures;
        }
        BOOL trusted = self.previewMode ? YES : self.appWorkspace.accessibilityTrusted;
        view.statusText = @"";
        view.acceptsApplications = self.previewMode || !profile || [self canMoveIntoProfile:profile];
        BOOL ready = !self.armed && !self.preparing && !self.restoring && !self.displayOperationInProgress && !self.appOperationInProgress;
        [view updateRows:rows virtualDisplayAvailable:ready accessibilityTrusted:trusted];
    }
}
- (void)wechatPermission:(id)sender {
    (void)sender;
    if (self.previewMode) return;
    NSError *error = nil;
    BOOL opened = [self.windowRecovery openAccessibilitySettings:&error];
    self.wechatPermissionMessage = opened
        ? @"设置已打开，仍需你开启 yomado 开关。授权后这里会自动更新。"
        : error.localizedDescription ?: @"请手动进入系统设置的控制权限页面，开启 yomado。";
    [self updateWeChatControls];
}
- (void)wechatMove:(id)sender {
    (void)sender;
    if (self.previewMode) return;
    [self dropApplication:@{@"bundleIdentifier":@"com.tencent.xinWeChat", @"sourceDisplayID":@0}
         targetDisplayID:self.virtualDisplay.displayID];
}
- (void)wechatRestore:(id)sender {
    (void)sender;
    if (self.previewMode) return;
    [self dropApplication:@{@"bundleIdentifier":@"com.tencent.xinWeChat", @"sourceDisplayID":@(self.wechatDisplayID)} targetDisplayID:0];
}
- (void)showWindow:(id)sender {
    (void)sender;
    if (self.previewMode) return;
    YMPresentControlPanel(self.window);
}
- (BOOL)applicationShouldHandleReopen:(NSApplication *)application hasVisibleWindows:(BOOL)hasVisibleWindows {
    (void)application;
    (void)hasVisibleWindows;
    [self showWindow:nil];
    return NO;
}
- (BOOL)windowShouldClose:(NSWindow *)window { [window orderOut:nil]; return NO; }
- (void)updateInventory {
    if (self.updatingInventory) return;
    self.updatingInventory = YES;
    @try {
        NSArray *snapshot = self.previewMode ? self.previewSnapshot : DisplaySnapshot();
        if (!self.previewMode) {
            [self refreshRecoveryTargetWithSnapshot:snapshot];
            NSMutableArray *ids = [NSMutableArray array];
            for (YMManagedDisplay *profile in [self activeProfiles]) [ids addObject:@(profile.display.displayID)];
            [self.appWorkspace refreshWithVirtualDisplayIDs:ids displaySnapshot:snapshot];
            [self updateWeChatControls];
        }
        [self updateApplicationCardsWithSnapshot:snapshot];
        NSUInteger physicalCount = 0, virtualCount = 0;
        for (NSDictionary *item in snapshot) {
            if (![item[@"isActive"] boolValue] || ![item[@"isOnline"] boolValue]) continue;
            if ([item[@"isVirtual"] boolValue]) virtualCount++; else physicalCount++;
        }
        self.inventoryLabel.stringValue = [NSString stringWithFormat:@"%lu 块实体屏 · %lu 块虚拟屏", (unsigned long)physicalCount, (unsigned long)virtualCount];
        BOOL busy = self.armed || self.preparing || self.restoring || self.layoutChangedForTrial || self.recoveryRequested || self.displayOperationInProgress || self.appOperationInProgress;
        self.addDisplayButton.enabled = !self.previewMode && !busy && !self.topologyRecoverySnapshot;
        self.statusPill.text = busy ? @"正在更新" : self.topologyRecoverySnapshot ? @"显示排列待恢复" : virtualCount ? @"工作屏已就绪" : @"尚未启动";
        self.statusPill.tint = busy ? NSColor.systemOrangeColor : virtualCount ? NSColor.controlAccentColor : NSColor.secondaryLabelColor;
        if (self.previewMode) {
            self.permissionContainer.hidden = YES;
            self.wechatRestoreButton.hidden = YES;
            self.wechatStatusLabel.hidden = YES;
            self.statusLabel.stringValue = @"";
            self.detailLabel.stringValue = @"界面示例 · 应用图标为示意；不会读取本机窗口。";
        }
    } @finally { self.updatingInventory = NO; }
}
- (void)powerAssertions:(BOOL)on {
    if (self.previewMode) return;
    if (on) {
        if (self.systemAssertion == kIOPMNullAssertionID)
            IOPMAssertionCreateWithName(kIOPMAssertionTypeNoIdleSleep, kIOPMAssertionLevelOn,
                CFSTR("Yomado virtual desktop"), &_systemAssertion);
        if (self.displayAssertion == kIOPMNullAssertionID)
            IOPMAssertionCreateWithName(kIOPMAssertionTypeNoDisplaySleep, kIOPMAssertionLevelOn,
                CFSTR("Yomado virtual desktop rendering"), &_displayAssertion);
    } else {
        if (self.systemAssertion != kIOPMNullAssertionID) IOPMAssertionRelease(self.systemAssertion);
        if (self.displayAssertion != kIOPMNullAssertionID) IOPMAssertionRelease(self.displayAssertion);
        self.systemAssertion = self.displayAssertion = kIOPMNullAssertionID;
    }
}
- (BOOL)setVirtualMain:(BOOL)virtualMain {
    if (self.previewMode) return NO;
    CGDisplayConfigRef config = NULL;
    if (CGBeginDisplayConfiguration(&config) != kCGErrorSuccess || !config) return NO;
    CGDirectDisplayID vd = self.virtualDisplay.displayID;
    CGDirectDisplayID primary = virtualMain ? vd : self.originalMain;
    if (!virtualMain && (!primary || !ADDisplayActive(primary))) {
        for (NSDictionary *item in DisplaySnapshot()) {
            CGDirectDisplayID candidate = [item[@"displayID"] unsignedIntValue];
            if (ADDisplayActive(candidate) && ![VDVirtualDisplay isVirtualDisplay:candidate]) { primary = candidate; break; }
        }
    }
    if (!primary || !ADDisplayActive(primary)) { CGCancelDisplayConfiguration(config); return NO; }
    int32_t originalX = 0, originalY = 0;
    if (!virtualMain) {
        for (NSDictionary *item in self.originalLayout) {
            if ([item[@"displayID"] unsignedIntValue] == primary) {
                originalX = [item[@"x"] intValue];
                originalY = [item[@"y"] intValue];
                break;
            }
        }
    }
    int32_t x = (int32_t)CGDisplayBounds(primary).size.width;
    CGError err = CGConfigureDisplayOrigin(config, primary, 0, 0);
    for (NSDictionary *item in self.originalLayout) {
        CGDirectDisplayID ident = [item[@"displayID"] unsignedIntValue];
        if (ident == primary || (virtualMain && ident == vd) || !ADDisplayOnline(ident)) continue;
        int32_t px = virtualMain ? x : [item[@"x"] intValue] - originalX;
        int32_t py = virtualMain ? 0 : [item[@"y"] intValue] - originalY;
        if (err == kCGErrorSuccess) err = CGConfigureDisplayOrigin(config, ident, px, py);
        if (virtualMain) x += (int32_t)CGDisplayBounds(ident).size.width;
    }
    if (err != kCGErrorSuccess) { CGCancelDisplayConfiguration(config); return NO; }
    return CGCompleteDisplayConfiguration(config, kCGConfigureForAppOnly) == kCGErrorSuccess;
}
- (void)create:(id)sender {
    (void)sender;
    if (self.previewMode || self.topologyRecoverySnapshot || self.virtualDisplay.isCreated || !self.selectedProfile
        || self.displayOperationInProgress || self.appOperationInProgress || self.armed || self.preparing
        || self.restoring || self.layoutChangedForTrial || self.recoveryRequested) return;
    YMManagedDisplay *profile = self.selectedProfile;
    profile.topologyVerified = NO;
    self.displayOperationInProgress = YES;
    NSError *error = nil;
    YMDisplayTopologySnapshot *before = [self.displayTopology captureSnapshotWithError:&error];
    if (!before) {
        self.displayOperationInProgress = NO;
        [self reportTopologyError:error];
        [self updateInventory];
        return;
    }
    BOOL created = [profile.display createWithWidth:profile.width height:profile.height hiDPI:profile.hiDPI
                     name:[self titleForProfile:profile] error:&error];
    CGDirectDisplayID createdID = profile.display.displayID;
    NSUInteger width = profile.width, height = profile.height;
    BOOL hiDPI = profile.hiDPI;
    YMDisplayTopology *topology = self.displayTopology;
    void (^completeCreation)(BOOL, NSError *) = ^(BOOL configured, NSError *configurationError) {
        if (configured) {
            [self powerAssertions:YES];
            configured = self.systemAssertion != kIOPMNullAssertionID && self.displayAssertion != kIOPMNullAssertionID;
            if (!configured) configurationError = [NSError errorWithDomain:YMDisplayTopologyErrorDomain code:50
                userInfo:@{NSLocalizedDescriptionKey:@"保持唤醒请求失败，已取消创建工作屏。"}];
        }
        if (!configured) {
            // Only this operation's frozen owned object is removed. The main
            // event loop stays available while WindowServer removes it.
            if (profile.display.isCreated) [profile.display destroy];
            [self recoverTopology:before removedID:createdID completion:^(BOOL recovered, NSError *recoveryError) {
                if (![self activeProfiles].count) [self powerAssertions:NO];
                self.displayOperationInProgress = NO;
                [self reportTopologyError:recovered ? configurationError : recoveryError];
                [self updateInventory];
            }];
            return;
        }
        profile.topologyVerified = YES;
        [self saveDisplayProfiles];
        self.displayOperationInProgress = NO;
        self.statusLabel.stringValue = [NSString stringWithFormat:@"%@ 已启动", [self titleForProfile:profile]];
        self.detailLabel.stringValue = @"扩展模式与原有显示配置已核对，可以移入应用。";
        [self updateInventory];
    };
    if (!created) { completeCreation(NO, error); return; }
    [self performTopologyOperation:^BOOL(NSError **operationError) {
        return [topology configureAndVerifyNewDisplay:createdID width:width height:height hiDPI:hiDPI baseline:before error:operationError];
    } completion:completeCreation];
}
- (BOOL)writeStateEnding:(BOOL)end {
    if (self.previewMode) return NO;
    if (!self.statePath.length) return NO;
    NSMutableArray *origins = [NSMutableArray array];
    for (NSDictionary *item in self.originalLayout) {
        [origins addObject:@{@"id":item[@"displayID"], @"x":item[@"x"], @"y":item[@"y"]}];
    }
    NSDictionary *state = @{@"parentPID":@(getpid()), @"heartbeat":@(NSDate.date.timeIntervalSince1970 - (self.recoveryRequested ? 20 : 0)),
        @"armed":@(self.armed || self.layoutChangedForTrial), @"targets":self.targets ?: @[], @"virtualID":@(self.virtualDisplay.displayID),
        @"originalMain":@(self.originalMain), @"origins":origins, @"end":@(end)};
    NSData *data = [NSJSONSerialization dataWithJSONObject:state options:0 error:nil];
    return [data writeToFile:self.statePath options:NSDataWritingAtomic error:nil];
}
- (void)finishWatchdog {
    if (self.previewMode) return;
    [self writeStateEnding:YES];
    if (self.watchdog.running) [self.watchdog terminate];
    self.watchdog = nil;
    for (NSString *suffix in @[@"", @".ready", @".restored", @".error"])
        [NSFileManager.defaultManager removeItemAtPath:[self.statePath stringByAppendingString:suffix] error:nil];
}
- (BOOL)ensureWatchdog {
    if (self.previewMode) return NO;
    if (self.watchdog.running) return NO;
    [self finishWatchdog];
    self.statePath = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"Yomado-%@.json", NSUUID.UUID.UUIDString]];
    if (![self writeStateEnding:NO]) return NO;
    NSString *exe = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Contents/MacOS/YomadoWatchdog"];
    if (![NSFileManager.defaultManager isExecutableFileAtPath:exe]) return NO;
    self.watchdog = [[NSTask alloc] init];
    self.watchdog.executableURL = [NSURL fileURLWithPath:exe];
    self.watchdog.arguments = @[self.statePath, [NSString stringWithFormat:@"%d", getpid()]];
    self.watchdog.standardOutput = NSFileHandle.fileHandleWithNullDevice;
    self.watchdog.standardError = NSFileHandle.fileHandleWithNullDevice;
    NSError *error = nil;
    return [self.watchdog launchAndReturnError:&error];
}
- (void)startTrial:(id)sender {
    if (self.previewMode) return;
    (void)sender;
    if ([self activeProfiles].count != 1 || self.displayOperationInProgress || self.appOperationInProgress || self.armed || self.preparing || self.restoring || self.recoveryRequested || self.layoutChangedForTrial
        || ![self canMoveIntoProfile:self.selectedProfile]) return;
    CGDirectDisplayID target = [self.physicalChoice.selectedItem.representedObject unsignedIntValue];
    if (!target || target == self.virtualDisplay.displayID || [VDVirtualDisplay isVirtualDisplay:target]) return;
    if (CGDisplayIsInMirrorSet(target)) {
        self.detailLabel.stringValue = @"请先解除该实体显示器的镜像，再进行关屏测试。";
        return;
    }
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"开始实验性 15 秒关屏测试？";
    alert.informativeText = @"试验会将虚拟屏设为主屏、改变显示排列，再关闭所选实体输出。macOS 或应用可能移动其他窗口，恢复不能保证窗口原位。请先保存工作，并确保能直接接触 Mac 和显示器。不确认将尝试自动恢复；恢复快捷键：⌃⌥⌘R。";
    [alert addButtonWithTitle:@"开始测试"];
    [alert addButtonWithTitle:@"取消"];
    if ([alert runModal] != NSAlertFirstButtonReturn) return;
    // Recovery belongs to this explicit trial, never to display creation time.
    self.originalLayout = DisplaySnapshot();
    self.originalMain = CGMainDisplayID();
    self.targets = @[@(target)];
    self.preparing = YES;
    self.recoveryRequested = NO;
    NSUInteger generation = ++self.operationGeneration;
    self.statusLabel.stringValue = @"准备虚拟桌面与自动恢复…";
    if (![self ensureWatchdog]) {
        [self restore:nil];
        self.statusLabel.stringValue = @"没有关闭实体屏";
        self.detailLabel.stringValue = @"恢复进程或虚拟主屏准备失败，请重试。";
        [self updateInventory];
        return;
    }
    // Retain the snapshot even if completion fails: an attempted configuration
    // must be recovered before removal or another trial is allowed.
    self.layoutChangedForTrial = YES;
    if (![self writeStateEnding:NO] || ![self setVirtualMain:YES]) {
        [self restore:nil];
        return;
    }
    [self updateInventory];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (!self.preparing || generation != self.operationGeneration) return;
        NSString *ready = [self.statePath stringByAppendingString:@".ready"];
        if (!self.watchdog.running || ![NSFileManager.defaultManager fileExistsAtPath:ready]
            || !ADDisplayActive(self.virtualDisplay.displayID)
            || CGMainDisplayID() != self.virtualDisplay.displayID) {
            [self restore:nil];
            self.detailLabel.stringValue = @"虚拟主屏或独立恢复进程未就绪，实体屏保持开启。";
            return;
        }
        NSScreen *virtualScreen = nil;
        for (NSScreen *screen in NSScreen.screens)
            if ([screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue] == self.virtualDisplay.displayID) virtualScreen = screen;
        if (virtualScreen) {
            NSRect frame = virtualScreen.visibleFrame;
            [self.window setFrameOrigin:NSMakePoint(frame.origin.x + 40, frame.origin.y + MAX(30, frame.size.height - 660))];
        }
        self.armed = YES;
        self.trialDeadline = NSDate.date.timeIntervalSince1970 + 15;
        if (![self writeStateEnding:NO]) { [self restore:nil]; return; }
        NSString *failure = nil;
        if (!ConfigureEnabled(self.targets, NO, &failure)) {
            [self restore:nil];
            self.detailLabel.stringValue = failure ?: @"实体屏关闭失败，已请求恢复。";
            return;
        }
        self.preparing = NO;
        self.keepButton.enabled = YES;
        self.detailLabel.stringValue = @"在虚拟桌面确认截图和点击正常后，点击「确认可操作，保持关屏」。未确认会自动恢复。";
        [self updateInventory];
    });
}
- (void)keepOff:(id)sender {
    if (self.previewMode) return;
    (void)sender;
    if (!self.armed || self.trialDeadline <= 0 || !ADDisplayActive(self.virtualDisplay.displayID)) return;
    for (NSNumber *ident in self.targets) {
        if (ADDisplayActive(ident.unsignedIntValue)) {
            self.detailLabel.stringValue = @"实体屏仍处于活动状态，无法确认关屏成功。";
            return;
        }
    }
    self.trialDeadline = 0;
    self.keepButton.enabled = NO;
    self.statusLabel.stringValue = @"虚拟桌面运行中 · 实体屏已断开输出";
    self.detailLabel.stringValue = @"请确认实体屏确实不发光。输出已断开，但软件无法测量显示器的实际功耗。\n恢复：⌃⌥⌘R，或菜单栏「恢复实体显示器」。";
    [self writeStateEnding:NO];
    [self updateInventory];
}
- (void)restore:(id)sender {
    if (self.previewMode) return;
    (void)sender;
    if (self.restoring) return;
    self.restoring = YES;
    ++self.operationGeneration;
    self.recoveryRequested = self.armed || self.layoutChangedForTrial;
    [self writeStateEnding:NO];
    self.preparing = NO;
    self.keepButton.enabled = NO;
    self.trialDeadline = 0;
    NSString *failure = nil;
    if (self.armed && !ConfigureEnabled(self.targets, YES, &failure)) {
        self.statusLabel.stringValue = @"实体屏恢复失败，虚拟屏继续保留";
        self.detailLabel.stringValue = failure ?: @"每秒重试恢复；独立恢复进程也已收到恢复信号。";
        self.restoring = NO;
        return;
    }
    if (self.armed) {
        BOOL allActive = YES;
        for (NSNumber *ident in self.targets) allActive &= ADDisplayActive(ident.unsignedIntValue) != 0;
        if (!allActive) {
            // Reconfiguration is asynchronous. Do not release the last usable desktop.
            self.statusLabel.stringValue = @"等待实体屏恢复…";
            self.restoring = NO;
            return;
        }
    }
    if (self.layoutChangedForTrial && ![self setVirtualMain:NO]) {
        self.statusLabel.stringValue = @"显示排列恢复失败，虚拟屏继续保留";
        self.detailLabel.stringValue = @"将继续尝试恢复本次试验前的排列。请检查实体屏连接。";
        self.restoring = NO;
        return;
    }
    self.layoutChangedForTrial = NO;
    self.armed = NO;
    self.recoveryRequested = NO;
    [self finishWatchdog];
    [self writeStateEnding:NO];
    self.statusLabel.stringValue = self.virtualDisplay.isCreated ? @"实体屏已恢复，虚拟屏仍保留" : @"尚未创建虚拟屏";
    self.detailLabel.stringValue = @"可继续使用虚拟屏，或从菜单栏停止并移除它。";
    self.restoring = NO;
    [self updateInventory];
    [self showWindow:nil];
}
- (void)tick:(NSTimer *)timer {
    if (self.previewMode) return;
    (void)timer;
    if (self.appOperationInProgress || self.displayOperationInProgress) return;
    NSError *windowError = nil;
    self.appOperationInProgress = YES;
    @try {
        [self.windowRecovery pollForRecovery:&windowError];
    } @finally {
        self.appOperationInProgress = NO;
    }
    [self updateInventory];
    if (![self writeStateEnding:NO] && self.armed) { [self restore:nil]; return; }
    NSString *restoredPath = [self.statePath stringByAppendingString:@".restored"];
    if ([NSFileManager.defaultManager fileExistsAtPath:restoredPath]) {
        [NSFileManager.defaultManager removeItemAtPath:restoredPath error:nil];
        [self restore:nil];
        self.detailLabel.stringValue = @"独立恢复进程已恢复实体屏。重新测试前请确认虚拟屏可用。";
    }
    if (self.recoveryRequested || (self.armed && (!self.watchdog.running || !ADDisplayActive(self.virtualDisplay.displayID)))) { [self restore:nil]; return; }
    if (self.armed && self.trialDeadline > 0) {
        NSInteger remaining = (NSInteger)ceil(self.trialDeadline - NSDate.date.timeIntervalSince1970);
        if (remaining <= 0) { [self restore:nil]; return; }
        self.statusLabel.stringValue = [NSString stringWithFormat:@"实体屏关屏测试 · %ld 秒后自动恢复", (long)remaining];
    }
}
- (void)systemWillSleep:(NSNotification *)notification { (void)notification; [self restore:nil]; }
- (BOOL)restoreApplicationsForDisplayID:(CGDirectDisplayID)displayID {
    if (self.appOperationInProgress) return NO;
    self.appOperationInProgress = YES;
    @try {
    [self updateInventory];
    BOOL ownsPendingWeChat = self.windowRecovery.needsRestoreBeforeRemovingVirtualDisplay && self.wechatDisplayID == displayID;
    if (ownsPendingWeChat) {
        [self.windowRecovery refreshWithVirtualDisplayID:displayID displaySnapshot:DisplaySnapshot()];
        NSError *error = nil;
        if (![self.windowRecovery restoreWeChat:&error]) {
            [self reportApplicationError:error fallback:@"微信尚未返回实体屏；保留这个虚拟屏。"];
            return NO;
        }
    }
    if ([self.window.screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue] == displayID) {
        NSScreen *physicalScreen = nil;
        for (NSScreen *screen in NSScreen.screens) {
            CGDirectDisplayID candidate = [screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
            if (![VDVirtualDisplay isVirtualDisplay:candidate] && ADDisplayActive(candidate)) {
                physicalScreen = screen;
                if (candidate == CGMainDisplayID()) break;
            }
        }
        if (!physicalScreen) {
            self.detailLabel.stringValue = @"控制面板仍在该虚拟屏中，请先连接实体显示器。";
            return NO;
        }
        NSRect frame = self.window.frame, visible = physicalScreen.visibleFrame;
        frame.size.width = MIN(frame.size.width, visible.size.width);
        frame.size.height = MIN(frame.size.height, visible.size.height);
        frame.origin = NSMakePoint(NSMidX(visible) - frame.size.width / 2, NSMidY(visible) - frame.size.height / 2);
        [self.window setFrame:frame display:YES];
        [self updateInventory];
    }
    NSError *error = nil;
    if (![self.appWorkspace restoreDisplayID:displayID error:&error]) {
        [self reportApplicationError:error fallback:@"有应用窗口未能返回实体屏；保留这个虚拟屏。"];
        return NO;
    }
    // AX confirms placement before WindowServer's visible-window list catches
    // up. Wait only for inventory convergence, never repeat a window move.
    BOOL emptied = WaitUntil(^BOOL{
        [self updateInventory];
        return ![self.appWorkspace needsRestoreForDisplayID:displayID];
    }, 1.5);
    if (!emptied) {
        [self reportApplicationError:nil fallback:@"仍有应用窗口或窗口清单尚未更新，已保留这个虚拟屏。请稍后重试关闭。"];
        return NO;
    }
    return YES;
    } @finally {
        self.appOperationInProgress = NO;
        [self updateInventory];
    }

}
- (void)stop:(id)sender {
    (void)sender;
    if (self.previewMode || self.displayOperationInProgress || self.appOperationInProgress) return;
    if (self.topologyRecoverySnapshot) { [self retryTopologyRecovery:nil]; return; }
    if (self.armed || self.preparing || self.layoutChangedForTrial) [self restore:nil];
    if (self.armed || self.preparing || self.restoring || self.layoutChangedForTrial || self.recoveryRequested) return;
    VDVirtualDisplay *closing = self.virtualDisplay;
    if (!closing.isCreated) return;
    if (![self restoreApplicationsForDisplayID:closing.displayID]) return;
    BOOL physicalActive = NO;
    for (NSDictionary *item in DisplaySnapshot()) {
        CGDirectDisplayID ident = [item[@"displayID"] unsignedIntValue];
        if (ADDisplayActive(ident) && ![VDVirtualDisplay isVirtualDisplay:ident]) physicalActive = YES;
    }
    BOOL mainReady = physicalActive;
    if (mainReady && CGMainDisplayID() == closing.displayID) {
        // A manually chosen virtual main display needs a physical fallback.
        self.originalLayout = DisplaySnapshot();
        self.originalMain = 0;
        mainReady = [self setVirtualMain:NO];
    }
    if (!mainReady) {
        self.statusLabel.stringValue = @"保留虚拟屏：尚无可用的实体主屏";
        self.detailLabel.stringValue = @"请先打开或重新连接实体显示器，再关闭或退出。";
        return;
    }
    self.displayOperationInProgress = YES;
    NSError *topologyError = nil;
    YMDisplayTopologySnapshot *before = [self.displayTopology captureSnapshotWithError:&topologyError];
    CGDirectDisplayID removedID = closing.displayID;
    YMDisplayTopologySnapshot *survivors = [before snapshotByExcludingDisplayID:removedID];
    if (!survivors) {
        self.displayOperationInProgress = NO;
        [self reportTopologyError:topologyError];
        return;
    }
    [self finishWatchdog];
    self.selectedProfile.topologyVerified = NO;
    [closing destroy];
    [self recoverTopology:survivors removedID:removedID completion:^(BOOL recovered, NSError *recoveryError) {
        self.displayOperationInProgress = NO;
        if (![self activeProfiles].count) [self powerAssertions:NO];
        if (self.wechatDisplayID && ![self profileForDisplayID:self.wechatDisplayID]) self.wechatDisplayID = 0;
        if (!recovered) [self reportTopologyError:recoveryError];
        else {
            self.statusLabel.stringValue = @"所选虚拟屏已关闭";
            self.detailLabel.stringValue = @"其他工作屏继续运行。已关闭的屏幕保留名称，可再次启动。";
        }
        [self updateInventory];
        [self resumeTerminationAfterTopologyRecovery:recovered];
    }];
}
- (void)quit:(id)sender { (void)sender; [NSApp terminate:nil]; }
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    if (self.previewMode) return NSTerminateNow;
    (void)sender;
    if (self.displayOperationInProgress || self.appOperationInProgress) return NSTerminateCancel;
    if (self.topologyRecoverySnapshot) { self.terminationAfterTopologyRecovery = YES; [self retryTopologyRecovery:nil]; return NSTerminateCancel; }
    if (self.armed || self.preparing || self.layoutChangedForTrial) [self restore:nil];
    if (self.armed || self.preparing || self.restoring || self.layoutChangedForTrial || self.recoveryRequested) return NSTerminateCancel;
    NSArray<YMManagedDisplay *> *active = [self activeProfiles];
    // Restore every workspace before removing any; a failure leaves the whole
    // virtual topology available for manual recovery.
    for (YMManagedDisplay *profile in active) {
        if (![self restoreApplicationsForDisplayID:profile.display.displayID]) {
            [self showWindow:nil]; return NSTerminateCancel;
        }
    }
    if (active.count) {
        YMManagedDisplay *profile = active.firstObject;
        [self selectProfile:profile];
        self.terminationAfterTopologyRecovery = YES;
        [self stop:nil];
        // Successful asynchronous recovery resumes the quit sequence for the
        // remaining outputs. Failure leaves the app and recovery controls alive.
        if (!self.displayOperationInProgress) {
            self.terminationAfterTopologyRecovery = NO;
            if (profile.display.isCreated || self.topologyRecoverySnapshot) [self showWindow:nil];
        }
        return NSTerminateCancel;
    }
    if (self.windowRecovery.needsRestoreBeforeRemovingVirtualDisplay) { [self showWindow:nil]; return NSTerminateCancel; }
    [self writeStateEnding:YES];
    return NSTerminateNow;
}
- (void)applicationWillTerminate:(NSNotification *)notification {
    if (self.previewMode) return;
    (void)notification;
    [self.controlServer invalidate];
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [self.heartbeatTimer invalidate];
    if (self.hotkey) UnregisterEventHotKey(self.hotkey);
    if (self.keyHandler) RemoveEventHandler(self.keyHandler);
    [self powerAssertions:NO];
}
@end

#pragma mark - Fork: screen control CLI (fork-features/control)

@implementation ADController (YMControl)
- (NSDictionary *)controlDescriptionOfProfile:(YMManagedDisplay *)profile {
    NSMutableDictionary *screen = [@{@"id": @(profile.ordinal), @"name": profile.friendlyName, @"title": [self titleForProfile:profile],
        @"running": @(profile.display.isCreated), @"width": @(profile.width), @"height": @(profile.height), @"hiDPI": @(profile.hiDPI)} mutableCopy];
    if (profile.display.isCreated) {
        screen[@"displayID"] = @(profile.display.displayID);
        screen[@"verified"] = @(profile.topologyVerified);
    }
    return screen;
}
// SCREEN is matched by id (ordinal), then exact name, then exact title.
- (YMManagedDisplay *)controlProfileMatching:(NSString *)key problem:(NSString **)problem {
    NSInteger ordinal = key.integerValue;
    BOOL numeric = ordinal > 0 && [key isEqualToString:[NSString stringWithFormat:@"%ld", (long)ordinal]];
    for (YMManagedDisplay *profile in self.displayProfiles) if (numeric && profile.ordinal == (NSUInteger)ordinal) return profile;
    for (YMManagedDisplay *profile in self.displayProfiles) if ([profile.friendlyName isEqualToString:key]) return profile;
    for (YMManagedDisplay *profile in self.displayProfiles) if ([[self titleForProfile:profile] isEqualToString:key]) return profile;
    NSMutableArray *known = [NSMutableArray array];
    for (YMManagedDisplay *profile in self.displayProfiles) [known addObject:[self titleForProfile:profile]];
    *problem = [NSString stringWithFormat:@"no screen matches \"%@\"; known screens: %@", key, [known componentsJoinedByString:@", "]];
    return nil;
}
- (NSString *)controlBusyReason {
    if (self.topologyRecoverySnapshot) return @"a display arrangement recovery is pending; retry it from the yomado menu first";
    if (self.displayOperationInProgress || self.appOperationInProgress) return @"another display or window operation is in progress; retry shortly";
    if (self.armed || self.preparing || self.restoring || self.layoutChangedForTrial || self.recoveryRequested)
        return @"a physical-output trial or its recovery is in progress";
    return nil;
}
- (NSString *)controlFailureText {
    return self.detailLabel.stringValue.length ? self.detailLabel.stringValue : self.statusLabel.stringValue;
}
// create:/stop: finish asynchronously through topology verification; poll their
// shared in-progress flag on the main queue, then report the profile's final state.
- (void)controlAwait:(YMManagedDisplay *)profile running:(BOOL)wantRunning deadline:(NSDate *)deadline reply:(YMControlReply)reply {
    if (self.displayOperationInProgress && deadline.timeIntervalSinceNow > 0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self controlAwait:profile running:wantRunning deadline:deadline reply:reply];
        });
        return;
    }
    self.controlRequestActive = NO;
    if (self.displayOperationInProgress) { reply(YMControlFailure(@"timed out waiting for the display operation; check `Yomado screen list`")); return; }
    BOOL reached = profile.display.isCreated == wantRunning && (!wantRunning || profile.topologyVerified);
    reply(reached ? YMControlSuccess(@{@"screen": [self controlDescriptionOfProfile:profile]}) : YMControlFailure([self controlFailureText]));
}
- (void)controlSwitch:(YMManagedDisplay *)profile on:(BOOL)on reply:(YMControlReply)reply {
    [self selectProfile:profile];
    if (self.selectedProfile != profile) { reply(YMControlFailure(@"could not select the screen; another operation is in progress")); return; }
    self.controlRequestActive = YES;
    if (on) [self create:nil];
    else [self stop:nil];
    [self controlAwait:profile running:on deadline:[NSDate dateWithTimeIntervalSinceNow:60] reply:reply];
}
- (void)handleControlRequest:(YMControlRequest *)request reply:(YMControlReply)reply {
    if (request.command == YMControlCommandList) {
        NSMutableArray *screens = [NSMutableArray array];
        for (YMManagedDisplay *profile in self.displayProfiles) [screens addObject:[self controlDescriptionOfProfile:profile]];
        reply(YMControlSuccess(@{@"screens": screens}));
        return;
    }
    NSString *busy = [self controlBusyReason];
    if (request.command == YMControlCommandCreate) {
        if (busy) { reply(YMControlFailure(busy)); return; }
        YMManagedDisplay *profile = [self appendProfileNamed:request.name width:request.width ?: 1920 hiDPI:request.hiDPI == YMControlHiDPIOn];
        if (!profile) { reply(YMControlFailure(@"no screen ids left")); return; }
        [self controlSwitch:profile on:YES reply:reply];
        return;
    }
    NSString *problem = nil;
    YMManagedDisplay *profile = [self controlProfileMatching:request.screen problem:&problem];
    if (!profile) { reply(YMControlFailure(problem)); return; }
    BOOL running = profile.display.isCreated;
    switch (request.command) {
        case YMControlCommandStart:
        case YMControlCommandClose: {
            BOOL on = request.command == YMControlCommandStart;
            if (running == on) { reply(YMControlSuccess(@{@"screen": [self controlDescriptionOfProfile:profile], @"unchanged": @YES})); return; }
            if (busy) { reply(YMControlFailure(busy)); return; }
            [self controlSwitch:profile on:on reply:reply];
            return;
        }
        case YMControlCommandRename:
            if (busy) { reply(YMControlFailure(busy)); return; }
            profile.friendlyName = request.name;
            [self saveDisplayProfiles];
            [self updateInventory];
            // A running display keeps its system name until it is started again.
            reply(YMControlSuccess(@{@"screen": [self controlDescriptionOfProfile:profile], @"systemNameUpdatesOnNextStart": @(running)}));
            return;
        case YMControlCommandConfigure:
            if (running) { reply(YMControlFailure(@"close the screen before changing its size or HiDPI setting")); return; }
            if (busy) { reply(YMControlFailure(busy)); return; }
            if (request.width) { profile.width = request.width; profile.height = request.width == 2560 ? 1440 : 1080; }
            if (request.hiDPI != YMControlHiDPIUnchanged) profile.hiDPI = request.hiDPI == YMControlHiDPIOn;
            [self saveDisplayProfiles];
            [self updateInventory];
            reply(YMControlSuccess(@{@"screen": [self controlDescriptionOfProfile:profile]}));
            return;
        case YMControlCommandDelete:
            if (running) { reply(YMControlFailure(@"close the screen before deleting it")); return; }
            if (busy) { reply(YMControlFailure(busy)); return; }
            [self.displayProfiles removeObject:profile];
            if (self.selectedProfile == profile) {
                self.selectedProfile = self.displayProfiles.firstObject;
                self.virtualDisplay = self.selectedProfile.display;
            }
            [self saveDisplayProfiles];
            [self updateInventory];
            reply(YMControlSuccess(@{@"deleted": [self controlDescriptionOfProfile:profile]}));
            return;
        case YMControlCommandList:
        case YMControlCommandCreate:
            break; // handled above
    }
}
@end

static int SelfTest(NSString *directory, BOOL hiDPI) {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    [NSApp finishLaunching];
    NSArray *before = DisplaySnapshot();
    CGDirectDisplayID originalMain = CGMainDisplayID();
    VDVirtualDisplay *display = [[VDVirtualDisplay alloc] initWithSerialNumber:hiDPI ? 0x41445402 : 0x41445401];
    NSError *error = nil;
    if (![display createWithWidth:1920 height:1080 hiDPI:hiDPI name:@"Yomado Test" error:&error]) {
        fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 1;
    }
    CGDirectDisplayID ident = display.displayID;
    BOOL active = WaitUntil(^BOOL{ return ADDisplayActive(ident) != 0; }, 5);
    CGRect bounds = CGDisplayBounds(ident);
    __block NSScreen *virtualScreen = nil;
    BOOL screenFound = WaitUntil(^BOOL{
        for (NSScreen *screen in NSScreen.screens)
            if ([screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue] == ident) virtualScreen = screen;
        return virtualScreen != nil;
    }, 5);
    CGDisplayModeRef mode = CGDisplayCopyDisplayMode(ident);
    size_t pixelsWide = mode ? CGDisplayModeGetPixelWidth(mode) : 0;
    size_t pixelsHigh = mode ? CGDisplayModeGetPixelHeight(mode) : 0;
    if (mode) CGDisplayModeRelease(mode);
    CGFloat scale = virtualScreen.backingScaleFactor;
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 500, 240)
        styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    window.releasedWhenClosed = NO;
    window.title = @"Yomado 验证窗口";
    ADTestView *view = [[ADTestView alloc] initWithFrame:NSMakeRect(0, 0, 500, 240)];
    window.contentView = view;
    if (virtualScreen) [window setFrameOrigin:NSMakePoint(virtualScreen.frame.origin.x + 50, virtualScreen.frame.origin.y + 50)];
    [window orderFront:nil];
    BOOL windowOnVirtual = WaitUntil(^BOOL{ return [window.screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue] == ident; }, 3);
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
    NSData *first = [view PNGData];
    view.frameNumber = 1;
    view.needsDisplay = YES;
    NSData *second = [view PNGData];
    BOOL directoryWritten = [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
    BOOL firstWritten = [first writeToFile:[directory stringByAppendingPathComponent:@"frame-0.png"] atomically:YES];
    BOOL secondWritten = [second writeToFile:[directory stringByAppendingPathComponent:@"frame-1.png"] atomically:YES];
    // Exercise exactly the enable/disable API, but ONLY on our temporary virtual display.
    NSString *failure = nil;
    BOOL disabled = ConfigureEnabled(@[@(ident)], NO, &failure)
        && WaitUntil(^BOOL{ return ADDisplayActive(ident) == 0; }, 4);
    BOOL reenabled = ConfigureEnabled(@[@(ident)], YES, &failure)
        && WaitUntil(^BOOL{ return ADDisplayActive(ident) != 0; }, 4);
    NSArray *during = DisplaySnapshot();
    [window orderOut:nil];
    [window close];
    [display destroy];
    BOOL removed = WaitUntil(^BOOL{ return ADDisplayOnline(ident) == 0; }, 5);
    CGDisplayConfigRef layout = NULL;
    BOOL layoutRestored = CGBeginDisplayConfiguration(&layout) == kCGErrorSuccess;
    if (layoutRestored) {
        for (NSDictionary *item in before) {
            CGError err = CGConfigureDisplayOrigin(layout, [item[@"displayID"] unsignedIntValue], [item[@"x"] intValue], [item[@"y"] intValue]);
            if (err != kCGErrorSuccess) layoutRestored = NO;
        }
        if (layoutRestored) layoutRestored = CGCompleteDisplayConfiguration(layout, kCGConfigureForAppOnly) == kCGErrorSuccess;
        else CGCancelDisplayConfiguration(layout);
    }
    BOOL settled = WaitUntil(^BOOL{
        for (NSDictionary *item in before) {
            CGRect expected = CGRectMake([item[@"x"] doubleValue], [item[@"y"] doubleValue], [item[@"logicalWidth"] doubleValue], [item[@"logicalHeight"] doubleValue]);
            if (!CGRectEqualToRect(expected, CGDisplayBounds([item[@"displayID"] unsignedIntValue]))) return NO;
        }
        return YES;
    }, 3);
    NSArray *after = DisplaySnapshot();
    BOOL physicalTopologyRestored = layoutRestored && settled && before.count == after.count;
    for (NSDictionary *item in before) {
        CGDirectDisplayID prior = [item[@"displayID"] unsignedIntValue];
        CGRect expected = CGRectMake([item[@"x"] doubleValue], [item[@"y"] doubleValue], [item[@"logicalWidth"] doubleValue], [item[@"logicalHeight"] doubleValue]);
        physicalTopologyRestored &= ADDisplayActive(prior) && CGRectEqualToRect(expected, CGDisplayBounds(prior));
    }
    BOOL pass = active && screenFound && windowOnVirtual && physicalTopologyRestored
        && bounds.size.width == 1920 && bounds.size.height == 1080
        && pixelsWide == 1920 * (hiDPI ? 2 : 1) && pixelsHigh == 1080 * (hiDPI ? 2 : 1)
        && scale == (hiDPI ? 2 : 1) && directoryWritten && firstWritten && secondWritten
        && first.length > 0 && second.length > 0 && ![first isEqualToData:second]
        && disabled && reenabled && removed && CGMainDisplayID() == originalMain && before.count == after.count;
    NSDictionary *receipt = @{@"pass":@(pass), @"hiDPI":@(hiDPI), @"virtualID":@(ident),
        @"virtualActive":@(active), @"screenFound":@(screenFound), @"windowOnVirtual":@(windowOnVirtual),
        @"physicalTopologyRestored":@(physicalTopologyRestored), @"pixelWidth":@(pixelsWide), @"pixelHeight":@(pixelsHigh),
        @"backingScale":@(scale), @"framesExported":@(directoryWritten && firstWritten && secondWritten), @"logicalWidth":@(bounds.size.width), @"logicalHeight":@(bounds.size.height),
        @"ownViewFramesDiffer":@(![first isEqualToData:second]), @"virtualDisableVerified":@(disabled),
        @"virtualEnableVerified":@(reenabled), @"virtualRemoved":@(removed),
        @"physicalDisplaysNeverDisabled":@YES, @"mainDisplayRestored":@(CGMainDisplayID() == originalMain),
        @"before":before, @"during":during, @"after":after,
        @"scope":@"Own AppKit view only; not screen capture of MD/Blender; no monitor power measurement.",
        @"error":failure ?: @""};
    NSString *json = JSONText(receipt);
    BOOL receiptWritten = [json writeToFile:[directory stringByAppendingPathComponent:@"receipt.json"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    printf("%s\n", json.UTF8String);
    return pass && receiptWritten ? 0 : 2;
}

// Exercise independent recovery against only an owned temporary virtual display.
// The existing main physical display stays active throughout this check.
static int WatchdogTest(NSString *directory, NSString *helperPath) {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    [NSApp finishLaunching];
    CGDirectDisplayID originalMain = CGMainDisplayID();
    NSArray *before = DisplaySnapshot();
    VDVirtualDisplay *display = [[VDVirtualDisplay alloc] initWithSerialNumber:0x41445701];
    NSError *error = nil;
    if (![display createWithWidth:1280 height:720 hiDPI:NO name:@"Yomado Recovery Test" error:&error]) return 1;
    CGDirectDisplayID target = display.displayID;
    BOOL created = WaitUntil(^BOOL{ return ADDisplayActive(target); }, 5);
    [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *path = [directory stringByAppendingPathComponent:[NSString stringWithFormat:@"watchdog-%@.json", NSUUID.UUID.UUIDString]];
    NSTask *fakeParent = [[NSTask alloc] init];
    fakeParent.executableURL = [NSURL fileURLWithPath:@"/bin/sleep"];
    fakeParent.arguments = @[@"30"];
    BOOL parentLaunched = [fakeParent launchAndReturnError:&error];
    NSDictionary *state = @{@"parentPID":@(fakeParent.processIdentifier), @"heartbeat":@(NSDate.date.timeIntervalSince1970),
        @"armed":@YES, @"end":@NO, @"targets":@[@(target)], @"virtualID":@(originalMain)};
    BOOL stateWritten = [[NSJSONSerialization dataWithJSONObject:state options:0 error:nil] writeToFile:path atomically:YES];
    NSTask *helper = [[NSTask alloc] init];
    helper.executableURL = [NSURL fileURLWithPath:helperPath];
    helper.arguments = @[path, [NSString stringWithFormat:@"%d", fakeParent.processIdentifier]];
    helper.standardOutput = NSFileHandle.fileHandleWithNullDevice;
    helper.standardError = NSFileHandle.fileHandleWithNullDevice;
    BOOL helperLaunched = parentLaunched && stateWritten && [helper launchAndReturnError:&error];
    BOOL ready = helperLaunched && WaitUntil(^BOOL{ return [NSFileManager.defaultManager fileExistsAtPath:[path stringByAppendingString:@".ready"]]; }, 4);
    BOOL disabled = ready && ConfigureEnabled(@[@(target)], NO, nil)
        && WaitUntil(^BOOL{ return !ADDisplayActive(target); }, 4);
    if (fakeParent.running) [fakeParent terminate];
    BOOL restored = disabled && WaitUntil(^BOOL{
        return [NSFileManager.defaultManager fileExistsAtPath:[path stringByAppendingString:@".restored"]] && ADDisplayActive(target);
    }, 8);
    BOOL helperExited = helperLaunched && WaitUntil(^BOOL{ return !helper.running; }, 2);
    if (helper.running) [helper terminate];
    if (fakeParent.running) [fakeParent terminate];
    if (!ADDisplayActive(target)) ConfigureEnabled(@[@(target)], YES, nil);
    [display destroy];
    BOOL removed = WaitUntil(^BOOL{ return !ADDisplayOnline(target); }, 5);
    CGDisplayConfigRef layout = NULL;
    BOOL layoutRestored = CGBeginDisplayConfiguration(&layout) == kCGErrorSuccess;
    if (layoutRestored) {
        for (NSDictionary *item in before) {
            CGError err = CGConfigureDisplayOrigin(layout, [item[@"displayID"] unsignedIntValue], [item[@"x"] intValue], [item[@"y"] intValue]);
            if (err != kCGErrorSuccess) layoutRestored = NO;
        }
        if (layoutRestored) layoutRestored = CGCompleteDisplayConfiguration(layout, kCGConfigureForAppOnly) == kCGErrorSuccess;
        else CGCancelDisplayConfiguration(layout);
    }
    WaitUntil(^BOOL{
        for (NSDictionary *item in before) {
            CGRect expected = CGRectMake([item[@"x"] doubleValue], [item[@"y"] doubleValue], [item[@"logicalWidth"] doubleValue], [item[@"logicalHeight"] doubleValue]);
            if (!CGRectEqualToRect(expected, CGDisplayBounds([item[@"displayID"] unsignedIntValue]))) return NO;
        }
        return YES;
    }, 3);
    BOOL physicalRestored = layoutRestored && CGMainDisplayID() == originalMain;
    for (NSDictionary *item in before) {
        CGDirectDisplayID ident = [item[@"displayID"] unsignedIntValue];
        CGRect expected = CGRectMake([item[@"x"] doubleValue], [item[@"y"] doubleValue], [item[@"logicalWidth"] doubleValue], [item[@"logicalHeight"] doubleValue]);
        physicalRestored &= ADDisplayActive(ident) && CGRectEqualToRect(expected, CGDisplayBounds(ident));
    }
    BOOL pass = created && ready && disabled && restored && helperExited && removed && physicalRestored;
    NSDictionary *receipt = @{@"pass":@(pass), @"helperReady":@(ready), @"ownedVirtualDisabled":@(disabled),
        @"parentExitRecovery":@(restored), @"helperExited":@(helperExited), @"virtualRemoved":@(removed),
        @"physicalTopologyRestored":@(physicalRestored), @"physicalDisplaysNeverDisabled":@YES,
        @"scope":@"Killed a disposable child process; recovery target was only an owned temporary virtual display."};
    NSString *json = JSONText(receipt);
    BOOL written = [json writeToFile:[directory stringByAppendingPathComponent:@"receipt.json"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    printf("%s\n", json.UTF8String);
    for (NSString *suffix in @[@"", @".ready", @".restored", @".error"])
        [NSFileManager.defaultManager removeItemAtPath:[path stringByAppendingString:suffix] error:nil];
    return pass && written ? 0 : 2;
}

// Synthetic fixtures only. This route deliberately never installs ADController as
// the NSApplication delegate, starts a timer/menu/hotkey/watchdog, constructs a
// VDVirtualDisplay, calls live display enumeration, or activates/orders a window.
static NSArray<NSDictionary *> *UIPreviewSnapshot(BOOL created, BOOL trial, BOOL multi) {
    NSMutableArray *displays = [NSMutableArray array];
    [displays addObject:@{@"displayID":@900, @"name":@"Studio Display 1", @"x":trial ? @1920 : @0, @"y":@0,
        @"logicalWidth":@2560, @"logicalHeight":@1440, @"isMain":@(!trial), @"isVirtual":@NO, @"isActive":@(!trial), @"isOnline":@YES}];
    [displays addObject:@{@"displayID":@901, @"name":@"Studio Display 2", @"x":trial ? @4480 : @2560, @"y":@0,
        @"logicalWidth":@2560, @"logicalHeight":@1440, @"isMain":@NO, @"isVirtual":@NO, @"isActive":@YES, @"isOnline":@YES}];
    if (created) [displays addObject:@{@"displayID":@902, @"name":@"虚拟屏 1 · Codex", @"x":trial ? @0 : @5120, @"y":@0,
        @"logicalWidth":@1920, @"logicalHeight":@1080, @"isMain":@(trial), @"isVirtual":@YES, @"isActive":@YES, @"isOnline":@YES}];
    if (multi) [displays addObject:@{@"displayID":@903, @"name":@"虚拟屏 2 · GrokBot", @"x":@7040, @"y":@0,
        @"logicalWidth":@1920, @"logicalHeight":@1080, @"isMain":@NO, @"isVirtual":@YES, @"isActive":@YES, @"isOnline":@YES}];
    return displays;
}
static int PreviewUI(NSString *path, NSString *state, BOOL dark) {
    if (![@[@"empty", @"running", @"multi", @"trial"] containsObject:state]) {
        fprintf(stderr, "Preview state must be empty, running, multi, or trial.\n");
        return 64;
    }
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    NSAppearance *appearance = [NSAppearance appearanceNamed:dark ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
    NSApp.appearance = appearance;
    ADController *controller = [[ADController alloc] init];
    controller.previewMode = YES;
    controller.previewState = state;
    controller.previewSnapshot = UIPreviewSnapshot(![state isEqualToString:@"empty"], [state isEqualToString:@"trial"], [state isEqualToString:@"multi"]);
    [controller buildWindow];
    controller.window.appearance = appearance;
    [controller updateInventory];
    NSView *content = controller.window.contentView;
    [content layoutSubtreeIfNeeded];
    [controller.window setContentSize:NSMakeSize(1000, 410)];
    [content layoutSubtreeIfNeeded];
    // Native controls may settle their internal layers on a later run-loop turn.
    // Only this hidden fixture window exists in the preview process.
    for (NSUInteger pass = 0; pass < 3; pass++) {
        [content displayIfNeeded];
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        [content layoutSubtreeIfNeeded];
    }
    NSBitmapImageRep *bitmap = [content bitmapImageRepForCachingDisplayInRect:content.bounds];
    if (!bitmap) { fprintf(stderr, "Could not allocate UI preview bitmap.\n"); return 1; }
    [content cacheDisplayInRect:content.bounds toBitmapImageRep:bitmap];
    NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    NSError *error = nil;
    if (!png || ![png writeToFile:path options:NSDataWritingAtomic error:&error]) {
        fprintf(stderr, "Could not write UI preview (%s, %ld).\n", (error.domain ?: @"render").UTF8String, (long)error.code);
        return 1;
    }
    printf("%s\n", JSONText(@{@"renderedFrom":@"synthetic-ui-fixtures", @"state":state,
        @"appearance":dark ? @"dark" : @"light", @"pixelsWide":@(bitmap.pixelsWide), @"pixelsHigh":@(bitmap.pixelsHigh)}).UTF8String);
    [controller.window close];
    return 0;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc > 1 && strcmp(argv[1], "screen") == 0) return YMControlClientMain(argc, argv); // fork
        if (argc > 1 && strcmp(argv[1], "agent") == 0) return YMAgentClientMain(argc, argv); // fork
        if (argc > 1 && strcmp(argv[1], "--preview-ui") == 0) {
            if (argc < 3 || argc > 5 || (argc == 5 && strcmp(argv[4], "light") != 0 && strcmp(argv[4], "dark") != 0)) {
                fprintf(stderr, "Usage: Yomado --preview-ui <png-path> [empty|running|multi|trial] [light|dark]\n");
                return 64;
            }
            return PreviewUI([NSString stringWithUTF8String:argv[2]],
                argc > 3 ? [NSString stringWithUTF8String:argv[3]] : @"running", argc > 4 && strcmp(argv[4], "dark") == 0);
        }
        if (argc > 1 && strcmp(argv[1], "--diagnose") == 0) {
            BOOL includeIdentifiers = argc == 3 && strcmp(argv[2], "--include-device-identifiers") == 0;
            if (argc > 2 && !includeIdentifiers) {
                fprintf(stderr, "Usage: Yomado --diagnose [--include-device-identifiers]\n");
                return 64;
            }
            printf("%s\n", JSONTextWithIdentifiers(@{@"virtualDisplayAPI":@([VDVirtualDisplay isAPIAvailable]),
                @"physicalDisplaySwitchAPI":@(EnableAPI() != NULL), @"displays":DisplaySnapshot()}, includeIdentifiers).UTF8String);
            return 0;
        }
        if (argc > 2 && strcmp(argv[1], "--self-test") == 0)
            return SelfTest([NSString stringWithUTF8String:argv[2]], argc > 3 && strcmp(argv[3], "hidpi") == 0);
        if (argc > 3 && strcmp(argv[1], "--watchdog-test") == 0)
            return WatchdogTest([NSString stringWithUTF8String:argv[2]], [NSString stringWithUTF8String:argv[3]]);
        [NSApplication sharedApplication];
        // The interactive app needs a regular identity for independent Stage
        // Manager grouping. Keep LSUIElement for the noninteractive modes above;
        // the normal app shows both its Dock icon and the existing status item.
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        ADController *controller = [[ADController alloc] init];
        NSApp.delegate = controller;
        [NSApp run];
        return 0;
    }
}
