// Fork feature: agent sessions. File locations shared by the helper and its clients.
// See fork-features/agent/README.md.
#import <Foundation/Foundation.h>
#import <mach-o/dyld.h>
#import <limits.h>
#import <stdlib.h>

static inline NSString *YMAgentSupportDirectory(void) {
    NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    return [support URLByAppendingPathComponent:@"dev.chekusu.yomado" isDirectory:YES].path;
}

static inline NSString *YMAgentSocketPath(void) {
    return [YMAgentSupportDirectory() stringByAppendingPathComponent:@"agent.sock"];
}

static inline NSString *YMAgentLockPath(void) {
    return [YMAgentSupportDirectory() stringByAppendingPathComponent:@"agent.lock"];
}

// The helper is a nested bundle, so LaunchServices never mistakes it for Yomado
// itself: Yomado.app/Contents/Helpers/YomadoAgent.app. Clients run from
// Yomado.app/Contents/MacOS.
static inline NSString *YMAgentHelperPath(void) {
    char raw[PATH_MAX];
    uint32_t size = sizeof(raw);
    char resolved[PATH_MAX];
    if (_NSGetExecutablePath(raw, &size) != 0 || !realpath(raw, resolved)) return nil;
    NSString *contents = [NSString stringWithUTF8String:resolved].stringByDeletingLastPathComponent.stringByDeletingLastPathComponent;
    return [contents stringByAppendingPathComponent:@"Helpers/YomadoAgent.app/Contents/MacOS/YomadoAgent"];
}
