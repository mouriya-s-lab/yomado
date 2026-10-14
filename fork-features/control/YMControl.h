// Fork feature: command-line control of named virtual screens.
// The running app owns every virtual display, so the CLI is a thin client that
// sends one JSON request over a per-user Unix socket and prints the reply.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, YMControlCommand) {
    YMControlCommandList,
    YMControlCommandCreate,    // name?, width?, hiDPI?
    YMControlCommandStart,     // screen
    YMControlCommandClose,     // screen
    YMControlCommandRename,    // screen, name
    YMControlCommandConfigure, // screen, width? and/or hiDPI?
    YMControlCommandDelete,    // screen (must be closed)
};

typedef NS_ENUM(NSInteger, YMControlHiDPI) {
    YMControlHiDPIUnchanged,
    YMControlHiDPIOn,
    YMControlHiDPIOff,
};

// A validated request. The parser guarantees each command carries exactly the
// fields listed above; unused fields are nil/0/Unchanged.
@interface YMControlRequest : NSObject
@property(readonly) YMControlCommand command;
@property(readonly, copy, nullable) NSString *screen;
@property(readonly, copy, nullable) NSString *name;
@property(readonly) NSUInteger width; // 0 = unchanged (configure) or default (create)
@property(readonly) YMControlHiDPI hiDPI;
+ (nullable instancetype)requestWithJSONObject:(id)object error:(NSError **)error;
- (NSDictionary *)JSONObject;
@end

typedef void (^YMControlReply)(NSDictionary *response);
typedef void (^YMControlHandler)(YMControlRequest *request, YMControlReply reply);

// Replies share one shape: {"ok": true, ...payload} or {"ok": false, "error": text}.
NSDictionary *YMControlSuccess(NSDictionary *payload);
NSDictionary *YMControlFailure(NSString *message);

// Validates a screen name the same way the rename dialog does; nil when valid.
NSString *_Nullable YMControlNameProblem(NSString *name);

// Listens on the control socket. The handler and its reply run on the main queue;
// each reply must be called exactly once.
@interface YMControlServer : NSObject
- (nullable instancetype)initWithHandler:(YMControlHandler)handler error:(NSError **)error;
- (void)invalidate;
@end

// Entry point for `Yomado screen ...`; returns the process exit status.
int YMControlClientMain(int argc, const char *_Nonnull argv[_Nonnull]);

NS_ASSUME_NONNULL_END
