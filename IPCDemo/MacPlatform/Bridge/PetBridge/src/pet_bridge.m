#import <AppKit/AppKit.h>
#include "pet_bridge.h"
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>

/* C ABI, private Objective-C/ARC implementation. No native object is exposed
 * through the public header. This implementation deliberately targets Mac only. */
struct pet_bridge_window {
    void *retained_window;
    struct pet_bridge_window *next;
};
static struct pet_bridge_window *g_handles = NULL; /* main thread only */
static atomic_size_t g_live_handles = 0;
static atomic_size_t g_live_windows = 0;
static _Thread_local const char *g_error = "";

@interface PBTestWindow : NSWindow
@end
@implementation PBTestWindow
- (instancetype)initWithContentRect:(NSRect)rect styleMask:(NSWindowStyleMask)style backing:(NSBackingStoreType)backing defer:(BOOL)defer {
    self = [super initWithContentRect:rect styleMask:style backing:backing defer:defer];
    if (self) atomic_fetch_add(&g_live_windows, 1);
    return self;
}
- (BOOL)canBecomeKey { return NO; }
- (BOOL)canBecomeMain { return NO; }
- (void)dealloc {
    size_t remaining = atomic_fetch_sub(&g_live_windows, 1) - 1;
    fprintf(stderr, "[petbridge] native window deallocated; live_native_windows=%zu\n", remaining);
}
@end

static int require_main(void) {
    if (![NSThread isMainThread]) { g_error = "MAIN_THREAD_REQUIRED"; return 0; }
    g_error = ""; return 1;
}
static int is_live(const struct pet_bridge_window *handle) {
    for (const struct pet_bridge_window *cursor = g_handles; cursor; cursor = cursor->next)
        if (cursor == handle) return 1;
    return 0;
}
const char *bridge_last_error(void) { return g_error; }
size_t bridge_debug_live_handles(void) { return atomic_load(&g_live_handles); }
size_t bridge_debug_live_native_windows(void) { return atomic_load(&g_live_windows); }

pet_bridge_window *bridge_create_test_window(void) {
    if (!require_main()) return NULL;
    @autoreleasepool {
        struct pet_bridge_window *handle = calloc(1, sizeof(*handle));
        if (!handle) { g_error = "ALLOCATION_FAILED"; return NULL; }
        @try {
            if (!NSApp) {
                NSApplication *application = [NSApplication sharedApplication];
                [application setActivationPolicy:NSApplicationActivationPolicyAccessory];
                [application finishLaunching];
            }
            NSRect area = NSScreen.mainScreen ? NSScreen.mainScreen.visibleFrame : NSMakeRect(0, 0, 1280, 800);
            NSRect frame = NSMakeRect(NSMidX(area) - 140, NSMidY(area) - 70, 280, 140);
            PBTestWindow *window = [[PBTestWindow alloc] initWithContentRect:frame
                styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                backing:NSBackingStoreBuffered defer:NO];
            if (!window) { free(handle); g_error = "WINDOW_CREATION_FAILED"; return NULL; }
            window.title = @"petbridge 最小调用测试";
            window.releasedWhenClosed = NO;
            window.animationBehavior = NSWindowAnimationBehaviorNone;
            window.backgroundColor = NSColor.windowBackgroundColor;
            NSTextField *label = [NSTextField labelWithString:@"Swift → C ABI → AppKit\n测试后自动关闭"];
            label.frame = NSMakeRect(12, 35, 256, 60);
            label.alignment = NSTextAlignmentCenter;
            [window.contentView addSubview:label];
            [window orderFrontRegardless];
            handle->retained_window = (__bridge_retained void *)window;
            handle->next = g_handles; g_handles = handle;
            atomic_fetch_add(&g_live_handles, 1);
            fprintf(stderr, "[petbridge] created; live_handles=%zu live_native_windows=%zu\n", bridge_debug_live_handles(), bridge_debug_live_native_windows());
            return handle;
        } @catch (NSException *exception) {
            (void)exception;
            free(handle); g_error = "APPKIT_CREATE_EXCEPTION";
            return NULL;
        }
    }
}
int bridge_set_topmost(pet_bridge_window *handle, int is_top) {
    if (!require_main()) return -2;
    if (!handle || !is_live(handle) || (is_top != 0 && is_top != 1)) { g_error = "INVALID_HANDLE_OR_ARGUMENT"; return -1; }
    @autoreleasepool {
        @try {
            NSWindow *window = (__bridge NSWindow *)handle->retained_window;
            window.level = is_top ? NSFloatingWindowLevel : NSNormalWindowLevel;
            fprintf(stderr, "[petbridge] set_topmost=%d native_level=%ld\n", is_top, (long)window.level);
            return 0;
        } @catch (NSException *exception) {
            (void)exception; g_error = "APPKIT_LEVEL_EXCEPTION"; return -1;
        }
    }
}
int bridge_debug_is_topmost(pet_bridge_window *handle) {
    if (!require_main()) return -2;
    if (!handle || !is_live(handle)) { g_error = "INVALID_HANDLE"; return -1; }
    NSWindow *window = (__bridge NSWindow *)handle->retained_window;
    return window.level == NSFloatingWindowLevel ? 1 : 0;
}
void bridge_destroy_window(pet_bridge_window *handle) {
    if (!handle) return;
    if (!require_main()) return;
    if (!is_live(handle)) { g_error = "INVALID_HANDLE"; return; }
    @autoreleasepool {
        struct pet_bridge_window **link = &g_handles;
        while (*link != handle) link = &(*link)->next;
        *link = handle->next;
        /* Balance exactly the __bridge_retained above. ARC releases the native
         * object when this local leaves scope; free() is only for our C handle. */
        NSWindow *window = (__bridge_transfer NSWindow *)handle->retained_window;
        handle->retained_window = NULL;
        @try { [window orderOut:nil]; [window close]; }
        @catch (NSException *exception) { (void)exception; g_error = "APPKIT_CLOSE_EXCEPTION"; }
        free(handle);
        atomic_fetch_sub(&g_live_handles, 1);
        fprintf(stderr, "[petbridge] destroyed; live_handles=%zu\n", bridge_debug_live_handles());
    }
}
