// SPDX-FileCopyrightText: 2026 Verlintas
// SPDX-License-Identifier: AGPL-3.0-only

// ExtraWeChat runtime: window privacy for WeChat.
//
// Loaded into the patched copy through DYLD_INSERT_LIBRARIES (the copy is
// re-signed with com.apple.security.cs.allow-dyld-environment-variables).
// It marks every WeChat NSWindow as excluded from screen capture / screen
// sharing. This mirrors WeChat's own "hide window from screenshots" setting,
// but covers chat windows, image viewers and other panels too.

#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>
#include <stdlib.h>
#include <string.h>

static BOOL gEnabled = NO;

static void applyPrivacy(NSWindow *window) {
    if (!gEnabled || window == nil) return;
    @try {
        window.sharingType = NSWindowSharingNone;
    } @catch (NSException *exception) {
        (void)exception;
        // Never let a privacy failure disturb WeChat.
    }
}

static void applyToAllWindows(void) {
    if (!gEnabled) return;
    NSApplication *app = NSApp;
    if (app == nil) return;
    for (NSWindow *window in app.windows) {
        applyPrivacy(window);
    }
}

typedef void (*VoidIdIMP)(id, SEL, id);
typedef void (*VoidIMP)(id, SEL);
typedef id (*InitWindowIMP)(id, SEL, NSRect, NSWindowStyleMask,
                            NSBackingStoreType, BOOL);
typedef void (*OrderWindowIMP)(id, SEL, NSInteger, NSInteger);
typedef void (*SetSharingIMP)(id, SEL, NSWindowSharingType);

static VoidIdIMP gOrderFront = NULL;
static VoidIdIMP gMakeKeyAndOrderFront = NULL;
static VoidIMP gOrderFrontRegardless = NULL;
static InitWindowIMP gInitWindow = NULL;
static OrderWindowIMP gOrderWindow = NULL;
static SetSharingIMP gSetSharing = NULL;
static NSTimer *gPrivacyTimer = nil;

static void hookOrderFront(id self, SEL _cmd, id sender) {
    applyPrivacy(self);
    if (gOrderFront) gOrderFront(self, _cmd, sender);
}

static void hookMakeKeyAndOrderFront(id self, SEL _cmd, id sender) {
    applyPrivacy(self);
    if (gMakeKeyAndOrderFront) gMakeKeyAndOrderFront(self, _cmd, sender);
}

static void hookOrderFrontRegardless(id self, SEL _cmd) {
    applyPrivacy(self);
    if (gOrderFrontRegardless) gOrderFrontRegardless(self, _cmd);
}

static void hookOrderWindow(id self, SEL _cmd, NSInteger place, NSInteger other) {
    applyPrivacy(self);
    if (gOrderWindow) gOrderWindow(self, _cmd, place, other);
    applyToAllWindows();
}

static void hookSetSharing(id self, SEL _cmd, NSWindowSharingType type) {
    if (gEnabled) type = NSWindowSharingNone;
    if (gSetSharing) gSetSharing(self, _cmd, type);
}

static id hookInitWindow(id self, SEL _cmd, NSRect rect,
                         NSWindowStyleMask style, NSBackingStoreType backing,
                         BOOL defer) {
    id result = gInitWindow ? gInitWindow(self, _cmd, rect, style, backing, defer) : nil;
    applyPrivacy(result);
    return result;
}

static void replaceMethod(Class cls, SEL selector, IMP replacement, IMP *original) {
    Method method = class_getInstanceMethod(cls, selector);
    if (method == NULL) return;
    *original = method_getImplementation(method);
    method_setImplementation(method, replacement);
}

__attribute__((constructor)) static void initialize(void) {
    @autoreleasepool {
        const char *value = getenv("EXTRAWECHAT_WINDOW_PRIVACY");
        if (value == NULL || strcmp(value, "1") != 0) return;
        gEnabled = YES;

        Class windowClass = [NSWindow class];
        replaceMethod(windowClass, @selector(orderFront:),
                      (IMP)hookOrderFront, (IMP *)&gOrderFront);
        replaceMethod(windowClass, @selector(makeKeyAndOrderFront:),
                      (IMP)hookMakeKeyAndOrderFront, (IMP *)&gMakeKeyAndOrderFront);
        replaceMethod(windowClass, @selector(orderFrontRegardless),
                      (IMP)hookOrderFrontRegardless, (IMP *)&gOrderFrontRegardless);
        replaceMethod(windowClass, @selector(orderWindow:relativeTo:),
                      (IMP)hookOrderWindow, (IMP *)&gOrderWindow);
        replaceMethod(windowClass, @selector(setSharingType:),
                      (IMP)hookSetSharing, (IMP *)&gSetSharing);
        replaceMethod(windowClass,
                      @selector(initWithContentRect:styleMask:backing:defer:),
                      (IMP)hookInitWindow, (IMP *)&gInitWindow);

        // Some WeChat panels bypass orderFront: or are created before the
        // dylib loads. Watch window events and keep a low-frequency sweep so
        // every window ends up with sharingType = .none.
        for (NSString *name in @[
                 NSWindowDidBecomeKeyNotification,
                 NSWindowDidBecomeMainNotification,
                 @"NSWindowDidOrderOnScreenNotification"
             ]) {
            [[NSNotificationCenter defaultCenter]
                addObserverForName:name
                            object:nil
                             queue:[NSOperationQueue mainQueue]
                        usingBlock:^(NSNotification *note) {
                            applyPrivacy(note.object);
                            applyToAllWindows();
                        }];
        }

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{ applyToAllWindows(); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1500 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{ applyToAllWindows(); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4000 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{ applyToAllWindows(); });
        gPrivacyTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                       repeats:YES
                                                         block:^(NSTimer *timer) {
            (void)timer;
            applyToAllWindows();
        }];
    }
}
