#import "AtelierClockView.h"
#import <math.h>
#import <os/log.h>

static NSString * const ACModule = @"local.atelier.clock";

// Every five minutes, dissolve to the next position over ten seconds.
// Coordinates are fractions of a small radius around the center, in device pixels.
typedef struct { NSPoint from, to; CGFloat mix; } ACDisplayShift;
static ACDisplayShift ACDisplayShiftForElapsed(NSTimeInterval elapsed, BOOL reducedMotion) {
    static const NSPoint positions[]={{0,0},{0.8,0.6},{-0.6,0.8},{-0.8,-0.6},{0.6,-0.8}};
    elapsed=MAX(0,elapsed);
    double cycle=floor(elapsed/300.0);
    NSUInteger index=(NSUInteger)fmod(cycle,5);
    if (cycle==0) return (ACDisplayShift){positions[0],positions[0],0};
    CGFloat t=MIN(1,(elapsed-cycle*300.0)/10.0);
    if (reducedMotion) t=1;
    return (ACDisplayShift){positions[(index+4)%5],positions[index],t*t*(3-2*t)};
}

// Deterministic value noise for original procedural wood. No photographs,
// sampled image data, or external assets are used to generate these materials.
static double ACWoodNoise(NSInteger x, NSInteger y, uint32_t seed) {
    uint32_t h=(uint32_t)x*UINT32_C(374761393)+(uint32_t)y*UINT32_C(668265263)+seed;
    h=(h^(h>>13))*UINT32_C(1274126177); h^=h>>16;
    return (h&0xffff)/65535.0;
}
static double ACWoodField(double x, double y, uint32_t seed) {
    NSInteger ix=(NSInteger)floor(x), iy=(NSInteger)floor(y);
    double fx=x-ix, fy=y-iy; fx=fx*fx*(3-2*fx); fy=fy*fy*(3-2*fy);
    double a=ACWoodNoise(ix,iy,seed), b=ACWoodNoise(ix+1,iy,seed);
    double c=ACWoodNoise(ix,iy+1,seed), d=ACWoodNoise(ix+1,iy+1,seed);
    return (a+(b-a)*fx)*(1-fy)+(c+(d-c)*fx)*fy;
}

#pragma mark - Primitives

static NSColor *ACColor(unsigned int hex) {
    return [NSColor colorWithSRGBRed:((hex >> 16) & 255) / 255.0
                              green:((hex >> 8) & 255) / 255.0
                               blue:(hex & 255) / 255.0 alpha:1];
}
static NSPoint ACPoint(CGFloat r, CGFloat a) { return NSMakePoint(sin(a)*r, cos(a)*r); }
static void ACStroke(NSPoint a, NSPoint b, CGFloat width, NSColor *color) {
    [color setStroke];
    NSBezierPath *p = [NSBezierPath bezierPath];
    p.lineWidth = width; p.lineCapStyle = NSLineCapStyleRound;
    [p moveToPoint:a]; [p lineToPoint:b]; [p stroke];
}
// As ACStroke but with flat (butt) end caps, so a line terminates flush at its
// endpoints instead of bulging half a line width past them.
static void ACStrokeFlat(NSPoint a, NSPoint b, CGFloat width, NSColor *color) {
    [color setStroke];
    NSBezierPath *p = [NSBezierPath bezierPath];
    p.lineWidth = width; p.lineCapStyle = NSLineCapStyleButt;
    [p moveToPoint:a]; [p lineToPoint:b]; [p stroke];
}
static void ACDot(CGFloat radius, NSColor *color) {
    [color setFill]; [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(-radius,-radius,2*radius,2*radius)] fill];
}
static NSFont *ACFont(NSString *name, CGFloat size, NSFontWeight weight) {
    return [NSFont fontWithName:name size:size] ?: [NSFont systemFontOfSize:size weight:weight];
}
static void ACTextF(NSString *text, NSPoint point, NSFont *font, NSColor *color) {
    NSDictionary *attrs = @{NSFontAttributeName:font, NSForegroundColorAttributeName:color};
    NSSize s = [text sizeWithAttributes:attrs];
    [text drawAtPoint:NSMakePoint(point.x-s.width/2,point.y-s.height/2) withAttributes:attrs];
}
static void ACText(NSString *text, NSPoint point, CGFloat size, NSColor *color) {
    ACTextF(text, point, ACFont(@"AvenirNext-Regular", size, NSFontWeightLight), color);
}
static NSColor *ACMix(NSColor *a, NSColor *b, CGFloat t) {
    a=[a colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    b=[b colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    return [NSColor colorWithSRGBRed:a.redComponent+(b.redComponent-a.redComponent)*t
                               green:a.greenComponent+(b.greenComponent-a.greenComponent)*t
                                blue:a.blueComponent+(b.blueComponent-a.blueComponent)*t alpha:1];
}
// Straight capsule hand from -tail to length along +y, rotated by -angle.
static void ACCapsuleHand(CGFloat angle, CGFloat length, CGFloat width, CGFloat tail, NSColor *fill) {
    [NSGraphicsContext saveGraphicsState];
    NSAffineTransform *r=[NSAffineTransform transform]; [r rotateByRadians:-angle]; [r concat];
    NSBezierPath *p=[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(-width/2,-tail,width,length+tail)
                                                   xRadius:width/2 yRadius:width/2];
    [fill setFill]; [p fill];
    [NSGraphicsContext restoreGraphicsState];
}
// Stylized studio reflection in dial coordinates. Both hands move through the
// same broad light/dark field; it never rotates or stretches with a hand's bounds.
// The narrow bright transition suggests a reflected softbox on a flat surface.
static void ACMetalReflection(NSBezierPath *surface, NSColor *edge, NSColor *mid, NSColor *hi) {
    [NSGraphicsContext saveGraphicsState];
    [surface addClip];
    NSColor *spec=ACMix(hi,[NSColor whiteColor],0.48);
    NSColor *lo=ACMix(edge,[NSColor blackColor],0.28);
    NSGradient *g=[[NSGradient alloc] initWithColorsAndLocations:
                   mid,0.0, hi,0.24, spec,0.34, spec,0.38,
                   mid,0.43, lo,0.52, edge,0.64, mid,0.82, hi,1.0, nil];
    [g drawFromPoint:NSMakePoint(-180,240) toPoint:NSMakePoint(180,-240)
            options:NSGradientDrawsBeforeStartingLocation|NSGradientDrawsAfterEndingLocation];
    [NSGraphicsContext restoreGraphicsState];
}
// Flat metal blade with a very thin bevel and a recessed matte luminous inset.
// Rotate the geometry, leaving the reflection and the upper-left light fixed.
static void ACMetalHand(CGFloat angle, CGFloat length, CGFloat width, CGFloat tail, CGFloat tipLen,
                        NSColor *edge, NSColor *mid, NSColor *hi, NSColor *inset) {
    [NSGraphicsContext saveGraphicsState];
    NSAffineTransform *r=[NSAffineTransform transform]; [r rotateByRadians:-angle];
    NSPoint corners[]={NSMakePoint(-width/2,-tail), NSMakePoint(-width/2,length-tipLen),
                       NSMakePoint(0,length), NSMakePoint(width/2,length-tipLen), NSMakePoint(width/2,-tail)};
    for (NSInteger i=0;i<5;i++) corners[i]=[r transformPoint:corners[i]];
    NSBezierPath *hand=[NSBezierPath bezierPath];
    [hand moveToPoint:corners[0]];
    for (NSInteger i=1;i<5;i++) [hand lineToPoint:corners[i]];
    [hand closePath];
    // Solid base first so the caller's drop shadow is cast by the whole silhouette.
    [mid setFill]; [hand fill];
    // Internal reflections and bevels must not cast additional drop shadows.
    [[NSShadow new] set];
    ACMetalReflection(hand,edge,mid,hi);
    // Clockwise polygon: (-dy,dx) is the outward edge normal. Its dot product
    // with the fixed light (-0.6,0.8) lights each bevel as the blade rotates.
    [NSGraphicsContext saveGraphicsState];
    [hand addClip];
    NSColor *bevelLo=ACMix(edge,[NSColor blackColor],0.35);
    NSColor *bevelHi=ACMix(hi,[NSColor whiteColor],0.60);
    for (NSInteger i=0;i<5;i++) {
        NSPoint a=corners[i], b=corners[(i+1)%5];
        CGFloat dx=b.x-a.x, dy=b.y-a.y;
        CGFloat light=(0.6*dy+0.8*dx)/hypot(dx,dy);
        ACStroke(a,b,1.5,ACMix(bevelLo,bevelHi,(light+1)/2));
    }
    [NSGraphicsContext restoreGraphicsState];
    // Recessed matte inset down the centre.
    [r concat];
    CGFloat iw=MAX(2.6,width*0.34);
    CGFloat bot=-tail+9, top=length-tipLen-6;
    NSBezierPath *slot=[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(-iw/2,bot,iw,top-bot) xRadius:iw/2 yRadius:iw/2];
    [inset setFill]; [slot fill];
    CGFloat sideLight=0.6*cos(angle)+0.8*sin(angle);
    ACStroke(NSMakePoint(-iw/2,bot+2),NSMakePoint(-iw/2,top-2),0.7,
             ACMix(inset,[NSColor blackColor],0.12+0.18*MAX(0,sideLight)));
    ACStroke(NSMakePoint(iw/2,bot+2),NSMakePoint(iw/2,top-2),0.7,
             ACMix(inset,[NSColor blackColor],0.12+0.18*MAX(0,-sideLight)));
    [NSGraphicsContext restoreGraphicsState];
}
// One end of a Georg hand. The short concave shoulder is tangent to the hub;
// most of the blade remains very slender, with only a slight taper to its tip.
// sign=-1 draws the counterweight as part of the same continuous outline.
static void ACGeorgBlade(NSBezierPath *h, CGFloat length, CGFloat hub, CGFloat width, CGFloat tip, CGFloat sign) {
    CGFloat rootX=hub*0.4, rootY=hub*sqrt(0.84);
    CGFloat tangentX=4*sqrt(0.84), tangentY=4*0.4;
    [h curveToPoint:NSMakePoint(-sign*width/2,sign*(hub+14))
       controlPoint1:NSMakePoint(sign*(-rootX+tangentX),sign*(rootY+tangentY))
       controlPoint2:NSMakePoint(-sign*width/2,sign*(hub+5))];
    [h curveToPoint:NSMakePoint(-sign*tip/2,sign*(length-tip/2))
       controlPoint1:NSMakePoint(-sign*width/2,sign*(hub+35))
       controlPoint2:NSMakePoint(-sign*tip/2,sign*(length-15))];
    [h appendBezierPathWithArcWithCenter:NSMakePoint(0,sign*(length-tip/2)) radius:tip/2
                             startAngle:sign>0?180:0 endAngle:sign>0?0:-180 clockwise:YES];
    [h curveToPoint:NSMakePoint(sign*width/2,sign*(hub+14))
       controlPoint1:NSMakePoint(sign*tip/2,sign*(length-15))
       controlPoint2:NSMakePoint(sign*width/2,sign*(hub+35))];
    [h curveToPoint:NSMakePoint(sign*rootX,sign*rootY)
       controlPoint1:NSMakePoint(sign*width/2,sign*(hub+5))
       controlPoint2:NSMakePoint(sign*(rootX-tangentX),sign*(rootY+tangentY))];
}
static NSBezierPath *ACGeorgHand(CGFloat length, CGFloat tail, CGFloat hub, CGFloat width, CGFloat tip) {
    NSBezierPath *h=[NSBezierPath bezierPath];
    CGFloat join=atan2(sqrt(0.84),0.4)*180/M_PI;
    [h moveToPoint:NSMakePoint(-hub*0.4,hub*sqrt(0.84))];
    ACGeorgBlade(h,length,hub,width,tip,1);
    [h appendBezierPathWithArcWithCenter:NSZeroPoint radius:hub startAngle:join endAngle:-join clockwise:YES];
    ACGeorgBlade(h,tail,hub,width,tip,-1);
    [h appendBezierPathWithArcWithCenter:NSZeroPoint radius:hub startAngle:180+join endAngle:180-join clockwise:YES];
    [h closePath];
    return h;
}

typedef NS_ENUM(NSInteger, ACRole) {
    ACFace, ACSurround, ACRim, ACInk, ACMuted,
    ACAccentA, ACAccentB, ACAccentC, ACHand, ACHandInset,
    ACSeconds, ACLume, ACRoleCount
};

typedef struct { const char *name; unsigned int c[2][ACRoleCount]; } ACPalette;

// Role order per entry:
// {Face, Surround, Rim, Ink, Muted, AccentA, AccentB, AccentC, Hand, HandInset, Seconds, Lume}

// --- Atelier: only the face color varies; other roles are constant per theme. ---
#define ATELIER_LIGHT(face) {face,face,0,0x30383b,0x30383b,0xaaa99f,0xffffff,0,0x414847,0xf6f4df,0xb94b31,0xfffef5}
#define ATELIER_DARK        {0x161b1e,0x161b1e,0,0xcbd9cd,0xcbd9cd,0x48524e,0x68766b,0,0x66726b,0xc5e5cd,0xe6ac77,0xc5e5cd}
static const ACPalette kAtelierPalettes[] = {
    {"Paper",      {ATELIER_LIGHT(0xeeeae1), ATELIER_DARK}},
    {"Sage",       {ATELIER_LIGHT(0xd5ded6), ATELIER_DARK}},
    {"Lavender",   {ATELIER_LIGHT(0xd3d7ec), ATELIER_DARK}},
    {"Terracotta", {ATELIER_LIGHT(0xe9baaa), ATELIER_DARK}},
    {"Ochre",      {ATELIER_LIGHT(0xe5c664), ATELIER_DARK}},
};

// --- Bill: uses Face, Ink, Muted, Hand, Seconds, AccentA(metal perimeter). ---
// --- Bill: metallic hands. Face, Ink(lines), Muted(ticks), AccentA(metal edge),
//     AccentB(metal highlight), Hand(metal mid), Seconds, Lume(dot + hand inset). ---
static const ACPalette kBillPalettes[] = {
    {"Porcelain · Silver", {{0xF2F0E9,0xF2F0E9,0,0x2A2B28,0x8A8B84,0x767C82,0xF1F4F6,0,0xB9BFC5,0,0x5A6066,0xC6CE78},
                            {0x0E0F0D,0x0E0F0D,0,0xD8D7CE,0x8A8B84,0x60666C,0xEAEEF0,0,0xAEB4BA,0,0xAEB6BC,0xCBE39A}}},
    {"Porcelain · Gold",   {{0xF2F0E9,0xF2F0E9,0,0x2A2B28,0x8A8B84,0x8A6C2A,0xF3DF98,0,0xC9A446,0,0x6B5A2E,0xC6CE78},
                            {0x0E0F0D,0x0E0F0D,0,0xD8D7CE,0x8A8B84,0x7A5F24,0xF0DB90,0,0xC49E40,0,0xC9B77E,0xCBE39A}}},
    {"Ceramic Blue · Silver",{{0xC6DAE0,0xC6DAE0,0,0x25302F,0x6C7E7E,0x6E767C,0xEDF2F4,0,0xB3BDC3,0,0x46504F,0xBFCE86},
                            {0x0C1213,0x0C1213,0,0xC7D8D6,0x7C8A89,0x5C666C,0xE8EEF0,0,0xAAB6BC,0,0xAEBEBC,0xC3E39A}}},
    {"Sage · Silver",      {{0xD1DBC9,0xD1DBC9,0,0x27302A,0x73806E,0x727A80,0xEEF3F2,0,0xB6C0C4,0,0x46504A,0xC2CE7C},
                            {0x0C120F,0x0C120F,0,0xCBD6CC,0x78857A,0x5E666A,0xE9EEEC,0,0xACB6BA,0,0xAEBEB5,0xC6E39A}}},
    {"Sand · Gold",        {{0xE9DCC4,0xE9DCC4,0,0x322D24,0x8A8066,0x866A28,0xF2DE94,0,0xC6A244,0,0x5A4E2E,0xBFB86A},
                            {0x12100B,0x12100B,0,0xDBD3BF,0x8B8168,0x745A22,0xEFD98C,0,0xC09B3E,0,0xC7B37A,0xC9D79A}}},
};

// --- Los Angeles: veneer face, wooden case and markers, enamel hands.
//     AccentA is the painted cardinal accent; AccentB is the brass pivot.
static const ACPalette kLAPalettes[] = {
    {"Birch · Vermilion", {{0xD8BC91,0xEAE6DE,0x795334,0x332F27,0x77624C,0xAD4932,0xB59A64,0,0x292D2B,0,0xB6462F,0},
                           {0x332B21,0x171A18,0x453322,0xE5D4B4,0xA49172,0xD98260,0xBAA16C,0,0xF0E4CB,0,0xE59670,0}}},
    {"Ash · Petrol",      {{0xE0D7C5,0xE5E8E2,0x857460,0x334441,0x807E6C,0x3E7375,0xB9A375,0,0x294E50,0,0xB96B3F,0},
                           {0x293431,0x161C1C,0x46514A,0xDEDCC7,0x9CA99A,0x82B7AD,0xBBA77B,0,0xE7EDDF,0,0xD99A64,0}}},
    {"Walnut · Brass",    {{0x68442B,0xE5DFD2,0x39271D,0xF0DFC0,0xC1A27A,0xD2AC65,0xD2AC65,0,0xF7EACF,0,0xDFAD5B,0},
                           {0x2D211B,0x191716,0x231B17,0xD6C4A6,0xA88D68,0xC6A162,0xC9A66E,0,0xF0E1C4,0,0xDBAD63,0}}},
    {"Smoked · Ivory",    {{0x655F53,0xDEDCD5,0x373930,0xF1E7D0,0xBBB09A,0xDECCAA,0xB3A17E,0,0xF7EEDB,0,0xC46E46,0},
                           {0x292A26,0x171916,0x21251F,0xD9D2BE,0x929780,0xC8C0A3,0xAC9F7F,0,0xEBE8D7,0,0xD79569,0}}},
};

// --- Ikko: Face, Surround, Rim, Ink, Muted, Hand, Seconds. ---
static const ACPalette kIkkoPalettes[] = {
    {"Off-White", {{0xF7F6F2,0xE9E7E1,0xDDDAD2,0x292A28,0x777973,0,0,0,0x292A28,0,0x35362F,0},
                   {0x1E1E1C,0x161615,0x262624,0xEDEBE4,0x8C8D86,0,0,0,0xEDEBE4,0,0xCFCFC7,0}}},
    {"Warm Grey", {{0xE3E1DA,0xD4D2CB,0xC9C6BE,0x2B2A27,0x76766E,0,0,0,0x2B2A27,0,0x38372F,0},
                   {0x201F1C,0x151513,0x2A2926,0xEBE9E1,0x8A8A82,0,0,0,0xEBE9E1,0,0xCDCDC3,0}}},
    {"Butter",    {{0xF4EDD6,0xE9E0C6,0xDCD2B6,0x2C2A22,0x807A66,0,0,0,0x2C2A22,0,0x3A382E,0},
                   {0x201D14,0x16130C,0x28241A,0xEEE9D9,0x8E876F,0,0,0,0xEEE9D9,0,0xCFCBBB,0}}},
    {"Slate Blue",{{0xE6ECEE,0xD8DFE2,0xCBD3D6,0x25292B,0x6E767A,0,0,0,0x25292B,0,0x33383A,0},
                   {0x1B1F22,0x111417,0x262B2E,0xE6EBED,0x828A8E,0,0,0,0xE6EBED,0,0xCBD1D3,0}}},
};

// --- Georg: recessed monochrome dial in a flat tapered frame.
//     Face, Surround, Rim(frame), Ink(unused), Muted(minute dots), AccentA(frame
//     highlight), AccentB(hour dots), AccentC(hour hand), Hand(minute hand + hub),
//     HandInset(face edge vignette), Seconds(brass blade), Lume(unused). ---
static const ACPalette kGeorgPalettes[] = {
    {"Cobalt",     {{0x234995,0xEFEDEA,0x2376BE,0,0x0D6DA1,0x63ABE0,0x058ABE,0x00A9D2,0xF4F6FB,0x153777,0x8D8859,0},
                    {0x162A6E,0x0E0F12,0x24469E,0,0x38509E,0x3C63C0,0x5A86BE,0x6AA0D8,0xEDF1FA,0x0F2059,0xC0A050,0}}},
    {"Onyx",       {{0x1A1A1C,0xEDECE6,0x2C2C2F,0,0x54545A,0x4A4A4E,0x76767E,0xBFC3CC,0xF2F2F0,0x101012,0xC7A24C,0},
                    {0x121213,0x0C0C0D,0x242427,0,0x48484E,0x3C3C40,0x6A6A72,0xB4B8C2,0xECECEA,0x0B0B0C,0xC0A050,0}}},
    {"Bone",       {{0xF1F1EE,0xDDDCD6,0xE4E4E0,0,0xB6B6B0,0xFBFBF9,0x9AA6B2,0x4C6B86,0x2A2C30,0xE2E2DD,0xB8912F,0},
                    {0xE8E8E4,0x111110,0xD8D8D3,0,0xAEAEA8,0xF4F4F1,0x93A0AC,0x45647F,0x26282C,0xD6D6D0,0xB8912F,0}}},
    {"Forest",     {{0x16553B,0xEDECE6,0x2C7D5A,0,0x3C7A5C,0x53A67E,0x74C0A0,0x9FE0C4,0xF3F7F3,0x0F3D2A,0xC7A24C,0},
                    {0x0F3B2A,0x0B0D0C,0x1F5C41,0,0x2E6048,0x3C8060,0x5CA588,0x86CBAE,0xEDF3EE,0x0A2C1E,0xC0A050,0}}},
    {"Terracotta", {{0x9E4A34,0xEDECE6,0xC26A4E,0,0xC07458,0xDE9078,0xE0A98F,0xF0C3A8,0xF7F1EC,0x7E3625,0xC7A24C,0},
                    {0x6E3223,0x0F0C0B,0x8E4C36,0,0x8E5744,0xB0705A,0xB98670,0xD0A38C,0xF1E9E2,0x561F14,0xC0A050,0}}},
};

static const ACPalette *ACPalettesForDesign(NSInteger design, NSInteger *count) {
    switch (design) {
        case 1: *count = sizeof(kBillPalettes)/sizeof(ACPalette); return kBillPalettes;
        case 2: *count = sizeof(kLAPalettes)/sizeof(ACPalette);   return kLAPalettes;
        case 3: *count = sizeof(kIkkoPalettes)/sizeof(ACPalette); return kIkkoPalettes;
        case 4: *count = sizeof(kGeorgPalettes)/sizeof(ACPalette); return kGeorgPalettes;
        default:*count = sizeof(kAtelierPalettes)/sizeof(ACPalette); return kAtelierPalettes;
    }
}
static NSColor *ACR(const ACPalette *p, BOOL dark, ACRole role) { return ACColor(p->c[dark?1:0][role]); }
// Bill lume keeps a glow-paint character while following the currently selected
// Bill palette: blend the dial face with the classic lume tint, then shift the
// intensity for light/dark appearance.
static NSColor *ACBillLume(const ACPalette *p, BOOL dark) {
    NSColor *face=ACR(p,dark,ACFace);
    NSColor *legacy=ACR(p,dark,ACLume);
    NSColor *themed=ACMix(face,legacy,0.58);
    return dark ? ACMix(themed,[NSColor blackColor],0.20)
                : ACMix(themed,[NSColor whiteColor],0.28);
}

static NSString * const kDesignNames[] = { @"Atelier", @"Bill", @"Los Angeles", @"Ikko", @"Georg" };
static const NSInteger ACAutomaticDesign = 5;

// Stable date-based randomness, shared by the desktop app and screensaver.
static uint64_t ACDailyHash(uint64_t value) {
    value += UINT64_C(0x9e3779b97f4a7c15);
    value = (value ^ (value >> 30)) * UINT64_C(0xbf58476d1ce4e5b9);
    value = (value ^ (value >> 27)) * UINT64_C(0x94d049bb133111eb);
    return value ^ (value >> 31);
}
typedef struct { NSInteger design, palette; } ACDailyStyle;
static ACDailyStyle ACDailyStyleForDay(NSUInteger day) {
    // Shuffle each five-day block, reserving its last design first. Knowing the
    // previous block's last design lets us avoid repeats across block boundaries
    // without stored history, including after restarts or days away.
    uint64_t block=(day-1)/5;
    NSInteger last=ACDailyHash(block)%5, previous=ACDailyHash(block-1)%5;
    NSInteger order[5], n=0;
    for (NSInteger i=0;i<5;i++) if (i!=last) order[n++]=i;
    for (NSInteger i=3;i>0;i--) {
        NSInteger j=ACDailyHash(block ^ (UINT64_C(0xd1b54a32d192ed03)+(uint64_t)i))%(i+1);
        NSInteger temp=order[i]; order[i]=order[j]; order[j]=temp;
    }
    if (order[0]==previous) { NSInteger temp=order[0]; order[0]=order[1]; order[1]=temp; }
    order[4]=last;
    NSInteger design=order[(day-1)%5], count;
    ACPalettesForDesign(design,&count);
    NSInteger palette=ACDailyHash((uint64_t)day ^ UINT64_C(0xa0761d6478bd642f))%count;
    return (ACDailyStyle){design,palette};
}
static NSUInteger ACDayNumber(NSDate *date, NSCalendar *calendar) {
    // Count Gregorian civil dates from local components. Counting elapsed days
    // from an era's start can inherit historical zone offsets near midnight.
    NSDateComponents *c=[calendar components:NSCalendarUnitYear|NSCalendarUnitMonth|NSCalendarUnitDay fromDate:date];
    static const NSInteger monthStart[]={0,31,59,90,120,151,181,212,243,273,304,334};
    NSInteger prior=c.year-1;
    BOOL leap=c.year%4==0 && (c.year%100!=0 || c.year%400==0);
    return prior*365+prior/4-prior/100+prior/400+monthStart[c.month-1]+c.day+(c.month>2 && leap);
}

// Accept keyboard focus when hosted remotely, without taking the main-window
// role away from Settings. The host owns presentation of this window.
@interface ACOptionsWindow : NSWindow @end
@implementation ACOptionsWindow
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return NO; }
@end

static os_log_t ACOptionsLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log=os_log_create("local.atelier.clock","Options"); });
    return log;
}

#pragma mark - View

@implementation AtelierClockView {
    ScreenSaverDefaults *_defaults;
    NSInteger _design, _palette, _appearance, _movement;
    CGFloat _scale;
    NSTimeInterval _displayStart;
    BOOL _automatic, _numerals;
    NSCalendar *_dailyCalendar;
    NSUInteger _dailyDay;
    NSImage *_dialCache;
    NSMutableDictionary<NSNumber *, NSImage *> *_woodTextures;
    NSSize _cachedSize;
    BOOL _cachedDark, _cachedNumerals;
    NSInteger _cachedDesign, _cachedPalette;
    NSWindow *_options;
    NSPopUpButton *_designControl, *_paletteControl, *_appearanceControl, *_movementControl;
    NSSlider *_sizeControl;
    NSButton *_numeralControl;
#ifdef AC_HARNESS
    NSDate *_acDate;
    NSNumber *_acDisplayElapsed;
#endif
}

- (instancetype)initWithFrame:(NSRect)frame isPreview:(BOOL)preview {
    self = [super initWithFrame:frame isPreview:preview];
    if (self) {
        _displayStart=[NSProcessInfo processInfo].systemUptime;
        _defaults = [ScreenSaverDefaults defaultsForModuleWithName:ACModule];
        [_defaults registerDefaults:@{@"design":@0, @"palette":@0, @"appearance":@2,
                                     @"movement":@0, @"size":@0.84, @"automatic":@NO, @"numerals":@NO}];
        _dailyCalendar=[[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
        _dailyCalendar.timeZone=[NSTimeZone localTimeZone];
        self.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [self reloadPreferences];
    }
    return self;
}
- (BOOL)isOpaque { return YES; }
- (void)reloadPreferences {
    _design = MAX(0, MIN(4, [_defaults integerForKey:@"design"]));
    NSInteger count; ACPalettesForDesign(_design, &count);
    _palette = MAX(0, MIN(count-1, [_defaults integerForKey:@"palette"]));
    _appearance = MAX(0, MIN(2, [_defaults integerForKey:@"appearance"]));
    _movement = MAX(0, MIN(2, [_defaults integerForKey:@"movement"]));
    _scale = MAX(0.45, MIN(0.92, [_defaults doubleForKey:@"size"]));
    _automatic = [_defaults boolForKey:@"automatic"];
    _dailyDay = 0;
    [self updateDailyStyleForDate:[self clockDate]];
    _numerals = [_defaults boolForKey:@"numerals"];
    self.animationTimeInterval = _movement == 0 ? 1.0/30.0 : 1.0/8.0;
    _dialCache = nil;
    self.needsDisplay = YES;
}
- (void)startAnimation {
    _displayStart=[NSProcessInfo processInfo].systemUptime;
    [self reloadPreferences]; [super startAnimation];
}
- (void)animateOneFrame { self.needsDisplay = YES; }
- (NSDate *)clockDate {
#ifdef AC_HARNESS
    if (_acDate) return _acDate;
#endif
    return [NSDate date];
}
- (NSUInteger)dayNumberForDate:(NSDate *)date {
    // NSCalendar snapshots its zone; refresh it so travel follows local midnight.
    _dailyCalendar.timeZone=[NSTimeZone defaultTimeZone];
    return ACDayNumber(date,_dailyCalendar);
}
- (void)updateDailyStyleForDate:(NSDate *)date {
    if (!_automatic) return;
    NSUInteger day=[self dayNumberForDate:date];
    if (day==_dailyDay) return;
    ACDailyStyle style=ACDailyStyleForDay(day);
    _design=style.design; _palette=style.palette; _dailyDay=day;
    _dialCache=nil;
}
- (BOOL)isDark {
    if (_appearance == 0) return NO;
    if (_appearance == 1) return YES;
    return [[self.effectiveAppearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]]
            isEqualToString:NSAppearanceNameDarkAqua];
}
- (const ACPalette *)currentPalette {
    NSInteger count; const ACPalette *table = ACPalettesForDesign(_design, &count);
    return &table[MAX(0, MIN(count-1, _palette))];
}

- (void)drawRect:(NSRect)dirtyRect {
    NSDate *now=[self clockDate];
    [self updateDailyStyleForDate:now];
    BOOL dark=[self isDark];
    const ACPalette *p=[self currentPalette];
    // On macOS 14+ the legacyScreenSaver host reports -bounds in backing pixels
    // while the graphics context is Retina-scaled. Derive geometry from the context's
    // real drawable (its clip box, in points) instead of -bounds.
    NSRect area=self.bounds;
    // Per-axis device scale of the context. The small System Settings preview can
    // set an anisotropic CTM (its x and y map to different pixel counts); a uniform
    // scale would then render the dial as an ellipse. Measure both axes and size the
    // clock in real pixels so it stays perfectly round in every host.
    CGFloat sx=1, sy=1;
    CGContextRef cg=[NSGraphicsContext currentContext].CGContext;
    if (cg) {
        CGRect clip=CGContextGetClipBoundingBox(cg);
        if (clip.size.width>1 && clip.size.height>1) area=NSRectFromCGRect(clip);
        CGAffineTransform ctm=CGContextGetCTM(cg);
        sx=hypot(ctm.a,ctm.b); if (sx<=0) sx=1;
        sy=hypot(ctm.c,ctm.d); if (sy<=0) sy=1;
    }
    // Largest round circle (in pixels) that fits the drawable, then the shared
    // per-640-unit pixel scale. Splitting it back out by axis cancels the CTM's
    // anisotropy, so equal 640-space lengths cover equal pixel counts on screen.
    CGFloat diameterPx=MIN(area.size.width*sx,area.size.height*sy)*_scale;
    if (diameterPx<1) { [ACR(p,dark,ACSurround) setFill]; NSRectFill(area); return; }
    CGFloat unitPx=diameterPx/640.0;
    NSTimeInterval epoch=now.timeIntervalSince1970;
    // Cache static vector artwork as a resolution-aware image; animate only the hands.
    if (!_dialCache || !NSEqualSizes(_cachedSize,area.size) || _cachedDark!=dark ||
        _cachedDesign!=_design || _cachedPalette!=_palette || _cachedNumerals!=_numerals) {
        __weak AtelierClockView *weakSelf=self;
        _dialCache=[NSImage imageWithSize:NSMakeSize(640,640) flipped:NO drawingHandler:^BOOL(NSRect rect) {
            [NSGraphicsContext saveGraphicsState];
            NSAffineTransform *t=[NSAffineTransform transform]; [t translateXBy:320 yBy:320]; [t concat];
            [weakSelf drawStatic:p dark:dark];
            [NSGraphicsContext restoreGraphicsState]; return YES;
        }];
        _cachedSize=area.size; _cachedDark=dark;
        _cachedDesign=_design; _cachedPalette=_palette; _cachedNumerals=_numerals;
    }
    NSDateComponents *c=[[NSCalendar currentCalendar] components:NSCalendarUnitHour|NSCalendarUnitMinute|NSCalendarUnitSecond fromDate:now];
    double seconds=c.second+(epoch-floor(epoch));
    double handSeconds=_movement==1 ? floor(seconds*8)/8 : (_movement==2 ? floor(seconds) : seconds);
    double hourAngle=((c.hour%12)+c.minute/60.0+seconds/3600.0)*M_PI/6;
    double minuteAngle=(c.minute+seconds/60.0)*M_PI/30;
    double secondAngle=handSeconds*M_PI/30;
    NSTimeInterval elapsed=[NSProcessInfo processInfo].systemUptime-_displayStart;
#ifdef AC_HARNESS
    if (_acDisplayElapsed) elapsed=_acDisplayElapsed.doubleValue;
#endif
    ACDisplayShift shift=self.isPreview ? (ACDisplayShift){NSZeroPoint,NSZeroPoint,0} :
        ACDisplayShiftForElapsed(elapsed,[NSWorkspace sharedWorkspace].accessibilityDisplayShouldReduceMotion);
    CGFloat radius=MIN(area.size.width*sx,area.size.height*sy)*0.012;
    BOOL dissolving=cg && shift.mix>0 && shift.mix<1;
    for (NSInteger pass=0;pass<(dissolving?2:1);pass++) {
        NSPoint offset=pass==1 || shift.mix>=1 ? shift.to : shift.from;
        [NSGraphicsContext saveGraphicsState];
        if (pass==1) {
            // Blend a complete opaque scene, so overlapping hands and markers
            // keep their brightness instead of being alpha-composited twice.
            CGContextSetAlpha(cg,shift.mix);
            CGContextBeginTransparencyLayer(cg,NULL);
        }
        [ACR(p,dark,ACSurround) setFill]; NSRectFill(area);
        NSAffineTransform *transform=[NSAffineTransform transform];
        [transform translateXBy:NSMidX(area)+offset.x*radius/sx yBy:NSMidY(area)+offset.y*radius/sy];
        [transform scaleXBy:unitPx/sx yBy:unitPx/sy]; [transform concat];
        [_dialCache drawInRect:NSMakeRect(-320,-320,640,640) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1];
        [self drawHands:p dark:dark hour:hourAngle minute:minuteAngle second:secondAngle];
        if (pass==1) CGContextEndTransparencyLayer(cg);
        [NSGraphicsContext restoreGraphicsState];
    }
}

- (void)drawStatic:(const ACPalette *)p dark:(BOOL)dark {
    switch (_design) {
        case 1: [self drawBillStatic:p dark:dark]; break;
        case 2: [self drawLAStatic:p dark:dark]; break;
        case 3: [self drawIkkoStatic:p dark:dark]; break;
        case 4: [self drawGeorgStatic:p dark:dark]; break;
        default:[self drawAtelierStatic:p dark:dark]; break;
    }
}
- (void)drawHands:(const ACPalette *)p dark:(BOOL)dark hour:(double)ha minute:(double)ma second:(double)sa {
    switch (_design) {
        case 1: [self drawBillHands:p dark:dark hour:ha minute:ma second:sa]; break;
        case 2: [self drawLAHands:p dark:dark hour:ha minute:ma second:sa]; break;
        case 3: [self drawIkkoHands:p dark:dark hour:ha minute:ma second:sa]; break;
        case 4: [self drawGeorgHands:p dark:dark hour:ha minute:ma second:sa]; break;
        default:[self drawAtelierHands:p dark:dark hour:ha minute:ma second:sa]; break;
    }
}

#pragma mark - Atelier (original)

- (void)drawAtelierStatic:(const ACPalette *)p dark:(BOOL)dark {
    NSColor *ink = ACR(p,dark,ACInk);
    NSColor *muted = [ink colorWithAlphaComponent:0.48];
    NSColor *metal = ACR(p,dark,ACAccentA);
    NSColor *lume = ACR(p,dark,ACLume);
    for (NSInteger i=0;i<60;i++) {
        CGFloat a=i*M_PI/30.0;
        if (i%5) ACStroke(ACPoint(257,a),ACPoint(271,a),1.8,muted);
    }
    for (NSInteger i=0;i<12;i++) {
        CGFloat a=i*M_PI/6.0;
        [NSGraphicsContext saveGraphicsState];
        NSShadow *shadow = [NSShadow new];
        shadow.shadowOffset=NSMakeSize(1.3,-2.0); shadow.shadowBlurRadius=3;
        shadow.shadowColor=[NSColor colorWithWhite:0 alpha:dark ? 0.55 : 0.18]; [shadow set];
        ACStroke(ACPoint(232,a),ACPoint(271,a),9,metal);
        [NSGraphicsContext restoreGraphicsState];
        ACStroke(ACPoint(232,a),ACPoint(271,a),7,ACR(p,dark,ACAccentB));
        ACStroke(ACPoint(235,a),ACPoint(269,a),3.6,lume);
        if (_numerals) ACText([NSString stringWithFormat:@"%ld",(long)(i==0 ? 12 : i)],ACPoint(184,a),35,ink);
        [NSGraphicsContext saveGraphicsState];
        NSAffineTransform *rotation=[NSAffineTransform transform];
        [rotation rotateByRadians:-a]; [rotation concat];
        ACTextF([NSString stringWithFormat:@"%02ld",(long)(i==0 ? 60 : i*5)],NSMakePoint(0,301),
                ACFont(@"AvenirNext-Regular",16,NSFontWeightLight),muted);
        [NSGraphicsContext restoreGraphicsState];
    }
}
- (void)drawAtelierHand:(CGFloat)angle length:(CGFloat)length width:(CGFloat)width dark:(BOOL)dark palette:(const ACPalette *)p {
    [NSGraphicsContext saveGraphicsState];
    NSAffineTransform *rotation=[NSAffineTransform transform]; [rotation rotateByRadians:-angle]; [rotation concat];
    NSBezierPath *hand=[NSBezierPath bezierPath];
    [hand moveToPoint:NSMakePoint(-width/2,-25)];
    [hand lineToPoint:NSMakePoint(-width/2,length-17)];
    [hand lineToPoint:NSMakePoint(-2,length)]; [hand lineToPoint:NSMakePoint(2,length)];
    [hand lineToPoint:NSMakePoint(width/2,length-17)]; [hand lineToPoint:NSMakePoint(width/2,-25)]; [hand closePath];
    [NSGraphicsContext saveGraphicsState];
    NSShadow *shadow=[NSShadow new]; shadow.shadowOffset=NSMakeSize(3,-4); shadow.shadowBlurRadius=5;
    shadow.shadowColor=[NSColor colorWithWhite:0 alpha:dark ? 0.5 : 0.22]; [shadow set];
    [ACR(p,dark,ACHand) setFill]; [hand fill];
    [NSGraphicsContext restoreGraphicsState];
    [ACColor(dark ? 0x91a396 : 0xc6c7be) setStroke]; hand.lineWidth=0.7; [hand stroke];
    ACStroke(NSMakePoint(0,34),NSMakePoint(0,length-24),width*0.40,ACR(p,dark,ACHandInset));
    [NSGraphicsContext restoreGraphicsState];
}
- (void)drawAtelierHands:(const ACPalette *)p dark:(BOOL)dark hour:(double)ha minute:(double)ma second:(double)sa {
    [self drawAtelierHand:ha length:166 width:13 dark:dark palette:p];
    [self drawAtelierHand:ma length:254 width:9 dark:dark palette:p];
    [NSGraphicsContext saveGraphicsState];
    NSShadow *shadow=[NSShadow new]; shadow.shadowOffset=NSMakeSize(2,-3); shadow.shadowBlurRadius=3;
    shadow.shadowColor=[NSColor colorWithWhite:0 alpha:0.18]; [shadow set];
    ACStroke(ACPoint(-54,sa),ACPoint(272,sa),2.1,ACR(p,dark,ACSeconds));
    [NSGraphicsContext restoreGraphicsState];
    ACDot(11,ACColor(dark ? 0x536357 : 0xc9cac2));
    ACDot(7,ACColor(dark ? 0xb5c4b7 : 0xf9f7ed));
    ACDot(3,ACR(p,dark,ACSeconds));
}

#pragma mark - Bill (precision)

- (void)drawBillStatic:(const ACPalette *)p dark:(BOOL)dark {
    NSColor *ink = ACR(p,dark,ACInk);
    NSColor *muted = ACR(p,dark,ACMuted);
    NSColor *lume = ACBillLume(p,dark);
    // Faint outer boundary at the minute track.
    NSBezierPath *ring=[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(-286,-286,572,572)];
    ring.lineWidth=1.0; [muted setStroke]; [ring stroke];
    // Long fine hour lines with short minute ticks between them.
    for (NSInteger i=0;i<60;i++) {
        CGFloat a=i*M_PI/30.0;
        if (i%5==0) ACStrokeFlat(ACPoint(168,a),ACPoint(286,a),1.7,ink);   // long hour line
        else        ACStrokeFlat(ACPoint(274,a),ACPoint(286,a),1.3,muted); // short minute tick
    }
    // Luminous dots sit just inside the minute track: double at 12, singles at 3/6/9.
    CGFloat dotRadius=260;
    void (^dot)(NSPoint) = ^(NSPoint c){
        NSRect r=NSMakeRect(c.x-6.5,c.y-6.5,13,13);
        [lume setFill]; [[NSBezierPath bezierPathWithOvalInRect:r] fill];
        NSBezierPath *o=[NSBezierPath bezierPathWithOvalInRect:r]; o.lineWidth=0.9; [muted setStroke]; [o stroke];
    };
    dot(NSMakePoint(-13,dotRadius)); dot(NSMakePoint(13,dotRadius)); // 12 — double
    dot(ACPoint(dotRadius,M_PI/2));                                 // 3
    dot(ACPoint(dotRadius,M_PI));                                   // 6
    dot(ACPoint(dotRadius,3*M_PI/2));                                // 9
}
- (void)drawBillHands:(const ACPalette *)p dark:(BOOL)dark hour:(double)ha minute:(double)ma second:(double)sa {
    NSColor *edge=ACR(p,dark,ACAccentA);
    NSColor *mid=ACR(p,dark,ACHand);
    NSColor *hi=ACR(p,dark,ACAccentB);
    NSColor *inset=ACBillLume(p,dark);
    NSColor *seconds=ACR(p,dark,ACSeconds);
    // Soft shared shadow under the metal hands.
    [NSGraphicsContext saveGraphicsState];
    NSShadow *shadow=[NSShadow new]; shadow.shadowOffset=NSMakeSize(1.5,-2.5); shadow.shadowBlurRadius=4;
    shadow.shadowColor=[NSColor colorWithWhite:0 alpha:dark?0.5:0.20]; [shadow set];
    ACMetalHand(ha,176,17,22,30,edge,mid,hi,inset);   // short hour blade
    ACMetalHand(ma,266,13,22,44,edge,mid,hi,inset);   // minute: reaches the track
    [NSGraphicsContext restoreGraphicsState];
    // Exceptionally fine seconds hand with a small restrained counterweight.
    ACStroke(ACPoint(-40,sa),ACPoint(272,sa),1.6,seconds);
    [NSGraphicsContext saveGraphicsState];
    NSAffineTransform *r=[NSAffineTransform transform]; [r rotateByRadians:-sa]; [r concat];
    ACDot(6,seconds);
    [NSGraphicsContext restoreGraphicsState];
    // Polished centre hub.
    ACDot(7.5,mid);
    NSBezierPath *hub=[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(-7.5,-7.5,15,15)];
    hub.lineWidth=0.8; [edge setStroke]; [hub stroke];
    ACDot(2.6,edge);
}

#pragma mark - Los Angeles (wood and enamel)

- (NSImage *)woodTextureForFinish:(NSInteger)finish {
    if (!_woodTextures) _woodTextures=[NSMutableDictionary dictionary];
    finish=MAX(0,MIN(2,finish));
    NSImage *image=_woodTextures[@(finish)];
    if (image) return image;
    const NSInteger size=1024;
    NSBitmapImageRep *bitmap=[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
        pixelsWide:size pixelsHigh:size bitsPerSample:8 samplesPerPixel:3 hasAlpha:NO
        isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    if (!bitmap) return nil;
    // Three finishes: broad plywood growth rings, fine pale grain, and dark grain.
    const double colors[3][3]={{0.77,0.61,0.42},{0.81,0.74,0.63},{0.43,0.28,0.16}};
    uint32_t seed=UINT32_C(19073)+(uint32_t)finish*UINT32_C(7919);
    for (NSInteger y=0;y<size;y++) {
        unsigned char *row=bitmap.bitmapData+y*bitmap.bytesPerRow;
        for (NSInteger x=0;x<size;x++) {
            double u=(double)x/size*2-1, v=(double)y/size*2-1;
            double warp=ACWoodField(u*1.6+3,v*2.2+4,seed)-0.5;
            double flow=finish==0?sqrt(0.34*(u-0.2)*(u-0.2)+(v+2.4)*(v+2.4)):
                                  v+0.045*sin(u*3.4)+0.07*warp;
            double phase=flow*(finish==0?18:finish==1?32:48)+warp*0.65;
            double band=0.5+0.5*sin(phase*2*M_PI);
            double pores=pow(band,18)*(0.4+0.6*ACWoodField(u*7+8,v*9+10,seed+1));
            double fibers=ACWoodField(u*10+12,v*340+350,seed+2)-0.5;
            double broad=ACWoodField(u*2+4,v*5+7,seed+3)-0.5;
            double fleck=ACWoodNoise(x,y,seed+4)-0.5;
            double tone=1+broad*0.14+fibers*0.10+fleck*0.025-pores*(finish==2?0.24:0.12);
            for (NSInteger channel=0;channel<3;channel++)
                row[x*3+channel]=(unsigned char)lrint(MAX(0,MIN(1,colors[finish][channel]*tone))*255);
        }
    }
    image=[[NSImage alloc] initWithSize:NSMakeSize(size,size)];
    [image addRepresentation:bitmap];
    _woodTextures[@(finish)]=image;
    return image;
}
- (void)fillWood:(NSBezierPath *)path image:(NSImage *)image rect:(NSRect)rect
           base:(NSColor *)base strength:(CGFloat)strength {
    [base setFill]; [path fill];
    if (!image || image.size.width<=0 || image.size.height<=0) return;
    [NSGraphicsContext saveGraphicsState];
    [path addClip];
    // Aspect-fill one continuous sheet of procedural veneer.
    CGFloat scale=MAX(rect.size.width/image.size.width,rect.size.height/image.size.height);
    NSSize size=NSMakeSize(image.size.width*scale,image.size.height*scale);
    NSRect dest=NSMakeRect(NSMidX(rect)-size.width/2,NSMidY(rect)-size.height/2,size.width,size.height);
    [NSGraphicsContext currentContext].imageInterpolation=NSImageInterpolationHigh;
    [image drawInRect:dest fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:strength];
    [NSGraphicsContext restoreGraphicsState];
}
- (void)drawLAStatic:(const ACPalette *)p dark:(BOOL)dark {
    NSColor *ink=ACR(p,dark,ACInk), *rim=ACR(p,dark,ACRim);
    NSInteger finish=_palette==0?0:_palette==2?2:1;
    NSImage *veneer=[self woodTextureForFinish:finish];
    NSImage *brownWood=[self woodTextureForFinish:2];
    NSRect bodyRect=NSMakeRect(-302,-302,604,604), faceRect=NSMakeRect(-294,-294,588,588);
    NSBezierPath *body=[NSBezierPath bezierPathWithOvalInRect:bodyRect];
    [NSGraphicsContext saveGraphicsState];
    NSShadow *shadow=[NSShadow new]; shadow.shadowOffset=NSMakeSize(2,-5); shadow.shadowBlurRadius=10;
    shadow.shadowColor=[NSColor colorWithWhite:0 alpha:dark?0.45:0.22]; [shadow set];
    [rim setFill]; [body fill];
    [NSGraphicsContext restoreGraphicsState];
    [self fillWood:body image:brownWood rect:bodyRect base:rim strength:dark?0.14:0.42];
    NSBezierPath *face=[NSBezierPath bezierPathWithOvalInRect:faceRect];
    CGFloat grain=dark?0.12:(_palette>=2?0.32:0.66);
    [self fillWood:face image:veneer rect:faceRect base:ACR(p,dark,ACFace) strength:grain];
    // Broad satin illumination keeps the grain visible beneath the finish.
    NSGradient *light=[[NSGradient alloc] initWithStartingColor:[NSColor colorWithWhite:1 alpha:dark?0.025:0.12]
                                                  endingColor:[NSColor colorWithWhite:0 alpha:0.10]];
    [light drawInBezierPath:face angle:-65];
    body.lineWidth=0.9; [[NSColor colorWithWhite:1 alpha:0.16] setStroke]; [body stroke];
    // Small drilled-looking minute dots leave space around the applied hour marks.
    for (NSInteger i=0;i<60;i++) if (i%5) {
        NSPoint pt=ACPoint(277,i*M_PI/30.0);
        [[ACR(p,dark,ACMuted) colorWithAlphaComponent:0.65] setFill];
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(pt.x-0.9,pt.y-0.9,1.8,1.8)] fill];
    }
    for (NSInteger i=0;i<12;i++) {
        CGFloat angle=i*M_PI/6;
        BOOL cardinal=i%3==0;
        NSColor *marker=cardinal?ACR(p,dark,ACAccentA):ink;
        if (_numerals && cardinal) {
            // Numerals occupy the marker ring itself, rather than a second inner ring.
            NSPoint pt=ACPoint(246,angle);
            NSString *number=[NSString stringWithFormat:@"%ld",(long)(i==0?12:i)];
            ACTextF(number,pt,ACFont(@"Futura-Medium",43,NSFontWeightMedium),marker);
            continue;
        }
        [NSGraphicsContext saveGraphicsState];
        NSAffineTransform *r=[NSAffineTransform transform]; [r rotateByRadians:-angle]; [r concat];
        // Long, softly pointed lozenges share the hour hand's broad-shouldered shape.
        CGFloat half=cardinal?10:7;
        NSBezierPath *mark=[NSBezierPath bezierPath];
        [mark moveToPoint:NSMakePoint(0,216)];
        [mark curveToPoint:NSMakePoint(-half,252) controlPoint1:NSMakePoint(-3,225) controlPoint2:NSMakePoint(-half,243)];
        [mark curveToPoint:NSMakePoint(0,269) controlPoint1:NSMakePoint(-half,261) controlPoint2:NSMakePoint(-3,269)];
        [mark curveToPoint:NSMakePoint(half,252) controlPoint1:NSMakePoint(3,269) controlPoint2:NSMakePoint(half,261)];
        [mark curveToPoint:NSMakePoint(0,216) controlPoint1:NSMakePoint(half,243) controlPoint2:NSMakePoint(3,225)];
        [mark closePath];
        [NSGraphicsContext saveGraphicsState];
        NSShadow *ms=[NSShadow new]; ms.shadowOffset=NSMakeSize(1,-1.5); ms.shadowBlurRadius=2;
        ms.shadowColor=[NSColor colorWithWhite:0 alpha:0.25]; [ms set];
        [marker setFill]; [mark fill];
        [NSGraphicsContext restoreGraphicsState];
        if (!cardinal && !dark && _palette<2)
            [self fillWood:mark image:brownWood rect:NSMakeRect(-32,205,64,80) base:ink strength:0.48];
        mark.lineWidth=0.6; [[NSColor colorWithWhite:1 alpha:0.16] setStroke]; [mark stroke];
        [NSGraphicsContext restoreGraphicsState];
    }
}
- (void)drawLAHands:(const ACPalette *)p dark:(BOOL)dark hour:(double)ha minute:(double)ma second:(double)sa {
    NSColor *enamel=ACR(p,dark,ACHand), *seconds=ACR(p,dark,ACSeconds);
    // Distinct silhouettes: a short sculpted paddle and a long, fine lance.
    NSBezierPath *hour=[NSBezierPath bezierPath];
    [hour moveToPoint:NSMakePoint(-6,-22)];
    [hour lineToPoint:NSMakePoint(-8,72)];
    [hour curveToPoint:NSMakePoint(-18,122) controlPoint1:NSMakePoint(-10,93) controlPoint2:NSMakePoint(-18,110)];
    [hour curveToPoint:NSMakePoint(0,178) controlPoint1:NSMakePoint(-18,138) controlPoint2:NSMakePoint(-5,166)];
    [hour curveToPoint:NSMakePoint(18,122) controlPoint1:NSMakePoint(5,166) controlPoint2:NSMakePoint(18,138)];
    [hour curveToPoint:NSMakePoint(8,72) controlPoint1:NSMakePoint(18,110) controlPoint2:NSMakePoint(10,93)];
    [hour lineToPoint:NSMakePoint(6,-22)]; [hour closePath];
    NSBezierPath *minute=[NSBezierPath bezierPath];
    [minute moveToPoint:NSMakePoint(-4,-27)]; [minute lineToPoint:NSMakePoint(-6,48)];
    [minute lineToPoint:NSMakePoint(-2,237)]; [minute lineToPoint:NSMakePoint(2,237)];
    [minute lineToPoint:NSMakePoint(6,48)]; [minute lineToPoint:NSMakePoint(4,-27)]; [minute closePath];
    NSAffineTransform *hr=[NSAffineTransform transform]; [hr rotateByRadians:-ha]; [hour transformUsingAffineTransform:hr];
    NSAffineTransform *mr=[NSAffineTransform transform]; [mr rotateByRadians:-ma]; [minute transformUsingAffineTransform:mr];
    [NSGraphicsContext saveGraphicsState];
    NSShadow *shadow=[NSShadow new]; shadow.shadowOffset=NSMakeSize(2,-3); shadow.shadowBlurRadius=4;
    shadow.shadowColor=[NSColor colorWithWhite:0 alpha:dark?0.40:0.25]; [shadow set];
    [enamel setFill]; [hour fill]; [minute fill];
    [NSGraphicsContext restoreGraphicsState];
    ACStroke(ACPoint(-52,sa),ACPoint(260,sa),1.8,seconds);
    ACDot(9,enamel); ACDot(6.5,ACR(p,dark,ACAccentB)); ACDot(2.2,seconds);
}

#pragma mark - Ikko (everyday)

- (void)drawIkkoStatic:(const ACPalette *)p dark:(BOOL)dark {
    NSColor *ink=ACR(p,dark,ACInk);
    NSColor *ticks=ACR(p,dark,ACMuted);
    // Shallow rim with a soft contact shadow, then the face.
    [NSGraphicsContext saveGraphicsState];
    NSShadow *sh=[NSShadow new]; sh.shadowOffset=NSMakeSize(0,-3); sh.shadowBlurRadius=12;
    sh.shadowColor=[NSColor colorWithWhite:0 alpha:dark?0.5:0.14]; [sh set];
    [ACR(p,dark,ACRim) setFill];
    [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(-306,-306,612,612)] fill];
    [NSGraphicsContext restoreGraphicsState];
    [ACR(p,dark,ACFace) setFill];
    [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(-288,-288,576,576)] fill];
    // 60 minute ticks outside the numerals, longer at the fives.
    for (NSInteger i=0;i<60;i++) {
        CGFloat a=i*M_PI/30.0; BOOL five=(i%5==0);
        ACStroke(ACPoint(five?258:268,a),ACPoint(280,a),five?3.4:1.6,ticks);
    }
    // All twelve upright numerals, medium-weight open sans.
    NSFont *font=ACFont(@"HelveticaNeue-Medium",48,NSFontWeightMedium);
    for (NSInteger i=0;i<12;i++) {
        int v=(int)(i==0?12:i);
        ACTextF([NSString stringWithFormat:@"%d",v],ACPoint(206,i*M_PI/6.0),font,ink);
    }
}
- (void)drawIkkoHands:(const ACPalette *)p dark:(BOOL)dark hour:(double)ha minute:(double)ma second:(double)sa {
    NSColor *ink=ACR(p,dark,ACHand);
    NSColor *seconds=ACR(p,dark,ACSeconds);
    [NSGraphicsContext saveGraphicsState];
    NSShadow *shadow=[NSShadow new]; shadow.shadowOffset=NSMakeSize(1.5,-2.5); shadow.shadowBlurRadius=3.5;
    shadow.shadowColor=[NSColor colorWithWhite:0 alpha:dark?0.45:0.16]; [shadow set];
    ACCapsuleHand(ha,150,17,24,ink);   // shorter, visibly wider hour hand
    ACCapsuleHand(ma,244,11,24,ink);   // minute reaches the track
    [NSGraphicsContext restoreGraphicsState];
    ACStroke(ACPoint(-44,sa),ACPoint(248,sa),2.0,seconds);
    ACDot(8,ink);
    ACDot(3,ACR(p,dark,ACFace));
}

#pragma mark - Georg (Nordic)

- (void)drawGeorgStatic:(const ACPalette *)p dark:(BOOL)dark {
    NSColor *frame=ACR(p,dark,ACRim);
    NSColor *frameHi=ACR(p,dark,ACAccentA);
    NSColor *frameLo=ACMix(frame,[NSColor blackColor],0.30);
    NSColor *face=ACR(p,dark,ACFace);
    NSColor *faceEdge=ACR(p,dark,ACHandInset);
    NSColor *dots=ACR(p,dark,ACMuted);
    NSColor *hourDots=ACR(p,dark,ACAccentB);
    // Narrow outer lip catches the upper-left light. The inward-facing bevel
    // catches it on the opposite (lower-right) side, as on a recessed bowl.
    NSBezierPath *outer=[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(-314,-314,628,628)];
    NSGradient *lip=[[NSGradient alloc] initWithStartingColor:ACMix(frameHi,[NSColor whiteColor],0.24)
                                               endingColor:frame];
    [lip drawInBezierPath:outer angle:-45];
    NSBezierPath *bezel=[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(-310,-310,620,620)];
    NSGradient *bevel=[[NSGradient alloc] initWithColorsAndLocations:
                      frame,0.0, frameLo,0.30, frame,0.65, frameHi,1.0, nil];
    [bevel drawInBezierPath:bezel angle:-45];
    // A soft specular roll along the outer lip avoids a stack of flat rings.
    NSGradient *lipSheen=[[NSGradient alloc] initWithColorsAndLocations:
                         [NSColor colorWithWhite:1 alpha:0],0.0,
                         [NSColor colorWithWhite:1 alpha:0.20],0.76,
                         [NSColor colorWithWhite:1 alpha:0],1.0, nil];
    [NSGraphicsContext saveGraphicsState];
    [outer addClip];
    [lipSheen drawFromCenter:NSZeroPoint radius:299 toCenter:NSZeroPoint radius:314 options:0];
    [NSGraphicsContext restoreGraphicsState];
    NSBezierPath *wall=[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(-296,-296,592,592)];
    NSGradient *wallLight=[[NSGradient alloc] initWithStartingColor:ACMix(faceEdge,[NSColor blackColor],0.50)
                                                     endingColor:ACMix(frame,face,0.55)];
    [wallLight drawInBezierPath:wall angle:-45];
    NSRect faceRect=NSMakeRect(-286,-286,572,572);
    NSBezierPath *faceDisc=[NSBezierPath bezierPathWithOvalInRect:faceRect];
    [NSGraphicsContext saveGraphicsState];
    [faceDisc addClip];
    NSGradient *dial=[[NSGradient alloc] initWithColorsAndLocations:
                     ACMix(face,[NSColor whiteColor],0.025),0.0, face,0.72, faceEdge,1.0, nil];
    [dial drawInRect:faceRect relativeCenterPosition:NSMakePoint(0.12,-0.14)];
    // Cast the rim's shadow INTO the dial, not behind a raised face disc.
    // Offset down/right puts the deepest occlusion under the upper-left lip.
    NSBezierPath *outside=[NSBezierPath bezierPathWithRect:NSMakeRect(-400,-400,800,800)];
    // Slightly oversize the hole so antialiasing does not paint a seam at the clip.
    [outside appendBezierPathWithOvalInRect:NSInsetRect(faceRect,-0.75,-0.75)];
    outside.windingRule=NSWindingRuleEvenOdd;
    NSShadow *recess=[NSShadow new]; recess.shadowOffset=NSMakeSize(10,-15); recess.shadowBlurRadius=26;
    recess.shadowColor=[NSColor colorWithWhite:0 alpha:dark?0.65:0.60]; [recess set];
    [faceEdge setFill]; [outside fill];
    [NSGraphicsContext restoreGraphicsState];
    for (NSInteger i=0;i<60;i++) {
        CGFloat a=i*M_PI/30.0; BOOL hour=(i%5==0);
        CGFloat rad=hour?3.6:1.5; NSColor *c=hour?hourDots:dots;
        NSPoint pt=ACPoint(254,a);
        [c setFill]; [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(pt.x-rad,pt.y-rad,2*rad,2*rad)] fill];
    }
}
- (void)georgHand:(CGFloat)angle length:(CGFloat)length tail:(CGFloat)tail
             hub:(CGFloat)hub width:(CGFloat)width tip:(CGFloat)tip color:(NSColor *)color {
    NSBezierPath *hand=ACGeorgHand(length,tail,hub,width,tip);
    // Transform the outline, keeping the shadow direction fixed on the dial.
    NSAffineTransform *r=[NSAffineTransform transform]; [r rotateByRadians:-angle];
    [hand transformUsingAffineTransform:r];
    [color setFill]; [hand fill];
}
- (void)drawGeorgHands:(const ACPalette *)p dark:(BOOL)dark hour:(double)ha minute:(double)ma second:(double)sa {
    [NSGraphicsContext saveGraphicsState];
    NSShadow *shadow=[NSShadow new]; shadow.shadowOffset=NSMakeSize(5,-7); shadow.shadowBlurRadius=8;
    shadow.shadowColor=[NSColor colorWithWhite:0 alpha:dark?0.38:0.28]; [shadow set];
    // Restrained brass seconds blade and short counterweight, underneath both hands.
    [self georgHand:sa length:250 tail:80 hub:15 width:4.2 tip:2.4 color:ACR(p,dark,ACSeconds)];
    [self georgHand:ha length:190 tail:79 hub:22 width:5.0 tip:3.0 color:ACR(p,dark,ACAccentC)];
    // The white circle and both organic shoulders share one silhouette and shadow.
    [self georgHand:ma length:238 tail:80 hub:24 width:5.4 tip:3.4 color:ACR(p,dark,ACHand)];
    [NSGraphicsContext restoreGraphicsState];
}

#pragma mark - Options

- (BOOL)hasConfigureSheet { return YES; }
- (NSWindow *)configureSheet {
    // This property can be queried more than once during a presentation. Never
    // end the host's session or reset unsaved controls merely because it asks.
    BOOL active=_options && (_options.sheetParent || _options.visible || NSApp.modalWindow==_options);
    os_log(ACOptionsLog(),"configureSheet view=%p window=%p active=%d",self,_options,active);
    if (active) return _options;
    if (!_options) {
        _options=[[ACOptionsWindow alloc] initWithContentRect:NSMakeRect(0,0,460,356) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
        _options.title=@"Atelier Clock"; _options.releasedWhenClosed=NO;
        NSView *v=_options.contentView;
        NSArray *labels=@[@"Design",@"Palette",@"Appearance",@"Movement",@"Size"];
        for (NSInteger i=0;i<5;i++) {
            NSTextField *label=[NSTextField labelWithString:labels[i]];
            label.frame=NSMakeRect(28,296-i*44,110,24); [v addSubview:label];
        }
        _designControl=[[NSPopUpButton alloc] initWithFrame:NSMakeRect(150,294,282,26) pullsDown:NO];
        for (int i=0;i<5;i++) {
            [_designControl addItemWithTitle:kDesignNames[i]];
            _designControl.lastItem.tag=i;
        }
        [_designControl.menu addItem:[NSMenuItem separatorItem]];
        [_designControl addItemWithTitle:@"Auto · Daily"];
        _designControl.lastItem.tag=ACAutomaticDesign;
        _designControl.target=self; _designControl.action=@selector(designChanged:); [v addSubview:_designControl];
        _paletteControl=[[NSPopUpButton alloc] initWithFrame:NSMakeRect(150,250,282,26) pullsDown:NO]; [v addSubview:_paletteControl];
        _appearanceControl=[[NSPopUpButton alloc] initWithFrame:NSMakeRect(150,206,282,26) pullsDown:NO];
        [_appearanceControl addItemsWithTitles:@[@"Light",@"Dark",@"Follow system"]]; [v addSubview:_appearanceControl];
        _movementControl=[[NSPopUpButton alloc] initWithFrame:NSMakeRect(150,162,282,26) pullsDown:NO];
        [_movementControl addItemsWithTitles:@[@"Smooth · 30 frames / second",@"Mechanical · 8 steps / second",@"Quartz · 1 step / second"]]; [v addSubview:_movementControl];
        _sizeControl=[NSSlider sliderWithValue:0.84 minValue:0.45 maxValue:0.92 target:nil action:NULL];
        _sizeControl.frame=NSMakeRect(150,118,282,24); [v addSubview:_sizeControl];
        _numeralControl=[NSButton checkboxWithTitle:@"Show hour numerals" target:nil action:NULL];
        _numeralControl.frame=NSMakeRect(150,80,282,24); [v addSubview:_numeralControl];
        NSButton *cancel=[NSButton buttonWithTitle:@"Cancel" target:self action:@selector(cancelOptions:)];
        cancel.frame=NSMakeRect(247,24,85,32); cancel.keyEquivalent=@"\e"; [v addSubview:cancel];
        NSButton *done=[NSButton buttonWithTitle:@"Save" target:self action:@selector(saveOptions:)];
        done.frame=NSMakeRect(340,24,85,32); done.keyEquivalent=@"\r"; [v addSubview:done];
    }
    [self updateDailyStyleForDate:[self clockDate]];
    NSInteger selection=_automatic?ACAutomaticDesign:_design;
    [_designControl selectItemWithTag:selection];
    [self populatePalettesForDesign:selection select:_palette];
    [_appearanceControl selectItemAtIndex:_appearance];
    [_movementControl selectItemAtIndex:_movement];
    _sizeControl.doubleValue=_scale;
    _numeralControl.state=_numerals ? NSControlStateValueOn : NSControlStateValueOff;
    return _options;
}
- (void)populatePalettesForDesign:(NSInteger)design select:(NSInteger)index {
    [_paletteControl removeAllItems];
    BOOL automatic=design==ACAutomaticDesign;
    _paletteControl.enabled=!automatic;
    if (automatic) {
        ACDailyStyle today=ACDailyStyleForDay([self dayNumberForDate:[self clockDate]]);
        NSInteger count; const ACPalette *table=ACPalettesForDesign(today.design,&count);
        [_paletteControl addItemWithTitle:[NSString stringWithFormat:@"%@ · %@",kDesignNames[today.design],
                                         [NSString stringWithUTF8String:table[today.palette].name]]];
        [_paletteControl selectItemAtIndex:0];
        return;
    }
    NSInteger count; const ACPalette *table=ACPalettesForDesign(design,&count);
    for (NSInteger i=0;i<count;i++) [_paletteControl addItemWithTitle:[NSString stringWithUTF8String:table[i].name]];
    [_paletteControl selectItemAtIndex:MAX(0,MIN(count-1,index))];
}
- (void)designChanged:(id)sender {
    [self populatePalettesForDesign:_designControl.selectedItem.tag select:0];
}
- (void)closeOptionsWithReturnCode:(NSModalResponse)code {
    NSWindow *sheet=_options;
    if (!sheet) return;
    NSWindow *parent=sheet.sheetParent;
    BOOL modal=NSApp.modalWindow==sheet;
    os_log(ACOptionsLog(),"dismiss view=%p window=%p parent=%p modal=%d response=%ld",self,sheet,parent,modal,(long)code);
    if (parent) {
        [parent endSheet:sheet returnCode:code];
    } else if (modal) {
        // Hiding a parentless modal window does not exit its modal event loop.
        // Only stop a session belonging to our window, never the host's own one.
        [NSApp stopModalWithCode:code];
    } else {
        // ScreenSaverView's configureSheet contract explicitly uses NSApp's
        // endSheet API. A legacy/remote host need not expose a local sheetParent.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [NSApp endSheet:sheet returnCode:code];
#pragma clang diagnostic pop
    }
    [sheet orderOut:nil];
}
- (void)cancelOptions:(id)sender { [self closeOptionsWithReturnCode:NSModalResponseCancel]; }
- (void)saveOptions:(id)sender {
    BOOL automatic=_designControl.selectedItem.tag==ACAutomaticDesign;
    [_defaults setBool:automatic forKey:@"automatic"];
    if (!automatic) {
        [_defaults setInteger:_designControl.selectedItem.tag forKey:@"design"];
        [_defaults setInteger:_paletteControl.indexOfSelectedItem forKey:@"palette"];
    }
    [_defaults setInteger:_appearanceControl.indexOfSelectedItem forKey:@"appearance"];
    [_defaults setInteger:_movementControl.indexOfSelectedItem forKey:@"movement"];
    [_defaults setDouble:_sizeControl.doubleValue forKey:@"size"];
    [_defaults setBool:_numeralControl.state==NSControlStateValueOn forKey:@"numerals"];
    [_defaults synchronize]; [self reloadPreferences]; [self closeOptionsWithReturnCode:NSModalResponseOK];
}
#ifdef AC_HARNESS
- (void)acConfigureDesign:(NSInteger)design palette:(NSInteger)pal appearance:(NSInteger)ap numerals:(BOOL)n {
    _design=design; _palette=pal; _appearance=ap; _numerals=n; _movement=0; _automatic=NO; _scale=0.92;
    _dialCache=nil;
}
- (void)acSetDate:(NSDate *)date { _acDate=date; }
- (void)acSetScale:(CGFloat)scale { _scale=scale; _dialCache=nil; }
- (void)acSetDisplayElapsed:(NSTimeInterval)elapsed { _acDisplayElapsed=@(elapsed); }
#endif
@end
