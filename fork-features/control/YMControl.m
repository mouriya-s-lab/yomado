#import "YMControl.h"
#import <AppKit/AppKit.h>
#import <mach-o/dyld.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <sys/un.h>
#import <limits.h>
#import <unistd.h>

static NSString *const YMControlErrorDomain = @"dev.chekusu.yomado.control";
static NSString *const YMControlBundleID = @"dev.chekusu.yomado";
static const size_t YMControlMaxRequest = 64 * 1024;

static NSError *YMControlError(NSString *text) {
    return [NSError errorWithDomain:YMControlErrorDomain code:1 userInfo:@{NSLocalizedDescriptionKey: text}];
}

NSDictionary *YMControlSuccess(NSDictionary *payload) {
    NSMutableDictionary *reply = [payload mutableCopy];
    reply[@"ok"] = @YES;
    return reply;
}

NSDictionary *YMControlFailure(NSString *message) {
    return @{@"ok": @NO, @"error": message};
}

NSString *YMControlNameProblem(NSString *name) {
    if (!name.length || name.length > 60) return @"name must be 1–60 characters";
    if ([name rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound)
        return @"name must not contain line breaks or control characters";
    return nil;
}

#pragma mark - Request

@implementation YMControlRequest
- (instancetype)initWithCommand:(YMControlCommand)command screen:(NSString *)screen name:(NSString *)name
                          width:(NSUInteger)width hiDPI:(YMControlHiDPI)hiDPI {
    if ((self = [super init])) {
        _command = command; _screen = [screen copy]; _name = [name copy]; _width = width; _hiDPI = hiDPI;
    }
    return self;
}

+ (NSDictionary<NSString *, NSNumber *> *)commandsByName {
    return @{@"list": @(YMControlCommandList), @"create": @(YMControlCommandCreate), @"start": @(YMControlCommandStart),
             @"close": @(YMControlCommandClose), @"rename": @(YMControlCommandRename), @"configure": @(YMControlCommandConfigure),
             @"delete": @(YMControlCommandDelete)};
}

+ (instancetype)requestWithJSONObject:(id)object error:(NSError **)error {
    NSString *problem = nil;
    YMControlRequest *request = [self parse:object problem:&problem];
    if (!request && error) *error = YMControlError(problem);
    return request;
}

+ (instancetype)parse:(id)object problem:(NSString **)problem {
    if (![object isKindOfClass:NSDictionary.class]) { *problem = @"request must be a JSON object"; return nil; }
    NSDictionary *json = object;
    NSSet *known = [NSSet setWithArray:@[@"command", @"screen", @"name", @"width", @"hiDPI"]];
    for (id key in json) if (![known containsObject:key]) { *problem = [NSString stringWithFormat:@"unknown field \"%@\"", key]; return nil; }

    NSNumber *command = [json[@"command"] isKindOfClass:NSString.class] ? self.commandsByName[json[@"command"]] : nil;
    if (!command) { *problem = @"command must be one of list, create, start, close, rename, configure, delete"; return nil; }

    id rawScreen = json[@"screen"], rawName = json[@"name"], rawWidth = json[@"width"], rawHiDPI = json[@"hiDPI"];
    if (rawScreen && (![rawScreen isKindOfClass:NSString.class] || ![rawScreen length])) { *problem = @"screen must be a non-empty string"; return nil; }
    NSString *name = nil;
    if (rawName) {
        if (![rawName isKindOfClass:NSString.class]) { *problem = @"name must be a string"; return nil; }
        name = [rawName stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSString *nameProblem = YMControlNameProblem(name);
        if (nameProblem) { *problem = nameProblem; return nil; }
    }
    NSUInteger width = 0;
    if (rawWidth) {
        // NSNumber also bridges JSON booleans; reject them explicitly.
        if (![rawWidth isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)rawWidth) == CFBooleanGetTypeID()
            || ([rawWidth unsignedIntegerValue] != 1920 && [rawWidth unsignedIntegerValue] != 2560)) {
            *problem = @"width must be 1920 (1920×1080) or 2560 (2560×1440)"; return nil;
        }
        width = [rawWidth unsignedIntegerValue];
    }
    YMControlHiDPI hiDPI = YMControlHiDPIUnchanged;
    if (rawHiDPI) {
        if (CFGetTypeID((__bridge CFTypeRef)rawHiDPI) != CFBooleanGetTypeID()) { *problem = @"hiDPI must be true or false"; return nil; }
        hiDPI = [rawHiDPI boolValue] ? YMControlHiDPIOn : YMControlHiDPIOff;
    }

    BOOL hasScreen = rawScreen != nil, hasName = name != nil, hasSettings = width || hiDPI != YMControlHiDPIUnchanged;
    switch ((YMControlCommand)command.integerValue) {
        case YMControlCommandList:
            if (hasScreen || hasName || hasSettings) { *problem = @"list takes no arguments"; return nil; }
            break;
        case YMControlCommandCreate:
            if (hasScreen) { *problem = @"create does not take a screen"; return nil; }
            break;
        case YMControlCommandStart:
        case YMControlCommandClose:
        case YMControlCommandDelete:
            if (!hasScreen || hasName || hasSettings) { *problem = @"start, close and delete take only a screen"; return nil; }
            break;
        case YMControlCommandRename:
            if (!hasScreen || !hasName || hasSettings) { *problem = @"rename takes a screen and a new name"; return nil; }
            break;
        case YMControlCommandConfigure:
            if (!hasScreen || hasName || !hasSettings) { *problem = @"configure takes a screen and a size and/or HiDPI setting"; return nil; }
            break;
    }
    return [[self alloc] initWithCommand:(YMControlCommand)command.integerValue screen:rawScreen name:name width:width hiDPI:hiDPI];
}

- (NSDictionary *)JSONObject {
    NSString *command = [[self.class commandsByName] allKeysForObject:@(self.command)].firstObject;
    NSMutableDictionary *json = [NSMutableDictionary dictionaryWithObject:command forKey:@"command"];
    if (self.screen) json[@"screen"] = self.screen;
    if (self.name) json[@"name"] = self.name;
    if (self.width) json[@"width"] = @(self.width);
    if (self.hiDPI != YMControlHiDPIUnchanged) json[@"hiDPI"] = self.hiDPI == YMControlHiDPIOn ? @YES : @NO; // @(a == b) would box an int
    return json;
}
@end

#pragma mark - Socket plumbing

static NSString *YMControlSocketPath(void) {
    NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    return [[support URLByAppendingPathComponent:YMControlBundleID isDirectory:YES] URLByAppendingPathComponent:@"control.sock"].path;
}

static BOOL YMControlAddress(NSString *path, struct sockaddr_un *address) {
    memset(address, 0, sizeof(*address));
    address->sun_family = AF_UNIX;
    const char *raw = path.fileSystemRepresentation;
    if (strlen(raw) >= sizeof(address->sun_path)) return NO;
    strlcpy(address->sun_path, raw, sizeof(address->sun_path));
    return YES;
}

// Returns a connected descriptor, or -1 with errno set.
static int YMControlConnect(NSString *path) {
    struct sockaddr_un address;
    if (!YMControlAddress(path, &address)) { errno = ENAMETOOLONG; return -1; }
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int on = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
    if (connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0) { int saved = errno; close(fd); errno = saved; return -1; }
    return fd;
}

static BOOL YMControlWriteAll(int fd, NSData *data) {
    const uint8_t *bytes = data.bytes;
    size_t left = data.length;
    while (left) {
        ssize_t n = write(fd, bytes, left);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return NO;
        bytes += n; left -= (size_t)n;
    }
    return YES;
}

// Reads until a newline or EOF. Returns nil on error, timeout or oversize input.
static NSData *YMControlReadLine(int fd, size_t limit) {
    NSMutableData *data = [NSMutableData data];
    uint8_t buffer[4096];
    while (data.length <= limit) {
        ssize_t n = read(fd, buffer, sizeof(buffer));
        if (n < 0 && errno == EINTR) continue;
        if (n < 0) return nil;
        if (n == 0) return data;
        [data appendBytes:buffer length:(NSUInteger)n];
        const void *newline = memchr(buffer, '\n', (size_t)n);
        if (newline) {
            NSUInteger end = data.length - (NSUInteger)n + (NSUInteger)((const uint8_t *)newline - buffer);
            return [data subdataWithRange:NSMakeRange(0, end)];
        }
    }
    return nil;
}

static void YMControlSetTimeout(int fd, int seconds) {
    struct timeval timeout = {.tv_sec = seconds, .tv_usec = 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
}

static NSData *YMControlLine(NSDictionary *object) {
    NSMutableData *data = [[NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingSortedKeys | NSJSONWritingWithoutEscapingSlashes error:nil] mutableCopy];
    [data appendBytes:"\n" length:1];
    return data;
}

#pragma mark - Server

@implementation YMControlServer {
    int _listenFD;
    NSString *_path;
    dispatch_queue_t _queue;
    dispatch_source_t _source;
    YMControlHandler _handler;
}

- (instancetype)initWithHandler:(YMControlHandler)handler error:(NSError **)error {
    if (!(self = [super init])) return nil;
    _handler = [handler copy];
    _path = YMControlSocketPath();
    _listenFD = -1;
    NSString *directory = _path.stringByDeletingLastPathComponent;
    NSError *dirError = nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES
                                                  attributes:@{NSFilePosixPermissions: @0700} error:&dirError]) {
        if (error) *error = dirError;
        return nil;
    }
    chmod(directory.fileSystemRepresentation, 0700);
    int live = YMControlConnect(_path);
    if (live >= 0) {
        close(live);
        if (error) *error = YMControlError(@"another yomado instance already serves the control socket");
        return nil;
    }
    struct sockaddr_un address;
    if (!YMControlAddress(_path, &address)) {
        if (error) *error = YMControlError(@"control socket path is too long");
        return nil;
    }
    unlink(_path.fileSystemRepresentation);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0 || bind(fd, (struct sockaddr *)&address, sizeof(address)) != 0
        || chmod(_path.fileSystemRepresentation, 0600) != 0 || listen(fd, 8) != 0) {
        NSString *reason = [NSString stringWithFormat:@"control socket setup failed: %s", strerror(errno)];
        if (fd >= 0) close(fd);
        if (error) *error = YMControlError(reason);
        return nil;
    }
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
    fcntl(fd, F_SETFD, FD_CLOEXEC);
    _listenFD = fd;
    _queue = dispatch_queue_create("dev.chekusu.yomado.control", DISPATCH_QUEUE_SERIAL);
    _source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, _queue);
    __weak YMControlServer *weakSelf = self;
    dispatch_source_set_event_handler(_source, ^{ [weakSelf acceptPending]; });
    dispatch_source_set_cancel_handler(_source, ^{ close(fd); });
    dispatch_resume(_source);
    return self;
}

- (void)acceptPending {
    for (;;) {
        int client = accept(_listenFD, NULL, NULL);
        if (client < 0) return; // EAGAIN: drained
        fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK);
        fcntl(client, F_SETFD, FD_CLOEXEC);
        int on = 1;
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
        YMControlSetTimeout(client, 5);
        [self serveClient:client];
    }
}

- (void)serveClient:(int)client {
    dispatch_queue_t queue = _queue;
    void (^finish)(NSDictionary *) = ^(NSDictionary *response) {
        dispatch_async(queue, ^{ YMControlWriteAll(client, YMControlLine(response)); close(client); });
    };
    NSData *line = YMControlReadLine(client, YMControlMaxRequest);
    id json = line ? [NSJSONSerialization JSONObjectWithData:line options:0 error:nil] : nil;
    NSError *parseError = nil;
    YMControlRequest *request = json ? [YMControlRequest requestWithJSONObject:json error:&parseError] : nil;
    if (!request) {
        finish(YMControlFailure(parseError.localizedDescription ?: @"request must be one line of JSON"));
        return;
    }
    YMControlHandler handler = _handler;
    dispatch_async(dispatch_get_main_queue(), ^{
        __block BOOL replied = NO;
        handler(request, ^(NSDictionary *response) {
            NSAssert(!replied, @"control reply sent twice");
            if (replied) return;
            replied = YES;
            finish(response);
        });
    });
}

- (void)invalidate {
    if (!_source) return;
    dispatch_source_cancel(_source);
    _source = nil;
    unlink(_path.fileSystemRepresentation);
}

- (void)dealloc { [self invalidate]; }
@end

#pragma mark - Client

static void YMControlUsage(FILE *stream) {
    fputs("usage: Yomado screen <command>\n"
          "  list\n"
          "  create [--name NAME] [--size 1920x1080|2560x1440] [--hidpi|--no-hidpi]\n"
          "  start SCREEN\n"
          "  close SCREEN\n"
          "  rename SCREEN NAME\n"
          "  configure SCREEN [--size 1920x1080|2560x1440] [--hidpi|--no-hidpi]\n"
          "  delete SCREEN            (closed screens only)\n"
          "SCREEN is a screen id (its number), its name, or its full title.\n"
          "Prints one JSON object. Exit status: 0 ok, 1 refused or failed, 2 usage, 3 yomado unreachable.\n", stream);
}

// Parses `screen` arguments into the same JSON object the server validates.
static NSDictionary *YMControlArguments(NSArray<NSString *> *args, NSString **problem) {
    if (!args.count) { *problem = @"missing command"; return nil; }
    NSMutableDictionary *json = [NSMutableDictionary dictionaryWithObject:args[0] forKey:@"command"];
    NSMutableArray<NSString *> *positional = [NSMutableArray array];
    for (NSUInteger i = 1; i < args.count; i++) {
        NSString *arg = args[i];
        if ([arg isEqualToString:@"--hidpi"]) json[@"hiDPI"] = @YES;
        else if ([arg isEqualToString:@"--no-hidpi"]) json[@"hiDPI"] = @NO;
        else if ([arg isEqualToString:@"--name"] || [arg isEqualToString:@"--size"]) {
            if (i + 1 >= args.count) { *problem = [NSString stringWithFormat:@"%@ needs a value", arg]; return nil; }
            NSString *value = args[++i];
            if ([arg isEqualToString:@"--name"]) json[@"name"] = value;
            else if ([value isEqualToString:@"1920x1080"]) json[@"width"] = @1920;
            else if ([value isEqualToString:@"2560x1440"]) json[@"width"] = @2560;
            else { *problem = @"--size must be 1920x1080 or 2560x1440"; return nil; }
        } else if ([arg hasPrefix:@"--"]) { *problem = [NSString stringWithFormat:@"unknown option %@", arg]; return nil; }
        else [positional addObject:arg];
    }
    NSString *command = args[0];
    NSUInteger expected = [command isEqualToString:@"rename"] ? 2
        : ([command isEqualToString:@"list"] || [command isEqualToString:@"create"]) ? 0 : 1;
    if (positional.count != expected) { *problem = [NSString stringWithFormat:@"%@ takes %lu positional argument(s)", command, (unsigned long)expected]; return nil; }
    if (expected >= 1) json[@"screen"] = positional[0];
    if (expected == 2) json[@"name"] = positional[1];
    return json;
}

static NSString *YMControlBundlePath(void) {
    char raw[PATH_MAX];
    uint32_t size = sizeof(raw);
    char resolved[PATH_MAX];
    if (_NSGetExecutablePath(raw, &size) != 0 || !realpath(raw, resolved)) return NSBundle.mainBundle.bundlePath;
    // .../Yomado.app/Contents/MacOS/Yomado
    return [NSString stringWithUTF8String:resolved].stringByDeletingLastPathComponent
        .stringByDeletingLastPathComponent.stringByDeletingLastPathComponent;
}

static BOOL YMControlAppRunning(void) {
    pid_t me = getpid();
    for (NSRunningApplication *app in [NSRunningApplication runningApplicationsWithBundleIdentifier:YMControlBundleID])
        if (app.processIdentifier != me && !app.terminated) return YES;
    return NO;
}

// Starts yomado without activating it or showing its control panel.
static BOOL YMControlLaunchApp(NSString **problem) {
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/open"];
    task.arguments = @[@"-g", @"-j", @"-a", YMControlBundlePath(), @"--args", @"--background"];
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) { *problem = error.localizedDescription; return NO; }
    [task waitUntilExit];
    if (task.terminationStatus != 0) { *problem = @"open(1) could not launch yomado"; return NO; }
    return YES;
}

static int YMControlConnectOrLaunch(NSString *path, NSString **problem) {
    int fd = YMControlConnect(path);
    if (fd >= 0) return fd;
    if (YMControlAppRunning()) {
        *problem = @"yomado is running but its control socket is unavailable; this build may predate the CLI";
        return -1;
    }
    if (!YMControlLaunchApp(problem)) return -1;
    for (int attempt = 0; attempt < 150; attempt++) {
        usleep(100 * 1000);
        fd = YMControlConnect(path);
        if (fd >= 0) return fd;
    }
    *problem = @"launched yomado, but its control socket did not appear within 15 s";
    return -1;
}

int YMControlClientMain(int argc, const char *argv[]) {
    @autoreleasepool {
        NSMutableArray<NSString *> *args = [NSMutableArray array];
        for (int i = 2; i < argc; i++) [args addObject:[NSString stringWithUTF8String:argv[i]]];
        if (args.count == 1 && ([args[0] isEqualToString:@"--help"] || [args[0] isEqualToString:@"help"])) {
            YMControlUsage(stdout); return 0;
        }
        NSString *problem = nil;
        NSDictionary *json = YMControlArguments(args, &problem);
        NSError *error = nil;
        YMControlRequest *request = json ? [YMControlRequest requestWithJSONObject:json error:&error] : nil;
        if (!request) {
            fprintf(stderr, "error: %s\n", (problem ?: error.localizedDescription).UTF8String);
            YMControlUsage(stderr);
            return 2;
        }
        int fd = YMControlConnectOrLaunch(YMControlSocketPath(), &problem);
        if (fd < 0) { fprintf(stderr, "error: %s\n", problem.UTF8String); return 3; }
        // Display creation waits for topology verification; allow generous time.
        YMControlSetTimeout(fd, 90);
        NSData *reply = YMControlWriteAll(fd, YMControlLine(request.JSONObject)) ? YMControlReadLine(fd, 1024 * 1024) : nil;
        close(fd);
        NSDictionary *response = reply.length ? [NSJSONSerialization JSONObjectWithData:reply options:0 error:nil] : nil;
        if (![response isKindOfClass:NSDictionary.class]) { fprintf(stderr, "error: no reply from yomado\n"); return 3; }
        NSData *pretty = [NSJSONSerialization dataWithJSONObject:response
            options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys | NSJSONWritingWithoutEscapingSlashes error:nil];
        fwrite(pretty.bytes, 1, pretty.length, stdout);
        fputc('\n', stdout);
        return [response[@"ok"] boolValue] ? 0 : 1;
    }
}
