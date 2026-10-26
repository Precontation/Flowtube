#import "FTFeedViewController.h"
#import "FTEngine.h"
#import "FTRuntime.h"
#import "FTSettingsViewController.h"
#import "FTNavigation.h"

UIColor *FTBackgroundColor(void) {
    // YouTube's own surfaces: #0F0F0F dark, white light.
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark
            ? [UIColor colorWithRed:15 / 255.0 green:15 / 255.0 blue:15 / 255.0 alpha:1]
            : UIColor.whiteColor;
    }];
}

#pragma mark - Images

@implementation FTImages

+ (NSCache *)cache {
    static NSCache *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [NSCache new];
        cache.totalCostLimit = 60 * 1024 * 1024;
    });
    return cache;
}

+ (void)loadURL:(NSString *)url into:(UIImageView *)imageView fallback:(NSString *)fallback {
    imageView.accessibilityIdentifier = url;
    imageView.image = nil;
    if (url.length == 0) {
        if (fallback.length) [self loadURL:fallback into:imageView fallback:nil];
        return;
    }
    UIImage *cached = [self.cache objectForKey:url];
    if (cached) {
        imageView.image = cached;
        return;
    }
    NSURL *address = [NSURL URLWithString:url];
    if (address == nil) return;
    [[NSURLSession.sharedSession dataTaskWithURL:address completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        UIImage *image = (data && status < 400) ? [UIImage imageWithData:data] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![imageView.accessibilityIdentifier isEqualToString:url]) return; // reused cell
            if (image == nil) {
                if (fallback.length) [self loadURL:fallback into:imageView fallback:nil];
                return;
            }
            [self.cache setObject:image forKey:url cost:data.length];
            imageView.image = image;
        });
    }] resume];
}

@end

#pragma mark - Cells

@interface FTVideoCell : UICollectionViewCell
@property (nonatomic) UIImageView *thumbnail;
@property (nonatomic) UILabel *duration;
@property (nonatomic) UIImageView *avatar;
@property (nonatomic) UILabel *title;
@property (nonatomic) UILabel *meta;
@property (nonatomic) UILabel *reason;
- (void)showVideo:(FTVideo *)video;
@end

@implementation FTVideoCell

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _thumbnail = [UIImageView new];
        _thumbnail.contentMode = UIViewContentModeScaleAspectFill;
        _thumbnail.clipsToBounds = YES;
        _thumbnail.backgroundColor = [UIColor.secondarySystemFillColor colorWithAlphaComponent:0.5];
        _thumbnail.layer.cornerRadius = 12;
        _thumbnail.layer.cornerCurve = kCACornerCurveContinuous;

        _duration = [UILabel new];
        _duration.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightSemibold];
        _duration.textColor = UIColor.whiteColor;
        _duration.backgroundColor = [UIColor colorWithWhite:0 alpha:0.78];
        _duration.textAlignment = NSTextAlignmentCenter;
        _duration.layer.cornerRadius = 4;
        _duration.clipsToBounds = YES;

        _avatar = [UIImageView new];
        _avatar.contentMode = UIViewContentModeScaleAspectFill;
        _avatar.clipsToBounds = YES;
        _avatar.layer.cornerRadius = 18;
        _avatar.backgroundColor = UIColor.secondarySystemFillColor;

        _title = [UILabel new];
        _title.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
        _title.textColor = UIColor.labelColor;
        _title.numberOfLines = 2;

        _meta = [UILabel new];
        _meta.font = [UIFont systemFontOfSize:12.5];
        _meta.textColor = UIColor.secondaryLabelColor;
        _meta.numberOfLines = 1;

        _reason = [UILabel new];
        _reason.font = [UIFont systemFontOfSize:12];
        _reason.textColor = UIColor.tertiaryLabelColor;
        _reason.numberOfLines = 1;

        for (UIView *view in @[_thumbnail, _avatar, _title, _meta, _reason]) {
            view.translatesAutoresizingMaskIntoConstraints = NO;
            [self.contentView addSubview:view];
        }
        _duration.translatesAutoresizingMaskIntoConstraints = NO;
        [_thumbnail addSubview:_duration];

        [NSLayoutConstraint activateConstraints:@[
            [_thumbnail.topAnchor constraintEqualToAnchor:self.contentView.topAnchor],
            [_thumbnail.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
            [_thumbnail.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
            [_thumbnail.heightAnchor constraintEqualToAnchor:_thumbnail.widthAnchor multiplier:9.0 / 16.0],
            [_duration.trailingAnchor constraintEqualToAnchor:_thumbnail.trailingAnchor constant:-8],
            [_duration.bottomAnchor constraintEqualToAnchor:_thumbnail.bottomAnchor constant:-8],
            [_duration.heightAnchor constraintEqualToConstant:20],
            [_duration.widthAnchor constraintGreaterThanOrEqualToConstant:36],

            [_avatar.topAnchor constraintEqualToAnchor:_thumbnail.bottomAnchor constant:12],
            [_avatar.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:12],
            [_avatar.widthAnchor constraintEqualToConstant:36],
            [_avatar.heightAnchor constraintEqualToConstant:36],

            [_title.topAnchor constraintEqualToAnchor:_thumbnail.bottomAnchor constant:11],
            [_title.leadingAnchor constraintEqualToAnchor:_avatar.trailingAnchor constant:12],
            [_title.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-12],
            [_meta.topAnchor constraintEqualToAnchor:_title.bottomAnchor constant:4],
            [_meta.leadingAnchor constraintEqualToAnchor:_title.leadingAnchor],
            [_meta.trailingAnchor constraintEqualToAnchor:_title.trailingAnchor],
            [_reason.topAnchor constraintEqualToAnchor:_meta.bottomAnchor constant:3],
            [_reason.leadingAnchor constraintEqualToAnchor:_title.leadingAnchor],
            [_reason.trailingAnchor constraintEqualToAnchor:_title.trailingAnchor],
            [_reason.bottomAnchor constraintLessThanOrEqualToAnchor:self.contentView.bottomAnchor constant:-16],
        ]];
    }
    return self;
}

- (void)showVideo:(FTVideo *)video {
    NSString *fallback = [NSString stringWithFormat:@"https://i.ytimg.com/vi/%@/hqdefault.jpg", video.videoID];
    NSString *best = video.thumbnailURL.length ? video.thumbnailURL
        : [NSString stringWithFormat:@"https://i.ytimg.com/vi/%@/hq720.jpg", video.videoID];
    [FTImages loadURL:best into:self.thumbnail fallback:fallback];
    [FTImages loadURL:video.avatarURL into:self.avatar fallback:nil];
    self.avatar.hidden = video.avatarURL.length == 0;
    self.duration.text = video.durationText.length ? [NSString stringWithFormat:@" %@ ", video.durationText] : nil;
    self.duration.hidden = video.durationText.length == 0;
    self.duration.backgroundColor = video.isLive ? UIColor.systemRedColor : [UIColor colorWithWhite:0 alpha:0.78];
    self.title.text = video.title;
    self.meta.text = video.metaText;
    self.reason.text = video.reason.length ? video.reason : nil;
    self.accessibilityLabel = [NSString stringWithFormat:@"%@, %@", video.title, video.metaText];
    self.isAccessibilityElement = YES;
}

@end

/// The first row: the For you / Subscriptions switch and a menu (YouTube's feed, settings).
@interface FTHeaderCell : UICollectionViewCell
@property (nonatomic) UISegmentedControl *kinds;
@property (nonatomic) UIButton *more;
@property (nonatomic) UIView *spacer;
@end

@implementation FTHeaderCell

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _kinds = [[UISegmentedControl alloc] initWithItems:@[@"For you", @"Subscriptions"]];
        _kinds.selectedSegmentIndex = 0;

        UIButtonConfiguration *config = [UIButtonConfiguration plainButtonConfiguration];
        config.image = [UIImage systemImageNamed:@"ellipsis.circle"];
        config.baseForegroundColor = UIColor.labelColor;
        _more = [UIButton buttonWithConfiguration:config primaryAction:nil];
        _more.showsMenuAsPrimaryAction = YES;
        _more.accessibilityLabel = @"More";
        [_more setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

        _spacer = [UIView new];
        _spacer.hidden = YES;
        [_spacer setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
        UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[_kinds, _spacer, _more]];
        row.alignment = UIStackViewAlignmentCenter;
        row.spacing = 8;
        row.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:row];
        [NSLayoutConstraint activateConstraints:@[
            [row.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:12],
            [row.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-4],
            [row.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:6],
            [row.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-10],
            [_kinds.heightAnchor constraintGreaterThanOrEqualToConstant:32],
        ]];
    }
    return self;
}

@end

/// A message row: first run, offline, empty.
@interface FTNoticeCell : UICollectionViewCell
@property (nonatomic) UILabel *title;
@property (nonatomic) UILabel *body;
@property (nonatomic) UIButton *primary;
@property (nonatomic) UIButton *secondary;
@end

@implementation FTNoticeCell

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        UIView *card = [UIView new];
        card.backgroundColor = UIColor.secondarySystemFillColor;
        card.layer.cornerRadius = 14;
        card.layer.cornerCurve = kCACornerCurveContinuous;
        _title = [UILabel new];
        _title.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
        _title.numberOfLines = 0;
        _body = [UILabel new];
        _body.font = [UIFont systemFontOfSize:14];
        _body.textColor = UIColor.secondaryLabelColor;
        _body.numberOfLines = 0;
        UIButtonConfiguration *filled = [UIButtonConfiguration filledButtonConfiguration];
        filled.baseBackgroundColor = UIColor.labelColor;
        filled.baseForegroundColor = UIColor.systemBackgroundColor;
        filled.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
        _primary = [UIButton buttonWithConfiguration:filled primaryAction:nil];
        UIButtonConfiguration *plain = [UIButtonConfiguration grayButtonConfiguration];
        plain.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
        _secondary = [UIButton buttonWithConfiguration:plain primaryAction:nil];
        UIStackView *buttons = [[UIStackView alloc] initWithArrangedSubviews:@[_primary, _secondary]];
        buttons.spacing = 8;
        buttons.distribution = UIStackViewDistributionFillProportionally;
        UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[_title, _body, buttons]];
        stack.axis = UILayoutConstraintAxisVertical;
        stack.spacing = 8;
        [stack setCustomSpacing:14 afterView:_body];
        stack.alignment = UIStackViewAlignmentLeading;
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        card.translatesAutoresizingMaskIntoConstraints = NO;
        [card addSubview:stack];
        [self.contentView addSubview:card];
        [NSLayoutConstraint activateConstraints:@[
            [card.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:12],
            [card.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-12],
            [card.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:4],
            [card.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-16],
            [stack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
            [stack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
            [stack.topAnchor constraintEqualToAnchor:card.topAnchor constant:16],
            [stack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-16],
        ]];
    }
    return self;
}

@end

@interface FTSpinnerCell : UICollectionViewCell
@property (nonatomic) UIActivityIndicatorView *spinner;
@end

@implementation FTSpinnerCell
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        _spinner.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_spinner];
        [NSLayoutConstraint activateConstraints:@[
            [_spinner.centerXAnchor constraintEqualToAnchor:self.contentView.centerXAnchor],
            [_spinner.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        ]];
    }
    return self;
}
@end

#pragma mark - Feed

typedef NS_ENUM(NSInteger, FTSection) {
    FTSectionHeader,
    FTSectionNotice,
    FTSectionVideos,
    FTSectionFooter,
    FTSectionCount,
};

typedef NS_ENUM(NSInteger, FTNotice) {
    FTNoticeNone,
    FTNoticeWelcome,
    FTNoticeOffline,
    FTNoticeEmpty,
    FTNoticeNoSubscriptions,
};

@interface FTFeedViewController () <UICollectionViewDataSource, UICollectionViewDelegate>
@property (nonatomic) UICollectionView *collectionView;
@property (nonatomic) NSMutableArray<FTVideo *> *videos;
@property (nonatomic) BOOL loading;
@property (nonatomic) BOOL loadingMore;
@property (nonatomic) BOOL exhausted;
@property (nonatomic) FTNotice notice;
@property (nonatomic) NSDate *loadedAt;
@end

@implementation FTFeedViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.videos = [NSMutableArray array];
    self.view.backgroundColor = FTBackgroundColor();

    __weak typeof(self) weakSelf = self;
    UICollectionViewCompositionalLayout *layout = [[UICollectionViewCompositionalLayout alloc]
        initWithSectionProvider:^NSCollectionLayoutSection *(NSInteger section, id<NSCollectionLayoutEnvironment> environment) {
            return [weakSelf layoutSection:section environment:environment];
        }];
    self.collectionView = [[UICollectionView alloc] initWithFrame:self.view.bounds collectionViewLayout:layout];
    self.collectionView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.collectionView.backgroundColor = UIColor.clearColor;
    self.collectionView.dataSource = self;
    self.collectionView.delegate = self;
    self.collectionView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    self.collectionView.alwaysBounceVertical = YES;
    [self.collectionView registerClass:FTVideoCell.class forCellWithReuseIdentifier:@"video"];
    [self.collectionView registerClass:FTHeaderCell.class forCellWithReuseIdentifier:@"header"];
    [self.collectionView registerClass:FTNoticeCell.class forCellWithReuseIdentifier:@"notice"];
    [self.collectionView registerClass:FTSpinnerCell.class forCellWithReuseIdentifier:@"spinner"];
    UIRefreshControl *refresh = [UIRefreshControl new];
    [refresh addTarget:self action:@selector(pulled:) forControlEvents:UIControlEventValueChanged];
    self.collectionView.refreshControl = refresh;
    [self.view addSubview:self.collectionView];
    [self applyInsets];
    [self refresh];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // Like YouTube, a Home left for a long while comes back fresh.
    if (self.loadedAt && -self.loadedAt.timeIntervalSinceNow > 30 * 60 && !self.loading) {
        [self refresh];
    }
}

- (void)setChromeInsets:(UIEdgeInsets)chromeInsets {
    if (UIEdgeInsetsEqualToEdgeInsets(chromeInsets, _chromeInsets)) return;
    _chromeInsets = chromeInsets;
    [self applyInsets];
}

- (void)applyInsets {
    if (!self.isViewLoaded) return;
    UIEdgeInsets insets = self.chromeInsets;
    if (self.standalone) insets = self.view.safeAreaInsets;
    self.collectionView.contentInset = insets;
    self.collectionView.verticalScrollIndicatorInsets = insets;
}

- (void)viewSafeAreaInsetsDidChange {
    [super viewSafeAreaInsetsDidChange];
    if (self.standalone) [self applyInsets];
}

- (NSCollectionLayoutSection *)layoutSection:(NSInteger)section environment:(id<NSCollectionLayoutEnvironment>)environment {
    CGFloat width = environment.container.effectiveContentSize.width;
    if (section == FTSectionVideos) {
        // One column on a phone, a grid on wider screens, like YouTube's Home.
        NSInteger columns = width >= 1100 ? 4 : width >= 820 ? 3 : width >= 560 ? 2 : 1;
        CGFloat gap = columns > 1 ? 16 : 0;
        NSCollectionLayoutSize *itemSize = [NSCollectionLayoutSize
            sizeWithWidthDimension:[NSCollectionLayoutDimension fractionalWidthDimension:1.0 / columns]
                   heightDimension:[NSCollectionLayoutDimension estimatedDimension:320]];
        NSCollectionLayoutItem *item = [NSCollectionLayoutItem itemWithLayoutSize:itemSize];
        NSCollectionLayoutSize *groupSize = [NSCollectionLayoutSize
            sizeWithWidthDimension:[NSCollectionLayoutDimension fractionalWidthDimension:1]
                   heightDimension:[NSCollectionLayoutDimension estimatedDimension:320]];
        NSCollectionLayoutGroup *group;
        if (@available(iOS 16.0, *)) {
            group = [NSCollectionLayoutGroup horizontalGroupWithLayoutSize:groupSize repeatingSubitem:item count:columns];
        } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            group = [NSCollectionLayoutGroup horizontalGroupWithLayoutSize:groupSize subitem:item count:columns];
#pragma clang diagnostic pop
        }
        group.interItemSpacing = [NSCollectionLayoutSpacing fixedSpacing:gap];
        NSCollectionLayoutSection *layout = [NSCollectionLayoutSection sectionWithGroup:group];
        layout.interGroupSpacing = 4;
        layout.contentInsets = NSDirectionalEdgeInsetsMake(0, columns > 1 ? 16 : 0, 0, columns > 1 ? 16 : 0);
        return layout;
    }
    NSCollectionLayoutSize *size = [NSCollectionLayoutSize
        sizeWithWidthDimension:[NSCollectionLayoutDimension fractionalWidthDimension:1]
               heightDimension:[NSCollectionLayoutDimension estimatedDimension:section == FTSectionFooter ? 64 : 60]];
    NSCollectionLayoutItem *item = [NSCollectionLayoutItem itemWithLayoutSize:size];
    NSCollectionLayoutGroup *group = [NSCollectionLayoutGroup verticalGroupWithLayoutSize:size subitems:@[item]];
    return [NSCollectionLayoutSection sectionWithGroup:group];
}

#pragma mark Loading

- (void)pulled:(UIRefreshControl *)control {
    [self refresh];
}

- (void)refresh {
    if (self.loading) return;
    self.loading = YES;
    self.exhausted = NO;
    if (self.videos.count == 0) [self reloadContent];
    __weak typeof(self) weakSelf = self;
    FTFeedKind kind = self.kind;
    void (^done)(FTPage *) = ^(FTPage *page) {
        FTFeedViewController *me = weakSelf;
        if (me == nil) return;
        if (me.kind != kind) return; // switched while loading
        me.loading = NO;
        if (kind == FTFeedKindSubscriptions) me.exhausted = YES; // one page
        [me.collectionView.refreshControl endRefreshing];
        me.loadedAt = NSDate.date;
        if (page.videos.count > 0) {
            me.videos = [page.videos mutableCopy];
            me.notice = page.coldStart && ![NSUserDefaults.standardUserDefaults boolForKey:@"FlowTube.WelcomeDone"]
                ? FTNoticeWelcome : FTNoticeNone;
            [me.collectionView setContentOffset:CGPointMake(0, -me.collectionView.contentInset.top) animated:NO];
        } else {
            me.videos = [NSMutableArray array];
            me.notice = (page == nil || page.offline) ? FTNoticeOffline
                : kind == FTFeedKindSubscriptions ? FTNoticeNoSubscriptions : FTNoticeEmpty;
        }
        if (kind == FTFeedKindSubscriptions && me.notice == FTNoticeWelcome) me.notice = FTNoticeNone;
        [me reloadContent];
    };
    if (kind == FTFeedKindSubscriptions) [FTEngine.shared loadSubscriptions:done];
    else [FTEngine.shared loadHomeMore:NO completion:done];
}

- (void)setKind:(FTFeedKind)kind {
    if (_kind == kind) return;
    _kind = kind;
    if (!self.isViewLoaded) return;
    self.loading = NO;
    self.loadingMore = NO;
    self.videos = [NSMutableArray array];
    self.notice = FTNoticeNone;
    [self reloadContent];
    [self refresh];
}

- (void)setSubscriptionsTab:(BOOL)subscriptionsTab {
    _subscriptionsTab = subscriptionsTab;
    if (subscriptionsTab) self.kind = FTFeedKindSubscriptions;
}

- (void)kindChanged:(UISegmentedControl *)control {
    self.kind = (FTFeedKind)control.selectedSegmentIndex;
}

- (UIMenu *)headerMenu {
    __weak typeof(self) weakSelf = self;
    NSMutableArray *items = [NSMutableArray array];
    if (self.standalone) {
        [items addObject:[UIAction actionWithTitle:@"Close" image:[UIImage systemImageNamed:@"xmark"] identifier:nil handler:^(UIAction *a) {
            [weakSelf close];
        }]];
    } else if (!self.subscriptionsTab) {
        [items addObject:[UIAction actionWithTitle:@"Show YouTube's feed" image:[UIImage systemImageNamed:@"play.rectangle"] identifier:nil handler:^(UIAction *a) {
            [weakSelf showYouTube];
        }]];
    }
    [items addObject:[UIAction actionWithTitle:@"Refresh" image:[UIImage systemImageNamed:@"arrow.clockwise"] identifier:nil handler:^(UIAction *a) {
        [weakSelf refresh];
    }]];
    [items addObject:[UIAction actionWithTitle:@"Flow settings" image:[UIImage systemImageNamed:@"gearshape"] identifier:nil handler:^(UIAction *a) {
        [weakSelf openSettings];
    }]];
    return [UIMenu menuWithChildren:items];
}

/// Reloads everything but the header row, so its segmented control keeps its own animation.
- (void)reloadContent {
    NSIndexSet *content = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(FTSectionNotice, FTSectionCount - FTSectionNotice)];
    if ([self.collectionView numberOfSections] != FTSectionCount) {
        [self.collectionView reloadData];
        return;
    }
    [UIView performWithoutAnimation:^{
        [self.collectionView reloadSections:content];
    }];
}

- (void)loadMore {
    if (self.kind != FTFeedKindForYou) return;
    if (self.loading || self.loadingMore || self.exhausted || self.videos.count == 0) return;
    self.loadingMore = YES;
    __weak typeof(self) weakSelf = self;
    [FTEngine.shared loadHomeMore:YES completion:^(FTPage *page) {
        FTFeedViewController *me = weakSelf;
        if (me == nil) return;
        me.loadingMore = NO;
        NSMutableSet *known = [NSMutableSet set];
        for (FTVideo *video in me.videos) [known addObject:video.videoID];
        NSMutableArray *added = [NSMutableArray array];
        for (FTVideo *video in page.videos) {
            if (![known containsObject:video.videoID]) [added addObject:video];
        }
        if (added.count == 0) {
            me.exhausted = YES;
            [me.collectionView reloadSections:[NSIndexSet indexSetWithIndex:FTSectionFooter]];
            return;
        }
        NSInteger start = me.videos.count;
        [me.videos addObjectsFromArray:added];
        NSMutableArray *paths = [NSMutableArray array];
        for (NSInteger i = start; i < (NSInteger)me.videos.count; i++) {
            [paths addObject:[NSIndexPath indexPathForItem:i inSection:FTSectionVideos]];
        }
        [me.collectionView performBatchUpdates:^{
            [me.collectionView insertItemsAtIndexPaths:paths];
        } completion:nil];
    }];
}

#pragma mark Data source

- (NSInteger)numberOfSectionsInCollectionView:(UICollectionView *)collectionView {
    return FTSectionCount;
}

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    switch (section) {
        case FTSectionHeader: return 1;
        case FTSectionNotice: return self.notice == FTNoticeNone ? 0 : 1;
        case FTSectionVideos: return self.videos.count;
        case FTSectionFooter: return (self.loading && self.videos.count == 0) || (self.videos.count > 0 && !self.exhausted) ? 1 : 0;
    }
    return 0;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    switch (indexPath.section) {
        case FTSectionHeader: {
            FTHeaderCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"header" forIndexPath:indexPath];
            // On YouTube's Subscriptions tab there is nothing to switch between.
            cell.kinds.hidden = self.subscriptionsTab;
            cell.spacer.hidden = !self.subscriptionsTab;
            if (cell.kinds.selectedSegmentIndex != self.kind) cell.kinds.selectedSegmentIndex = self.kind;
            [cell.kinds removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];
            [cell.kinds addTarget:self action:@selector(kindChanged:) forControlEvents:UIControlEventValueChanged];
            cell.more.menu = [self headerMenu];
            return cell;
        }
        case FTSectionNotice:
            return [self noticeCellAt:indexPath];
        case FTSectionVideos: {
            FTVideoCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"video" forIndexPath:indexPath];
            [cell showVideo:self.videos[indexPath.item]];
            return cell;
        }
        default: {
            FTSpinnerCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"spinner" forIndexPath:indexPath];
            [cell.spinner startAnimating];
            return cell;
        }
    }
}

- (UICollectionViewCell *)noticeCellAt:(NSIndexPath *)indexPath {
    FTNoticeCell *cell = [self.collectionView dequeueReusableCellWithReuseIdentifier:@"notice" forIndexPath:indexPath];
    [cell.primary removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];
    [cell.secondary removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];
    UIButtonConfiguration *primary = cell.primary.configuration;
    UIButtonConfiguration *secondary = cell.secondary.configuration;
    cell.secondary.hidden = NO;
    switch (self.notice) {
        case FTNoticeWelcome:
            cell.title.text = @"Flow learns from what you watch";
            cell.body.text = @"Everything it learns stays on this iPhone. Watch, like and long-press videos to teach it, or give it a head start.";
            primary.title = @"Pick interests";
            secondary.title = @"Import from Takeout";
            [cell.primary addTarget:self action:@selector(pickInterests) forControlEvents:UIControlEventTouchUpInside];
            [cell.secondary addTarget:self action:@selector(openSettings) forControlEvents:UIControlEventTouchUpInside];
            break;
        case FTNoticeOffline:
            cell.title.text = @"Couldn't reach YouTube";
            cell.body.text = @"Flow's searches didn't go through. Check your connection and try again.";
            primary.title = @"Try again";
            cell.secondary.hidden = YES;
            [cell.primary addTarget:self action:@selector(refresh) forControlEvents:UIControlEventTouchUpInside];
            break;
        case FTNoticeNoSubscriptions:
            cell.title.text = @"No subscriptions in Flow yet";
            cell.body.text = @"Subscribe to channels in YouTube, or copy the channels your account follows.";
            primary.title = @"Copy from my account";
            secondary.title = @"Import a file";
            [cell.primary addTarget:self action:@selector(copyFromAccount) forControlEvents:UIControlEventTouchUpInside];
            [cell.secondary addTarget:self action:@selector(openSettings) forControlEvents:UIControlEventTouchUpInside];
            break;
        default:
            cell.title.text = @"Nothing to show yet";
            cell.body.text = @"Pick a few interests so Flow knows where to start.";
            primary.title = @"Pick interests";
            secondary.title = @"Try again";
            [cell.primary addTarget:self action:@selector(pickInterests) forControlEvents:UIControlEventTouchUpInside];
            [cell.secondary addTarget:self action:@selector(refresh) forControlEvents:UIControlEventTouchUpInside];
            break;
    }
    cell.primary.configuration = primary;
    cell.secondary.configuration = secondary;
    return cell;
}

#pragma mark Interaction

- (void)collectionView:(UICollectionView *)collectionView willDisplayCell:(UICollectionViewCell *)cell forItemAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == FTSectionVideos && indexPath.item >= (NSInteger)self.videos.count - 5) {
        [self loadMore];
    }
}

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section != FTSectionVideos) return;
    FTVideo *video = self.videos[indexPath.item];
    [self.host feed:self openVideoID:video.videoID];
}

- (UIContextMenuConfiguration *)collectionView:(UICollectionView *)collectionView contextMenuConfigurationForItemAtIndexPath:(NSIndexPath *)indexPath point:(CGPoint)point {
    if (indexPath.section != FTSectionVideos) return nil;
    FTVideo *video = self.videos[indexPath.item];
    __weak typeof(self) weakSelf = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:video.videoID previewProvider:nil actionProvider:^UIMenu *(NSArray *suggested) {
        UIAction *notInterested = [UIAction actionWithTitle:@"Not interested" image:[UIImage systemImageNamed:@"hand.thumbsdown"] identifier:nil handler:^(UIAction *a) {
            [FTEngine.shared feedback:@"notInterested" videoID:video.videoID video:video.json];
            [weakSelf removeVideosMatching:^BOOL(FTVideo *v) { return [v.videoID isEqualToString:video.videoID]; }];
        }];
        UIAction *channel = [UIAction actionWithTitle:@"Don't recommend channel" image:[UIImage systemImageNamed:@"nosign"] identifier:nil handler:^(UIAction *a) {
            if (video.channelID.length == 0) return;
            [FTEngine.shared blockChannel:video.channelID];
            [weakSelf removeVideosMatching:^BOOL(FTVideo *v) { return [v.channelID isEqualToString:video.channelID]; }];
        }];
        channel.attributes = UIMenuElementAttributesDestructive;
        UIAction *share = [UIAction actionWithTitle:@"Share" image:[UIImage systemImageNamed:@"square.and.arrow.up"] identifier:nil handler:^(UIAction *a) {
            [weakSelf share:video atIndexPath:indexPath];
        }];
        UIAction *copy = [UIAction actionWithTitle:@"Copy link" image:[UIImage systemImageNamed:@"link"] identifier:nil handler:^(UIAction *a) {
            UIPasteboard.generalPasteboard.string = [NSString stringWithFormat:@"https://youtu.be/%@", video.videoID];
        }];
        NSMutableArray *teachItems = [NSMutableArray arrayWithObjects:notInterested, channel, nil];
        if (video.channelID.length) {
            BOOL following = [FTEngine.shared.subscribedIDs containsObject:video.channelID];
            NSString *title = following ? @"Unsubscribe in Flow" : @"Subscribe in Flow";
            UIAction *follow = [UIAction actionWithTitle:title image:[UIImage systemImageNamed:following ? @"person.crop.circle.badge.minus" : @"person.crop.circle.badge.plus"] identifier:nil handler:^(UIAction *a) {
                [FTEngine.shared setSubscribed:!following channelID:video.channelID name:video.channelName];
                FTToast(following ? [NSString stringWithFormat:@"Unsubscribed from %@ in Flow", video.channelName]
                                  : [NSString stringWithFormat:@"Subscribed to %@ in Flow", video.channelName]);
            }];
            [teachItems insertObject:follow atIndex:0];
            UIAction *open = [UIAction actionWithTitle:@"Go to channel" image:[UIImage systemImageNamed:@"person.crop.square"] identifier:nil handler:^(UIAction *a) {
                FTOpenBrowse(video.channelID, weakSelf);
            }];
            [teachItems addObject:open];
        }
        UIMenu *teach = [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:teachItems];
        UIMenu *other = [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[share, copy]];
        return [UIMenu menuWithTitle:video.reason children:@[teach, other]];
    }];
}

- (void)removeVideosMatching:(BOOL (^)(FTVideo *))match {
    NSMutableArray *paths = [NSMutableArray array];
    NSMutableIndexSet *indexes = [NSMutableIndexSet indexSet];
    [self.videos enumerateObjectsUsingBlock:^(FTVideo *video, NSUInteger i, BOOL *stop) {
        if (match(video)) {
            [indexes addIndex:i];
            [paths addObject:[NSIndexPath indexPathForItem:i inSection:FTSectionVideos]];
        }
    }];
    if (indexes.count == 0) return;
    [self.collectionView performBatchUpdates:^{
        [self.videos removeObjectsAtIndexes:indexes];
        [self.collectionView deleteItemsAtIndexPaths:paths];
    } completion:nil];
}

- (void)share:(FTVideo *)video atIndexPath:(NSIndexPath *)indexPath {
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://youtu.be/%@", video.videoID]];
    UIActivityViewController *sheet = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
    UICollectionViewCell *cell = [self.collectionView cellForItemAtIndexPath:indexPath];
    sheet.popoverPresentationController.sourceView = cell ?: self.view;
    sheet.popoverPresentationController.sourceRect = cell ? cell.bounds : self.view.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)showYouTube {
    [self.host feedWantsYouTube:self];
}

- (void)close {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)copyFromAccount {
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"FlowTube.CopyRequested"];
    FTToast(@"Opening your subscriptions so Flow can copy them…");
    FTOpenBrowse(@"FEchannels", self);
}

- (void)openSettings {
    FTSettingsViewController *settings = [FTSettingsViewController new];
    __weak typeof(self) weakSelf = self;
    settings.onChange = ^{ [weakSelf refresh]; };
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:settings];
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)pickInterests {
    FTTopicsViewController *topics = [FTTopicsViewController new];
    __weak typeof(self) weakSelf = self;
    topics.onDone = ^{
        [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"FlowTube.WelcomeDone"];
        weakSelf.notice = FTNoticeNone;
        weakSelf.videos = [NSMutableArray array];
        [weakSelf refresh];
    };
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:topics];
    [self presentViewController:nav animated:YES completion:nil];
}

@end
