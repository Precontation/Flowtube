// FlowTube: in local mode, YouTube's subscribe and like buttons show Flow's state.
//
// Signed out, YouTube draws every channel as "Subscribe" and every video as unrated, because it
// knows nothing — Flow does. Those buttons are Elements components drawn from the watch page's
// data (the watch-next response): renderers like SubscribeButtonRenderer / LikeButtonRenderer and
// state entities like SubscriptionStateEntity / LikeStatusEntity. Before YouTube hands that
// response to the watch page, FlowTube walks it (protobuf descriptors, any depth) and sets those
// fields from Flow's own subscriptions and ratings, so the page draws Flow's state.
//
// After a tap, YouTube doesn't redraw (it never ran the action), so the tapped subscribe button's
// label is switched in place; the full state shows the next time the video opens.

#import "FTRuntime.h"
#import "FTEngine.h"
#import "FTSettingsViewController.h"

NSString *FTCurrentVideoID(void);

#pragma mark - Flow's ratings

static NSString *const FTRatingsKey = @"FlowTube.Ratings";

/// "like" or "dislike" for a video Flow has a rating for.
NSString *FTRatingFor(NSString *videoID) {
    if (videoID.length == 0) return nil;
    NSDictionary *ratings = [NSUserDefaults.standardUserDefaults dictionaryForKey:FTRatingsKey];
    id rating = ratings[videoID];
    return [rating isKindOfClass:NSString.class] ? rating : nil;
}

void FTSetRating(NSString *videoID, NSString *rating) {
    if (videoID.length == 0) return;
    NSMutableDictionary *ratings = [([NSUserDefaults.standardUserDefaults dictionaryForKey:FTRatingsKey] ?: @{}) mutableCopy];
    if ([rating isEqualToString:@"like"] || [rating isEqualToString:@"dislike"]) ratings[videoID] = rating;
    else [ratings removeObjectForKey:videoID];
    if (ratings.count > 2000) {
        // Oldest entries aren't tracked; dropping arbitrary ones only forgets a button state.
        NSArray *keys = [ratings.allKeys subarrayWithRange:NSMakeRange(0, ratings.count - 2000)];
        [ratings removeObjectsForKeys:keys];
    }
    [NSUserDefaults.standardUserDefaults setObject:ratings forKey:FTRatingsKey];
}

#pragma mark - Walking protobuf messages

static Class FTMessageClass(void) {
    static Class cls;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cls = NSClassFromString(@"GPBMessage"); });
    return cls;
}

static BOOL FTHas(id message, NSString *field) {
    if (field.length == 0) return NO;
    NSString *name = [field hasSuffix:@"Array"] ? nil : [NSString stringWithFormat:@"has%@%@",
        [[field substringToIndex:1] uppercaseString], [field substringFromIndex:1]];
    if (name == nil) return YES;
    SEL has = NSSelectorFromString(name);
    if (![message respondsToSelector:has]) return YES; // no presence bit: read it
    return ((BOOL (*)(id, SEL))objc_msgSend)(message, has);
}

static id FTExtensionValue(id message, id descriptor) {
    SEL get = NSSelectorFromString(@"getExtension:");
    if (![message respondsToSelector:get]) return nil;
    @try {
        return ((id (*)(id, SEL, id))objc_msgSend)(message, get, descriptor);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

/// Visits every message reachable from `root` (fields and extensions), each once.
static void FTWalk(id message, NSUInteger depth, NSHashTable *seen, void (^visit)(id message)) {
    Class base = FTMessageClass();
    if (message == nil || base == Nil || ![message isKindOfClass:base]) return;
    if (depth > 64 || seen.count > 40000 || [seen containsObject:message]) return;
    [seen addObject:message];
    visit(message);
    id descriptor = [[message class] respondsToSelector:@selector(descriptor)]
        ? ((id (*)(id, SEL))objc_msgSend)([message class], @selector(descriptor)) : nil;
    for (id field in (NSArray *)(FTGet(descriptor, @"fields") ?: @[])) {
        if (FTGet(field, @"msgClass") == nil) continue;     // not a message field
        if ((NSInteger)FTDouble(field, @"fieldType") == 2) continue; // maps
        NSString *name = FTGet(field, @"name");
        if (![name isKindOfClass:NSString.class] || !FTHas(message, name)) continue;
        id value = FTValue(message, name);
        if ([value isKindOfClass:NSArray.class]) {
            for (id item in (NSArray *)value) FTWalk(item, depth + 1, seen, visit);
        } else {
            FTWalk(value, depth + 1, seen, visit);
        }
    }
    for (id extension in (NSArray *)(FTGet(message, @"extensionsCurrentlySet") ?: @[])) {
        id value = FTExtensionValue(message, extension);
        if ([value isKindOfClass:NSArray.class]) {
            for (id item in (NSArray *)value) FTWalk(item, depth + 1, seen, visit);
        } else {
            FTWalk(value, depth + 1, seen, visit);
        }
    }
}

static BOOL FTSetBool(id message, NSString *setter, BOOL value) {
    SEL selector = NSSelectorFromString(setter);
    if (![message respondsToSelector:selector]) return NO;
    NSMethodSignature *signature = [message methodSignatureForSelector:selector];
    if (signature.numberOfArguments != 3) return NO;
    char type = [signature getArgumentTypeAtIndex:2][0];
    if (type != 'B' && type != 'c') return NO;
    ((void (*)(id, SEL, BOOL))objc_msgSend)(message, selector, value);
    return YES;
}

static BOOL FTSetInt(id message, NSString *setter, int value) {
    SEL selector = NSSelectorFromString(setter);
    if (![message respondsToSelector:selector]) return NO;
    NSMethodSignature *signature = [message methodSignatureForSelector:selector];
    if (signature.numberOfArguments != 3) return NO;
    char type = [signature getArgumentTypeAtIndex:2][0];
    if (type != 'i' && type != 'I') return NO;
    ((void (*)(id, SEL, int))objc_msgSend)(message, selector, value);
    return YES;
}

#pragma mark - Applying Flow's state

static void FTApplyLocalState(id response) {
    if (!FTLocalModeEnabled() || response == nil) return;
    NSHashTable *seen = [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality];

    // First pass: whose page this is.
    __block NSString *videoID = nil;
    __block NSString *ownerChannel = nil;
    NSMutableSet<NSString *> *related = [NSMutableSet set];
    FTWalk(response, 0, seen, ^(id message) {
        NSString *name = NSStringFromClass([message class]);
        if (ownerChannel == nil && [name containsString:@"VideoOwnerRenderer"]) {
            id endpoint = FTValue(FTValue(message, @"navigationEndpoint"), @"browseEndpoint");
            NSString *browseID = FTValue(endpoint, @"browseId");
            if ([browseID isKindOfClass:NSString.class] && [browseID hasPrefix:@"UC"]) ownerChannel = browseID;
        }
        if (videoID == nil && [name hasSuffix:@"WatchEndpoint"]) {
            NSString *candidate = FTValue(message, @"videoId");
            if ([candidate isKindOfClass:NSString.class] && candidate.length == 11) videoID = candidate;
        }
        if ([name containsString:@"Like"] || [name containsString:@"Subscri"]) [related addObject:name];
    });
    id current = FTValue(FTValue(response, @"currentVideoEndpoint"), @"watchEndpoint");
    if ([FTValue(current, @"videoId") isKindOfClass:NSString.class]) videoID = FTValue(current, @"videoId");
    if (videoID.length == 0) videoID = FTCurrentVideoID();

    BOOL subscribed = ownerChannel.length && [FTEngine.shared.subscribedIDs containsObject:ownerChannel];
    NSString *rating = FTRatingFor(videoID);
    // YTLikeStatus: 0 like, 1 dislike, 2 neutral.
    int likeStatus = [rating isEqualToString:@"like"] ? 0 : [rating isEqualToString:@"dislike"] ? 1 : 2;

    // Second pass: set what the buttons read.
    __block NSUInteger subscribeSet = 0, likeSet = 0;
    [seen removeAllObjects];
    FTWalk(response, 0, seen, ^(id message) {
        NSString *name = NSStringFromClass([message class]);
        if ([name containsString:@"Subscri"] && ([name hasSuffix:@"StateEntity"] || [name hasSuffix:@"ButtonRenderer"] || [name hasSuffix:@"ButtonViewModel"])) {
            // A renderer that names its channel answers for that channel.
            NSString *channel = FTValue(message, @"channelId");
            BOOL value = [channel isKindOfClass:NSString.class] && channel.length
                ? [FTEngine.shared.subscribedIDs containsObject:channel] : subscribed;
            if (FTSetBool(message, @"setSubscribed:", value)) subscribeSet++;
        } else if ([name containsString:@"LikeStatusEntity"] || ([name hasSuffix:@"LikeButtonRenderer"] && ![name containsString:@"Comment"])) {
            if (FTSetInt(message, @"setLikeStatus:", likeStatus)) likeSet++;
        }
    });
    FTLog(@"watch page %@: channel %@ %@, rating %@ — set %lu subscribe, %lu like fields (seen: %@)",
          videoID ?: @"?", ownerChannel ?: @"?", subscribed ? @"followed" : @"not followed", rating ?: @"none",
          (unsigned long)subscribeSet, (unsigned long)likeSet,
          [[related.allObjects sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@","]);
}

static IMP FTOriginalSetWatchNext;
static IMP FTOriginalPrepareWatchNext;

static void FTSetWatchNext(id self, SEL _cmd, id response) {
    @try { FTApplyLocalState(response); } @catch (NSException *exception) { FTLog(@"button state failed: %@", exception.reason); }
    ((void (*)(id, SEL, id))FTOriginalSetWatchNext)(self, _cmd, response);
}

static void FTPrepareWatchNext(id self, SEL _cmd, id response) {
    @try { FTApplyLocalState(response); } @catch (NSException *exception) { FTLog(@"button state failed: %@", exception.reason); }
    ((void (*)(id, SEL, id))FTOriginalPrepareWatchNext)(self, _cmd, response);
}

static void FTHookOneObject(NSString *className, NSString *selector, IMP replacement, IMP *original) {
    Class cls = NSClassFromString(className);
    Method method = cls ? class_getInstanceMethod(cls, NSSelectorFromString(selector)) : NULL;
    if (method == NULL) {
        FTLog(@"button-state hook skipped: -[%@ %@] missing", className, selector);
        return;
    }
    NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
    if (signature.numberOfArguments != 3 || signature.methodReturnType[0] != 'v' || [signature getArgumentTypeAtIndex:2][0] != '@') return;
    FTHook(className, selector, replacement, original);
}

#pragma mark - The tapped button

/// Text drawn by Elements lives on Texture nodes; this finds them under a view.
static void FTEachTextNode(UIView *view, NSUInteger depth, void (^visit)(id node)) {
    if (view == nil || depth > 6) return;
    id node = FTValue(view, @"asyncdisplaykit_node");
    if ([node respondsToSelector:@selector(attributedText)] && [node respondsToSelector:NSSelectorFromString(@"setAttributedText:")]) {
        visit(node);
    }
    for (UIView *child in view.subviews) FTEachTextNode(child, depth + 1, visit);
}

/// Switches a tapped subscribe button's label between "Subscribe" and "Subscribed".
void FTShowSubscribed(UIView *button, BOOL subscribed) {
    if (![button isKindOfClass:UIView.class]) return;
    // The tap may come from a child of the button; the label is a little further up.
    UIView *root = button;
    for (NSUInteger i = 0; i < 3 && root.superview; i++) {
        NSString *label = [root.accessibilityLabel lowercaseString] ?: @"";
        if ([label containsString:@"subscribe"]) break;
        root = root.superview;
    }
    __block BOOL changed = NO;
    FTEachTextNode(root, 0, ^(id node) {
        NSAttributedString *text = ((NSAttributedString *(*)(id, SEL))objc_msgSend)(node, @selector(attributedText));
        NSString *plain = text.string.lowercaseString;
        NSString *replacement = nil;
        if (subscribed && [plain isEqualToString:@"subscribe"]) replacement = @"Subscribed";
        if (!subscribed && [plain isEqualToString:@"subscribed"]) replacement = @"Subscribe";
        if (replacement == nil) return;
        NSMutableAttributedString *updated = [text mutableCopy];
        [updated replaceCharactersInRange:NSMakeRange(0, updated.length) withString:replacement];
        ((void (*)(id, SEL, id))objc_msgSend)(node, NSSelectorFromString(@"setAttributedText:"), updated);
        changed = YES;
    });
    root.accessibilityLabel = subscribed ? @"Subscribed" : @"Subscribe";
    FTLog(@"subscribe button label %@", changed ? @"switched" : @"not found");
}

void FTInstallButtonStateHooks(void) {
    FTHookOneObject(@"YTPlayerViewController", @"setWatchNextResponse:", (IMP)FTSetWatchNext, &FTOriginalSetWatchNext);
    FTHookOneObject(@"YTWatchController", @"prepareWithWatchNextResponse:", (IMP)FTPrepareWatchNext, &FTOriginalPrepareWatchNext);
}
