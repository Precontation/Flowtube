#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class FTFeedViewController;

@protocol FTFeedHost <NSObject>
/// Opens a video in YouTube's own player.
- (void)feed:(FTFeedViewController *)feed openVideoID:(NSString *)videoID;
/// The viewer chose YouTube's feed instead.
- (void)feedWantsYouTube:(FTFeedViewController *)feed;
@end

typedef NS_ENUM(NSInteger, FTFeedKind) {
    FTFeedKindForYou,        // Flow's algorithm
    FTFeedKindSubscriptions, // followed channels' uploads, newest first
};

@interface FTFeedViewController : UIViewController
@property (nonatomic) FTFeedKind kind;
/// Shown as YouTube's Subscriptions tab (local mode): subscriptions only, no switch to YouTube.
@property (nonatomic) BOOL subscriptionsTab;
@property (nonatomic, weak, nullable) id<FTFeedHost> host;
/// Space YouTube's own bars take over the feed.
@property (nonatomic) UIEdgeInsets chromeInsets;
/// Shown modally (fallback entry): adds a close button instead of the YouTube switch.
@property (nonatomic) BOOL standalone;
- (void)refresh;
@end

/// Thumbnails and avatars, cached in memory.
@interface FTImages : NSObject
+ (void)loadURL:(nullable NSString *)url into:(UIImageView *)imageView fallback:(nullable NSString *)fallback;
@end

UIColor *FTBackgroundColor(void);

NS_ASSUME_NONNULL_END
