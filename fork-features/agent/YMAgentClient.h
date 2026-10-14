// Fork feature: agent sessions. `Yomado agent`, the line REPL client.
// See fork-features/agent/clients.md.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Converts one REPL line into a session request (without "id"). Returns nil
// with `problem` set when the line is not a valid command. Exposed for tests.
NSDictionary *_Nullable YMAgentRequestFromLine(NSString *line, NSString *_Nullable *_Nonnull problem);

// Entry point for `Yomado agent [--screen NAME]`; returns the process exit status.
int YMAgentClientMain(int argc, const char *_Nonnull argv[_Nonnull]);

NS_ASSUME_NONNULL_END
