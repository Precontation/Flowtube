// FlowTube: Flow's feed on YouTube's Home.
//
// The Home tab is the YTBrowseViewController whose browse id is FEwhat_to_watch. Flow's feed sits
// over YouTube's own feed, in exactly the frame and insets YouTube gives its collection view, so
// YouTube's top bar, chips and tab bar (and YTKACE's changes to them) are left alone. The tab bar
// is never touched. If Home can't be found (a future YouTube), a small Flow button appears instead.

#import "FTRuntime.h"
#import "FTEngine.h"
#import "FTFeedViewController.h"
#import "FTSettingsViewController.h"
#import "FTNavigation.h"

void FTInstallPlayerHooks(void);
void FTInstallCommandHooks(void);
void FTInstallButtonStateHooks(void);

static IMP FTOriginalBrowseDidAppear;
static IMP FTOriginalBrowseLayout;
static const void *FTHostKey = &FTHostKey;
static BOOL FTFoundHome;

#pragma mark - Host

/// Owns the Flow feed on one Home controller.
@interface FTHomeHost : NSObject <FTFeedHost>
@property (nonatomic, weak) UIViewController *browse;
/// YouTube's Subscriptions tab rather than Home: shown in local mode only, with no switch back.
@property (nonatomic) BOOL subscriptionsTab;
@property (nonatomic) FTFeedViewController *feed;
@property (nonatomic) UIButton *flowPill;
@property (nonatomic, weak) UIScrollView *youtubeFeed;
- (void)layout;
@end

@implementation FTHomeHost

- (instancetype)initWithBrowse:(UIViewController *)browse subscriptionsTab:(BOOL)subscriptionsTab {
    if ((self = [super init])) {
        _browse = browse;
        _subscriptionsTab = subscriptionsTab;
        _feed = [FTFeedViewController new];
        _feed.subscriptionsTab = subscriptionsTab;
        _feed.host = self;
        [browse addChildViewController:_feed];
        [browse.view addSubview:_feed.view];
        [_feed didMoveToParentViewController:browse];

        UIButtonConfiguration *config = [UIButtonConfiguration filledButtonConfiguration];
        config.title = @"Flow";
        config.image = [UIImage systemImageNamed:@"rectangle.stack"];
        config.imagePadding = 6;
        config.baseForegroundColor = UIColor.systemBackgroundColor;
        config.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
        config.baseBackgroundColor = UIColor.labelColor;
        _flowPill = [UIButton buttonWithConfiguration:config primaryAction:nil];
        _flowPill.accessibilityLabel = @"Show Flow feed";
        [_flowPill addTarget:self action:@selector(showFlow) forControlEvents:UIControlEventTouchUpInside];
        [browse.view addSubview:_flowPill];

        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(modeChanged)
                                                   name:FTHomeModeChangedNotification object:nil];
        [self apply];
    }
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

/// YouTube's own feed: the largest scroll view on Home that is not Flow's.
- (UIScrollView *)findYouTubeFeed {
    UIScrollView *best = nil;
    CGFloat bestArea = 0;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:self.browse.view];
    NSUInteger visited = 0;
    while (queue.count && visited < 400) {
        UIView *view = queue.firstObject;
        [queue removeObjectAtIndex:0];
        visited++;
        if (view == self.feed.view || view == self.flowPill) continue;
        if ([view isKindOfClass:UICollectionView.class] || [view isKindOfClass:UITableView.class]) {
            CGRect frame = [view convertRect:view.bounds toView:self.browse.view];
            CGFloat area = CGRectGetWidth(frame) * CGRectGetHeight(frame);
            // Horizontal strips (the chips) are not the feed.
            if (area > bestArea && CGRectGetHeight(frame) > CGRectGetHeight(self.browse.view.bounds) * 0.5) {
                best = (UIScrollView *)view;
                bestArea = area;
            }
            continue;
        }
        [queue addObjectsFromArray:view.subviews];
    }
    return best;
}

- (void)layout {
    UIView *root = self.browse.view;
    if (root == nil) return;
    if (self.youtubeFeed == nil || self.youtubeFeed.window == nil) self.youtubeFeed = [self findYouTubeFeed];
    UIScrollView *youtube = self.youtubeFeed;
    UIView *feedView = self.feed.view;
    CGRect frame;
    UIEdgeInsets insets;
    if (youtube != nil && youtube.superview != nil) {
        // Directly above YouTube's feed, in its frame: whatever YouTube draws over its feed (the
        // top bar, chips, floating buttons) stays over Flow too, and its insets clear them.
        UIView *container = youtube.superview;
        if (feedView.superview != container
            || [container.subviews indexOfObject:feedView] < [container.subviews indexOfObject:youtube]) {
            [container insertSubview:feedView aboveSubview:youtube];
        }
        feedView.frame = youtube.frame;
        insets = youtube.adjustedContentInset;
        insets.top = MAX(0, insets.top);
        insets.bottom = MAX(0, insets.bottom);
        frame = [container convertRect:youtube.frame toView:root];
    } else {
        if (feedView.superview != root) [root addSubview:feedView];
        frame = root.bounds;
        insets = root.safeAreaInsets;
        feedView.frame = frame;
        [root bringSubviewToFront:feedView];
    }
    self.feed.chromeInsets = UIEdgeInsetsMake(insets.top, 0, insets.bottom, 0);

    [self.flowPill sizeToFit];
    CGSize pill = self.flowPill.bounds.size;
    CGFloat bottom = CGRectGetMaxY(frame) - insets.bottom - pill.height - 16;
    self.flowPill.frame = CGRectMake(CGRectGetMaxX(frame) - pill.width - 16, bottom, pill.width, pill.height);
    [root bringSubviewToFront:self.flowPill];
}

- (void)apply {
    BOOL flow = self.subscriptionsTab ? FTLocalModeEnabled() : FTHomeEnabled();
    self.feed.view.hidden = !flow;
    self.flowPill.hidden = flow || self.subscriptionsTab;
    if (flow && self.subscriptionsTab && self.feed.isViewLoaded) [self.feed refresh];
    // YouTube's own feed stays loaded underneath; it just isn't reachable while Flow shows.
    self.youtubeFeed.accessibilityElementsHidden = flow;
    self.youtubeFeed.scrollsToTop = !flow;
    self.feed.view.accessibilityViewIsModal = NO;
    [self layout];
}

- (void)modeChanged {
    [UIView transitionWithView:self.browse.view duration:0.2 options:UIViewAnimationOptionTransitionCrossDissolve animations:^{
        [self apply];
    } completion:nil];
}

- (void)showFlow {
    FTSetHomeEnabled(YES);
}

- (void)feedWantsYouTube:(FTFeedViewController *)feed {
    FTSetHomeEnabled(NO);
}

- (void)feed:(FTFeedViewController *)feed openVideoID:(NSString *)videoID {
    FTOpenVideo(videoID, self.browse, feed.view);
}

@end

#pragma mark - Hooks

static FTHomeHost *FTHostFor(UIViewController *controller, BOOL create) {
    FTHomeHost *host = objc_getAssociatedObject(controller, FTHostKey);
    if (host != nil || !create) return host;
    NSString *browseID = FTString(controller, @[@"browseID", @"browseIdentifier"]);
    BOOL home = [browseID isEqualToString:@"FEwhat_to_watch"];
    // YouTube's own Subscriptions tab is only covered in local mode (signed out it is a sign-in wall).
    BOOL subscriptions = [browseID isEqualToString:@"FEsubscriptions"] && FTLocalModeEnabled();
    if (!home && !subscriptions) return nil;
    host = [[FTHomeHost alloc] initWithBrowse:controller subscriptionsTab:subscriptions];
    objc_setAssociatedObject(controller, FTHostKey, host, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (home) FTFoundHome = YES;
    FTLog(@"attached to %@", browseID);
    return host;
}

static void FTBrowseDidAppear(UIViewController *self, SEL _cmd, BOOL animated) {
    ((void (*)(id, SEL, BOOL))FTOriginalBrowseDidAppear)(self, _cmd, animated);
    @try {
        [FTHostFor(self, YES) layout];
    } @catch (NSException *exception) {
        FTLog(@"home attach failed: %@", exception.reason);
    }
}

static void FTBrowseLayout(UIViewController *self, SEL _cmd) {
    ((void (*)(id, SEL))FTOriginalBrowseLayout)(self, _cmd);
    [FTHostFor(self, NO) layout];
}

#pragma mark - Fallback entry

/// A small button for when Home can't be found: opens the feed full screen.
@interface FTFallback : NSObject <FTFeedHost>
@end

@implementation FTFallback

+ (instancetype)shared {
    static FTFallback *fallback;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ fallback = [FTFallback new]; });
    return fallback;
}

- (void)install {
    UIWindow *window = FTKeyWindow();
    if (window == nil || FTFoundHome) return;
    UIButtonConfiguration *config = [UIButtonConfiguration filledButtonConfiguration];
    config.image = [UIImage systemImageNamed:@"rectangle.stack"];
    config.baseForegroundColor = UIColor.systemBackgroundColor;
    config.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    config.baseBackgroundColor = UIColor.labelColor;
    UIButton *button = [UIButton buttonWithConfiguration:config primaryAction:nil];
    button.accessibilityLabel = @"Open Flow feed";
    button.frame = CGRectMake(CGRectGetWidth(window.bounds) - 60, CGRectGetHeight(window.bounds) * 0.62, 44, 44);
    button.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    [button addTarget:self action:@selector(open:) forControlEvents:UIControlEventTouchUpInside];
    [button addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(drag:)]];
    [window addSubview:button];
    FTLog(@"Home not found; showing the Flow button");
}

- (void)drag:(UIPanGestureRecognizer *)pan {
    UIView *button = pan.view;
    CGPoint move = [pan translationInView:button.superview];
    button.center = CGPointMake(button.center.x + move.x, button.center.y + move.y);
    [pan setTranslation:CGPointZero inView:button.superview];
}

- (void)open:(UIButton *)button {
    UIViewController *top = button.window.rootViewController;
    while (top.presentedViewController) top = top.presentedViewController;
    FTFeedViewController *feed = [FTFeedViewController new];
    feed.standalone = YES;
    feed.host = self;
    feed.modalPresentationStyle = UIModalPresentationFullScreen;
    [top presentViewController:feed animated:YES completion:nil];
}

- (void)feed:(FTFeedViewController *)feed openVideoID:(NSString *)videoID {
    UIViewController *presenter = feed.presentingViewController;
    [feed dismissViewControllerAnimated:YES completion:^{
        FTOpenVideo(videoID, presenter, presenter.view);
    }];
}

- (void)feedWantsYouTube:(FTFeedViewController *)feed {
    [feed dismissViewControllerAnimated:YES completion:nil];
}

@end

#pragma mark - Entry

__attribute__((constructor)) static void FTInit(void) {
    @autoreleasepool {
        FTLog(@"loading");
        FTInstallPlayerHooks();
        FTInstallCommandHooks();
        FTInstallButtonStateHooks();
        FTHook(@"YTBrowseViewController", @"viewDidAppear:", (IMP)FTBrowseDidAppear, &FTOriginalBrowseDidAppear);
        FTHook(@"YTBrowseViewController", @"viewDidLayoutSubviews", (IMP)FTBrowseLayout, &FTOriginalBrowseLayout);
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil
                                                         queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            [FTEngine shared]; // opens the engine off the main thread
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [[FTFallback shared] install];
            });
        }];
    }
}
