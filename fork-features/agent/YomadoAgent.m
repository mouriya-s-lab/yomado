// Fork feature: agent sessions. The YomadoAgent helper process.
// Design: fork-features/agent/README.md; operation shapes: operations.md.
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <ImageIO/ImageIO.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <dlfcn.h>
#import <sys/file.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <sys/un.h>
#import "YMAgentPaths.h"
#import "YMControl.h"

static NSString *const YMAgentVersion = @"1";
static const NSTimeInterval YMWaitLimit = 15;
static const NSTimeInterval YMInputSettle = 0.12;
static const NSTimeInterval YMIdleExit = 60;

#pragma mark - Private symbols

typedef void (*YMSetWindowLocationFn)(CGEventRef, CGPoint);
typedef AXError (*YMGetWindowFn)(AXUIElementRef, CGWindowID *);
static YMSetWindowLocationFn YMSetWindowLocation;
static YMGetWindowFn YMGetWindow;

static BOOL YMLoadPrivateSymbols(void) {
    YMSetWindowLocation = (YMSetWindowLocationFn)dlsym(RTLD_DEFAULT, "CGEventSetWindowLocation");
    YMGetWindow = (YMGetWindowFn)dlsym(RTLD_DEFAULT, "_AXUIElementGetWindow");
    return YMSetWindowLocation && YMGetWindow;
}

#pragma mark - Errors

static NSString *const YMErrorDomain = @"dev.chekusu.yomado.agent";

static NSError *YMError(NSString *code, NSString *format, ...) NS_FORMAT_FUNCTION(2, 3);
static NSError *YMError(NSString *code, NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    return [NSError errorWithDomain:YMErrorDomain code:1 userInfo:@{@"code": code, NSLocalizedDescriptionKey: message}];
}

#define YMFAIL(CODE, ...) do { if (error) *error = YMError(CODE, __VA_ARGS__); return nil; } while (0)

#pragma mark - Small helpers

// Waits inside a request. Dispatching AppKit events (not only run-loop sources)
// keeps NSScreen.screens current when a virtual display appears mid-request.
static BOOL YMWaitUntil(NSTimeInterval timeout, BOOL (^done)(void)) {
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (!done()) {
        if (end.timeIntervalSinceNow <= 0) return NO;
        NSEvent *event = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]
                                               inMode:NSDefaultRunLoopMode dequeue:YES];
        if (event) [NSApp sendEvent:event];
    }
    return YES;
}

static void YMPump(NSTimeInterval seconds) { YMWaitUntil(seconds, ^BOOL { return NO; }); }

// Runs `block` on the main thread through the main run loop. Unlike the main
// dispatch queue, run-loop blocks also run while a request pumps the run loop
// inside YMWaitUntil, so completion handlers and new lines arrive mid-request.
static void YMOnMain(dispatch_block_t block) {
    CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopCommonModes, block);
    CFRunLoopWakeUp(CFRunLoopGetMain());
}

static NSDictionary *YMRect(CGRect r) {
    return @{@"x": @(r.origin.x), @"y": @(r.origin.y), @"width": @(r.size.width), @"height": @(r.size.height)};
}

static BOOL YMIsNumber(id value) {
    return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID();
}

// Argument readers: return NO and set `error` (code `usage`) on a missing or ill-typed value.
static BOOL YMArgNumber(NSDictionary *args, NSString *key, BOOL required, double *out, NSError **error) {
    id value = args[key];
    if (!value) {
        if (required && error) *error = YMError(@"usage", @"missing argument \"%@\"", key);
        return !required;
    }
    if (!YMIsNumber(value)) { if (error) *error = YMError(@"usage", @"\"%@\" must be a number", key); return NO; }
    *out = [value doubleValue];
    return YES;
}

static BOOL YMArgString(NSDictionary *args, NSString *key, BOOL required, NSString **out, NSError **error) {
    id value = args[key];
    if (!value) {
        if (required && error) *error = YMError(@"usage", @"missing argument \"%@\"", key);
        return !required;
    }
    if (![value isKindOfClass:NSString.class] || ![value length]) { if (error) *error = YMError(@"usage", @"\"%@\" must be a non-empty string", key); return NO; }
    *out = value;
    return YES;
}

static BOOL YMArgPoint(NSDictionary *args, NSString *key, BOOL required, BOOL *present, CGPoint *out, NSError **error) {
    id value = args[key];
    *present = value != nil;
    if (!value) {
        if (required && error) *error = YMError(@"usage", @"missing argument \"%@\"", key);
        return !required;
    }
    if (![value isKindOfClass:NSDictionary.class] || !YMIsNumber(value[@"x"]) || !YMIsNumber(value[@"y"])) {
        if (error) *error = YMError(@"usage", @"\"%@\" must be {\"x\": number, \"y\": number}", key);
        return NO;
    }
    *out = CGPointMake([value[@"x"] doubleValue], [value[@"y"] doubleValue]);
    return YES;
}

#pragma mark - Windows (WindowServer + Accessibility)

static NSDictionary *YMCGWindowInfo(CGWindowID wid) {
    CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow, wid);
    NSArray *items = CFBridgingRelease(list);
    for (NSDictionary *item in items) if ([item[(id)kCGWindowNumber] unsignedIntValue] == wid) return item;
    return nil;
}

static CGRect YMWindowBounds(NSDictionary *info) {
    CGRect bounds = CGRectZero;
    CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)info[(id)kCGWindowBounds], &bounds);
    return bounds;
}

static NSDictionary *YMWindowJSON(CGWindowID wid) {
    NSDictionary *info = YMCGWindowInfo(wid);
    if (!info) return nil;
    pid_t pid = [info[(id)kCGWindowOwnerPID] intValue];
    NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    return @{@"id": @(wid), @"pid": @(pid), @"app": info[(id)kCGWindowOwnerName] ?: app.localizedName ?: @"",
             @"bundleId": app.bundleIdentifier ?: @"", @"title": info[(id)kCGWindowName] ?: @"",
             @"bounds": YMRect(YMWindowBounds(info))};
}

static AXUIElementRef YMCopyAppElement(pid_t pid) {
    AXUIElementRef app = AXUIElementCreateApplication(pid);
    AXUIElementSetMessagingTimeout(app, 1.0);
    return app;
}

// The application's AX windows that carry a CGWindowID, in AX order.
static NSArray<NSDictionary *> *YMAXWindows(pid_t pid) {
    AXUIElementRef app = YMCopyAppElement(pid);
    CFTypeRef value = NULL;
    NSMutableArray *result = [NSMutableArray array];
    if (AXUIElementCopyAttributeValue(app, kAXWindowsAttribute, &value) == kAXErrorSuccess) {
        for (id element in (__bridge NSArray *)value) {
            CGWindowID wid = 0;
            if (YMGetWindow((__bridge AXUIElementRef)element, &wid) == kAXErrorSuccess && wid)
                [result addObject:@{@"id": @(wid), @"element": element}];
        }
        CFRelease(value);
    }
    CFRelease(app);
    return result;
}

static id YMAXWindowElement(pid_t pid, CGWindowID wid) {
    for (NSDictionary *window in YMAXWindows(pid)) if ([window[@"id"] unsignedIntValue] == wid) return window[@"element"];
    return nil;
}

#pragma mark - AeroSpace

static NSString *YMAeroSpacePath(void) {
    NSMutableArray *dirs = [[NSProcessInfo.processInfo.environment[@"PATH"] ?: @"" componentsSeparatedByString:@":"] mutableCopy];
    [dirs addObjectsFromArray:@[@"/opt/homebrew/bin", @"/usr/local/bin"]];
    for (NSString *dir in dirs) {
        NSString *candidate = [dir stringByAppendingPathComponent:@"aerospace"];
        if (dir.length && [NSFileManager.defaultManager isExecutableFileAtPath:candidate]) return candidate;
    }
    return nil;
}

// Runs the AeroSpace CLI; returns stdout, or nil when it fails or takes over 5 s.
static NSString *YMAeroSpace(NSString *path, NSArray<NSString *> *arguments) {
    if (!path) return nil;
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:path];
    task.arguments = arguments;
    NSPipe *output = [NSPipe pipe];
    task.standardOutput = output;
    task.standardError = NSFileHandle.fileHandleWithNullDevice;
    if (![task launchAndReturnError:nil]) return nil;
    NSData *data = [output.fileHandleForReading readDataToEndOfFile];
    if (!YMWaitUntil(5, ^BOOL { return !task.running; })) { [task terminate]; return nil; }
    if (task.terminationStatus != 0) return nil;
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

static NSArray<NSString *> *YMLines(NSString *text) {
    NSMutableArray *lines = [NSMutableArray array];
    for (NSString *line in [text componentsSeparatedByString:@"\n"])
        if (line.length) [lines addObject:line];
    return lines;
}

#pragma mark - Session

@interface YMSession : NSObject
@property NSInteger sessionID;
@property int fd;
@property(nonatomic) dispatch_source_t readSource;
@property BOOL closed;
@property BOOL opened;
@property NSInteger screenID;
@property(copy) NSString *screenTitle;
@property CGDirectDisplayID displayID;
@property NSMutableSet<NSNumber *> *owned;      // window ids
@property NSMutableSet<NSNumber *> *handedOff;  // window ids of agent apps given to the user
@property NSMutableSet<NSNumber *> *apps;       // pids launched or adopted by the session
@property NSMutableArray<NSDictionary *> *events;
@property NSMutableDictionary<NSString *, id> *refs;
@property NSMutableDictionary<NSNumber *, NSArray<NSString *> *> *refsByWindow;
@property NSInteger nextRef;
@property NSInteger nextCapture;
@property CGWindowID pointerWindow;
@property CGPoint pointer;
@property(copy) NSString *launchingBundleID;
@property CGEventSourceRef keySource;
@property NSMutableData *buffer; // touched only on the socket queue
@end

@implementation YMSession
- (instancetype)init {
    if ((self = [super init])) {
        _owned = [NSMutableSet set]; _handedOff = [NSMutableSet set]; _apps = [NSMutableSet set];
        _events = [NSMutableArray array]; _refs = [NSMutableDictionary dictionary];
        _refsByWindow = [NSMutableDictionary dictionary]; _buffer = [NSMutableData data];
        _keySource = CGEventSourceCreate(kCGEventSourceStatePrivate);
    }
    return self;
}
- (void)dealloc { if (_keySource) CFRelease(_keySource); }
- (BOOL)ownsPid:(pid_t)pid {
    for (NSNumber *wid in self.owned)
        if ([YMCGWindowInfo(wid.unsignedIntValue)[(id)kCGWindowOwnerPID] intValue] == pid) return YES;
    return NO;
}
@end

typedef NSDictionary *(^YMOperation)(YMSession *session, NSDictionary *args, NSError **error);

#pragma mark - Helper

@interface YMAgent : NSObject
@property NSMutableArray<YMSession *> *sessions;
@property NSMutableArray<NSArray *> *pending; // [session, request]
@property BOOL executing;
@property YMSession *current;
@property(copy) NSString *currentStolenBy;
@property NSRunningApplication *userFront;
@property NSDictionary<NSString *, YMOperation> *operations;
@property(copy) NSString *aerospace;
@property NSInteger nextSessionID;
@property NSTimer *sweepTimer;
@property NSDate *idleSince;
@property(nonatomic) dispatch_queue_t socketQueue;
@property(nonatomic) dispatch_source_t listenSource;
@property int listenFD;
@end

@implementation YMAgent

#pragma mark Socket server

- (BOOL)listenWithProblem:(NSString **)problem {
    NSString *path = YMAgentSocketPath();
    [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES
                                             attributes:@{NSFilePosixPermissions: @0700} error:nil];
    struct sockaddr_un address = {.sun_family = AF_UNIX};
    if (strlen(path.fileSystemRepresentation) >= sizeof(address.sun_path)) { *problem = @"socket path too long"; return NO; }
    strlcpy(address.sun_path, path.fileSystemRepresentation, sizeof(address.sun_path));
    unlink(path.fileSystemRepresentation);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0 || bind(fd, (struct sockaddr *)&address, sizeof(address)) != 0
        || chmod(path.fileSystemRepresentation, 0600) != 0 || listen(fd, 16) != 0) {
        *problem = [NSString stringWithFormat:@"agent socket setup failed: %s", strerror(errno)];
        if (fd >= 0) close(fd);
        return NO;
    }
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
    fcntl(fd, F_SETFD, FD_CLOEXEC);
    self.listenFD = fd;
    self.socketQueue = dispatch_queue_create("dev.chekusu.yomado.agent.socket", DISPATCH_QUEUE_SERIAL);
    self.listenSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, self.socketQueue);
    __weak YMAgent *weakSelf = self;
    dispatch_source_set_event_handler(self.listenSource, ^{ [weakSelf acceptPending]; });
    dispatch_resume(self.listenSource);
    return YES;
}

// Socket queue.
- (void)acceptPending {
    for (;;) {
        int client = accept(self.listenFD, NULL, NULL);
        if (client < 0) return;
        fcntl(client, F_SETFL, fcntl(client, F_GETFL) | O_NONBLOCK);
        fcntl(client, F_SETFD, FD_CLOEXEC);
        int on = 1;
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
        YMSession *session = [[YMSession alloc] init];
        session.fd = client;
        dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)client, 0, self.socketQueue);
        session.readSource = source;
        __weak YMAgent *weakSelf = self;
        dispatch_source_set_event_handler(source, ^{ [weakSelf readFrom:session]; });
        dispatch_source_set_cancel_handler(source, ^{
            YMOnMain(^{ [weakSelf endSession:session]; });
        });
        YMOnMain(^{
            YMAgent *agent = weakSelf;
            session.sessionID = ++agent.nextSessionID;
            [agent.sessions addObject:session];
            agent.idleSince = nil;
        });
        dispatch_resume(source);
    }
}

// Socket queue: split complete lines and hand them to the main queue.
- (void)readFrom:(YMSession *)session {
    uint8_t chunk[16384];
    for (;;) {
        ssize_t n = read(session.fd, chunk, sizeof(chunk));
        if (n > 0) { [session.buffer appendBytes:chunk length:(NSUInteger)n]; continue; }
        if (n < 0 && (errno == EAGAIN || errno == EINTR)) break;
        dispatch_source_cancel(session.readSource); // EOF or error
        return;
    }
    if (session.buffer.length > 4 * 1024 * 1024) { dispatch_source_cancel(session.readSource); return; }
    for (;;) {
        const uint8_t *bytes = session.buffer.bytes;
        const uint8_t *newline = memchr(bytes, '\n', session.buffer.length);
        if (!newline) return;
        NSUInteger length = (NSUInteger)(newline - bytes);
        NSData *line = [session.buffer subdataWithRange:NSMakeRange(0, length)];
        [session.buffer replaceBytesInRange:NSMakeRange(0, length + 1) withBytes:NULL length:0];
        __weak YMAgent *weakSelf = self;
        YMOnMain(^{ [weakSelf enqueue:session line:line]; });
    }
}

- (void)endSession:(YMSession *)session {
    if (session.closed) return;
    session.closed = YES;
    close(session.fd);
    [self.sessions removeObject:session];
    if (!self.sessions.count) self.idleSince = NSDate.date;
}

- (void)send:(NSDictionary *)response to:(YMSession *)session {
    if (session.closed) return;
    NSMutableData *data = [[NSJSONSerialization dataWithJSONObject:response options:NSJSONWritingWithoutEscapingSlashes error:nil] mutableCopy];
    [data appendBytes:"\n" length:1];
    const uint8_t *bytes = data.bytes;
    size_t left = data.length;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
    while (left) {
        ssize_t n = write(session.fd, bytes, left);
        if (n > 0) { bytes += n; left -= (size_t)n; continue; }
        if (n < 0 && (errno == EAGAIN || errno == EINTR) && deadline.timeIntervalSinceNow > 0) { usleep(2000); continue; }
        dispatch_source_cancel(session.readSource); // client stopped reading
        return;
    }
}

#pragma mark Request queue (D3: one request at a time, arrival order)

- (void)enqueue:(YMSession *)session line:(NSData *)line {
    [self.pending addObject:@[session, line]];
    [self drain];
}

- (void)drain {
    if (self.executing) return;
    while (self.pending.count) {
        NSArray *next = self.pending.firstObject;
        [self.pending removeObjectAtIndex:0];
        YMSession *session = next[0];
        if (session.closed) continue;
        self.executing = YES;
        @autoreleasepool { [self execute:next[1] session:session]; }
        self.executing = NO;
    }
}

- (void)execute:(NSData *)line session:(YMSession *)session {
    id request = [NSJSONSerialization JSONObjectWithData:line options:0 error:nil];
    id requestID = [request isKindOfClass:NSDictionary.class] && YMIsNumber(request[@"id"]) ? request[@"id"] : NSNull.null;
    NSError *error = nil;
    NSDictionary *result = nil;
    NSString *op = [request isKindOfClass:NSDictionary.class] ? request[@"op"] : nil;
    YMOperation operation = [op isKindOfClass:NSString.class] ? self.operations[op] : nil;
    if (![request isKindOfClass:NSDictionary.class]) error = YMError(@"usage", @"request must be one JSON object per line");
    else if (!operation) error = YMError(@"usage", @"unknown op \"%@\"", op);
    else if (!session.opened && ![op isEqualToString:@"open"] && ![op isEqualToString:@"status"])
        error = YMError(@"not_open", @"send \"open\" first");
    else {
        self.current = session;
        self.currentStolenBy = nil;
        if (session.opened) [self sweep:session];
        NSMutableDictionary *args = [request mutableCopy];
        [args removeObjectsForKeys:@[@"id", @"op"]];
        result = operation(session, args, &error);
        if (result && self.currentStolenBy) {
            error = YMError(@"focus_stolen", @"%@ became the front application; the user's application was restored", self.currentStolenBy);
            result = nil;
        }
        self.current = nil;
    }
    NSMutableDictionary *response = [@{@"id": requestID, @"ok": result ? @YES : @NO, @"events": [session.events copy]} mutableCopy];
    [session.events removeAllObjects];
    if (result) response[@"result"] = result;
    else response[@"error"] = @{@"code": error.userInfo[@"code"] ?: @"usage", @"message": error.localizedDescription ?: @"failed"};
    [self send:response to:session];
}

#pragma mark Focus guard (D5)

- (NSString *)agentAppOwner:(NSRunningApplication *)app session:(YMSession **)owner {
    for (YMSession *session in self.sessions) {
        BOOL launching = session.launchingBundleID && [session.launchingBundleID isEqualToString:app.bundleIdentifier];
        if (launching || ([session.apps containsObject:@(app.processIdentifier)] && [session ownsPid:app.processIdentifier])) {
            *owner = session;
            return app.localizedName ?: app.bundleIdentifier ?: @"application";
        }
    }
    return nil;
}

- (void)applicationActivated:(NSNotification *)note {
    NSRunningApplication *app = note.userInfo[NSWorkspaceApplicationKey];
    if (!app || app.processIdentifier == getpid()) return;
    YMSession *owner = nil;
    NSString *name = [self agentAppOwner:app session:&owner];
    if (!name) { self.userFront = app; return; }
    NSRunningApplication *user = self.userFront;
    if (!user || user.terminated || user.processIdentifier == app.processIdentifier) return;
    [user activateWithOptions:0];
    if (owner == self.current) self.currentStolenBy = name;
    else [owner.events addObject:@{@"type": @"focus_restored", @"pid": @(app.processIdentifier), @"app": name,
                                  @"restoredPid": @(user.processIdentifier), @"restoredApp": user.localizedName ?: @""}];
}

#pragma mark Screens and placement (D6)

// Monitor id of the session's display, via AeroSpace's NSScreen index.
- (NSString *)aerospaceMonitorForDisplay:(CGDirectDisplayID)displayID {
    NSArray<NSScreen *> *screens = NSScreen.screens;
    for (NSString *line in YMLines(YMAeroSpace(self.aerospace, @[@"list-monitors", @"--format", @"%{monitor-id} %{monitor-appkit-nsscreen-screens-id}"]))) {
        NSArray *parts = [line componentsSeparatedByString:@" "];
        if (parts.count != 2) continue;
        NSInteger index = [parts[1] integerValue] - 1;
        if (index < 0 || index >= (NSInteger)screens.count) continue;
        if ([screens[(NSUInteger)index].deviceDescription[@"NSScreenNumber"] unsignedIntValue] == displayID) return parts[0];
    }
    return nil;
}

- (NSString *)workspaceForSession:(YMSession *)session {
    NSString *monitor = self.aerospace ? [self aerospaceMonitorForDisplay:session.displayID] : nil;
    if (!monitor) return nil;
    return YMLines(YMAeroSpace(self.aerospace, @[@"list-workspaces", @"--monitor", monitor, @"--visible"])).firstObject;
}

- (BOOL)moveWindow:(CGWindowID)wid pid:(pid_t)pid toDisplay:(CGDirectDisplayID)displayID workspace:(NSString *)workspace {
    if (workspace) {
        NSString *wid_s = [NSString stringWithFormat:@"%u", wid];
        return YMWaitUntil(3, ^BOOL {
            return YMAeroSpace(self.aerospace, @[@"move-node-to-workspace", @"--window-id", wid_s, workspace]) != nil;
        });
    }
    id element = YMAXWindowElement(pid, wid);
    if (!element) return NO;
    CGRect display = CGDisplayBounds(displayID);
    CGPoint origin = CGPointMake(display.origin.x + 40, display.origin.y + 60);
    AXValueRef value = AXValueCreate(kAXValueTypeCGPoint, &origin);
    AXError status = AXUIElementSetAttributeValue((__bridge AXUIElementRef)element, kAXPositionAttribute, value);
    CFRelease(value);
    return status == kAXErrorSuccess;
}

- (void)own:(CGWindowID)wid pid:(pid_t)pid session:(YMSession *)session {
    [session.owned addObject:@(wid)];
    [session.handedOff removeObject:@(wid)];
    [session.apps addObject:@(pid)];
    if (![self moveWindow:wid pid:pid toDisplay:session.displayID workspace:[self workspaceForSession:session]]) return;
    // AeroSpace moves the window asynchronously; report bounds only once it is on the screen.
    CGRect display = CGDisplayBounds(session.displayID);
    YMWaitUntil(3, ^BOOL { return CGRectIntersectsRect(YMWindowBounds(YMCGWindowInfo(wid)), display); });
}

// A window has at most one owner session.
- (YMSession *)ownerOf:(NSNumber *)wid {
    for (YMSession *session in self.sessions) if ([session.owned containsObject:wid]) return session;
    return nil;
}

// Adopts new windows of the session's applications and forgets closed ones.
- (void)sweep:(YMSession *)session {
    for (NSNumber *wid in [session.owned copy]) {
        if (YMCGWindowInfo(wid.unsignedIntValue)) continue;
        [session.owned removeObject:wid];
        [self dropRefsForWindow:wid session:session];
        [session.events addObject:@{@"type": @"window_closed", @"window": wid}];
    }
    for (NSNumber *pid in [session.apps copy]) {
        NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid.intValue];
        if (!app || app.terminated) { [session.apps removeObject:pid]; continue; }
        for (NSDictionary *window in YMAXWindows(pid.intValue)) {
            NSNumber *wid = window[@"id"];
            if ([session.owned containsObject:wid] || [session.handedOff containsObject:wid] || [self ownerOf:wid]) continue;
            [self own:wid.unsignedIntValue pid:pid.intValue session:session];
            NSDictionary *json = YMWindowJSON(wid.unsignedIntValue);
            if (json) [session.events addObject:@{@"type": @"window_adopted", @"window": json}];
        }
    }
}

- (void)sweepTick:(NSTimer *)timer {
    (void)timer;
    if (self.executing) return;
    self.executing = YES;
    for (YMSession *session in [self.sessions copy]) if (session.opened && !session.closed) [self sweep:session];
    self.executing = NO;
    [self drain];
    if (!self.sessions.count && self.idleSince && -self.idleSince.timeIntervalSinceNow > YMIdleExit) exit(0);
}

#pragma mark Validation

- (NSDictionary *)ownedWindow:(YMSession *)session args:(NSDictionary *)args error:(NSError **)error {
    double raw = 0;
    if (!YMArgNumber(args, @"window", YES, &raw, error)) return nil;
    CGWindowID wid = (CGWindowID)raw;
    if (![session.owned containsObject:@(wid)]) YMFAIL(@"not_owned", @"window %u is not owned by this session", wid);
    NSDictionary *info = YMCGWindowInfo(wid);
    if (!info) YMFAIL(@"not_owned", @"window %u no longer exists", wid);
    return info;
}

- (void)dropRefsForWindow:(NSNumber *)wid session:(YMSession *)session {
    for (NSString *ref in session.refsByWindow[wid] ?: @[]) [session.refs removeObjectForKey:ref];
    [session.refsByWindow removeObjectForKey:wid];
}

#pragma mark Input (D4)

- (void)postMouse:(NSEventType)type info:(NSDictionary *)info at:(CGPoint)local clicks:(NSInteger)clicks {
    CGWindowID wid = [info[(id)kCGWindowNumber] unsignedIntValue];
    pid_t pid = [info[(id)kCGWindowOwnerPID] intValue];
    CGRect bounds = YMWindowBounds(info);
    NSEvent *event = [NSEvent mouseEventWithType:type location:NSMakePoint(local.x, bounds.size.height - local.y)
                                   modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:(NSInteger)wid
                                         context:nil eventNumber:0 clickCount:clicks pressure:type == NSEventTypeMouseMoved ? 0 : 1];
    CGEventRef cg = event.CGEvent;
    if (!cg) return;
    CGEventSetLocation(cg, CGPointMake(bounds.origin.x + local.x, bounds.origin.y + local.y));
    CGEventSetIntegerValueField(cg, kCGMouseEventWindowUnderMousePointer, wid);
    CGEventSetIntegerValueField(cg, kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent, wid);
    YMSetWindowLocation(cg, local);
    CGEventPostToPid(pid, cg);
    usleep(15000);
}

- (void)makeMain:(NSDictionary *)info {
    id element = YMAXWindowElement([info[(id)kCGWindowOwnerPID] intValue], [info[(id)kCGWindowNumber] unsignedIntValue]);
    if (element) AXUIElementSetAttributeValue((__bridge AXUIElementRef)element, kAXMainAttribute, kCFBooleanTrue);
}

- (void)postKey:(CGKeyCode)code flags:(CGEventFlags)flags text:(NSString *)text pid:(pid_t)pid session:(YMSession *)session {
    for (int down = 1; down >= 0; down--) {
        CGEventRef event = CGEventCreateKeyboardEvent(session.keySource, code, down);
        if (text) {
            UniChar buffer[16];
            NSUInteger length = MIN(text.length, (NSUInteger)16);
            [text getCharacters:buffer range:NSMakeRange(0, length)];
            CGEventKeyboardSetUnicodeString(event, length, buffer);
        }
        CGEventSetFlags(event, flags);
        CGEventPostToPid(pid, event);
        CFRelease(event);
        usleep(8000);
    }
}

- (NSDictionary *)pointerJSON:(YMSession *)session {
    return @{@"window": @(session.pointerWindow), @"x": @(session.pointer.x), @"y": @(session.pointer.y)};
}

// Resolves optional x/y against the virtual pointer.
- (BOOL)target:(YMSession *)session info:(NSDictionary *)info args:(NSDictionary *)args point:(CGPoint *)point error:(NSError **)error {
    double x = NAN, y = NAN;
    if (!YMArgNumber(args, @"x", NO, &x, error) || !YMArgNumber(args, @"y", NO, &y, error)) return NO;
    CGWindowID wid = [info[(id)kCGWindowNumber] unsignedIntValue];
    if (isnan(x) != isnan(y)) { if (error) *error = YMError(@"usage", @"give both x and y, or neither"); return NO; }
    if (isnan(x)) {
        if (session.pointerWindow != wid) { if (error) *error = YMError(@"usage", @"the virtual pointer is not in window %u; give x and y", wid); return NO; }
        *point = session.pointer;
    } else *point = CGPointMake(x, y);
    return YES;
}

#pragma mark Capture

- (BOOL)checkCapturePermission:(NSError **)error {
    if (CGPreflightScreenCaptureAccess()) return YES;
    if (error) *error = YMError(@"permission", @"the helper has no Screen Recording grant; run the agent from a tool that has it");
    return NO;
}

- (CGImageRef)copyImageWithFilter:(SCContentFilter *)filter error:(NSError **)error CF_RETURNS_RETAINED {
    SCStreamConfiguration *config = [[SCStreamConfiguration alloc] init];
    config.width = (size_t)llround(filter.contentRect.size.width * filter.pointPixelScale);
    config.height = (size_t)llround(filter.contentRect.size.height * filter.pointPixelScale);
    config.showsCursor = NO;
    config.ignoreGlobalClipSingleWindow = YES;
    __block CGImageRef image = NULL;
    __block NSString *failure = nil;
    __block BOOL done = NO;
    [SCScreenshotManager captureImageWithFilter:filter configuration:config completionHandler:^(CGImageRef captured, NSError *err) {
        // `captured` is valid only inside this handler; retain it before hopping threads.
        CGImageRef retained = captured ? CGImageRetain(captured) : NULL;
        NSString *reason = err.localizedDescription ?: @"no image";
        YMOnMain(^{
            image = retained;
            if (!retained) failure = reason;
            done = YES;
        });
    }];
    if (!YMWaitUntil(YMWaitLimit, ^BOOL { return done; })) { if (error) *error = YMError(@"timeout", @"capture took longer than 15 s"); return NULL; }
    if (!image && error) *error = YMError(@"capture_failed", @"%@", failure);
    return image;
}

- (SCShareableContent *)shareableContent:(NSError **)error {
    __block SCShareableContent *content = nil;
    __block NSString *failure = nil;
    __block BOOL done = NO;
    [SCShareableContent getShareableContentExcludingDesktopWindows:NO onScreenWindowsOnly:NO completionHandler:^(SCShareableContent *c, NSError *err) {
        YMOnMain(^{ content = c; failure = err.localizedDescription; done = YES; });
    }];
    if (!YMWaitUntil(YMWaitLimit, ^BOOL { return done; }) || !content) {
        if (error) *error = YMError(@"capture_failed", @"window list unavailable: %@", failure ?: @"timeout");
        return nil;
    }
    return content;
}

// Draws the virtual pointer (an arrow, tip at `tip` in image pixels) and writes a PNG.
- (BOOL)writeImage:(CGImageRef)image pointer:(CGPoint)tip draw:(BOOL)draw scale:(CGFloat)scale to:(NSString *)path {
    size_t width = CGImageGetWidth(image), height = CGImageGetHeight(image);
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(NULL, width, height, 8, 0, space, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(space);
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
    if (draw) {
        CGFloat s = 1.4 * scale, x = tip.x, y = (CGFloat)height - tip.y;
        CGPoint arrow[] = {{x, y}, {x, y - 16 * s}, {x + 4 * s, y - 12 * s}, {x + 7 * s, y - 18 * s},
                           {x + 9 * s, y - 17 * s}, {x + 6 * s, y - 11 * s}, {x + 11 * s, y - 11 * s}};
        CGContextAddLines(context, arrow, 7);
        CGContextClosePath(context);
        CGContextSetRGBFillColor(context, 1.0, 0.25, 0.45, 1.0);
        CGContextSetRGBStrokeColor(context, 1, 1, 1, 1);
        CGContextSetLineWidth(context, 1.5 * scale);
        CGContextDrawPath(context, kCGPathFillStroke);
    }
    CGImageRef output = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    CGImageDestinationRef destination = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path],
                                                                        (__bridge CFStringRef)UTTypePNG.identifier, 1, NULL);
    BOOL ok = destination != NULL;
    if (destination) {
        CGImageDestinationAddImage(destination, output, NULL);
        ok = CGImageDestinationFinalize(destination);
        CFRelease(destination);
    }
    CGImageRelease(output);
    return ok;
}

#pragma mark Operations

- (NSDictionary<NSString *, YMOperation> *)makeOperations {
    __weak YMAgent *weakSelf = self;
    NSMutableDictionary<NSString *, YMOperation> *ops = [NSMutableDictionary dictionary];

    ops[@"status"] = ^NSDictionary *(YMSession *session, NSDictionary *args, NSError **error) {
        (void)session; (void)args; (void)error;
        YMAgent *agent = weakSelf;
        return @{@"version": YMAgentVersion, @"pid": @(getpid()), @"aerospace": @(agent.aerospace != nil),
                 @"grants": @{@"accessibility": @(AXIsProcessTrusted()), @"screenRecording": @(CGPreflightScreenCaptureAccess())},
                 @"sessions": @(agent.sessions.count)};
    };

    ops[@"open"] = ^NSDictionary *(YMSession *session, NSDictionary *args, NSError **error) {
        YMAgent *agent = weakSelf;
        if (session.opened) YMFAIL(@"usage", @"this session is already open on %@", session.screenTitle);
        if (!AXIsProcessTrusted()) YMFAIL(@"permission", @"the helper has no Accessibility grant; run the agent from a tool that has it");
        NSString *match = @"Agent";
        if (!YMArgString(args, @"screen", NO, &match, error)) return nil;
        NSString *problem = nil;
        NSDictionary *list = YMControlSend([YMControlRequest requestWithJSONObject:@{@"command": @"list"} error:nil], &problem);
        if (!list) YMFAIL(@"yomado_unreachable", @"%@", problem);
        NSDictionary *found = nil;
        for (NSDictionary *screen in list[@"screens"])
            if ([[screen[@"id"] stringValue] isEqualToString:match] || [screen[@"name"] isEqualToString:match] || [screen[@"title"] isEqualToString:match]) found = screen;
        NSDictionary *request = !found ? @{@"command": @"create", @"name": match}
                              : ![found[@"running"] boolValue] ? @{@"command": @"start", @"screen": [found[@"id"] stringValue]} : nil;
        if (request) {
            NSError *invalid = nil;
            YMControlRequest *parsed = [YMControlRequest requestWithJSONObject:request error:&invalid];
            if (!parsed) YMFAIL(@"usage", @"%@", invalid.localizedDescription);
            NSDictionary *reply = YMControlSend(parsed, &problem);
            if (!reply) YMFAIL(@"yomado_unreachable", @"%@", problem);
            if (![reply[@"ok"] boolValue]) YMFAIL(@"no_screen", @"%@", reply[@"error"]);
            found = reply[@"screen"];
        }
        session.screenID = [found[@"id"] integerValue];
        session.screenTitle = found[@"title"];
        session.displayID = [found[@"displayID"] unsignedIntValue];
        session.opened = YES;
        // AeroSpace learns about a new monitor asynchronously.
        __block NSString *workspace = nil;
        if (agent.aerospace) YMWaitUntil(5, ^BOOL { workspace = [agent workspaceForSession:session]; return workspace != nil; });
        return @{@"session": @(session.sessionID),
                 @"screen": @{@"id": @(session.screenID), @"title": session.screenTitle, @"displayID": @(session.displayID),
                              @"bounds": YMRect(CGDisplayBounds(session.displayID)), @"workspace": workspace ?: NSNull.null}};
    };

    ops[@"windows"] = ^NSDictionary *(YMSession *session, NSDictionary *args, NSError **error) {
        (void)args; (void)error;
        NSMutableArray *windows = [NSMutableArray array];
        for (NSNumber *wid in session.owned) { NSDictionary *json = YMWindowJSON(wid.unsignedIntValue); if (json) [windows addObject:json]; }
        return @{@"windows": windows};
    };

    ops[@"launch"] = ^NSDictionary *(YMSession *session, NSDictionary *args, NSError **error) {
        YMAgent *agent = weakSelf;
        NSString *name = nil;
        if (!YMArgString(args, @"app", YES, &name, error)) return nil;
        NSURL *url = nil;
        if ([name hasSuffix:@".app"] && [NSFileManager.defaultManager fileExistsAtPath:name]) url = [NSURL fileURLWithPath:name];
        if (!url) url = [NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:name];
        if (!url) for (NSString *dir in @[@"/Applications", @"/System/Applications", @"/System/Applications/Utilities",
                                          [NSHomeDirectory() stringByAppendingPathComponent:@"Applications"]]) {
            NSString *candidate = [[dir stringByAppendingPathComponent:name] stringByAppendingPathExtension:@"app"];
            if ([NSFileManager.defaultManager fileExistsAtPath:candidate]) { url = [NSURL fileURLWithPath:candidate]; break; }
        }
        if (!url) YMFAIL(@"launch_failed", @"no application named \"%@\"", name);
        NSString *bundleID = [NSBundle bundleWithURL:url].bundleIdentifier;
        if (bundleID && [NSRunningApplication runningApplicationsWithBundleIdentifier:bundleID].count)
            YMFAIL(@"app_running", @"%@ is already running; it may be the user's copy", name);
        session.launchingBundleID = bundleID;
        NSWorkspaceOpenConfiguration *config = [NSWorkspaceOpenConfiguration configuration];
        config.activates = NO;
        config.addsToRecentItems = NO;
        __block NSRunningApplication *launched = nil;
        __block NSString *failure = nil;
        __block BOOL done = NO;
        [NSWorkspace.sharedWorkspace openApplicationAtURL:url configuration:config completionHandler:^(NSRunningApplication *app, NSError *err) {
            YMOnMain(^{ launched = app; failure = err.localizedDescription; done = YES; });
        }];
        BOOL started = YMWaitUntil(YMWaitLimit, ^BOOL { return done; });
        if (!started || !launched) { session.launchingBundleID = nil; YMFAIL(started ? @"launch_failed" : @"timeout", @"%@", failure ?: @"launch did not finish"); }
        pid_t pid = launched.processIdentifier;
        [session.apps addObject:@(pid)];
        __block NSArray *windows = nil;
        BOOL appeared = YMWaitUntil(YMWaitLimit, ^BOOL { windows = YMAXWindows(pid); return windows.count > 0; });
        session.launchingBundleID = nil;
        if (!appeared) YMFAIL(@"timeout", @"%@ opened no window within 15 s", name);
        NSMutableArray *result = [NSMutableArray array];
        for (NSDictionary *window in windows) {
            [agent own:[window[@"id"] unsignedIntValue] pid:pid session:session];
            NSDictionary *json = YMWindowJSON([window[@"id"] unsignedIntValue]);
            if (json) [result addObject:json];
        }
        YMPump(YMInputSettle);
        return @{@"windows": result};
    };

    ops[@"adopt"] = ^NSDictionary *(YMSession *session, NSDictionary *args, NSError **error) {
        double raw = 0;
        if (!YMArgNumber(args, @"window", YES, &raw, error)) return nil;
        CGWindowID wid = (CGWindowID)raw;
        NSDictionary *info = YMCGWindowInfo(wid);
        if (!info) YMFAIL(@"no_window", @"window %u does not exist", wid);
        YMSession *owner = [weakSelf ownerOf:@(wid)];
        if (owner && owner != session) YMFAIL(@"not_owned", @"window %u is owned by session %ld", wid, (long)owner.sessionID);
        [weakSelf own:wid pid:[info[(id)kCGWindowOwnerPID] intValue] session:session];
        return @{@"window": YMWindowJSON(wid) ?: @{}};
    };

    ops[@"capture"] = ^NSDictionary *(YMSession *session, NSDictionary *args, NSError **error) {
        YMAgent *agent = weakSelf;
        if (![agent checkCapturePermission:error]) return nil;
        NSString *path = nil;
        if (!YMArgString(args, @"path", NO, &path, error)) return nil;
        id drawArg = args[@"pointer"];
        BOOL draw = drawArg ? [drawArg boolValue] : YES;
        if (!path) {
            NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"yomado-agent"];
            [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
            path = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"s%ld-%ld.png", (long)session.sessionID, (long)++session.nextCapture]];
        }
        SCShareableContent *content = [agent shareableContent:error];
        if (!content) return nil;
        SCContentFilter *filter = nil;
        CGRect bounds;
        if (args[@"window"]) {
            NSDictionary *info = [agent ownedWindow:session args:args error:error];
            if (!info) return nil;
            CGWindowID wid = [info[(id)kCGWindowNumber] unsignedIntValue];
            for (SCWindow *window in content.windows) if (window.windowID == wid) filter = [[SCContentFilter alloc] initWithDesktopIndependentWindow:window];
            bounds = YMWindowBounds(info);
        } else {
            for (SCDisplay *display in content.displays)
                if (display.displayID == session.displayID) filter = [[SCContentFilter alloc] initWithDisplay:display excludingWindows:@[]];
            bounds = CGDisplayBounds(session.displayID);
        }
        if (!filter) YMFAIL(@"capture_failed", @"the window or screen is not capturable");
        CGImageRef image = [agent copyImageWithFilter:filter error:error];
        if (!image) return nil;
        CGFloat scale = CGImageGetWidth(image) / MAX(bounds.size.width, 1);
        NSDictionary *pointerInfo = session.pointerWindow ? YMCGWindowInfo(session.pointerWindow) : nil;
        CGRect pointerWindow = YMWindowBounds(pointerInfo);
        CGPoint global = CGPointMake(pointerWindow.origin.x + session.pointer.x, pointerWindow.origin.y + session.pointer.y);
        BOOL inside = pointerInfo && CGRectContainsPoint(bounds, global);
        CGPoint tip = CGPointMake((global.x - bounds.origin.x) * scale, (global.y - bounds.origin.y) * scale);
        BOOL written = [agent writeImage:image pointer:tip draw:draw && inside scale:scale to:path];
        NSDictionary *pixels = @{@"width": @(CGImageGetWidth(image)), @"height": @(CGImageGetHeight(image))};
        CGImageRelease(image);
        if (!written) YMFAIL(@"capture_failed", @"could not write %@", path);
        return @{@"path": path, @"pixels": pixels, @"scale": @(scale), @"bounds": YMRect(bounds)};
    };

    ops[@"ax"] = ^NSDictionary *(YMSession *session, NSDictionary *args, NSError **error) {
        YMAgent *agent = weakSelf;
        NSDictionary *info = [agent ownedWindow:session args:args error:error];
        if (!info) return nil;
        CGWindowID wid = [info[(id)kCGWindowNumber] unsignedIntValue];
        id root = YMAXWindowElement([info[(id)kCGWindowOwnerPID] intValue], wid);
        if (!root) YMFAIL(@"ax_failed", @"window %u has no accessibility element", wid);
        CGRect bounds = YMWindowBounds(info);
        [agent dropRefsForWindow:@(wid) session:session];
        NSMutableArray *elements = [NSMutableArray array];
        NSMutableArray *refs = [NSMutableArray array];
        NSMutableArray *queue = [NSMutableArray arrayWithObject:root];
        NSUInteger visited = 0;
        while (queue.count && visited < 3000) {
            id element = queue.firstObject;
            [queue removeObjectAtIndex:0];
            visited++;
            AXUIElementRef el = (__bridge AXUIElementRef)element;
            CFTypeRef children = NULL;
            if (AXUIElementCopyAttributeValue(el, kAXChildrenAttribute, &children) == kAXErrorSuccess) {
                [queue addObjectsFromArray:(__bridge NSArray *)children];
                CFRelease(children);
            }
            CFArrayRef actionNames = NULL;
            AXUIElementCopyActionNames(el, &actionNames);
            NSArray *actions = CFBridgingRelease(actionNames) ?: @[];
            Boolean settable = false;
            AXUIElementIsAttributeSettable(el, kAXValueAttribute, &settable);
            if (!actions.count && !settable) continue;
            NSMutableDictionary *entry = [NSMutableDictionary dictionary];
            for (NSArray *pair in @[@[@"role", (id)kAXRoleAttribute], @[@"title", (id)kAXTitleAttribute],
                                    @[@"description", (id)kAXDescriptionAttribute], @[@"value", (id)kAXValueAttribute]]) {
                CFTypeRef value = NULL;
                id text = @"";
                if (AXUIElementCopyAttributeValue(el, (__bridge CFStringRef)pair[1], &value) == kAXErrorSuccess && value) {
                    id object = CFBridgingRelease(value);
                    if ([object isKindOfClass:NSString.class]) text = object;
                    else if ([object isKindOfClass:NSNumber.class]) text = [object stringValue];
                }
                entry[pair[0]] = text;
            }
            CGPoint position = CGPointZero; CGSize size = CGSizeZero;
            CFTypeRef value = NULL;
            if (AXUIElementCopyAttributeValue(el, kAXPositionAttribute, &value) == kAXErrorSuccess) { AXValueGetValue(value, kAXValueTypeCGPoint, &position); CFRelease(value); }
            if (AXUIElementCopyAttributeValue(el, kAXSizeAttribute, &value) == kAXErrorSuccess) { AXValueGetValue(value, kAXValueTypeCGSize, &size); CFRelease(value); }
            NSString *ref = [NSString stringWithFormat:@"e%ld", (long)++session.nextRef];
            session.refs[ref] = element;
            [refs addObject:ref];
            entry[@"ref"] = ref;
            entry[@"actions"] = actions;
            entry[@"settable"] = @(settable);
            entry[@"x"] = @(position.x - bounds.origin.x); entry[@"y"] = @(position.y - bounds.origin.y);
            entry[@"width"] = @(size.width); entry[@"height"] = @(size.height);
            [elements addObject:entry];
        }
        session.refsByWindow[@(wid)] = refs;
        return @{@"elements": elements};
    };

    YMOperation (^axRef)(BOOL) = ^YMOperation(BOOL setValue) {
        return ^NSDictionary *(YMSession *session, NSDictionary *args, NSError **error) {
            NSString *ref = nil, *action = (__bridge NSString *)kAXPressAction, *value = nil;
            if (!YMArgString(args, @"ref", YES, &ref, error)) return nil;
            if (setValue ? !YMArgString(args, @"value", YES, &value, error) : !YMArgString(args, @"action", NO, &action, error)) return nil;
            id element = session.refs[ref];
            if (!element) YMFAIL(@"stale_ref", @"unknown element reference %@; call ax again", ref);
            AXUIElementRef el = (__bridge AXUIElementRef)element;
            AXError status = setValue ? AXUIElementSetAttributeValue(el, kAXValueAttribute, (__bridge CFStringRef)value)
                                      : AXUIElementPerformAction(el, (__bridge CFStringRef)action);
            if (status == kAXErrorInvalidUIElement) YMFAIL(@"stale_ref", @"element %@ no longer exists", ref);
            if (status != kAXErrorSuccess) YMFAIL(@"ax_failed", @"accessibility call failed with AXError %d", (int)status);
            YMPump(YMInputSettle);
            return @{};
        };
    };
    ops[@"press"] = axRef(NO);
    ops[@"set"] = axRef(YES);

    ops[@"move"] = ^NSDictionary *(YMSession *session, NSDictionary *args, NSError **error) {
        YMAgent *agent = weakSelf;
        NSDictionary *info = [agent ownedWindow:session args:args error:error];
        CGPoint point;
        if (!info || ![agent target:session info:info args:args point:&point error:error]) return nil;
        if (!args[@"x"]) YMFAIL(@"usage", @"move needs x and y");
        [agent postMouse:NSEventTypeMouseMoved info:info at:point clicks:0];
        session.pointerWindow = [info[(id)kCGWindowNumber] unsignedIntValue];
        session.pointer = point;
        return @{@"pointer": [agent pointerJSON:session]};
    };

    ops[@"click"] = ^NSDictionary *(YMSession *session, NSDictionary *args, NSError **error) {
        YMAgent *agent = weakSelf;
        NSDictionary *info = [agent ownedWindow:session args:args error:error];
        CGPoint point;
        if (!info || ![agent target:session info:info args:args point:&point error:error]) return nil;
        NSString *button = @"left";
        double count = 1;
        if (!YMArgString(args, @"button", NO, &button, error) || !YMArgNumber(args, @"count", NO, &count, error)) return nil;
        if (![button isEqualToString:@"left"] && ![button isEqualToString:@"right"]) YMFAIL(@"usage", @"button must be left or right");
        if (count < 1 || count > 3) YMFAIL(@"usage", @"count must be 1, 2 or 3");
        BOOL right = [button isEqualToString:@"right"];
        [agent postMouse:NSEventTypeMouseMoved info:info at:point clicks:0];
        for (NSInteger n = 1; n <= (NSInteger)count; n++) {
            [agent postMouse:right ? NSEventTypeRightMouseDown : NSEventTypeLeftMouseDown info:info at:point clicks:n];
            [agent postMouse:right ? NSEventTypeRightMouseUp : NSEventTypeLeftMouseUp info:info at:point clicks:n];
        }
        session.pointerWindow = [info[(id)kCGWindowNumber] unsignedIntValue];
        session.pointer = point;
        YMPump(YMInputSettle);
        return @{@"pointer": [agent pointerJSON:session]};
    };

    ops[@"drag"] = ^NSDictionary *(YMSession *session, NSDictionary *args, NSError **error) {
        YMAgent *agent = weakSelf;
        NSDictionary *info = [agent ownedWindow:session args:args error:error];
        if (!info) return nil;
        BOOL hasFrom = NO, hasTo = NO;
        CGPoint from = session.pointer, to = CGPointZero;
        double steps = 12;
        if (!YMArgPoint(args, @"to", YES, &hasTo, &to, error) || !YMArgPoint(args, @"from", NO, &hasFrom, &from, error)
            || !YMArgNumber(args, @"steps", NO, &steps, error)) return nil;
        CGWindowID wid = [info[(id)kCGWindowNumber] unsignedIntValue];
        if (!hasFrom && session.pointerWindow != wid) YMFAIL(@"usage", @"the virtual pointer is not in window %u; give from", wid);
        NSInteger count = MAX(1, MIN(200, (NSInteger)steps));
        [agent postMouse:NSEventTypeMouseMoved info:info at:from clicks:0];
        [agent postMouse:NSEventTypeLeftMouseDown info:info at:from clicks:1];
        for (NSInteger i = 1; i <= count; i++) {
            CGFloat t = (CGFloat)i / count;
            [agent postMouse:NSEventTypeLeftMouseDragged info:info at:CGPointMake(from.x + (to.x - from.x) * t, from.y + (to.y - from.y) * t) clicks:1];
        }
        [agent postMouse:NSEventTypeLeftMouseUp info:info at:to clicks:1];
        session.pointerWindow = wid;
        session.pointer = to;
        YMPump(YMInputSettle);
        return @{@"pointer": [agent pointerJSON:session]};
    };

    ops[@"scroll"] = ^NSDictionary *(YMSession *session, NSDictionary *args, NSError **error) {
        YMAgent *agent = weakSelf;
        NSDictionary *info = [agent ownedWindow:session args:args error:error];
        CGPoint point;
        double dy = 0, dx = 0;
        if (!info || ![agent target:session info:info args:args point:&point error:error]
            || !YMArgNumber(args, @"dy", YES, &dy, error) || !YMArgNumber(args, @"dx", NO, &dx, error)) return nil;
        CGWindowID wid = [info[(id)kCGWindowNumber] unsignedIntValue];
        CGRect bounds = YMWindowBounds(info);
        [agent postMouse:NSEventTypeMouseMoved info:info at:point clicks:0];
        CGEventRef event = CGEventCreateScrollWheelEvent(NULL, kCGScrollEventUnitLine, 2, (int32_t)-dy, (int32_t)-dx);
        CGEventSetLocation(event, CGPointMake(bounds.origin.x + point.x, bounds.origin.y + point.y));
        CGEventSetIntegerValueField(event, kCGMouseEventWindowUnderMousePointer, wid);
        CGEventSetIntegerValueField(event, kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent, wid);
        YMSetWindowLocation(event, point);
        CGEventPostToPid([info[(id)kCGWindowOwnerPID] intValue], event);
        CFRelease(event);
        session.pointerWindow = wid;
        session.pointer = point;
        YMPump(YMInputSettle);
        return @{@"pointer": [agent pointerJSON:session]};
    };

    ops[@"type"] = ^NSDictionary *(YMSession *session, NSDictionary *args, NSError **error) {
        YMAgent *agent = weakSelf;
        NSDictionary *info = [agent ownedWindow:session args:args error:error];
        NSString *text = nil;
        if (!info || !YMArgString(args, @"text", YES, &text, error)) return nil;
        [agent makeMain:info];
        pid_t pid = [info[(id)kCGWindowOwnerPID] intValue];
        __block NSUInteger typed = 0;
        [text enumerateSubstringsInRange:NSMakeRange(0, text.length) options:NSStringEnumerationByComposedCharacterSequences
                              usingBlock:^(NSString *character, NSRange r1, NSRange r2, BOOL *stop) {
            (void)r1; (void)r2; (void)stop;
            [agent postKey:0 flags:0 text:character pid:pid session:session];
            typed++;
        }];
        YMPump(YMInputSettle);
        return @{@"typed": @(typed)};
    };

    ops[@"key"] = ^NSDictionary *(YMSession *session, NSDictionary *args, NSError **error) {
        YMAgent *agent = weakSelf;
        NSDictionary *info = [agent ownedWindow:session args:args error:error];
        if (!info) return nil;
        NSArray *keys = args[@"keys"];
        if (![keys isKindOfClass:NSArray.class] || !keys.count) YMFAIL(@"usage", @"keys must be a non-empty array of strings");
        static NSDictionary<NSString *, NSNumber *> *codes;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            codes = @{@"a": @0, @"s": @1, @"d": @2, @"f": @3, @"h": @4, @"g": @5, @"z": @6, @"x": @7, @"c": @8, @"v": @9, @"b": @11,
                      @"q": @12, @"w": @13, @"e": @14, @"r": @15, @"y": @16, @"t": @17, @"1": @18, @"2": @19, @"3": @20, @"4": @21,
                      @"6": @22, @"5": @23, @"=": @24, @"9": @25, @"7": @26, @"-": @27, @"8": @28, @"0": @29, @"]": @30, @"o": @31,
                      @"u": @32, @"[": @33, @"i": @34, @"p": @35, @"l": @37, @"j": @38, @"'": @39, @"k": @40, @";": @41, @"\\": @42,
                      @",": @43, @"/": @44, @"n": @45, @"m": @46, @".": @47, @"`": @50, @"return": @36, @"enter": @36, @"tab": @48,
                      @"space": @49, @"delete": @51, @"escape": @53, @"forwarddelete": @117, @"home": @115, @"end": @119,
                      @"pageup": @116, @"pagedown": @121, @"left": @123, @"right": @124, @"down": @125, @"up": @126,
                      @"f1": @122, @"f2": @120, @"f3": @99, @"f4": @118, @"f5": @96, @"f6": @97, @"f7": @98, @"f8": @100,
                      @"f9": @101, @"f10": @109, @"f11": @103, @"f12": @111};
        });
        NSDictionary<NSString *, NSNumber *> *modifiers = @{@"cmd": @(kCGEventFlagMaskCommand), @"shift": @(kCGEventFlagMaskShift),
            @"alt": @(kCGEventFlagMaskAlternate), @"option": @(kCGEventFlagMaskAlternate),
            @"ctrl": @(kCGEventFlagMaskControl), @"control": @(kCGEventFlagMaskControl)};
        NSMutableArray *parsed = [NSMutableArray array];
        for (id combo in keys) {
            if (![combo isKindOfClass:NSString.class]) YMFAIL(@"usage", @"keys must be strings");
            NSArray *parts = [[combo lowercaseString] componentsSeparatedByString:@"+"];
            NSNumber *code = codes[parts.lastObject];
            if (!code) YMFAIL(@"usage", @"unknown key \"%@\"", parts.lastObject);
            CGEventFlags flags = 0;
            for (NSString *part in [parts subarrayWithRange:NSMakeRange(0, parts.count - 1)]) {
                NSNumber *flag = modifiers[part];
                if (!flag) YMFAIL(@"usage", @"unknown modifier \"%@\"", part);
                flags |= flag.unsignedLongLongValue;
            }
            [parsed addObject:@[code, @(flags)]];
        }
        [agent makeMain:info];
        pid_t pid = [info[(id)kCGWindowOwnerPID] intValue];
        for (NSArray *key in parsed)
            [agent postKey:(CGKeyCode)[key[0] unsignedShortValue] flags:[key[1] unsignedLongLongValue] text:nil pid:pid session:session];
        YMPump(YMInputSettle);
        return @{};
    };

    ops[@"handoff"] = ^NSDictionary *(YMSession *session, NSDictionary *args, NSError **error) {
        YMAgent *agent = weakSelf;
        NSArray *ids = args[@"windows"];
        if (![ids isKindOfClass:NSArray.class] || !ids.count) YMFAIL(@"usage", @"windows must be a non-empty array of window ids");
        NSMutableArray *infos = [NSMutableArray array];
        for (id wid in ids) {
            NSDictionary *info = [agent ownedWindow:session args:@{@"window": wid} error:error];
            if (!info) return nil;
            [infos addObject:info];
        }
        NSString *problem = nil;
        NSDictionary *list = YMControlSend([YMControlRequest requestWithJSONObject:@{@"command": @"list"} error:nil], &problem);
        NSMutableSet *virtualIDs = [NSMutableSet set];
        for (NSDictionary *screen in list[@"screens"]) if (screen[@"displayID"]) [virtualIDs addObject:screen[@"displayID"]];
        NSDictionary *target = nil;
        NSString *workspace = nil;
        CGDirectDisplayID display = CGMainDisplayID();
        if (agent.aerospace) {
            NSArray<NSScreen *> *screens = NSScreen.screens;
            for (NSString *line in YMLines(YMAeroSpace(agent.aerospace, @[@"list-monitors", @"--format", @"%{monitor-id} %{monitor-appkit-nsscreen-screens-id}"]))) {
                NSArray *parts = [line componentsSeparatedByString:@" "];
                NSInteger index = parts.count == 2 ? [parts[1] integerValue] - 1 : -1;
                if (index < 0 || index >= (NSInteger)screens.count) continue;
                if ([virtualIDs containsObject:screens[(NSUInteger)index].deviceDescription[@"NSScreenNumber"]]) continue;
                NSArray *empty = YMLines(YMAeroSpace(agent.aerospace, @[@"list-workspaces", @"--monitor", parts[0], @"--empty", @"--visible", @"no"]));
                for (NSString *name in empty) if (name.length == 1 && [name characterAtIndex:0] >= '1' && [name characterAtIndex:0] <= '9') { workspace = name; break; }
                workspace = workspace ?: empty.firstObject;
                if (workspace) break;
            }
            if (!workspace) YMFAIL(@"no_screen", @"no empty hidden AeroSpace workspace on a physical monitor");
            target = @{@"workspace": workspace};
        } else {
            if ([virtualIDs containsObject:@(display)]) YMFAIL(@"no_screen", @"the main display is a virtual screen");
            target = @{@"display": @(display)};
        }
        NSMutableArray *moved = [NSMutableArray array];
        for (NSDictionary *info in infos) {
            CGWindowID wid = [info[(id)kCGWindowNumber] unsignedIntValue];
            [session.owned removeObject:@(wid)];
            [session.handedOff addObject:@(wid)];
            [agent dropRefsForWindow:@(wid) session:session];
            [agent moveWindow:wid pid:[info[(id)kCGWindowOwnerPID] intValue] toDisplay:display workspace:workspace];
            CGRect agentDisplay = CGDisplayBounds(session.displayID);
            YMWaitUntil(3, ^BOOL { return !CGRectIntersectsRect(YMWindowBounds(YMCGWindowInfo(wid)), agentDisplay); });
            NSDictionary *json = YMWindowJSON(wid);
            if (json) [moved addObject:json];
        }
        if (session.pointerWindow && ![session.owned containsObject:@(session.pointerWindow)]) session.pointerWindow = 0;
        return @{@"target": target, @"windows": moved};
    };

    ops[@"quit"] = ^NSDictionary *(YMSession *session, NSDictionary *args, NSError **error) {
        id app = args[@"app"];
        NSRunningApplication *running = nil;
        if (YMIsNumber(app)) running = [NSRunningApplication runningApplicationWithProcessIdentifier:[app intValue]];
        else if ([app isKindOfClass:NSString.class])
            for (NSRunningApplication *candidate in [NSRunningApplication runningApplicationsWithBundleIdentifier:app])
                if ([session.apps containsObject:@(candidate.processIdentifier)]) running = candidate;
        if (!app) YMFAIL(@"usage", @"missing argument \"app\"");
        if (!running || ![session.apps containsObject:@(running.processIdentifier)] || ![session ownsPid:running.processIdentifier])
            YMFAIL(@"not_owned", @"%@ is not an application of this session", app);
        [running terminate];
        if (!YMWaitUntil(YMWaitLimit, ^BOOL { return running.terminated; })) YMFAIL(@"timeout", @"%@ did not quit within 15 s", running.localizedName);
        [weakSelf sweep:session];
        return @{};
    };

    return ops;
}

- (instancetype)init {
    if ((self = [super init])) {
        _sessions = [NSMutableArray array];
        _pending = [NSMutableArray array];
        _aerospace = YMAeroSpacePath();
        _operations = [self makeOperations];
        NSRunningApplication *front = NSWorkspace.sharedWorkspace.frontmostApplication;
        if (front.processIdentifier != getpid()) _userFront = front;
        _idleSince = NSDate.date;
    }
    return self;
}
@end

int main(int argc, const char *argv[]) {
    (void)argc; (void)argv;
    @autoreleasepool {
        signal(SIGPIPE, SIG_IGN);
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        if (!YMLoadPrivateSymbols()) { fprintf(stderr, "YomadoAgent: required private symbols are missing on this macOS\n"); return 1; }
        [NSFileManager.defaultManager createDirectoryAtPath:YMAgentSupportDirectory() withIntermediateDirectories:YES
                                                 attributes:@{NSFilePosixPermissions: @0700} error:nil];
        // One helper per user: the lock is held for the life of the process.
        int lock = open(YMAgentLockPath().fileSystemRepresentation, O_CREAT | O_RDWR | O_CLOEXEC, 0600);
        if (lock < 0 || flock(lock, LOCK_EX | LOCK_NB) != 0) { fprintf(stderr, "YomadoAgent: another helper is running\n"); return 0; }
        YMAgent *agent = [[YMAgent alloc] init];
        NSString *problem = nil;
        if (![agent listenWithProblem:&problem]) { fprintf(stderr, "YomadoAgent: %s\n", problem.UTF8String); return 1; }
        [NSWorkspace.sharedWorkspace.notificationCenter addObserver:agent selector:@selector(applicationActivated:)
                                                               name:NSWorkspaceDidActivateApplicationNotification object:nil];
        agent.sweepTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:agent selector:@selector(sweepTick:) userInfo:nil repeats:YES];
        fprintf(stderr, "YomadoAgent %s listening on %s (accessibility=%d screenRecording=%d aerospace=%s)\n", YMAgentVersion.UTF8String,
                YMAgentSocketPath().fileSystemRepresentation, AXIsProcessTrusted(), CGPreflightScreenCaptureAccess(),
                agent.aerospace.UTF8String ?: "none");
        [NSApp run];
    }
    return 0;
}
