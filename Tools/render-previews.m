// Documentation and picker images rendered by the same code as the native products.
#define AC_HARNESS 1
#import "../Sources/AtelierClockView.m"

static BOOL WritePreview(AtelierClockView *view, NSInteger width, NSInteger height, NSString *path) {
    NSRect bounds=NSMakeRect(0,0,width,height);
    view.frame=bounds;
    NSBitmapImageRep *bitmap=[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
        pixelsWide:width pixelsHigh:height bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES
        isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    if (!bitmap) return NO;
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap]];
    [view drawRect:bounds];
    [NSGraphicsContext restoreGraphicsState];
    NSData *png=[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    return [png writeToFile:path atomically:YES];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc!=4) return 1;
        NSString *output=[NSString stringWithUTF8String:argv[1]];
        NSString *resources=[NSString stringWithUTF8String:argv[2]];
        NSString *iconset=[NSString stringWithUTF8String:argv[3]];
        NSArray<NSString *> *names=@[@"atelier",@"bill",@"los-angeles",@"ikko",@"georg"];
        const NSInteger size=800;
        NSRect bounds=NSMakeRect(0,0,size,size);
        AtelierClockView *view=[[AtelierClockView alloc] initWithFrame:bounds isPreview:YES];
        NSCalendar *calendar=[[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
        NSDateComponents *time=[NSDateComponents new];
        time.year=2026; time.month=1; time.day=1; time.hour=10; time.minute=10; time.second=30;
        [view acSetDate:[calendar dateFromComponents:time]];
        for (NSInteger design=0;design<(NSInteger)names.count;design++) {
            [view acConfigureDesign:design palette:0 appearance:0 numerals:NO];
            NSString *path=[output stringByAppendingPathComponent:[names[design] stringByAppendingString:@".png"]];
            if (!WritePreview(view,size,size,path)) return 1;
        }
        // Ikko's bold hands and integral numerals stay legible in a small picker tile.
        [view acConfigureDesign:3 palette:0 appearance:0 numerals:NO];
        // Leave extra vertical margin for the picker tile's aspect-fill crop.
        [view acSetScale:0.78];
        if (!WritePreview(view,90,58,[resources stringByAppendingPathComponent:@"thumbnail.png"])) return 1;
        if (!WritePreview(view,180,116,[resources stringByAppendingPathComponent:@"thumbnail@2x.png"])) return 1;
        [view acSetScale:0.92];
        for (NSNumber *points in @[@16,@32,@128,@256,@512]) {
            NSInteger side=points.integerValue;
            for (NSInteger scale=1;scale<=2;scale++) {
                NSString *name=[NSString stringWithFormat:@"icon_%ldx%ld%@.png",
                    (long)side,(long)side,scale==2 ? @"@2x" : @""];
                if (!WritePreview(view,side*scale,side*scale,[iconset stringByAppendingPathComponent:name])) return 1;
            }
        }
        puts("Rendered five native dial previews in docs/previews/.");
        puts("Rendered Screen Saver picker thumbnails in Resources/.");
    }
    return 0;
}
