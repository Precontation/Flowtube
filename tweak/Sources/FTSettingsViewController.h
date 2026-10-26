#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const FTHomeEnabledKey;
extern NSString *const FTHomeModeChangedNotification;
BOOL FTHomeEnabled(void);
void FTSetHomeEnabled(BOOL enabled);

/// Local mode (off by default): Flow keeps subscriptions, likes and history on the device and
/// never sends them to YouTube, like Flow itself. Meant to be used with YouTube signed out.
BOOL FTLocalModeEnabled(void);
void FTSetLocalModeEnabled(BOOL enabled);

/// The library: subscriptions, liked videos and history kept by Flow.
@interface FTLibraryViewController : UITableViewController
@end

@interface FTSettingsViewController : UITableViewController
/// Something the feed depends on changed (an import, a reset).
@property (nonatomic, copy, nullable) void (^onChange)(void);
@end

/// Flow's onboarding: pick a few interests from its topic catalog.
@interface FTTopicsViewController : UICollectionViewController
@property (nonatomic, copy, nullable) void (^onDone)(void);
@end

NS_ASSUME_NONNULL_END
