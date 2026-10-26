// FlowTube: subscribes and likes, mirrored locally or (in local mode) kept local.
//
// Every action YouTube's buttons take is a YTICommand that passes through YTCommandRouter (and
// YTAccountScopedCommandRouter) — the same routers YTKACE hooks for its queue. A command's
// endpoints are protobuf extensions, so they are read structurally (`extensionsCurrentlySet`)
// by name, never by class: subscribeEndpoint / unsubscribeEndpoint carry channel ids and
// likeEndpoint a status and video id. Only the endpoints a command runs are read (including
// those of a commandExecutorCommand), not ones a dialog merely contains, so an "Unsubscribe?"
// confirmation counts when it is confirmed, not when it opens.
//
//   Normal mode: YouTube does what it always does; Flow mirrors subscribes locally.
//   Local mode:  subscribe, unsubscribe, like and dislike stay on the device. Signed out, the
//                "Sign in to subscribe/like" prompts are answered by Flow instead.
//
// The account's own channel list (Subscriptions → All, browse id FEchannels) is copied into
// Flow's subscriptions whenever it is opened, so Flow knows what you follow without your login.

#import "FTRuntime.h"
#import "FTEngine.h"
#import "FTNavigation.h"
#import "FTSettingsViewController.h"

NSString *FTCurrentVideoID(void);
NSString *FTCurrentChannelID(void);
NSString *FTCurrentChannelName(void);
void FTSetRating(NSString *videoID, NSString *rating);
NSString *FTRatingFor(NSString *videoID);
void FTShowSubscribed(UIView *button, BOOL subscribed);

typedef NS_ENUM(NSInteger, FTActionKind) {
    FTActionSubscribe,
    FTActionUnsubscribe,
    FTActionLike,
    FTActionDislike,
    FTActionUnlike,
    FTActionSignIn,
};

@interface FTAction : NSObject
@property (nonatomic) FTActionKind kind;
@property (nonatomic, copy) NSArray<NSString *> *channelIDs;
@property (nonatomic, copy) NSString *videoID;
@end

@implementation FTAction
@end

#pragma mark - Reading commands

static NSRegularExpression *FTChannelPattern(void) {
    static NSRegularExpression *pattern;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        pattern = [NSRegularExpression regularExpressionWithPattern:@"UC[0-9A-Za-z_-]{22}" options:0 error:nil];
    });
    return pattern;
}

static NSArray<NSString *> *FTChannelIDsIn(NSString *text) {
    if (text.length == 0) return @[];
    NSMutableOrderedSet *ids = [NSMutableOrderedSet orderedSet];
    for (NSTextCheckingResult *match in [FTChannelPattern() matchesInString:text options:0 range:NSMakeRange(0, text.length)]) {
        [ids addObject:[text substringWithRange:match.range]];
    }
    return ids.array;
}

static NSArray<NSString *> *FTStrings(id value) {
    NSMutableArray *out = [NSMutableArray array];
    if ([value isKindOfClass:NSString.class]) [out addObject:value];
    if ([value conformsToProtocol:@protocol(NSFastEnumeration)] && ![value isKindOfClass:NSString.class]) {
        for (id item in value) {
            if ([item isKindOfClass:NSString.class] && [item length]) [out addObject:item];
        }
    }
    return out;
}

static id FTExtension(id message, id descriptor) {
    SEL get = NSSelectorFromString(@"getExtension:");
    if (![message respondsToSelector:get]) return nil;
    @try {
        return ((id (*)(id, SEL, id))objc_msgSend)(message, get, descriptor);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static void FTCollect(id command, NSUInteger depth, NSMutableArray<FTAction *> *actions) {
    if (command == nil || depth > 3) return;
    NSArray *descriptors = FTGet(command, @"extensionsCurrentlySet");
    if (![descriptors isKindOfClass:NSArray.class]) return;
    for (id descriptor in descriptors) {
        NSString *name = [FTString(descriptor, @[@"singletonName", @"name"]) lowercaseString];
        if (name.length == 0) continue;
        id value = FTExtension(command, descriptor);
        if ([name containsString:@"commandexecutorcommand"]) {
            for (id inner in (NSArray *)(FTValue(value, @"commandsArray") ?: @[])) FTCollect(inner, depth + 1, actions);
            continue;
        }
        FTAction *action = [FTAction new];
        if ([name containsString:@"unsubscribeendpoint"]) {
            action.kind = FTActionUnsubscribe;
            action.channelIDs = FTStrings(FTValue(value, @"channelIdsArray"));
        } else if ([name containsString:@"subscribeendpoint"]) {
            action.kind = FTActionSubscribe;
            action.channelIDs = FTStrings(FTValue(value, @"channelIdsArray"));
        } else if ([name hasSuffix:@"likeendpoint"] && ![name containsString:@"playlist"] && ![name containsString:@"comment"]) {
            NSString *text = [value description] ?: @"";
            if ([text containsString:@"INDIFFERENT"]) action.kind = FTActionUnlike;
            else if ([text containsString:@"DISLIKE"]) action.kind = FTActionDislike;
            else if ([text containsString:@"LIKE"]) action.kind = FTActionLike;
            else {
                // The enum as a number: LIKE 0, DISLIKE 1, INDIFFERENT 2 (YTLikeStatus).
                double status = FTDouble(value, @"status");
                action.kind = status == 1 ? FTActionDislike : status == 2 ? FTActionUnlike : FTActionLike;
            }
            action.videoID = FTValue(FTValue(value, @"target"), @"videoId");
            if (![action.videoID isKindOfClass:NSString.class]) action.videoID = nil;
        } else if ([name containsString:@"signinendpoint"]) {
            action.kind = FTActionSignIn;
        } else if ([name containsString:@"modal"] || [name containsString:@"popup"]) {
            // A sign-in prompt: a modal that leads to the sign-in endpoint.
            if (![[[value description] lowercaseString] containsString:@"signin"]) continue;
            action.kind = FTActionSignIn;
        } else {
            continue;
        }
        [actions addObject:action];
    }
}

#pragma mark - Intent when signed out

/// What the tapped button was, from the view's (or its ancestors') accessibility.
static NSString *FTIntentFromView(UIView *view) {
    UIView *walk = [view isKindOfClass:UIView.class] ? view : nil;
    for (NSUInteger depth = 0; walk != nil && depth < 8; depth++, walk = walk.superview) {
        NSString *text = [[NSString stringWithFormat:@"%@ %@", walk.accessibilityIdentifier ?: @"", walk.accessibilityLabel ?: @""] lowercaseString];
        if ([text containsString:@"subscribe"]) return @"subscribe";
        if ([text containsString:@"dislike"]) return @"dislike";
        if ([text containsString:@"like"]) return @"like";
    }
    return nil;
}

/// What the sign-in prompt asks about ("Want to subscribe to this channel?", "Like this video?").
static NSString *FTIntentFromText(NSString *text) {
    NSString *lower = text.lowercaseString;
    if ([lower containsString:@"subscribe"]) return @"subscribe";
    if ([lower containsString:@"don't like"] || [lower containsString:@"dislike"]) return @"dislike";
    if ([lower containsString:@"like this video"]) return @"like";
    return nil;
}

static UIViewController *FTOwningController(UIView *view) {
    UIResponder *responder = [view isKindOfClass:UIView.class] ? view : nil;
    while (responder != nil) {
        if ([responder isKindOfClass:UIViewController.class]) return (UIViewController *)responder;
        responder = responder.nextResponder;
    }
    return nil;
}

/// The channel a signed-out subscribe button belongs to: named in the command, the channel page
/// it sits on, or the video playing.
static NSString *FTGuessChannel(NSString *commandText, UIView *view) {
    NSString *named = FTChannelIDsIn(commandText).firstObject;
    if (named) return named;
    for (UIViewController *controller = FTOwningController(view); controller != nil; controller = controller.parentViewController) {
        NSString *browseID = FTString(controller, @[@"browseID", @"browseIdentifier"]);
        if ([browseID hasPrefix:@"UC"]) return browseID;
    }
    return FTCurrentChannelID();
}

#pragma mark - Acting

static NSString *FTNameFor(NSString *channelID) {
    return [channelID isEqualToString:FTCurrentChannelID()] ? FTCurrentChannelName() : nil;
}

static void FTSubscribeLocally(NSString *channelID, BOOL subscribed, BOOL announce, UIView *button) {
    if (channelID.length == 0) return;
    [FTEngine.shared setSubscribed:subscribed channelID:channelID name:FTNameFor(channelID)];
    if (button) FTShowSubscribed(button, subscribed);
    if (!announce) return;
    NSString *name = FTNameFor(channelID);
    FTToast(subscribed
        ? (name.length ? [NSString stringWithFormat:@"Subscribed to %@ in Flow", name] : @"Subscribed in Flow")
        : (name.length ? [NSString stringWithFormat:@"Unsubscribed from %@ in Flow", name] : @"Unsubscribed in Flow"));
}

/// Signed out, the subscribe button can't say whether it would subscribe or unsubscribe, so a
/// second tap on a channel Flow already follows asks.
static void FTToggleSubscription(NSString *channelID, UIView *button) {
    if (![FTEngine.shared.subscribedIDs containsObject:channelID]) {
        FTSubscribeLocally(channelID, YES, YES, button);
        return;
    }
    NSString *name = FTNameFor(channelID) ?: @"this channel";
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"Unsubscribe from %@?", name]
                                                                   message:@"You follow it in Flow."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Unsubscribe" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        FTSubscribeLocally(channelID, NO, YES, button);
    }]];
    [FTTopViewController() presentViewController:alert animated:YES completion:nil];
}

static void FTRate(NSString *action, NSString *videoID) {
    if (videoID.length == 0) return;
    [FTEngine.shared feedback:action videoID:videoID video:nil];
    FTSetRating(videoID, action);
    NSDictionary *said = @{ @"like": @"Liked in Flow", @"dislike": @"Disliked in Flow", @"unlike": @"Rating removed in Flow" };
    FTToast(said[action] ?: @"Saved in Flow");
}

typedef struct {
    BOOL handled;          // don't let YouTube run it
    BOOL mirror;           // run it, then mirror locally
} FTDecision;

static __weak id FTLastCommand;
static NSTimeInterval FTLastCommandAt;
static FTDecision FTLastDecision;
static NSArray<FTAction *> *FTPendingMirror;

/// Decides what to do with a command before YouTube runs it.
static FTDecision FTDecide(id command, UIView *view) {
    FTDecision decision = { NO, NO };
    if (command == nil) return decision;
    // Routers hand the same command to each other; it is decided once.
    NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
    if (command == FTLastCommand && now - FTLastCommandAt < 1.0) {
        return (FTDecision){ FTLastDecision.handled, NO };
    }
    NSMutableArray<FTAction *> *actions = [NSMutableArray array];
    @try {
        FTCollect(command, 0, actions);
    } @catch (NSException *exception) {
        FTLog(@"reading a command failed: %@", exception.reason);
    }
    if (actions.count == 0) return decision;

    BOOL local = FTLocalModeEnabled();
    NSMutableArray *mirror = [NSMutableArray array];
    for (FTAction *action in actions) {
        switch (action.kind) {
            case FTActionSubscribe:
            case FTActionUnsubscribe: {
                BOOL subscribe = action.kind == FTActionSubscribe;
                if (local) {
                    // YouTube never hears about it, so its button keeps saying "Subscribe": a tap on
                    // a channel Flow already follows offers to unsubscribe.
                    for (NSString *channel in action.channelIDs) {
                        if (subscribe) dispatch_async(dispatch_get_main_queue(), ^{ FTToggleSubscription(channel, view); });
                        else FTSubscribeLocally(channel, NO, YES, view);
                    }
                    decision.handled = YES;
                } else {
                    [mirror addObject:action];
                }
                break;
            }
            case FTActionLike:
            case FTActionDislike:
            case FTActionUnlike:
                // Signed in, the like-service hook records likes once YouTube accepts them.
                if (local) {
                    NSString *verb = action.kind == FTActionLike ? @"like" : action.kind == FTActionDislike ? @"dislike" : @"unlike";
                    FTRate(verb, action.videoID ?: FTCurrentVideoID());
                    decision.handled = YES;
                }
                break;
            case FTActionSignIn: {
                if (!local) break;
                NSString *text = [command description] ?: @"";
                NSString *intent = FTIntentFromView(view) ?: FTIntentFromText(text);
                FTLog(@"sign-in prompt: intent=%@ view=%@", intent ?: @"unknown", NSStringFromClass([view class]));
                if ([intent isEqualToString:@"subscribe"]) {
                    NSString *channel = FTGuessChannel(text, view);
                    if (channel.length) {
                        dispatch_async(dispatch_get_main_queue(), ^{ FTToggleSubscription(channel, view); });
                        decision.handled = YES;
                    }
                } else if (intent != nil && FTCurrentVideoID().length) {
                    // The button shows Flow's rating, so tapping a lit one takes it back.
                    NSString *video = FTCurrentVideoID();
                    FTRate([FTRatingFor(video) isEqualToString:intent] ? @"unlike" : intent, video);
                    decision.handled = YES;
                }
                break;
            }
        }
    }
    if (mirror.count && !decision.handled) {
        decision.mirror = YES;
        FTPendingMirror = mirror;
    }
    FTLastCommand = command;
    FTLastCommandAt = now;
    FTLastDecision = decision;
    return decision;
}

/// After YouTube ran a subscribe or unsubscribe: the same, locally.
static void FTMirror(void) {
    NSArray<FTAction *> *actions = FTPendingMirror;
    FTPendingMirror = nil;
    for (FTAction *action in actions) {
        for (NSString *channel in action.channelIDs) {
            FTSubscribeLocally(channel, action.kind == FTActionSubscribe, NO, nil);
        }
    }
}

#pragma mark - Router hooks

// The routers return BOOL in current YouTube; a version returning void gets the void variants.
#define FT_ROUTER(N)                                                                                  \
    static IMP FTOriginal##N;                                                                         \
    static IMP FTOriginalBlock##N;                                                                    \
    static BOOL FTRoute##N(id self, SEL _cmd, id command, id entry, id view, id sender) {             \
        FTDecision d = FTDecide(command, view);                                                       \
        if (d.handled) return YES;                                                                    \
        BOOL result = ((BOOL (*)(id, SEL, id, id, id, id))FTOriginal##N)(self, _cmd, command, entry, view, sender); \
        if (d.mirror) FTMirror();                                                                     \
        return result;                                                                                \
    }                                                                                                 \
    static void FTRouteVoid##N(id self, SEL _cmd, id command, id entry, id view, id sender) {         \
        FTDecision d = FTDecide(command, view);                                                       \
        if (d.handled) return;                                                                        \
        ((void (*)(id, SEL, id, id, id, id))FTOriginal##N)(self, _cmd, command, entry, view, sender); \
        if (d.mirror) FTMirror();                                                                     \
    }                                                                                                 \
    static BOOL FTRouteBlock##N(id self, SEL _cmd, id command, id entry, id view, id sender, id block) { \
        FTDecision d = FTDecide(command, view);                                                       \
        if (d.handled) return YES;                                                                    \
        BOOL result = ((BOOL (*)(id, SEL, id, id, id, id, id))FTOriginalBlock##N)(self, _cmd, command, entry, view, sender, block); \
        if (d.mirror) FTMirror();                                                                     \
        return result;                                                                                \
    }                                                                                                 \
    static void FTRouteBlockVoid##N(id self, SEL _cmd, id command, id entry, id view, id sender, id block) { \
        FTDecision d = FTDecide(command, view);                                                       \
        if (d.handled) return;                                                                        \
        ((void (*)(id, SEL, id, id, id, id, id))FTOriginalBlock##N)(self, _cmd, command, entry, view, sender, block); \
        if (d.mirror) FTMirror();                                                                     \
    }

FT_ROUTER(0)
FT_ROUTER(1)

/// Installs the BOOL or void variant to match the method, and only when its arguments are objects.
static void FTHookRouter(NSString *className, NSString *selector, NSUInteger objectArgs, IMP boolVariant, IMP voidVariant, IMP *original) {
    Class cls = NSClassFromString(className);
    Method method = cls ? class_getInstanceMethod(cls, NSSelectorFromString(selector)) : NULL;
    if (method == NULL) {
        FTLog(@"router hook skipped: -[%@ %@] missing", className, selector);
        return;
    }
    NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
    if (signature.numberOfArguments != objectArgs + 2) return;
    for (NSUInteger i = 2; i < signature.numberOfArguments; i++) {
        if ([signature getArgumentTypeAtIndex:i][0] != '@') {
            FTLog(@"router hook skipped: -[%@ %@] has another signature", className, selector);
            return;
        }
    }
    char returns = signature.methodReturnType[0];
    if (returns == 'B' || returns == 'c') FTHook(className, selector, boolVariant, original);
    else if (returns == 'v') FTHook(className, selector, voidVariant, original);
}

#pragma mark - The account's channel list

static IMP FTOriginalLoadResponse;
static IMP FTOriginalLoadInitialResponse;

static void FTHarvestChannels(UIViewController *browse, id response) {
    if (![FTString(browse, @[@"browseID", @"browseIdentifier"]) isEqualToString:@"FEchannels"]) return;
    NSString *text = [response description];
    NSArray<NSString *> *ids = FTChannelIDsIn(text);
    if (ids.count == 0) return;
    NSMutableArray *channels = [NSMutableArray array];
    for (NSString *channelID in ids) [channels addObject:@{ @"id": channelID }];
    [FTEngine.shared addSubscriptions:channels completion:^(NSInteger added) {
        FTLog(@"account channel list: %lu channels, %ld new", (unsigned long)ids.count, (long)added);
        if (added > 0) {
            FTToast([NSString stringWithFormat:@"Flow copied %ld subscription%@ from your account", (long)added, added == 1 ? @"" : @"s"]);
        } else if (added == 0 && [NSUserDefaults.standardUserDefaults boolForKey:@"FlowTube.CopyRequested"]) {
            FTToast(@"Flow already has these subscriptions");
        }
        [NSUserDefaults.standardUserDefaults removeObjectForKey:@"FlowTube.CopyRequested"];
    }];
}

static void FTLoadResponse(UIViewController *self, SEL _cmd, id response) {
    ((void (*)(id, SEL, id))FTOriginalLoadResponse)(self, _cmd, response);
    @try { FTHarvestChannels(self, response); } @catch (__unused NSException *exception) {}
}

static void FTLoadInitialResponse(UIViewController *self, SEL _cmd, id response) {
    ((void (*)(id, SEL, id))FTOriginalLoadInitialResponse)(self, _cmd, response);
    @try { FTHarvestChannels(self, response); } @catch (__unused NSException *exception) {}
}

/// Hooks a one-object-argument void method only when it is one.
static void FTHookResponse(NSString *selector, IMP replacement, IMP *original) {
    Class cls = NSClassFromString(@"YTBrowseViewController");
    Method method = cls ? class_getInstanceMethod(cls, NSSelectorFromString(selector)) : NULL;
    if (method == NULL) return;
    NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
    if (signature.numberOfArguments != 3 || signature.methodReturnType[0] != 'v' || [signature getArgumentTypeAtIndex:2][0] != '@') return;
    FTHook(@"YTBrowseViewController", selector, replacement, original);
}

void FTInstallCommandHooks(void) {
    FTHookRouter(@"YTCommandRouter", @"handleCommand:entry:fromView:sender:", 4,
                 (IMP)FTRoute0, (IMP)FTRouteVoid0, &FTOriginal0);
    FTHookRouter(@"YTCommandRouter", @"handleCommand:entry:fromView:sender:completionBlock:", 5,
                 (IMP)FTRouteBlock0, (IMP)FTRouteBlockVoid0, &FTOriginalBlock0);
    FTHookRouter(@"YTAccountScopedCommandRouter", @"handleCommand:entry:fromView:sender:", 4,
                 (IMP)FTRoute1, (IMP)FTRouteVoid1, &FTOriginal1);
    FTHookRouter(@"YTAccountScopedCommandRouter", @"handleCommand:entry:fromView:sender:completionBlock:", 5,
                 (IMP)FTRouteBlock1, (IMP)FTRouteBlockVoid1, &FTOriginalBlock1);
    FTHookResponse(@"loadWithResponse:", (IMP)FTLoadResponse, &FTOriginalLoadResponse);
    FTHookResponse(@"loadWithInitialResponse:", (IMP)FTLoadInitialResponse, &FTOriginalLoadInitialResponse);
}
