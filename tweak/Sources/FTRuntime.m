#import "FTRuntime.h"

static NSMutableArray<NSString *> *FTLogLines(void) {
    static NSMutableArray *lines;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lines = [NSMutableArray array]; });
    return lines;
}

void FTLogMessage(NSString *message) {
    NSLog(@"[FlowTube] %@", message);
    static NSDateFormatter *formatter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        formatter = [NSDateFormatter new];
        formatter.dateFormat = @"HH:mm:ss";
    });
    NSMutableArray *lines = FTLogLines();
    @synchronized (lines) {
        [lines addObject:[NSString stringWithFormat:@"%@ %@", [formatter stringFromDate:NSDate.date], message]];
        if (lines.count > 400) [lines removeObjectsInRange:NSMakeRange(0, lines.count - 400)];
    }
}

NSString *FTLogText(void) {
    NSMutableArray *lines = FTLogLines();
    @synchronized (lines) {
        return [lines componentsJoinedByString:@"\n"];
    }
}

BOOL FTHook(NSString *className, NSString *selectorName, IMP replacement, IMP *original) {
    Class cls = NSClassFromString(className);
    if (cls == Nil || replacement == NULL) {
        FTLog(@"hook skipped: %@ missing", className);
        return NO;
    }
    SEL selector = NSSelectorFromString(selectorName);
    Method method = class_getInstanceMethod(cls, selector);
    if (method == NULL) {
        FTLog(@"hook skipped: -[%@ %@] missing", className, selectorName);
        return NO;
    }
    @synchronized ([NSObject class]) {
        IMP previous = method_getImplementation(method);
        // Inherited methods get an override on this class, so the superclass is untouched.
        if (!class_addMethod(cls, selector, replacement, method_getTypeEncoding(method))) {
            previous = method_setImplementation(class_getInstanceMethod(cls, selector), replacement);
        }
        *original = previous;
    }
    return YES;
}

id FTGet(id receiver, NSString *selectorName) {
    if (receiver == nil) return nil;
    SEL selector = NSSelectorFromString(selectorName);
    if (![receiver respondsToSelector:selector]) return nil;
    NSMethodSignature *signature = [receiver methodSignatureForSelector:selector];
    if (signature.numberOfArguments != 2 || signature.methodReturnType[0] != '@') return nil;
    @try {
        return ((id (*)(id, SEL))objc_msgSend)(receiver, selector);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

NSString *FTString(id receiver, NSArray<NSString *> *selectors) {
    for (NSString *selector in selectors) {
        id value = FTGet(receiver, selector);
        if ([value isKindOfClass:NSString.class] && [(NSString *)value length] > 0) return value;
    }
    return nil;
}

double FTDouble(id receiver, NSString *selectorName) {
    if (receiver == nil) return 0;
    SEL selector = NSSelectorFromString(selectorName);
    if (![receiver respondsToSelector:selector]) return 0;
    NSMethodSignature *signature = [receiver methodSignatureForSelector:selector];
    if (signature.numberOfArguments != 2) return 0;
    @try {
        switch (signature.methodReturnType[0]) {
            case 'd': return ((double (*)(id, SEL))objc_msgSend)(receiver, selector);
            case 'f': return ((float (*)(id, SEL))objc_msgSend)(receiver, selector);
            case 'q': case 'l': case 'i': case 's':
                return (double)((long long (*)(id, SEL))objc_msgSend)(receiver, selector);
            case 'Q': case 'L': case 'I': case 'S':
                return (double)((unsigned long long (*)(id, SEL))objc_msgSend)(receiver, selector);
            case '@': {
                id value = ((id (*)(id, SEL))objc_msgSend)(receiver, selector);
                return [value respondsToSelector:@selector(doubleValue)] ? [value doubleValue] : 0;
            }
            default: return 0;
        }
    } @catch (__unused NSException *exception) {
        return 0;
    }
}

BOOL FTBool(id receiver, NSString *selectorName) {
    if (receiver == nil) return NO;
    SEL selector = NSSelectorFromString(selectorName);
    if (![receiver respondsToSelector:selector]) return NO;
    NSMethodSignature *signature = [receiver methodSignatureForSelector:selector];
    if (signature.numberOfArguments != 2) return NO;
    char type = signature.methodReturnType[0];
    if (type != 'B' && type != 'c') return NO;
    @try {
        return ((BOOL (*)(id, SEL))objc_msgSend)(receiver, selector);
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

id FTValue(id receiver, NSString *key) {
    if (receiver == nil) return nil;
    @try {
        return [receiver valueForKey:key];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

UIWindow *FTKeyWindow(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        if (scene.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.isKeyWindow) return window;
        }
    }
    return nil;
}
