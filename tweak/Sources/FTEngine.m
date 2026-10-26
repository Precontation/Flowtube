#import "FTEngine.h"
#import "FTRuntime.h"
#import "flowneuro.h"
#import <UIKit/UIKit.h>

static NSString *FTTake(char *json) {
    if (json == NULL) return nil;
    NSString *text = [NSString stringWithUTF8String:json];
    fn_free(json);
    return text;
}

static id FTParse(NSString *text) {
    if (text.length == 0) return nil;
    return [NSJSONSerialization JSONObjectWithData:[text dataUsingEncoding:NSUTF8StringEncoding]
                                           options:0
                                             error:nil];
}

static NSString *FTJSON(id object) {
    if (object == nil) return nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
}

static NSString *FTStr(id value) {
    return [value isKindOfClass:NSString.class] ? value : nil;
}

#pragma mark - FTVideo

@implementation FTVideo

+ (instancetype)videoWithJSON:(NSDictionary *)json {
    FTVideo *video = [FTVideo new];
    video.json = json;
    video.videoID = FTStr(json[@"id"]) ?: @"";
    video.title = FTStr(json[@"title"]) ?: @"";
    video.channelName = FTStr(json[@"channelName"]) ?: @"";
    video.channelID = FTStr(json[@"channelId"]);
    video.thumbnailURL = FTStr(json[@"thumbnailUrl"]);
    video.avatarURL = FTStr(json[@"channelAvatarUrl"]);
    video.viewCountText = FTStr(json[@"viewCountText"]);
    video.publishedText = FTStr(json[@"publishedText"]);
    video.reason = FTStr(json[@"reason"]) ?: @"";
    video.source = FTStr(json[@"source"]) ?: @"";
    id duration = json[@"durationSeconds"];
    video.durationSeconds = [duration isKindOfClass:NSNumber.class] ? [duration integerValue] : 0;
    video.isLive = [json[@"isLive"] boolValue];
    return video;
}

- (NSString *)durationText {
    if (self.isLive) return @"LIVE";
    NSInteger s = self.durationSeconds;
    if (s <= 0) return @"";
    if (s >= 3600) return [NSString stringWithFormat:@"%ld:%02ld:%02ld", (long)(s / 3600), (long)(s / 60 % 60), (long)(s % 60)];
    return [NSString stringWithFormat:@"%ld:%02ld", (long)(s / 60), (long)(s % 60)];
}

- (NSString *)metaText {
    NSMutableArray *parts = [NSMutableArray array];
    if (self.channelName.length) [parts addObject:self.channelName];
    if (self.viewCountText.length) [parts addObject:self.viewCountText];
    if (self.publishedText.length) [parts addObject:self.publishedText];
    return [parts componentsJoinedByString:@" · "];
}

@end

@implementation FTPage
@end

#pragma mark - FTEngine

@interface FTEngine ()
@property (nonatomic) dispatch_queue_t queue;
@property (nonatomic) NSURLSession *session;
@property (nonatomic, readwrite) BOOL ready;
@property (nonatomic, copy) NSString *currentVideo;
@property (nonatomic) NSTimeInterval lastSave;
@property (atomic, readwrite, copy) NSSet<NSString *> *subscribedIDs;
@end

@implementation FTEngine

+ (instancetype)shared {
    static FTEngine *engine;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ engine = [FTEngine new]; });
    return engine;
}

- (instancetype)init {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("flowtube.engine", DISPATCH_QUEUE_SERIAL);
        // Logged out, no cookies, no cache: candidate fetching never touches the account.
        NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        config.HTTPCookieStorage = nil;
        config.HTTPShouldSetCookies = NO;
        config.URLCache = nil;
        config.timeoutIntervalForRequest = 10;
        config.timeoutIntervalForResource = 20;
        config.HTTPMaximumConnectionsPerHost = 6;
        _session = [NSURLSession sessionWithConfiguration:config];
        dispatch_async(_queue, ^{ [self open]; });
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(save)
                                                   name:UIApplicationDidEnterBackgroundNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(terminating)
                                                   name:UIApplicationWillTerminateNotification object:nil];
    }
    return self;
}

- (void)open {
    NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory
                                                         inDomains:NSUserDomainMask].firstObject;
    NSURL *dir = [support URLByAppendingPathComponent:@"FlowTube" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *language = NSLocale.preferredLanguages.firstObject ?: @"en";
    NSString *region = [NSLocale.currentLocale objectForKey:NSLocaleCountryCode] ?: @"US";
    self.ready = fn_open(dir.path.fileSystemRepresentation, language.UTF8String, region.UTF8String);
    FTLog(@"engine %@ at %@", self.ready ? @"ready" : @"FAILED", dir.path);
    [self refreshSubscribedIDs];
}

/// On the engine queue.
- (void)refreshSubscribedIDs {
    NSArray *subs = self.ready ? FTParse(FTTake(fn_library("subscriptions"))) : nil;
    NSMutableSet *ids = [NSMutableSet set];
    for (NSDictionary *sub in [subs isKindOfClass:NSArray.class] ? subs : @[]) {
        if ([sub isKindOfClass:NSDictionary.class] && FTStr(sub[@"id"])) [ids addObject:sub[@"id"]];
    }
    self.subscribedIDs = ids;
}

+ (FTVideo *)videoWithJSON:(NSDictionary *)json {
    return [FTVideo videoWithJSON:json];
}

- (void)save {
    dispatch_async(self.queue, ^{
        if (self.ready) fn_save();
        self.lastSave = NSDate.timeIntervalSinceReferenceDate;
    });
}

- (void)saveSoon {
    // Called on the engine queue after learning; writes at most every 20 seconds.
    if (NSDate.timeIntervalSinceReferenceDate - self.lastSave > 20) {
        fn_save();
        self.lastSave = NSDate.timeIntervalSinceReferenceDate;
    }
}

- (void)terminating {
    dispatch_sync(self.queue, ^{
        if (!self.ready) return;
        fn_watch_end();
        fn_save();
    });
}

#pragma mark Networking

/// Sends a plan's requests, at most six at once, and calls back with every answer.
- (void)send:(NSArray<NSDictionary *> *)requests completion:(void (^)(NSArray<NSDictionary *> *answers))completion {
    if (requests.count == 0) {
        completion(@[]);
        return;
    }
    NSMutableArray *answers = [NSMutableArray array];
    dispatch_group_t group = dispatch_group_create();
    dispatch_semaphore_t slots = dispatch_semaphore_create(6);
    dispatch_queue_t gate = dispatch_queue_create("flowtube.net", DISPATCH_QUEUE_CONCURRENT);
    for (NSDictionary *spec in requests) {
        NSURL *url = [NSURL URLWithString:FTStr(spec[@"url"]) ?: @""];
        NSString *requestID = FTStr(spec[@"id"]);
        if (url == nil || requestID == nil) continue;
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
        request.HTTPMethod = @"POST";
        request.HTTPBody = [FTStr(spec[@"body"]) dataUsingEncoding:NSUTF8StringEncoding];
        for (NSArray *header in spec[@"headers"]) {
            if ([header isKindOfClass:NSArray.class] && header.count == 2) {
                [request setValue:header[1] forHTTPHeaderField:header[0]];
            }
        }
        dispatch_group_enter(group);
        dispatch_async(gate, ^{
            dispatch_semaphore_wait(slots, DISPATCH_TIME_FOREVER);
            [[self.session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
                NSString *body = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
                if (error == nil && body != nil) {
                    @synchronized (answers) {
                        [answers addObject:@{ @"id": requestID, @"status": @(status), @"body": body }];
                    }
                }
                dispatch_semaphore_signal(slots);
                dispatch_group_leave(group);
            }] resume];
        });
    }
    dispatch_group_notify(group, self.queue, ^{ completion(answers); });
}

#pragma mark Home

- (void)loadHomeMore:(BOOL)more completion:(void (^)(FTPage *))completion {
    [self runPlan:^char *{ return fn_plan_home(more); } completion:completion];
}

- (void)loadSubscriptions:(void (^)(FTPage *))completion {
    [self runPlan:^char *{ return fn_plan_subscriptions(); } completion:completion];
}

/// Plans a page, sends its requests and assembles the answers.
- (void)runPlan:(char *(^)(void))planner completion:(void (^)(FTPage *))completion {
    void (^finish)(FTPage *) = ^(FTPage *page) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(page); });
    };
    dispatch_async(self.queue, ^{
        if (!self.ready) { finish(nil); return; }
        NSDictionary *plan = FTParse(FTTake(planner()));
        NSNumber *loadID = plan[@"loadId"];
        if (![loadID isKindOfClass:NSNumber.class]) { finish(nil); return; }
        [self send:plan[@"requests"] completion:^(NSArray<NSDictionary *> *answers) {
            // Runs on the engine queue.
            NSString *answersJSON = FTJSON(answers) ?: @"[]";
            NSDictionary *result = FTParse(FTTake(fn_assemble(loadID.unsignedLongLongValue, answersJSON.UTF8String)));
            [self saveSoon];
            if (![result isKindOfClass:NSDictionary.class]) { finish(nil); return; }
            FTPage *page = [FTPage new];
            NSMutableArray *videos = [NSMutableArray array];
            for (NSDictionary *item in result[@"items"]) {
                if ([item isKindOfClass:NSDictionary.class]) [videos addObject:[FTVideo videoWithJSON:item]];
            }
            page.videos = videos;
            page.offline = [result[@"offline"] boolValue];
            page.coldStart = [result[@"coldStart"] boolValue];
            finish(page);
        }];
    });
}

#pragma mark Watching

- (void)videoStarted:(NSString *)videoID title:(NSString *)title channelName:(NSString *)channelName channelID:(NSString *)channelID description:(NSString *)description {
    dispatch_async(self.queue, ^{
        if (!self.ready || videoID.length == 0) return;
        if ([self.currentVideo isEqualToString:videoID]) return;
        self.currentVideo = videoID;
        // Details the player already has open the session; the watch page adds the description
        // when the player had none, and the related list co-watch learns from.
        NSMutableDictionary *report = [@{ @"videoId": videoID, @"position": @0, @"duration": @0, @"playedDelta": @0 } mutableCopy];
        if (title.length) report[@"title"] = title;
        if (channelName.length) report[@"channelName"] = channelName;
        if (channelID.length) report[@"channelId"] = channelID;
        if (description.length) {
            // A watch page with only these fields gives the engine the description right away.
            NSDictionary *page = @{ @"contents": @{ @"twoColumnWatchNextResults": @{ @"results": @{ @"results": @{ @"contents": @[
                @{ @"videoPrimaryInfoRenderer": @{ @"title": @{ @"simpleText": title ?: @"" } } },
                @{ @"videoSecondaryInfoRenderer": @{
                    @"owner": @{ @"videoOwnerRenderer": @{ @"title": @{ @"simpleText": channelName ?: @"" },
                                                          @"navigationEndpoint": @{ @"browseEndpoint": @{ @"browseId": channelID ?: @"" } } } },
                    @"attributedDescription": @{ @"content": description } } } ] } } } } };
            fn_watch_page(videoID.UTF8String, (FTJSON(page) ?: @"{}").UTF8String);
        }
        fn_watch_progress((FTJSON(report) ?: @"{}").UTF8String);
        NSDictionary *spec = FTParse(FTTake(fn_watch_page_request(videoID.UTF8String)));
        if (spec == nil) return;
        [self send:@[spec] completion:^(NSArray<NSDictionary *> *answers) {
            NSDictionary *answer = answers.firstObject;
            NSInteger status = [answer[@"status"] integerValue];
            if (answer == nil || status < 200 || status >= 300) return;
            fn_watch_page(videoID.UTF8String, [answer[@"body"] UTF8String]);
        }];
    });
}

- (void)progressForVideo:(NSString *)videoID position:(double)position duration:(double)duration playedDelta:(double)playedDelta isLive:(BOOL)isLive {
    dispatch_async(self.queue, ^{
        if (!self.ready || videoID.length == 0) return;
        NSDictionary *report = @{ @"videoId": videoID, @"position": @(position), @"duration": @(duration),
                                  @"playedDelta": @(playedDelta), @"isLive": @(isLive) };
        fn_watch_progress((FTJSON(report) ?: @"{}").UTF8String);
    });
}

- (void)videoEnded {
    dispatch_async(self.queue, ^{
        if (!self.ready) return;
        fn_watch_end();
        self.currentVideo = nil;
        [self saveSoon];
    });
}

#pragma mark Signals

- (void)feedback:(NSString *)action videoID:(NSString *)videoID video:(NSDictionary *)video {
    dispatch_async(self.queue, ^{
        if (!self.ready || videoID.length == 0) return;
        NSString *videoJSON = video ? FTJSON(video) : nil;
        fn_feedback(videoID.UTF8String, action.UTF8String, videoJSON.UTF8String);
        [self saveSoon];
    });
}

- (void)setSubscribed:(BOOL)subscribed channelID:(NSString *)channelID name:(NSString *)name {
    dispatch_async(self.queue, ^{
        if (!self.ready || channelID.length == 0) return;
        fn_subscription(channelID.UTF8String, (name ?: @"").UTF8String, subscribed);
        fn_save();
        [self refreshSubscribedIDs];
    });
}

- (void)addSubscriptions:(NSArray<NSDictionary *> *)channels completion:(void (^)(NSInteger))completion {
    dispatch_async(self.queue, ^{
        NSInteger added = -1;
        if (self.ready) {
            // NewPipe's export shape, which the engine's importer reads.
            NSMutableArray *list = [NSMutableArray array];
            for (NSDictionary *channel in channels) {
                NSString *channelID = FTStr(channel[@"id"]);
                if (channelID.length == 0) continue;
                [list addObject:@{ @"url": [@"https://www.youtube.com/channel/" stringByAppendingString:channelID],
                                   @"name": FTStr(channel[@"name"]) ?: @"" }];
            }
            NSString *json = FTJSON(@{ @"subscriptions": list }) ?: @"{}";
            added = (NSInteger)fn_import("subscriptions-json", json.UTF8String);
            fn_save();
            [self refreshSubscribedIDs];
        }
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(added); });
    });
}

- (void)library:(NSString *)kind completion:(void (^)(NSArray<NSDictionary *> *))completion {
    dispatch_async(self.queue, ^{
        NSArray *items = self.ready ? FTParse(FTTake(fn_library(kind.UTF8String))) : nil;
        dispatch_async(dispatch_get_main_queue(), ^{ completion([items isKindOfClass:NSArray.class] ? items : @[]); });
    });
}

- (void)blockChannel:(NSString *)channelID {
    dispatch_async(self.queue, ^{
        if (self.ready && channelID.length) fn_block_channel(channelID.UTF8String);
    });
}

- (void)chooseTopics:(NSArray<NSString *> *)topics {
    dispatch_async(self.queue, ^{
        if (!self.ready) return;
        fn_choose_topics((FTJSON(topics) ?: @"[]").UTF8String);
        fn_save();
    });
}

- (void)import:(NSString *)kind contents:(NSString *)contents completion:(void (^)(NSInteger))completion {
    dispatch_async(self.queue, ^{
        NSInteger count = self.ready ? (NSInteger)fn_import(kind.UTF8String, contents.UTF8String) : -1;
        if (count >= 0) fn_save();
        [self refreshSubscribedIDs];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(count); });
    });
}

- (void)stats:(void (^)(NSDictionary *))completion {
    dispatch_async(self.queue, ^{
        NSDictionary *stats = self.ready ? FTParse(FTTake(fn_stats())) : nil;
        dispatch_async(dispatch_get_main_queue(), ^{ completion(stats); });
    });
}

- (void)topicCatalog:(void (^)(NSArray<NSDictionary *> *))completion {
    dispatch_async(self.queue, ^{
        NSArray *catalog = FTParse(FTTake(fn_topic_catalog()));
        dispatch_async(dispatch_get_main_queue(), ^{ completion([catalog isKindOfClass:NSArray.class] ? catalog : @[]); });
    });
}

- (void)setLearningPaused:(BOOL)paused {
    dispatch_async(self.queue, ^{
        if (!self.ready) return;
        fn_set_learning_paused(paused);
        fn_save();
    });
}

- (void)reset:(void (^)(void))completion {
    dispatch_async(self.queue, ^{
        if (self.ready) fn_reset();
        [self refreshSubscribedIDs];
        dispatch_async(dispatch_get_main_queue(), completion);
    });
}

@end
