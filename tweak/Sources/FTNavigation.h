// FlowTube: moving around YouTube with its own commands, and small confirmations.
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// The top-most view controller of the foreground window.
UIViewController *_Nullable FTTopViewController(void);

/// Sends a YTICommand up YouTube's responder chain, as tapping one of its own buttons would.
BOOL FTSendCommand(id command, id _Nullable responder, UIView *_Nullable view);

/// Plays a video in YouTube's player (falls back to the app's own URL handling).
void FTOpenVideo(NSString *videoID, id _Nullable responder, UIView *_Nullable view);
/// Opens a channel page, or any browse page ("FEchannels").
void FTOpenBrowse(NSString *browseID, id _Nullable responder);

/// A short message at the bottom of the screen.
void FTToast(NSString *message);

NS_ASSUME_NONNULL_END
