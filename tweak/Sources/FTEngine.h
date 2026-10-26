// FlowTube: the Objective-C face of the FlowNeuro engine (Rust, include/flowneuro.h).
// All engine work runs on one serial background queue; completions arrive on the main queue.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// One card of the Flow feed.
@interface FTVideo : NSObject
@property (nonatomic, copy) NSString *videoID;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *channelName;
@property (nonatomic, copy, nullable) NSString *channelID;
@property (nonatomic, copy, nullable) NSString *thumbnailURL;
@property (nonatomic, copy, nullable) NSString *avatarURL;
@property (nonatomic, copy, nullable) NSString *viewCountText;
@property (nonatomic, copy, nullable) NSString *publishedText;
@property (nonatomic, copy) NSString *reason;
@property (nonatomic, copy) NSString *source;
@property (nonatomic) NSInteger durationSeconds; // 0 when unknown
@property (nonatomic) BOOL isLive;
@property (nonatomic, copy) NSDictionary *json; // as the engine gave it, for feedback
@property (nonatomic, readonly) NSString *durationText;
@property (nonatomic, readonly) NSString *metaText;
@end

@interface FTPage : NSObject
@property (nonatomic, copy) NSArray<FTVideo *> *videos;
@property (nonatomic) BOOL offline;
@property (nonatomic) BOOL coldStart;
@end

@interface FTEngine : NSObject
+ (instancetype)shared;
@property (nonatomic, readonly) BOOL ready;

/// A Home page: refresh (`more` NO) or the next page.
- (void)loadHomeMore:(BOOL)more completion:(void (^)(FTPage *_Nullable page))completion;
/// The local Subscriptions page: followed channels' uploads, newest first.
- (void)loadSubscriptions:(void (^)(FTPage *_Nullable page))completion;

/// Channels followed locally; readable from the main thread, kept current.
@property (atomic, readonly, copy) NSSet<NSString *> *subscribedIDs;
- (void)setSubscribed:(BOOL)subscribed channelID:(NSString *)channelID name:(nullable NSString *)name;
/// Adds channels (from the account's channel list) without removing any. Calls back with how many were new.
- (void)addSubscriptions:(NSArray<NSDictionary *> *)channels completion:(nullable void (^)(NSInteger added))completion;
/// "subscriptions", "likes" or "history".
- (void)library:(NSString *)kind completion:(void (^)(NSArray<NSDictionary *> *items))completion;
+ (FTVideo *)videoWithJSON:(NSDictionary *)json;

// Watching (called from the player hooks).
- (void)videoStarted:(NSString *)videoID title:(nullable NSString *)title channelName:(nullable NSString *)channelName channelID:(nullable NSString *)channelID description:(nullable NSString *)description;
- (void)progressForVideo:(NSString *)videoID position:(double)position duration:(double)duration playedDelta:(double)playedDelta isLive:(BOOL)isLive;
- (void)videoEnded;

// Signals.
- (void)feedback:(NSString *)action videoID:(NSString *)videoID video:(nullable NSDictionary *)video;
- (void)blockChannel:(NSString *)channelID;
- (void)chooseTopics:(NSArray<NSString *> *)topics;
- (void)import:(NSString *)kind contents:(NSString *)contents completion:(void (^)(NSInteger count))completion;
- (void)stats:(void (^)(NSDictionary *_Nullable stats))completion;
- (void)topicCatalog:(void (^)(NSArray<NSDictionary *> *catalog))completion;
- (void)setLearningPaused:(BOOL)paused;
- (void)reset:(void (^)(void))completion;
- (void)save;
@end

NS_ASSUME_NONNULL_END
