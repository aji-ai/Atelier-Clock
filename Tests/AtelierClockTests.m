// Run with: bash Tests/run.sh
#define AC_HARNESS 1
#import "../Sources/AtelierClockView.m"
#include <assert.h>

// Exercise preference handling without changing the user's saved settings.
@interface ACTestDefaults : NSObject
@property NSMutableDictionary *values;
@end
@implementation ACTestDefaults
- (instancetype)init {
    if ((self=[super init])) _values=[@{@"design":@2,@"palette":@3,@"appearance":@1,
        @"movement":@2,@"size":@0.72,@"numerals":@YES,@"automatic":@NO} mutableCopy];
    return self;
}
- (NSInteger)integerForKey:(NSString *)key { return [_values[key] integerValue]; }
- (double)doubleForKey:(NSString *)key { return [_values[key] doubleValue]; }
- (BOOL)boolForKey:(NSString *)key { return [_values[key] boolValue]; }
- (void)setInteger:(NSInteger)value forKey:(NSString *)key { _values[key]=@(value); }
- (void)setDouble:(double)value forKey:(NSString *)key { _values[key]=@(value); }
- (void)setBool:(BOOL)value forKey:(NSString *)key { _values[key]=@(value); }
- (BOOL)synchronize { return YES; }
@end

static NSDate *ACDate(NSString *iso) {
    return [[NSISO8601DateFormatter new] dateFromString:iso];
}
static NSInteger ACInt(id view, NSString *key) { return [[view valueForKey:key] integerValue]; }

static NSBitmapImageRep *ACShiftFrame(AtelierClockView *view, NSTimeInterval elapsed) {
    [view acSetDisplayElapsed:elapsed];
    NSBitmapImageRep *bitmap=[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
        pixelsWide:256 pixelsHigh:256 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES
        isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap]];
    [view drawRect:NSMakeRect(0,0,256,256)];
    [NSGraphicsContext restoreGraphicsState];
    return bitmap;
}
static void ACTestDisplayShift(void) {
    ACDisplayShift initial=ACDisplayShiftForElapsed(299.99,NO);
    assert(NSEqualPoints(initial.from,NSZeroPoint) && initial.mix==0);
    assert(ACDisplayShiftForElapsed(300,NO).mix==0);
    assert(ACDisplayShiftForElapsed(305,NO).mix==0.5);
    assert(ACDisplayShiftForElapsed(310,NO).mix==1);
    assert(ACDisplayShiftForElapsed(300,YES).mix==1);
    for (NSInteger cycle=1;cycle<100;cycle++) {
        ACDisplayShift before=ACDisplayShiftForElapsed(cycle*300-0.001,NO);
        ACDisplayShift next=ACDisplayShiftForElapsed(cycle*300,NO);
        NSPoint held=before.mix==1 ? before.to : before.from;
        assert(NSEqualPoints(held,next.from));
        assert(!NSEqualPoints(next.from,next.to));
        // At maximum clock size, even the full 640-unit artwork stays inside.
        assert(hypot(next.to.x,next.to.y)<=1.00001);
        assert(0.92/2+fabs(next.to.x)*0.012<0.5);
        assert(0.92/2+fabs(next.to.y)*0.012<0.5);
    }
    AtelierClockView *view=[[AtelierClockView alloc] initWithFrame:NSMakeRect(0,0,256,256) isPreview:NO];
    [view acSetDate:ACDate(@"2026-01-01T10:10:30Z")];
    BOOL reduce=[NSWorkspace sharedWorkspace].accessibilityDisplayShouldReduceMotion;
    for (NSInteger design=0;design<5;design++) {
        [view acConfigureDesign:design palette:0 appearance:0 numerals:NO];
        NSBitmapImageRep *a=ACShiftFrame(view,0), *b=ACShiftFrame(view,310), *mid=ACShiftFrame(view,305);
        NSUInteger changed=0;
        for (NSInteger y=0;y<256;y++) for (NSInteger x=0;x<256;x++) {
            NSUInteger ca[4],cb[4],cm[4];
            [a getPixel:ca atX:x y:y]; [b getPixel:cb atX:x y:y]; [mid getPixel:cm atX:x y:y];
            assert(ca[3]==255 && cb[3]==255 && cm[3]==255);
            for (NSInteger channel=0;channel<3;channel++) {
                CGFloat expected=reduce ? cb[channel] : (ca[channel]+cb[channel])/2.0;
                assert(fabs(cm[channel]-expected)<=3);
                if (ca[channel]!=cb[channel]) changed++;
            }
        }
        assert(changed>100);
    }
    AtelierClockView *preview=[[AtelierClockView alloc] initWithFrame:NSMakeRect(0,0,256,256) isPreview:YES];
    [preview acConfigureDesign:0 palette:0 appearance:0 numerals:NO];
    [preview acSetDate:ACDate(@"2026-01-01T10:10:30Z")];
    NSBitmapImageRep *a=ACShiftFrame(preview,0), *b=ACShiftFrame(preview,305);
    assert(memcmp(a.bitmapData,b.bitmapData,a.bytesPerRow*a.pixelsHigh)==0);
    puts("Display shift passed (timing, continuity, safe bounds, five-dial blending, stable previews).");
}

static void ACTestOptionsLifecycle(AtelierClockView *view) {
    NSWindow *host=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,700,500)
        styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    host.releasedWhenClosed=NO; host.animationBehavior=NSWindowAnimationBehaviorNone;
    [host orderFront:nil];
    for (NSInteger i=0;i<100;i++) {
        NSWindow *sheet=[view configureSheet]; sheet.animationBehavior=NSWindowAnimationBehaviorNone;
        __block NSInteger completions=0;
        __block NSModalResponse result=NSModalResponseContinue;
        [host beginSheet:sheet completionHandler:^(NSModalResponse code) { completions++; result=code; }];
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
        assert(host.attachedSheet==sheet);
        NSPopUpButton *design=[view valueForKey:@"designControl"];
        [design selectItemAtIndex:4]; [view designChanged:nil];
        // Hosts may query the property repeatedly during one presentation.
        assert([view configureSheet]==sheet);
        assert(host.attachedSheet==sheet && sheet.sheetParent==host);
        assert(design.indexOfSelectedItem==4 && completions==0);
        if (i%2) [view saveOptions:nil]; else [view cancelOptions:nil];
        NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:1];
        while (!completions && deadline.timeIntervalSinceNow>0)
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
        assert(completions==1 && !host.attachedSheet && !sheet.sheetParent && !sheet.visible);
        assert(result==(i%2?NSModalResponseOK:NSModalResponseCancel));
    }
    // A host can run the returned window modally without assigning sheetParent.
    for (NSInteger i=0;i<20;i++) {
        NSWindow *sheet=[view configureSheet];
        NSModalSession session=[NSApp beginModalSessionForWindow:sheet];
        assert([NSApp runModalSession:session]==NSModalResponseContinue);
        assert(NSApp.modalWindow==sheet && !sheet.sheetParent);
        if (i%2) [view saveOptions:nil]; else [view cancelOptions:nil];
        NSModalResponse response=[NSApp runModalSession:session];
        [NSApp endModalSession:session];
        assert(response==(i%2?NSModalResponseOK:NSModalResponseCancel));
        assert(NSApp.modalWindow!=sheet && !sheet.visible);
    }
    [host close];
    puts("Options lifecycle passed (100 sheets, repeated getter calls, 20 parentless modal sessions).");
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        ACTestDisplayShift();
        BOOL options=argc>1 && strcmp(argv[1],"--options")==0;
        if (options) [NSApplication sharedApplication];
        BOOL seen[5][5]={0};
        NSInteger previous=-1;
        // More than five centuries, covering shuffled-block boundaries as well.
        for (NSUInteger day=1;day<=200000;day++) {
            ACDailyStyle a=ACDailyStyleForDay(day), b=ACDailyStyleForDay(day);
            assert(a.design==b.design && a.palette==b.palette);
            assert(a.design>=0 && a.design<5 && a.design!=previous);
            NSInteger count; ACPalettesForDesign(a.design,&count);
            assert(a.palette>=0 && a.palette<count);
            seen[a.design][a.palette]=YES; previous=a.design;
        }
        for (NSInteger design=0;design<5;design++) {
            NSInteger count; ACPalettesForDesign(design,&count);
            for (NSInteger palette=0;palette<count;palette++) assert(seen[design][palette]);
        }
        NSCalendar *calendar=[[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
        calendar.timeZone=[NSTimeZone timeZoneWithName:@"America/Los_Angeles"];
        // Midnight, leap day, year boundary, and both daylight-saving transitions.
        NSArray *pairs=@[
            @[@"2026-09-28T06:59:59Z",@"2026-09-28T07:00:00Z",@1],
            @[@"2028-02-29T07:59:59Z",@"2028-02-29T08:00:00Z",@1],
            @[@"2029-01-01T07:59:59Z",@"2029-01-01T08:00:00Z",@1],
            @[@"2026-03-08T09:59:59Z",@"2026-03-08T10:00:00Z",@0],
            @[@"2026-11-01T08:59:59Z",@"2026-11-01T09:00:00Z",@0]
        ];
        for (NSArray *pair in pairs) {
            NSUInteger a=ACDayNumber(ACDate(pair[0]),calendar), b=ACDayNumber(ACDate(pair[1]),calendar);
            if (b-a!=[pair[2] unsignedIntegerValue]) fprintf(stderr,"Calendar mismatch: %s -> %s (%lu -> %lu)\n",
                [pair[0] UTF8String],[pair[1] UTF8String],(unsigned long)a,(unsigned long)b);
            assert(b-a==[pair[2] unsignedIntegerValue]);
        }
        NSDate *before=ACDate(@"2026-09-28T06:59:59Z"), *after=ACDate(@"2026-09-28T07:00:00Z");
        NSUInteger localDay=ACDayNumber(before,calendar);
        NSCalendar *utc=[calendar copy]; utc.timeZone=[NSTimeZone timeZoneForSecondsFromGMT:0];
        assert(ACDayNumber(before,utc)==localDay+1);
        AtelierClockView *view=[[AtelierClockView alloc] initWithFrame:NSMakeRect(0,0,640,640) isPreview:YES];
        NSTimeZone *originalZone=[NSTimeZone defaultTimeZone];
        [NSTimeZone setDefaultTimeZone:utc.timeZone];
        assert([view dayNumberForDate:before]==localDay+1);
        [NSTimeZone setDefaultTimeZone:calendar.timeZone];
        assert([view dayNumberForDate:before]==localDay);
        ACTestDefaults *defaults=[ACTestDefaults new];
        [view setValue:defaults forKey:@"defaults"];
        [view setValue:calendar forKey:@"dailyCalendar"];
        [view acSetDate:before]; [view reloadPreferences];
        assert(ACInt(view,@"design")==2 && ACInt(view,@"palette")==3);
        [defaults setBool:YES forKey:@"automatic"]; [view reloadPreferences];
        ACDailyStyle expected=ACDailyStyleForDay(localDay);
        assert(ACInt(view,@"design")==expected.design && ACInt(view,@"palette")==expected.palette);
        [view setValue:[[NSImage alloc] initWithSize:NSMakeSize(1,1)] forKey:@"dialCache"];
        [view updateDailyStyleForDate:before]; assert([view valueForKey:@"dialCache"]!=nil);
        [view updateDailyStyleForDate:after]; assert([view valueForKey:@"dialCache"]==nil);
        assert(ACInt(view,@"design")!=expected.design);
        // Reopening/reloading on the same date produces the same selection.
        [view acSetDate:after]; NSInteger next=ACInt(view,@"design"); [view reloadPreferences];
        assert(ACInt(view,@"design")==next);
        assert([defaults integerForKey:@"design"]==2 && [defaults integerForKey:@"palette"]==3);
        [defaults setBool:NO forKey:@"automatic"]; [view reloadPreferences];
        [view updateDailyStyleForDate:before];
        assert(ACInt(view,@"design")==2 && ACInt(view,@"palette")==3);

        // Materials are generated without resources, repeat across instances,
        // and reuse their image within a view instead of regenerating per frame.
        AtelierClockView *other=[[AtelierClockView alloc] initWithFrame:NSMakeRect(0,0,640,640) isPreview:YES];
        for (NSInteger finish=0;finish<3;finish++) {
            NSImage *image=[view woodTextureForFinish:finish];
            assert(image && image==[view woodTextureForFinish:finish]);
            NSBitmapImageRep *a=(NSBitmapImageRep *)image.representations.firstObject;
            NSBitmapImageRep *b=(NSBitmapImageRep *)[other woodTextureForFinish:finish].representations.firstObject;
            assert(a.pixelsWide==1024 && a.pixelsHigh==1024 && b.bytesPerRow==a.bytesPerRow);
            assert(memcmp(a.bitmapData,b.bitmapData,a.bytesPerRow*a.pixelsHigh)==0);
            unsigned char low=255, high=0;
            for (NSInteger y=0;y<a.pixelsHigh;y+=17) for (NSInteger x=0;x<a.pixelsWide;x+=17) {
                unsigned char value=a.bitmapData[y*a.bytesPerRow+x*3];
                low=MIN(low,value); high=MAX(high,value);
            }
            assert(high-low>8);
        }
        puts("Procedural materials passed (resource-free generation, repeatability, cache, tonal variation).");
        if (options) {
            [view configureSheet];
            NSPopUpButton *design=[view valueForKey:@"designControl"], *palette=[view valueForKey:@"paletteControl"];
            assert(design.numberOfItems==7 && palette.enabled);
            assert([design itemAtIndex:5].separatorItem);
            [design selectItemWithTag:ACAutomaticDesign]; [view designChanged:nil];
            assert(!palette.enabled && palette.numberOfItems==1);
            [view cancelOptions:nil]; assert(![defaults boolForKey:@"automatic"]);
            [view configureSheet]; assert(design.indexOfSelectedItem==2 && palette.indexOfSelectedItem==3);
            [design selectItemWithTag:ACAutomaticDesign]; [view designChanged:nil]; [view saveOptions:nil];
            assert([defaults boolForKey:@"automatic"] && [defaults integerForKey:@"design"]==2);
            [view configureSheet]; assert(design.selectedItem.tag==ACAutomaticDesign && !palette.enabled);
            [design selectItemAtIndex:1]; [view designChanged:nil]; assert(palette.enabled);
            [palette selectItemAtIndex:4]; [view saveOptions:nil];
            assert(![defaults boolForKey:@"automatic"] && ACInt(view,@"design")==1 && ACInt(view,@"palette")==4);
            ACTestOptionsLifecycle(view);
        }
        [NSTimeZone setDefaultTimeZone:originalZone];
        puts("Daily style checks passed (200,000 days, calendar transitions, preferences, cache)." );
        if (options) puts("Options Save/Cancel and Auto/Manual checks passed.");
    }
    return 0;
}
