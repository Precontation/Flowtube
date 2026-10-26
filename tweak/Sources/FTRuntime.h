// FlowTube: small runtime helpers. Every hook and message checks that the class and selector
// exist first, so a YouTube update that renames something turns a feature off instead of
// crashing the app. Hooks chain: the implementation found at install time (YouTube's, or one
// another tweak such as YTKACE installed earlier) is always called through.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

NS_ASSUME_NONNULL_BEGIN

/// Logs to the device log and to an in-app buffer (Settings → Copy debug log).
void FTLogMessage(NSString *message);
#define FTLog(fmt, ...) FTLogMessage([NSString stringWithFormat:fmt, ##__VA_ARGS__])
/// The last few hundred FlowTube log lines, oldest first.
NSString *FTLogText(void);

/// Replaces `selector` on `className` with `replacement`, storing the previous implementation in
/// `*original`. Returns NO, and changes nothing, when the class or method is missing.
BOOL FTHook(NSString *className, NSString *selector, IMP replacement, IMP _Nullable *_Nonnull original);

/// `[receiver selector]` returning an object, or nil when it does not respond or throws.
id _Nullable FTGet(id _Nullable receiver, NSString *selector);
/// The first of `selectors` the receiver answers with a non-empty string.
NSString *_Nullable FTString(id _Nullable receiver, NSArray<NSString *> *selectors);
/// `[receiver selector]` returning a double (also reads CGFloat/float/NSInteger-backed getters
/// through KVC when the method is not a double), 0 when unavailable.
double FTDouble(id _Nullable receiver, NSString *selector);
BOOL FTBool(id _Nullable receiver, NSString *selector);
/// KVC read that never throws.
id _Nullable FTValue(id _Nullable receiver, NSString *key);

/// The top-most foreground window.
UIWindow *_Nullable FTKeyWindow(void);

NS_ASSUME_NONNULL_END
