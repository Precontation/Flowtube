#import "FTSettingsViewController.h"
#import "FTEngine.h"
#import "FTFeedViewController.h"
#import "FTNavigation.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

NSString *const FTHomeEnabledKey = @"FlowTube.HomeEnabled";
NSString *const FTHomeModeChangedNotification = @"FlowTubeHomeModeChanged";

BOOL FTHomeEnabled(void) {
    id value = [NSUserDefaults.standardUserDefaults objectForKey:FTHomeEnabledKey];
    return value == nil ? YES : [value boolValue];
}

void FTSetHomeEnabled(BOOL enabled) {
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:FTHomeEnabledKey];
    [NSNotificationCenter.defaultCenter postNotificationName:FTHomeModeChangedNotification object:nil];
}

static NSString *const FTLocalModeKey = @"FlowTube.LocalMode";

BOOL FTLocalModeEnabled(void) {
    return [NSUserDefaults.standardUserDefaults boolForKey:FTLocalModeKey];
}

void FTSetLocalModeEnabled(BOOL enabled) {
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:FTLocalModeKey];
    [NSNotificationCenter.defaultCenter postNotificationName:FTHomeModeChangedNotification object:nil];
}

typedef NS_ENUM(NSInteger, FTRow) {
    FTRowHome, FTRowPause,
    FTRowLocal, FTRowLibrary, FTRowCopyAccount,
    FTRowStats, FTRowTopics,
    FTRowInterests, FTRowSubsCSV, FTRowSubsJSON, FTRowHistory,
    FTRowReset,
};

@interface FTSettingsViewController () <UIDocumentPickerDelegate>
@property (nonatomic, copy) NSDictionary *stats;
@property (nonatomic, copy) NSString *importKind;
@end

@implementation FTSettingsViewController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Flow";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(done)];
    [self reloadStats];
}

- (void)reloadStats {
    [FTEngine.shared stats:^(NSDictionary *stats) {
        self.stats = stats ?: @{};
        [self.tableView reloadData];
    }];
}

- (void)done {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (NSArray<NSArray<NSNumber *> *> *)sections {
    return @[
        @[@(FTRowHome), @(FTRowPause)],
        @[@(FTRowLocal), @(FTRowLibrary), @(FTRowCopyAccount)],
        @[@(FTRowStats), @(FTRowTopics)],
        @[@(FTRowInterests), @(FTRowSubsCSV), @(FTRowSubsJSON), @(FTRowHistory)],
        @[@(FTRowReset)],
    ];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return self.sections.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.sections[section].count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return @[@"Feed", @"Your account", @"What Flow knows", @"Give Flow a head start", @""][section];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    switch (section) {
        case 0: return @"Paused, Flow still ranks your feed but stops learning from what you watch.";
        case 1: return FTLocalModeEnabled()
            ? @"Local mode is on: subscribing, liking and disliking stay on this device and YouTube never hears about them. Use it with YouTube signed out (profile picture → Switch account → Use YouTube signed out)."
            : @"Subscribing in YouTube also subscribes in Flow. Opening Subscriptions → All in YouTube copies that list into Flow (very long lists may only copy their first part; Takeout below gets them all).";
        case 3: return @"Files work signed out too: export from takeout.google.com (YouTube → subscriptions.csv, history → watch-history.json) or from NewPipe, then import here.";
        case 4: return @"FlowTube runs Flow's FlowNeuro engine (github.com/Flow-Tube, GPL-3.0). What it learns stays on this device. Its searches go to YouTube logged out, so they never touch your account; videos you open still play, count and sync on your account as usual.";
        default: return nil;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    FTRow row = (FTRow)self.sections[indexPath.section][indexPath.row].integerValue;
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    UIListContentConfiguration *content = [UIListContentConfiguration valueCellConfiguration];
    switch (row) {
        case FTRowHome: {
            content.text = @"Show Flow on Home";
            UISwitch *toggle = [UISwitch new];
            toggle.on = FTHomeEnabled();
            [toggle addTarget:self action:@selector(homeToggled:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = toggle;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            break;
        }
        case FTRowPause: {
            content.text = @"Pause learning";
            UISwitch *toggle = [UISwitch new];
            toggle.on = [self.stats[@"learningPaused"] boolValue];
            [toggle addTarget:self action:@selector(pauseToggled:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = toggle;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            break;
        }
        case FTRowLocal: {
            content = [UIListContentConfiguration subtitleCellConfiguration];
            content.text = @"Local mode";
            content.secondaryText = @"Keep subscriptions and likes off YouTube, like Flow";
            UISwitch *toggle = [UISwitch new];
            toggle.on = FTLocalModeEnabled();
            [toggle addTarget:self action:@selector(localToggled:) forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = toggle;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            break;
        }
        case FTRowLibrary:
            content.text = @"Library";
            content.secondaryText = [NSString stringWithFormat:@"%@ subscriptions", self.stats[@"subscriptions"] ?: @0];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            break;
        case FTRowCopyAccount:
            content.text = @"Copy subscriptions from my account";
            content.image = [UIImage systemImageNamed:@"arrow.down.circle"];
            break;
        case FTRowStats: {
            content = [UIListContentConfiguration subtitleCellConfiguration];
            content.text = [NSString stringWithFormat:@"%@ · %@ signals", self.stats[@"persona"] ?: @"…", self.stats[@"totalInteractions"] ?: @0];
            content.secondaryText = [NSString stringWithFormat:@"%@ watched · %@ liked · %@ subscriptions",
                                     self.stats[@"watchedVideos"] ?: @0, self.stats[@"likedVideos"] ?: @0, self.stats[@"subscriptions"] ?: @0];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            break;
        }
        case FTRowTopics: {
            content = [UIListContentConfiguration subtitleCellConfiguration];
            content.text = @"Top interests";
            NSArray *topics = self.stats[@"topTopics"];
            content.secondaryText = [topics isKindOfClass:NSArray.class] && topics.count ? [topics componentsJoinedByString:@", "] : @"None yet: watch a few videos.";
            content.secondaryTextProperties.numberOfLines = 0;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            break;
        }
        case FTRowInterests:
            content.text = @"Pick interests";
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            break;
        case FTRowSubsCSV:
            content.text = @"Subscriptions (Takeout .csv)";
            content.image = [UIImage systemImageNamed:@"person.2"];
            break;
        case FTRowSubsJSON:
            content.text = @"Subscriptions (NewPipe .json)";
            content.image = [UIImage systemImageNamed:@"person.2"];
            break;
        case FTRowHistory:
            content.text = @"Watch history (Takeout .json)";
            content.image = [UIImage systemImageNamed:@"clock.arrow.circlepath"];
            break;
        case FTRowReset:
            content.text = @"Forget everything";
            content.textProperties.color = UIColor.systemRedColor;
            break;
    }
    cell.contentConfiguration = content;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    FTRow row = (FTRow)self.sections[indexPath.section][indexPath.row].integerValue;
    switch (row) {
        case FTRowInterests: {
            FTTopicsViewController *topics = [FTTopicsViewController new];
            __weak typeof(self) weakSelf = self;
            topics.onDone = ^{
                [weakSelf reloadStats];
                if (weakSelf.onChange) weakSelf.onChange();
            };
            [self.navigationController pushViewController:topics animated:YES];
            break;
        }
        case FTRowLibrary:
            [self.navigationController pushViewController:[FTLibraryViewController new] animated:YES];
            break;
        case FTRowCopyAccount: [self copyFromAccount]; break;
        case FTRowSubsCSV: [self pick:@"subscriptions-csv" types:@[UTTypeCommaSeparatedText, UTTypePlainText]]; break;
        case FTRowSubsJSON: [self pick:@"subscriptions-json" types:@[UTTypeJSON, UTTypePlainText]]; break;
        case FTRowHistory: [self pick:@"history-json" types:@[UTTypeJSON, UTTypePlainText]]; break;
        case FTRowReset: [self confirmReset]; break;
        default: break;
    }
}

- (void)homeToggled:(UISwitch *)toggle {
    FTSetHomeEnabled(toggle.on);
}

- (void)localToggled:(UISwitch *)toggle {
    if (!toggle.on) {
        FTSetLocalModeEnabled(NO);
        [self.tableView reloadData];
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Turn on local mode?"
        message:@"Subscribing, liking and disliking will stay on this iPhone and YouTube won't hear about them. Flow shows your Subscriptions from its own list.\n\nFor YouTube to know nothing, also sign out of YouTube: profile picture → Switch account → Use YouTube signed out. Copy your subscriptions into Flow first, while you're still signed in."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *a) {
        toggle.on = NO;
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Copy subscriptions first" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        FTSetLocalModeEnabled(YES);
        [self copyFromAccount];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Turn on" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        FTSetLocalModeEnabled(YES);
        [self.tableView reloadData];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

/// Opens Subscriptions → All in YouTube; the list is copied into Flow as it loads.
- (void)copyFromAccount {
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"FlowTube.CopyRequested"];
    UIViewController *presenter = self.navigationController.presentingViewController ?: self.presentingViewController;
    [self dismissViewControllerAnimated:YES completion:^{
        FTToast(@"Opening your subscriptions so Flow can copy them…");
        FTOpenBrowse(@"FEchannels", presenter);
    }];
}

- (void)pauseToggled:(UISwitch *)toggle {
    [FTEngine.shared setLearningPaused:toggle.on];
}

- (void)pick:(NSString *)kind types:(NSArray<UTType *> *)types {
    self.importKind = kind;
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:YES];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSString *contents = url ? [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:nil] : nil;
    if (scoped) [url stopAccessingSecurityScopedResource];
    if (contents.length == 0) {
        [self alert:@"Couldn't read that file" message:@"Pick the file itself, not the Takeout .zip."];
        return;
    }
    [FTEngine.shared import:self.importKind contents:contents completion:^(NSInteger count) {
        if (count <= 0) {
            [self alert:@"Nothing imported" message:@"That file didn't look like the expected export."];
            return;
        }
        NSString *what = [self.importKind hasPrefix:@"history"] ? @"videos" : @"channels";
        [self alert:@"Imported" message:[NSString stringWithFormat:@"Flow learned from %ld %@.", (long)count, what]];
        [self reloadStats];
        if (self.onChange) self.onChange();
    }];
}

- (void)confirmReset {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Forget everything?"
        message:@"Flow forgets your interests, history, likes and imports on this device. Your YouTube account is not affected."
        preferredStyle:UIAlertControllerStyleAlert];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Forget" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        [FTEngine.shared reset:^{
            [NSUserDefaults.standardUserDefaults removeObjectForKey:@"FlowTube.WelcomeDone"];
            [self reloadStats];
            if (self.onChange) self.onChange();
        }];
    }]];
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)alert:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

#pragma mark - Topics

@interface FTChipCell : UICollectionViewCell
@property (nonatomic) UILabel *label;
@end

@implementation FTChipCell
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _label = [UILabel new];
        _label.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
        _label.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_label];
        self.contentView.layer.cornerRadius = 17;
        self.contentView.layer.cornerCurve = kCACornerCurveContinuous;
        [NSLayoutConstraint activateConstraints:@[
            [_label.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:14],
            [_label.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-14],
            [_label.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:8],
            [_label.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-8],
        ]];
        [self refresh];
    }
    return self;
}
- (void)setSelected:(BOOL)selected {
    [super setSelected:selected];
    [self refresh];
}
- (void)refresh {
    self.contentView.backgroundColor = self.selected ? UIColor.labelColor : UIColor.secondarySystemFillColor;
    self.label.textColor = self.selected ? UIColor.systemBackgroundColor : UIColor.labelColor;
    self.accessibilityTraits = self.selected ? UIAccessibilityTraitButton | UIAccessibilityTraitSelected : UIAccessibilityTraitButton;
}
@end

@interface FTTopicHeader : UICollectionReusableView
@property (nonatomic) UILabel *label;
@end

@implementation FTTopicHeader
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _label = [UILabel new];
        _label.font = [UIFont systemFontOfSize:17 weight:UIFontWeightBold];
        _label.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:_label];
        [NSLayoutConstraint activateConstraints:@[
            [_label.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [_label.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-6],
            [_label.topAnchor constraintEqualToAnchor:self.topAnchor constant:14],
        ]];
    }
    return self;
}
@end

@interface FTTopicsViewController ()
@property (nonatomic, copy) NSArray<NSDictionary *> *catalog;
@end

@implementation FTTopicsViewController

- (instancetype)init {
    NSCollectionLayoutSize *size = [NSCollectionLayoutSize sizeWithWidthDimension:[NSCollectionLayoutDimension estimatedDimension:90]
                                                                 heightDimension:[NSCollectionLayoutDimension absoluteDimension:34]];
    NSCollectionLayoutItem *item = [NSCollectionLayoutItem itemWithLayoutSize:size];
    NSCollectionLayoutGroup *group = [NSCollectionLayoutGroup horizontalGroupWithLayoutSize:
        [NSCollectionLayoutSize sizeWithWidthDimension:[NSCollectionLayoutDimension fractionalWidthDimension:1]
                                       heightDimension:[NSCollectionLayoutDimension absoluteDimension:34]] subitems:@[item]];
    group.interItemSpacing = [NSCollectionLayoutSpacing fixedSpacing:8];
    NSCollectionLayoutSection *section = [NSCollectionLayoutSection sectionWithGroup:group];
    section.interGroupSpacing = 8;
    section.contentInsets = NSDirectionalEdgeInsetsMake(0, 16, 8, 16);
    NSCollectionLayoutBoundarySupplementaryItem *header = [NSCollectionLayoutBoundarySupplementaryItem
        boundarySupplementaryItemWithLayoutSize:[NSCollectionLayoutSize sizeWithWidthDimension:[NSCollectionLayoutDimension fractionalWidthDimension:1]
                                                                               heightDimension:[NSCollectionLayoutDimension estimatedDimension:44]]
                                    elementKind:UICollectionElementKindSectionHeader alignment:NSRectAlignmentTop];
    section.boundarySupplementaryItems = @[header];
    return [super initWithCollectionViewLayout:[[UICollectionViewCompositionalLayout alloc] initWithSection:section]];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Your interests";
    self.collectionView.backgroundColor = FTBackgroundColor();
    self.collectionView.allowsMultipleSelection = YES;
    [self.collectionView registerClass:FTChipCell.class forCellWithReuseIdentifier:@"chip"];
    [self.collectionView registerClass:FTTopicHeader.class forSupplementaryViewOfKind:UICollectionElementKindSectionHeader withReuseIdentifier:@"header"];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Done" style:UIBarButtonItemStyleDone target:self action:@selector(done)];
    if (self.navigationController.viewControllers.firstObject == self) {
        self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(cancel)];
    }
    [FTEngine.shared topicCatalog:^(NSArray<NSDictionary *> *catalog) {
        self.catalog = catalog;
        [self.collectionView reloadData];
    }];
}

- (NSInteger)numberOfSectionsInCollectionView:(UICollectionView *)collectionView {
    return self.catalog.count;
}

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    return [self.catalog[section][@"topics"] count];
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    FTChipCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"chip" forIndexPath:indexPath];
    cell.label.text = self.catalog[indexPath.section][@"topics"][indexPath.item];
    return cell;
}

- (UICollectionReusableView *)collectionView:(UICollectionView *)collectionView viewForSupplementaryElementOfKind:(NSString *)kind atIndexPath:(NSIndexPath *)indexPath {
    FTTopicHeader *header = [collectionView dequeueReusableSupplementaryViewOfKind:kind withReuseIdentifier:@"header" forIndexPath:indexPath];
    header.label.text = self.catalog[indexPath.section][@"name"];
    return header;
}

- (void)done {
    NSMutableArray *topics = [NSMutableArray array];
    // In the order picked matters to Flow (the first three weigh most); selection order is not
    // kept by UICollectionView, so catalog order stands in.
    NSArray *paths = [self.collectionView.indexPathsForSelectedItems sortedArrayUsingSelector:@selector(compare:)];
    for (NSIndexPath *path in paths) {
        [topics addObject:self.catalog[path.section][@"topics"][path.item]];
    }
    if (topics.count) [FTEngine.shared chooseTopics:topics];
    void (^onDone)(void) = self.onDone;
    if (self.navigationController.viewControllers.firstObject == self) {
        [self dismissViewControllerAnimated:YES completion:^{ if (onDone && topics.count) onDone(); }];
    } else {
        [self.navigationController popViewControllerAnimated:YES];
        if (onDone && topics.count) onDone();
    }
}

- (void)cancel {
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end


#pragma mark - Library

typedef NS_ENUM(NSInteger, FTLibraryKind) {
    FTLibrarySubscriptions,
    FTLibraryLikes,
    FTLibraryHistory,
};

@interface FTLibraryViewController ()
@property (nonatomic) UISegmentedControl *picker;
@property (nonatomic, copy) NSArray<NSDictionary *> *items;
@end

@implementation FTLibraryViewController

- (instancetype)init {
    return [super initWithStyle:UITableViewStylePlain];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Library";
    self.items = @[];
    self.picker = [[UISegmentedControl alloc] initWithItems:@[@"Subscriptions", @"Liked", @"History"]];
    self.picker.selectedSegmentIndex = 0;
    [self.picker addTarget:self action:@selector(reload) forControlEvents:UIControlEventValueChanged];
    self.navigationItem.titleView = self.picker;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 64;
    [self reload];
}

- (FTLibraryKind)kind {
    return (FTLibraryKind)self.picker.selectedSegmentIndex;
}

- (void)reload {
    NSString *kind = @[@"subscriptions", @"likes", @"history"][self.kind];
    [FTEngine.shared library:kind completion:^(NSArray<NSDictionary *> *items) {
        self.items = items;
        [self.tableView reloadData];
    }];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.items.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (self.items.count) return nil;
    return @[@"No subscriptions in Flow yet. Subscribe in YouTube, copy them from your account in Flow's settings, or import a file.",
             @"Videos you like show up here.",
             @"Videos you watch show up here."][self.kind];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"item"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"item"];
    NSDictionary *item = self.items[indexPath.row];
    UIListContentConfiguration *content = [UIListContentConfiguration subtitleCellConfiguration];
    if (self.kind == FTLibrarySubscriptions) {
        NSString *name = [item[@"name"] isKindOfClass:NSString.class] && [item[@"name"] length] ? item[@"name"] : item[@"id"];
        content.text = name;
        content.image = [UIImage systemImageNamed:@"person.crop.circle"];
        content.imageProperties.tintColor = UIColor.secondaryLabelColor;
    } else {
        content.text = [item[@"title"] isKindOfClass:NSString.class] ? item[@"title"] : @"";
        content.textProperties.numberOfLines = 2;
        NSString *channel = item[@"channelName"];
        content.secondaryText = [channel isKindOfClass:NSString.class] ? channel : nil;
        content.secondaryTextProperties.color = UIColor.secondaryLabelColor;
    }
    cell.contentConfiguration = content;
    return cell;
}

- (NSString *)videoIDAt:(NSIndexPath *)indexPath {
    NSDictionary *item = self.items[indexPath.row];
    id value = item[@"videoId"] ?: item[@"id"];
    return [value isKindOfClass:NSString.class] ? value : nil;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSString *target = [self videoIDAt:indexPath];
    if (target.length == 0) return;
    BOOL channel = self.kind == FTLibrarySubscriptions;
    UIViewController *presenter = self.navigationController.presentingViewController;
    [self.navigationController dismissViewControllerAnimated:YES completion:^{
        if (channel) FTOpenBrowse(target, presenter);
        else FTOpenVideo(target, presenter, presenter.view);
    }];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *item = self.items[indexPath.row];
    NSString *target = [self videoIDAt:indexPath];
    if (target.length == 0 || self.kind == FTLibraryHistory) return nil;
    BOOL subscriptions = self.kind == FTLibrarySubscriptions;
    UIContextualAction *remove = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
        title:subscriptions ? @"Unsubscribe" : @"Unlike"
        handler:^(UIContextualAction *action, UIView *view, void (^done)(BOOL)) {
            if (subscriptions) [FTEngine.shared setSubscribed:NO channelID:target name:item[@"name"]];
            else [FTEngine.shared feedback:@"unlike" videoID:target video:item];
            NSMutableArray *items = [self.items mutableCopy];
            [items removeObjectAtIndex:indexPath.row];
            self.items = items;
            [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
            done(YES);
        }];
    return [UISwipeActionsConfiguration configurationWithActions:@[remove]];
}

@end
