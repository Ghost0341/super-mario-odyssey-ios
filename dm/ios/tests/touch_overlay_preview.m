// Game-free AppKit render of canonical overlay geometry/palette, not device QA.
#import <AppKit/AppKit.h>
#include "dm_touch_controls.h"
static CGContextRef context;
static void color(double alpha) { CGContextSetRGBFillColor(context,1,1,1,alpha); }
static CGPoint point(dm_tc_point p) { return CGPointMake(p.x,p.y); }
static CGRect rect(dm_tc_rect r) { return CGRectMake(r.x,r.y,r.width,r.height); }
static void path(CGPathRef p,double alpha) {
    color(alpha);CGContextSetRGBStrokeColor(context,1,1,1,DM_TC_STROKE_ALPHA);CGContextSetLineWidth(context,1.5);
    CGContextAddPath(context,p);CGContextDrawPath(context,kCGPathFillStroke);CGPathRelease(p);
}
static void circle(dm_tc_point p,double r,double alpha) {
    path(CGPathCreateWithEllipseInRect(CGRectMake(p.x-r,p.y-r,2*r,2*r),NULL),alpha);
}
static void label(NSString *s,dm_tc_point p,double size) {
    NSDictionary *attributes=@{NSFontAttributeName:[NSFont systemFontOfSize:size weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName:[NSColor colorWithWhite:1 alpha:DM_TC_TEXT_ALPHA]};
    NSSize z=[s sizeWithAttributes:attributes];[s drawAtPoint:NSMakePoint(p.x-z.width/2,p.y-z.height/2) withAttributes:attributes];
}
static CGPathRef drop(CGPoint c,double r,double angle,double round) {
    double d=r*DM_TC_DROP_TIP,th=acos(r/d);
    CGPoint tip=CGPointMake(c.x+d*cos(angle),c.y+d*sin(angle));
    CGPoint a=CGPointMake(c.x+r*cos(angle+th),c.y+r*sin(angle+th)),b=CGPointMake(c.x+r*cos(angle-th),c.y+r*sin(angle-th));
    CGMutablePathRef p=CGPathCreateMutable();CGPathMoveToPoint(p,NULL,b.x,b.y);
    CGPathAddArcToPoint(p,NULL,tip.x,tip.y,a.x,a.y,round);CGPathAddArc(p,NULL,c.x,c.y,r,angle+th,angle-th,0);CGPathCloseSubpath(p);return p;
}
static void render(NSString *output,int width,int height,dm_tc_insets insets,BOOL bounds) {
    NSBitmapImageRep *image=[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:width*2 pixelsHigh:height*2
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    NSGraphicsContext *graphics=[NSGraphicsContext graphicsContextWithBitmapImageRep:image];
    [NSGraphicsContext saveGraphicsState];NSGraphicsContext.currentContext=graphics;context=graphics.CGContext;
    CGContextScaleCTM(context,2,2);CGContextTranslateCTM(context,0,height);CGContextScaleCTM(context,1,-1);
    NSGraphicsContext.currentContext=[NSGraphicsContext graphicsContextWithCGContext:context flipped:YES];
    CGContextSetRGBFillColor(context,.10,.12,.15,1);CGContextFillRect(context,CGRectMake(0,0,width,height));
    dm_tc_layout l=dm_tc_make_layout(width,height,insets);double u=l.unit;
    for (int face=0;face<4;face++) { dm_tc_point p=dm_tc_face_position(l,face);circle(p,DM_TC_FACE_R*u,DM_TC_IDLE_ALPHA);label(@[@"A",@"B",@"X",@"Y"][face],p,20*u); }
    circle(l.left_stick,DM_TC_STICK_R*u,DM_TC_RING_ALPHA);circle(l.left_stick,DM_TC_KNOB_R*u,DM_TC_IDLE_ALPHA);
    circle(l.left_stick,DM_TC_KNOB_R*.62*u,0);
    for (int side=0;side<2;side++) {
        for (int trigger=0;trigger<2;trigger++) {
            dm_tc_point p=dm_tc_shoulder(l,side,trigger);double r=(trigger?DM_TC_ZL_R:DM_TC_L_R)*u;
            path(drop(point(p),r,side?-M_PI_4:-3*M_PI_4,4*u),DM_TC_IDLE_ALPHA);
            label(trigger?(side?@"ZR":@"ZL"):(side?@"R":@"L"),p,16*u);
        }
        dm_tc_point p=dm_tc_click(l,side);circle(p,DM_TC_CLICK_R*u,DM_TC_IDLE_ALPHA);label(side?@"R3":@"L3",p,13*u);
        dm_tc_rect r=dm_tc_pill(l,side);path(CGPathCreateWithRoundedRect(rect(r),r.height/2,r.height/2,NULL),DM_TC_IDLE_ALPHA);
        label(side?@"+":@"−",(dm_tc_point){r.x+r.width/2,r.y+r.height/2},18*u);
    }
    for (int arm=0;arm<4;arm++) {
        double a=arm*M_PI_2,w=DM_TC_ARM_W*u,r=DM_TC_DPAD_R*u,in=DM_TC_ARM_IN*u;
        CGPoint v[5]={{-w,-r},{w,-r},{w,-(in+w)},{0,-in},{-w,-(in+w)}};
        CGMutablePathRef p=CGPathCreateMutable();
        for (int i=0;i<5;i++) v[i]=CGPointMake(l.dpad.x+v[i].x*cos(a)-v[i].y*sin(a),l.dpad.y+v[i].x*sin(a)+v[i].y*cos(a));
        CGPathMoveToPoint(p,NULL,(v[4].x+v[0].x)/2,(v[4].y+v[0].y)/2);
        for (int i=0;i<5;i++) CGPathAddArcToPoint(p,NULL,v[i].x,v[i].y,v[(i+1)%5].x,v[(i+1)%5].y,6*u);
        CGPathCloseSubpath(p);path(p,DM_TC_IDLE_ALPHA);
    }
    NSImage *gear=[NSImage imageWithSystemSymbolName:@DM_TC_GEAR_SYMBOL accessibilityDescription:nil];
    gear=[gear imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:DM_TC_GEAR_ICON_SIZE weight:NSFontWeightRegular]];
    gear=[gear imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPaletteColors:@[[NSColor colorWithWhite:1 alpha:DM_TC_GEAR_ALPHA]]]];
    double inset=(DM_TC_GEAR_SIZE-DM_TC_GEAR_ICON_SIZE)/2;
    [gear drawInRect:NSRectFromCGRect(CGRectInset(rect(l.gear),inset,inset))];
    if (bounds) {
        CGContextSetRGBStrokeColor(context,.2,.8,1,.8);CGContextSetLineWidth(context,1);
        CGContextStrokeRect(context,rect(l.gear));
        for (int side=0;side<2;side++) CGContextStrokeRect(context,rect(dm_tc_pill_hit(l,side)));
    }
    [NSGraphicsContext restoreGraphicsState];
    [[image representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:output atomically:YES];
}
int main(int argc,char **argv) { @autoreleasepool {
    if (argc!=2) return 2;NSString *out=@(argv[1]);
    render([out stringByAppendingPathComponent:@"iphone-overlay.png"],956,440,(dm_tc_insets){0,62,21,62},NO);
    render([out stringByAppendingPathComponent:@"iphone-hit-regions.png"],956,440,(dm_tc_insets){0,62,21,62},YES);
    render([out stringByAppendingPathComponent:@"ipad-overlay.png"],1376,1032,(dm_tc_insets){24,0,20,0},NO);
    render([out stringByAppendingPathComponent:@"ipad-hit-regions.png"],1376,1032,(dm_tc_insets){24,0,20,0},YES);
    return 0;
} }
