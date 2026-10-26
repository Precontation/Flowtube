// FlowTube: what the viewer watches and likes, fed to the engine as Flow's player would.
//
// Playback is sampled every two seconds from the visible YTPlayerViewController rather than by
// hooking its time callbacks: those fire many times a second, their argument type differs between
// YouTube versions, and YTKACE/SponsorBlock already hook them. Sampling needs only getters.

#import "FTRuntime.h"
#import "FTEngine.h"

void FTSetRating(NSString *videoID, NSString *rating);

static NSHashTable *FTPlayers;
static IMP FTOriginalPlayerViewDidLoad;
static IMP FTOriginalNotifyLike;
static IMP FTOriginalNotifyLikeImpl;

static NSString *FTWatchingID;
static NSString *FTWatchingChannelID;
static NSString *FTWatchingChannelName;

NSString *FTCurrentVideoID(void) { return FTWatchingID; }
NSString *FTCurrentChannelID(void) { return FTWatchingChannelID; }
NSString *FTCurrentChannelName(void) { return FTWatchingChannelName; }
static double FTLastPosition = -1;
static double FTPendingPlayed;
static NSTimeInterval FTLastReport;
static NSTimeInterval FTLastSeenPlayer;

static void FTPlayerViewDidLoad(UIViewController *self, SEL _cmd) {
    ((void (*)(id, SEL))FTOriginalPlayerViewDidLoad)(self, _cmd);
    @synchronized (FTPlayers) {
        [FTPlayers addObject:self];
    }
}

/// The player the viewer is watching: on screen, not a muted inline preview, not an ad.
static UIViewController *FTActivePlayer(void) {
    NSArray *players;
    @synchronized (FTPlayers) {
        players = FTPlayers.allObjects;
    }
    for (UIViewController *player in players) {
        if (!player.isViewLoaded || player.view.window == nil) continue;
        if (FTBool(player, @"isInlinePlaybackActive")) continue;
        // Muted autoplay previews (search results, channel pages) are not watches.
        if (FTBool(FTGet(player, @"activeVideo"), @"isMuted")) continue;
        if (FTString(player, @[@"currentVideoID", @"contentVideoID"]) == nil) continue;
        return player;
    }
    return nil;
}

/// What the player already knows about the video (`videoDetails` of its player response).
static id FTVideoDetails(UIViewController *player) {
    id singleVideo = FTGet(FTGet(player, @"activeVideo"), @"singleVideo");
    id response = FTGet(FTGet(singleVideo, @"playbackData"), @"playerResponse");
    id data = FTGet(response, @"playerData") ?: response;
    return FTValue(data, @"videoDetails");
}

static void FTSample(void) {
    UIViewController *player = FTActivePlayer();
    NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
    if (player == nil) {
        // The player closed: a viewing missing for half a minute is over.
        if (FTWatchingID != nil && now - FTLastSeenPlayer > 30) {
            [FTEngine.shared videoEnded];
            FTWatchingID = nil;
            FTWatchingChannelID = nil;
            FTWatchingChannelName = nil;
        }
        return;
    }
    FTLastSeenPlayer = now;
    if (FTBool(player, @"isPlayingAd")) return;
    NSString *videoID = FTString(player, @[@"currentVideoID", @"contentVideoID"]);
    double position = FTDouble(player, @"currentVideoMediaTime");
    double duration = FTDouble(player, @"currentVideoTotalMediaTime");
    id details = FTVideoDetails(player);
    BOOL isLive = [FTValue(details, @"isLive") boolValue] || [FTValue(details, @"isLiveContent") boolValue];

    if (![videoID isEqualToString:FTWatchingID]) {
        FTWatchingID = videoID;
        FTLastPosition = position;
        FTPendingPlayed = 0;
        FTLastReport = now;
        NSString *detailsID = FTValue(details, @"videoId");
        BOOL matches = [detailsID isKindOfClass:NSString.class] && [detailsID isEqualToString:videoID];
        NSString *(^text)(NSString *) = ^NSString *(NSString *key) {
            id value = matches ? FTValue(details, key) : nil;
            return [value isKindOfClass:NSString.class] ? value : nil;
        };
        FTWatchingChannelID = text(@"channelId") ?: FTString(player, @[@"channelID"]);
        FTWatchingChannelName = text(@"author");
        [FTEngine.shared videoStarted:videoID
                                title:text(@"title")
                          channelName:FTWatchingChannelName
                            channelID:FTWatchingChannelID
                          description:text(@"shortDescription")];
        return;
    }
    // Time that moved forward at about playback speed was watched; a jump is a seek.
    double moved = position - FTLastPosition;
    if (moved > 0 && moved <= 2.0 * 2.5) {
        FTPendingPlayed += moved;
    }
    FTLastPosition = position;
    if (now - FTLastReport >= 6 && (FTPendingPlayed > 0 || duration > 0)) {
        [FTEngine.shared progressForVideo:videoID position:position duration:duration
                              playedDelta:FTPendingPlayed isLive:isLive];
        FTPendingPlayed = 0;
        FTLastReport = now;
    }
}

#pragma mark Likes

static void FTNoteLike(int status, NSString *videoID) {
    if (![videoID isKindOfClass:NSString.class] || videoID.length == 0) return;
    // YTLikeStatus: 0 like, 1 dislike, 2 neutral.
    NSString *action = status == 0 ? @"like" : status == 1 ? @"dislike" : @"unlike";
    [FTEngine.shared feedback:action videoID:videoID video:nil];
    FTSetRating(videoID, action);
}

static void FTNotifyLike(id self, SEL _cmd, int status, NSString *videoID) {
    ((void (*)(id, SEL, int, id))FTOriginalNotifyLike)(self, _cmd, status, videoID);
    FTNoteLike(status, videoID);
}

static void FTNotifyLikeImpl(id self, SEL _cmd, int status, NSString *videoID) {
    ((void (*)(id, SEL, int, id))FTOriginalNotifyLikeImpl)(self, _cmd, status, videoID);
    FTNoteLike(status, videoID);
}

/// Hooks only when the method takes (int, object), as Return YouTube Dislike's headers say.
static void FTHookLike(NSString *className, IMP replacement, IMP *original) {
    Class cls = NSClassFromString(className);
    Method method = cls ? class_getInstanceMethod(cls, @selector(notifyVideoLikeStatus:withID:)) : NULL;
    if (method == NULL) return;
    NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
    if (signature.numberOfArguments != 4 || [signature getArgumentTypeAtIndex:2][0] != 'i'
        || [signature getArgumentTypeAtIndex:3][0] != '@') {
        FTLog(@"like hook skipped: %@ has another signature", className);
        return;
    }
    // A subclass that inherits the method from YTLikeService is hooked through its parent.
    Class owner = cls;
    while (class_getSuperclass(owner) && class_getInstanceMethod(class_getSuperclass(owner), @selector(notifyVideoLikeStatus:withID:)) == method) {
        owner = class_getSuperclass(owner);
    }
    if (owner != cls) return;
    FTHook(className, @"notifyVideoLikeStatus:withID:", replacement, original);
}

void FTInstallPlayerHooks(void) {
    FTPlayers = [NSHashTable weakObjectsHashTable];
    FTHook(@"YTPlayerViewController", @"viewDidLoad", (IMP)FTPlayerViewDidLoad, &FTOriginalPlayerViewDidLoad);
    FTHookLike(@"YTLikeService", (IMP)FTNotifyLike, &FTOriginalNotifyLike);
    FTHookLike(@"YTLikeServiceImpl", (IMP)FTNotifyLikeImpl, &FTOriginalNotifyLikeImpl);
    dispatch_async(dispatch_get_main_queue(), ^{
        NSTimer *timer = [NSTimer timerWithTimeInterval:2.0 repeats:YES block:^(__unused NSTimer *t) {
            @autoreleasepool {
                FTSample();
            }
        }];
        timer.tolerance = 0.5;
        [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
    });
}
