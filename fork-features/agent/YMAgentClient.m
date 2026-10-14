#import "YMAgentClient.h"
#import "YMAgentPaths.h"
#import <fcntl.h>
#import <spawn.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <termios.h>
#import <unistd.h>

extern char **environ;

#pragma mark - Line parsing

static NSNumber *YMNumber(NSString *text) {
    NSScanner *scanner = [NSScanner scannerWithString:text];
    double value = 0;
    if (![scanner scanDouble:&value] || !scanner.isAtEnd) return nil;
    return @(value);
}

// The rest of the line after the first `skip` whitespace-separated words.
static NSString *YMRest(NSString *line, NSUInteger skip) {
    NSScanner *scanner = [NSScanner scannerWithString:line];
    scanner.charactersToBeSkipped = nil;
    NSCharacterSet *space = NSCharacterSet.whitespaceCharacterSet;
    for (NSUInteger i = 0; i < skip; i++) {
        [scanner scanCharactersFromSet:space intoString:NULL];
        [scanner scanUpToCharactersFromSet:space intoString:NULL];
    }
    [scanner scanCharactersFromSet:space intoString:NULL];
    return scanner.isAtEnd ? @"" : [line substringFromIndex:scanner.scanLocation];
}

NSDictionary *YMAgentRequestFromLine(NSString *line, NSString **problem) {
    NSString *trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if ([trimmed hasPrefix:@"{"]) {
        id json = [NSJSONSerialization JSONObjectWithData:[trimmed dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        if (![json isKindOfClass:NSDictionary.class] || ![json[@"op"] isKindOfClass:NSString.class]) { *problem = @"a JSON line must be an object with \"op\""; return nil; }
        NSMutableDictionary *request = [json mutableCopy];
        [request removeObjectForKey:@"id"];
        return request;
    }
    NSMutableArray<NSString *> *words = [NSMutableArray array];
    for (NSString *word in [trimmed componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet])
        if (word.length) [words addObject:word];
    if (!words.count) { *problem = @"empty line"; return nil; }
    NSString *op = words[0];
    NSArray<NSString *> *args = [words subarrayWithRange:NSMakeRange(1, words.count - 1)];
    NSMutableArray<NSNumber *> *numbers = [NSMutableArray array];
    for (NSString *arg in args) { NSNumber *n = YMNumber(arg); if (!n) break; [numbers addObject:n]; }
    NSString *(^needs)(NSString *) = ^NSString *(NSString *form) { return [NSString stringWithFormat:@"usage: %@", form]; };

    if ([op isEqualToString:@"status"] || [op isEqualToString:@"windows"]) {
        if (args.count) { *problem = needs(op); return nil; }
        return @{@"op": op};
    }
    if ([op isEqualToString:@"launch"] || [op isEqualToString:@"quit"]) {
        NSString *app = YMRest(trimmed, 1);
        if (!app.length) { *problem = needs([op stringByAppendingString:@" APP"]); return nil; }
        if ([op isEqualToString:@"quit"] && YMNumber(app)) return @{@"op": op, @"app": YMNumber(app)};
        return @{@"op": op, @"app": app};
    }
    if ([op isEqualToString:@"adopt"] || [op isEqualToString:@"ax"]) {
        if (args.count != 1 || numbers.count != 1) { *problem = needs([op stringByAppendingString:@" WINDOW"]); return nil; }
        return @{@"op": op, @"window": numbers[0]};
    }
    if ([op isEqualToString:@"capture"]) {
        if (args.count > 1 || numbers.count != args.count) { *problem = needs(@"capture [WINDOW]"); return nil; }
        return args.count ? @{@"op": op, @"window": numbers[0]} : @{@"op": op};
    }
    if ([op isEqualToString:@"press"]) {
        if (args.count < 1 || args.count > 2) { *problem = needs(@"press REF [ACTION]"); return nil; }
        return args.count == 2 ? @{@"op": op, @"ref": args[0], @"action": args[1]} : @{@"op": op, @"ref": args[0]};
    }
    if ([op isEqualToString:@"set"]) {
        NSString *value = YMRest(trimmed, 2);
        if (args.count < 2) { *problem = needs(@"set REF VALUE"); return nil; }
        return @{@"op": op, @"ref": args[0], @"value": value};
    }
    if ([op isEqualToString:@"move"]) {
        if (args.count != 3 || numbers.count != 3) { *problem = needs(@"move WINDOW X Y"); return nil; }
        return @{@"op": op, @"window": numbers[0], @"x": numbers[1], @"y": numbers[2]};
    }
    if ([op isEqualToString:@"click"]) {
        if (!numbers.count || (numbers.count != 1 && numbers.count != 3)) { *problem = needs(@"click WINDOW [X Y] [right] [double|triple]"); return nil; }
        NSMutableDictionary *request = [@{@"op": op, @"window": numbers[0]} mutableCopy];
        if (numbers.count == 3) { request[@"x"] = numbers[1]; request[@"y"] = numbers[2]; }
        for (NSString *word in [args subarrayWithRange:NSMakeRange(numbers.count, args.count - numbers.count)]) {
            if ([word isEqualToString:@"right"]) request[@"button"] = @"right";
            else if ([word isEqualToString:@"double"]) request[@"count"] = @2;
            else if ([word isEqualToString:@"triple"]) request[@"count"] = @3;
            else { *problem = needs(@"click WINDOW [X Y] [right] [double|triple]"); return nil; }
        }
        return request;
    }
    if ([op isEqualToString:@"drag"]) {
        if (args.count != numbers.count || (numbers.count != 3 && numbers.count != 5)) { *problem = needs(@"drag WINDOW X2 Y2 [X1 Y1]"); return nil; }
        NSMutableDictionary *request = [@{@"op": op, @"window": numbers[0], @"to": @{@"x": numbers[1], @"y": numbers[2]}} mutableCopy];
        if (numbers.count == 5) request[@"from"] = @{@"x": numbers[3], @"y": numbers[4]};
        return request;
    }
    if ([op isEqualToString:@"scroll"]) {
        if (args.count != numbers.count || (numbers.count != 2 && numbers.count != 3)) { *problem = needs(@"scroll WINDOW DY [DX]"); return nil; }
        NSMutableDictionary *request = [@{@"op": op, @"window": numbers[0], @"dy": numbers[1]} mutableCopy];
        if (numbers.count == 3) request[@"dx"] = numbers[2];
        return request;
    }
    if ([op isEqualToString:@"type"]) {
        if (args.count < 2 || numbers.count < 1) { *problem = needs(@"type WINDOW TEXT"); return nil; }
        return @{@"op": op, @"window": numbers[0], @"text": YMRest(trimmed, 2)};
    }
    if ([op isEqualToString:@"key"]) {
        if (args.count < 2) { *problem = needs(@"key WINDOW|APP COMBO..."); return nil; }
        // A number is a window id; anything else is a session app (bundle id), for menu shortcuts.
        NSArray *keys = [args subarrayWithRange:NSMakeRange(1, args.count - 1)];
        return numbers.count ? @{@"op": op, @"window": numbers[0], @"keys": keys} : @{@"op": op, @"app": args[0], @"keys": keys};
    }
    if ([op isEqualToString:@"handoff"]) {
        if (!args.count || numbers.count != args.count) { *problem = needs(@"handoff WINDOW..."); return nil; }
        return @{@"op": op, @"windows": numbers};
    }
    *problem = [NSString stringWithFormat:@"unknown command \"%@\"", op];
    return nil;
}

#pragma mark - Connection

static int YMAgentConnect(void) {
    struct sockaddr_un address = {.sun_family = AF_UNIX};
    const char *path = YMAgentSocketPath().fileSystemRepresentation;
    if (strlen(path) >= sizeof(address.sun_path)) return -1;
    strlcpy(address.sun_path, path, sizeof(address.sun_path));
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int on = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
    if (connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0) { close(fd); return -1; }
    return fd;
}

// Spawns the helper as a detached child so it runs with this process's grants.
static BOOL YMAgentSpawnHelper(NSString **problem) {
    NSString *helper = YMAgentHelperPath();
    if (![NSFileManager.defaultManager isExecutableFileAtPath:helper]) { *problem = [NSString stringWithFormat:@"helper not found at %@", helper]; return NO; }
    NSString *log = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/yomado-agent.log"];
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, log.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0600);
    posix_spawn_file_actions_adddup2(&actions, STDOUT_FILENO, STDERR_FILENO);
    posix_spawnattr_t attributes;
    posix_spawnattr_init(&attributes);
    posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETSID);
    pid_t pid = 0;
    char *argv[] = {(char *)helper.fileSystemRepresentation, NULL};
    int status = posix_spawn(&pid, helper.fileSystemRepresentation, &actions, &attributes, argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attributes);
    if (status != 0) { *problem = [NSString stringWithFormat:@"could not start the helper: %s", strerror(status)]; return NO; }
    return YES;
}

static int YMAgentConnectOrSpawn(NSString **problem) {
    int fd = YMAgentConnect();
    if (fd >= 0) return fd;
    if (!YMAgentSpawnHelper(problem)) return -1;
    for (int attempt = 0; attempt < 50; attempt++) {
        usleep(100 * 1000);
        fd = YMAgentConnect();
        if (fd >= 0) return fd;
    }
    *problem = @"the helper did not open its socket within 5 s; see ~/Library/Logs/yomado-agent.log";
    return -1;
}

static BOOL YMWriteLine(int fd, NSDictionary *object) {
    NSMutableData *data = [[NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingWithoutEscapingSlashes error:nil] mutableCopy];
    [data appendBytes:"\n" length:1];
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

// Reads one response line; `buffer` keeps bytes after the newline.
static NSData *YMReadLine(int fd, NSMutableData *buffer) {
    for (;;) {
        const void *newline = memchr(buffer.bytes, '\n', buffer.length);
        if (newline) {
            NSUInteger length = (NSUInteger)((const uint8_t *)newline - (const uint8_t *)buffer.bytes);
            NSData *line = [buffer subdataWithRange:NSMakeRange(0, length)];
            [buffer replaceBytesInRange:NSMakeRange(0, length + 1) withBytes:NULL length:0];
            return line;
        }
        uint8_t chunk[16384];
        ssize_t n = read(fd, chunk, sizeof(chunk));
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return nil;
        [buffer appendBytes:chunk length:(NSUInteger)n];
    }
}

#pragma mark - Input

static struct termios YMSavedTerminal;

static void YMRestoreTerminal(void) { tcsetattr(STDIN_FILENO, TCSANOW, &YMSavedTerminal); }

static void YMEnterRawInput(void) {
    if (tcgetattr(STDIN_FILENO, &YMSavedTerminal) != 0) return;
    atexit(YMRestoreTerminal);
    struct termios raw = YMSavedTerminal;
    raw.c_lflag &= ~(tcflag_t)(ICANON | ECHO); // keep ISIG: Ctrl-C still interrupts
    raw.c_cc[VMIN] = 1;
    raw.c_cc[VTIME] = 0;
    tcsetattr(STDIN_FILENO, TCSANOW, &raw);
}

// Reads one line from a non-canonical terminal with minimal editing: Backspace,
// Ctrl-U (clear), Ctrl-D on an empty line (end of input). Returns nil at end of input.
static NSData *YMReadTerminalLine(void) {
    NSMutableData *line = [NSMutableData data];
    for (;;) {
        unsigned char c;
        ssize_t n = read(STDIN_FILENO, &c, 1);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return line.length ? line : nil;
        if (c == '\r' || c == '\n') { fputs("\r\n", stdout); fflush(stdout); return line; }
        if (c == 0x04) { if (!line.length) { fputs("\r\n", stdout); return nil; } continue; }
        if (c == 0x7f || c == 0x08) {
            // Drop one UTF-8 character: continuation bytes are 10xxxxxx.
            const unsigned char *bytes = line.bytes;
            NSUInteger length = line.length;
            while (length && (bytes[length - 1] & 0xC0) == 0x80) length--;
            if (length) { length--; fputs("\b \b", stdout); fflush(stdout); }
            line.length = length;
            continue;
        }
        if (c == 0x15) { line.length = 0; fputs("\r\x1b[K> ", stdout); fflush(stdout); continue; }
        [line appendBytes:&c length:1];
        fwrite(&c, 1, 1, stdout);
        fflush(stdout);
    }
}

static NSData *YMReadPipeLine(void) {
    static char *raw = NULL;
    static size_t capacity = 0;
    ssize_t length = getline(&raw, &capacity, stdin);
    return length < 0 ? nil : [NSData dataWithBytes:raw length:(NSUInteger)length];
}

int YMAgentClientMain(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *screen = @"Agent";
        for (int i = 2; i < argc; i++) {
            if (strcmp(argv[i], "--screen") == 0 && i + 1 < argc) screen = [NSString stringWithUTF8String:argv[++i]];
            else { fprintf(stderr, "usage: Yomado agent [--screen NAME]\n"); return 2; }
        }
        NSString *problem = nil;
        int fd = YMAgentConnectOrSpawn(&problem);
        if (fd < 0) { fprintf(stderr, "error: %s\n", problem.UTF8String); return 3; }
        NSMutableData *buffer = [NSMutableData data];
        NSInteger nextID = 0;
        BOOL interactive = isatty(STDIN_FILENO);
        NSData *reply = YMWriteLine(fd, @{@"id": @(++nextID), @"op": @"open", @"screen": screen}) ? YMReadLine(fd, buffer) : nil;
        if (!reply) { fprintf(stderr, "error: the helper closed the connection\n"); return 3; }
        fwrite(reply.bytes, 1, reply.length, stdout); fputc('\n', stdout); fflush(stdout);
        NSDictionary *opened = [NSJSONSerialization JSONObjectWithData:reply options:0 error:nil];
        if (![opened[@"ok"] boolValue]) return 1;
        // A terminal in canonical mode caps a line at MAX_CANON (1024 bytes on macOS), which is too
        // short for `type` with long text, so the REPL reads a terminal in non-canonical mode.
        if (interactive) YMEnterRawInput();
        for (;;) {
            if (interactive) { fputs("> ", stdout); fflush(stdout); }
            NSData *bytes = interactive ? YMReadTerminalLine() : YMReadPipeLine();
            if (!bytes) break;
            NSString *line = [[NSString alloc] initWithData:bytes encoding:NSUTF8StringEncoding];
            line = [line stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet];
            if (!line.length) continue;
            NSDictionary *request = YMAgentRequestFromLine(line, &problem);
            if (!request) {
                NSDictionary *local = @{@"id": NSNull.null, @"ok": @NO, @"error": @{@"code": @"usage", @"message": problem}, @"events": @[]};
                NSData *data = [NSJSONSerialization dataWithJSONObject:local options:NSJSONWritingWithoutEscapingSlashes error:nil];
                fwrite(data.bytes, 1, data.length, stdout); fputc('\n', stdout); fflush(stdout);
                continue;
            }
            NSMutableDictionary *withID = [request mutableCopy];
            withID[@"id"] = @(++nextID);
            reply = YMWriteLine(fd, withID) ? YMReadLine(fd, buffer) : nil;
            if (!reply) { fprintf(stderr, "error: the helper closed the connection\n"); return 3; }
            fwrite(reply.bytes, 1, reply.length, stdout); fputc('\n', stdout); fflush(stdout);
        }
        close(fd);
        return 0;
    }
}
