#import <Cocoa/Cocoa.h>
#import "AtelierClockView.h"

@interface AtelierApp : NSObject <NSApplicationDelegate>
@property(strong) NSWindow *window;
@property(strong) AtelierClockView *clock;
@property(strong) NSTimer *timer;
@end
@implementation AtelierApp
- (void)applicationDidFinishLaunching:(NSNotification *)note {
    NSMenu *menu=[NSMenu new]; NSMenuItem *root=[NSMenuItem new]; [menu addItem:root];
    NSMenu *app=[NSMenu new]; root.submenu=app;
    [app addItemWithTitle:@"About Atelier Clock" action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];
    [app addItem:[NSMenuItem separatorItem]];
    NSMenuItem *settings=[app addItemWithTitle:@"Clock Settings…" action:@selector(settings:) keyEquivalent:@","]; settings.target=self;
    NSMenuItem *fullscreen=[app addItemWithTitle:@"Enter / Exit Full Screen" action:@selector(fullscreen:) keyEquivalent:@"f"]; fullscreen.target=self;
    [app addItem:[NSMenuItem separatorItem]];
    [app addItemWithTitle:@"Quit Atelier Clock" action:@selector(terminate:) keyEquivalent:@"q"];
    NSApp.mainMenu=menu;
    self.window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,1120,760)
        styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    self.window.title=@"Atelier Clock"; self.window.minSize=NSMakeSize(320,320);
    self.window.collectionBehavior=NSWindowCollectionBehaviorFullScreenPrimary;
    self.clock=[[AtelierClockView alloc] initWithFrame:self.window.contentView.bounds isPreview:NO];
    self.window.contentView=self.clock; [self.window center]; [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    __weak AtelierApp *weakSelf=self;
    self.timer=[NSTimer timerWithTimeInterval:1.0/30.0 repeats:YES block:^(NSTimer *timer) {
        if ((weakSelf.window.occlusionState & NSWindowOcclusionStateVisible) != 0) [weakSelf.clock animateOneFrame];
    }];
    [[NSRunLoop mainRunLoop] addTimer:self.timer forMode:NSRunLoopCommonModes];
}
- (void)settings:(id)sender { if (!self.window.attachedSheet) [self.window beginSheet:self.clock.configureSheet completionHandler:nil]; }
- (void)fullscreen:(id)sender { [self.window toggleFullScreen:nil]; }
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { return YES; }
- (void)applicationWillTerminate:(NSNotification *)notification { [self.timer invalidate]; }
@end
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app=[NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        __attribute__((objc_precise_lifetime)) AtelierApp *delegate=[AtelierApp new]; app.delegate=delegate; [app run];
    }
    return 0;
}
