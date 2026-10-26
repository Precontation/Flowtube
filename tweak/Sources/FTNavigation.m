#import "FTNavigation.h"
#import "FTRuntime.h"

UIViewController *FTTopViewController(void) {
    UIViewController *top = FTKeyWindow().rootViewController;
    while (top.presentedViewController != nil && !top.presentedViewController.isBeingDismissed) {
        top = top.presentedViewController;
    }
    return top;
}

static id FTMessage(NSString *className) {
    Class cls = NSClassFromString(className);
    return [cls respondsToSelector:@selector(message)] ? ((id (*)(id, SEL))objc_msgSend)(cls, @selector(message)) : nil;
}

BOOL FTSendCommand(id command, id responder, UIView *view) {
    if (command == nil) return NO;
    id first = responder ?: FTTopViewController();
    Class eventClass = NSClassFromString(@"YTCommandResponderEvent");
    SEL make = NSSelectorFromString(@"eventWithCommand:fromView:displayTitle:firstResponder:");
    if (first == nil || ![eventClass respondsToSelector:make]) return NO;
    @try {
        id event = ((id (*)(id, SEL, id, id, id, id))objc_msgSend)(eventClass, make, command, view, nil, first);
        if (![event respondsToSelector:@selector(send)]) return NO;
        ((void (*)(id, SEL))objc_msgSend)(event, @selector(send));
        return YES;
    } @catch (NSException *exception) {
        FTLog(@"command failed: %@", exception.reason);
        return NO;
    }
}

void FTOpenVideo(NSString *videoID, id responder, UIView *view) {
    Class commandClass = NSClassFromString(@"YTICommand");
    id command = nil;
    SEL factory = NSSelectorFromString(@"watchNavigationEndpointWithVideoID:");
    @try {
        if ([commandClass respondsToSelector:factory]) {
            command = ((id (*)(id, SEL, id))objc_msgSend)(commandClass, factory, videoID);
        }
        if (command == nil) {
            id endpoint = FTMessage(@"YTIWatchEndpoint");
            command = FTMessage(@"YTICommand");
            [endpoint setValue:videoID forKey:@"videoId"];
            [command setValue:endpoint forKey:@"watchEndpoint"];
        }
    } @catch (__unused NSException *exception) {
        command = nil;
    }
    if (FTSendCommand(command, responder, view)) return;
    // In-process URL handling: never leaves the app, even with the real YouTube installed.
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"youtube://www.youtube.com/watch?v=%@", videoID]];
    UIApplication *app = UIApplication.sharedApplication;
    if ([app.delegate respondsToSelector:@selector(application:openURL:options:)]) {
        [app.delegate application:app openURL:url options:@{}];
    }
}

void FTOpenBrowse(NSString *browseID, id responder) {
    Class commandClass = NSClassFromString(@"YTICommand");
    id command = nil;
    @try {
        SEL channel = NSSelectorFromString(@"browseNavigationEndpointWithChannelID:");
        SEL browse = NSSelectorFromString(@"browseNavigationEndpointWithBrowseID:");
        if ([browseID hasPrefix:@"UC"] && [commandClass respondsToSelector:channel]) {
            command = ((id (*)(id, SEL, id))objc_msgSend)(commandClass, channel, browseID);
        } else if ([commandClass respondsToSelector:browse]) {
            command = ((id (*)(id, SEL, id))objc_msgSend)(commandClass, browse, browseID);
        }
        if (command == nil) {
            id endpoint = FTMessage(@"YTIBrowseEndpoint");
            command = FTMessage(@"YTICommand");
            [endpoint setValue:browseID forKey:@"browseId"];
            [command setValue:endpoint forKey:@"browseEndpoint"];
        }
    } @catch (__unused NSException *exception) {
        command = nil;
    }
    if (FTSendCommand(command, responder, nil)) return;
    if ([browseID hasPrefix:@"UC"]) {
        NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"youtube://www.youtube.com/channel/%@", browseID]];
        UIApplication *app = UIApplication.sharedApplication;
        if ([app.delegate respondsToSelector:@selector(application:openURL:options:)]) {
            [app.delegate application:app openURL:url options:@{}];
        }
    }
}

void FTToast(NSString *message) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = FTKeyWindow();
        if (window == nil) return;
        UILabel *label = [UILabel new];
        label.text = message;
        label.numberOfLines = 2;
        label.textAlignment = NSTextAlignmentCenter;
        label.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        label.textColor = UIColor.systemBackgroundColor;
        label.backgroundColor = [UIColor.labelColor colorWithAlphaComponent:0.92];
        label.layer.cornerRadius = 18;
        label.layer.cornerCurve = kCACornerCurveContinuous;
        label.clipsToBounds = YES;
        CGFloat width = MIN(CGRectGetWidth(window.bounds) - 48, 360);
        CGSize fit = [label sizeThatFits:CGSizeMake(width - 32, CGFLOAT_MAX)];
        CGFloat height = MAX(36, fit.height + 18);
        CGFloat bottom = window.safeAreaInsets.bottom + 72;
        label.frame = CGRectMake((CGRectGetWidth(window.bounds) - width) / 2, CGRectGetHeight(window.bounds) - bottom - height, width, height);
        label.alpha = 0;
        label.accessibilityTraits = UIAccessibilityTraitStaticText;
        [window addSubview:label];
        UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, message);
        [UIView animateWithDuration:0.2 animations:^{ label.alpha = 1; } completion:^(BOOL done) {
            [UIView animateWithDuration:0.3 delay:2.2 options:0 animations:^{ label.alpha = 0; } completion:^(BOOL finished) {
                [label removeFromSuperview];
            }];
        }];
    });
}
