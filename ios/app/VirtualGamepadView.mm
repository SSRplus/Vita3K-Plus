#import "VirtualGamepadView.h"

#include "vita3k_ios.h"

// SDL_GamepadButton / SDL_GamepadAxis values (stable SDL3 ABI)
enum {
    BTN_SOUTH = 0, BTN_EAST = 1, BTN_WEST = 2, BTN_NORTH = 3, BTN_BACK = 4, BTN_GUIDE = 5, BTN_START = 6,
    BTN_LSTICK = 7, BTN_RSTICK = 8, BTN_LSHOULDER = 9, BTN_RSHOULDER = 10,
    BTN_UP = 11, BTN_DOWN = 12, BTN_LEFT = 13, BTN_RIGHT = 14,
    AXIS_LX = 0, AXIS_LY = 1, AXIS_RX = 2, AXIS_RY = 3
};

typedef NS_ENUM(NSInteger, PadKind) { PadButton, PadStickL, PadStickR, PadMenu };

@interface PadControl : NSObject
@property(nonatomic) PadKind kind;
@property(nonatomic) int button;
@property(nonatomic, copy) NSString *label;
@property(nonatomic) CGRect rect; // relative (0..1) in the view
@property(nonatomic) BOOL round;
@property(nonatomic) BOOL pressed;
@property(nonatomic, weak) UITouch *touch;
@property(nonatomic) CGPoint stick; // -1..1
@end
@implementation PadControl
@end

@implementation VirtualGamepadView {
    NSMutableArray<PadControl *> *_controls;
    BOOL _dpadUp, _dpadDown, _dpadLeft, _dpadRight;
    UIImpactFeedbackGenerator *_haptic;
}

- (PadControl *)add:(PadKind)k button:(int)b label:(NSString *)l x:(CGFloat)x y:(CGFloat)y w:(CGFloat)w h:(CGFloat)h round:(BOOL)r {
    PadControl *c = [PadControl new];
    c.kind = k;
    c.button = b;
    c.label = l;
    c.rect = CGRectMake(x, y, w, h);
    c.round = r;
    [_controls addObject:c];
    return c;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.multipleTouchEnabled = YES;
        self.backgroundColor = UIColor.clearColor;
        _haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        _controls = [NSMutableArray new];
        // sizes are fractions of the view; the shorter side drives the control size so they stay round
        [self add:PadButton button:BTN_LSHOULDER label:@"L" x:0.03 y:0.04 w:0.14 h:0.12 round:NO];
        [self add:PadButton button:BTN_RSHOULDER label:@"R" x:0.83 y:0.04 w:0.14 h:0.12 round:NO];
        [self add:PadButton button:BTN_UP label:@"▲" x:0.075 y:0.30 w:0.07 h:0.16 round:NO];
        [self add:PadButton button:BTN_DOWN label:@"▼" x:0.075 y:0.62 w:0.07 h:0.16 round:NO];
        [self add:PadButton button:BTN_LEFT label:@"◀" x:0.015 y:0.46 w:0.07 h:0.16 round:NO];
        [self add:PadButton button:BTN_RIGHT label:@"▶" x:0.135 y:0.46 w:0.07 h:0.16 round:NO];
        [self add:PadButton button:BTN_NORTH label:@"△" x:0.885 y:0.28 w:0.07 h:0.14 round:YES];
        [self add:PadButton button:BTN_SOUTH label:@"✕" x:0.885 y:0.64 w:0.07 h:0.14 round:YES];
        [self add:PadButton button:BTN_WEST label:@"□" x:0.815 y:0.46 w:0.07 h:0.14 round:YES];
        [self add:PadButton button:BTN_EAST label:@"○" x:0.955 y:0.46 w:0.04 h:0.14 round:YES];
        [self add:PadStickL button:BTN_LSTICK label:@"" x:0.20 y:0.66 w:0.12 h:0.30 round:YES];
        [self add:PadStickR button:BTN_RSTICK label:@"" x:0.68 y:0.66 w:0.12 h:0.30 round:YES];
        [self add:PadButton button:BTN_BACK label:@"SELECT" x:0.40 y:0.90 w:0.08 h:0.07 round:NO];
        [self add:PadButton button:BTN_START label:@"START" x:0.52 y:0.90 w:0.08 h:0.07 round:NO];
        [self add:PadButton button:BTN_GUIDE label:@"PS" x:0.46 y:0.02 w:0.08 h:0.08 round:YES];
        [self add:PadMenu button:0 label:@"≡" x:0.90 y:0.02 w:0.05 h:0.08 round:YES];
    }
    return self;
}

// Hit rect for a control, in points. Face/dpad use a square based on the short side.
- (CGRect)frameFor:(PadControl *)c {
    const CGFloat W = self.bounds.size.width, H = self.bounds.size.height;
    CGRect r = CGRectMake(c.rect.origin.x * W, c.rect.origin.y * H, c.rect.size.width * W, c.rect.size.height * H);
    if (c.round && c.kind == PadButton) {
        const CGFloat d = MIN(r.size.width, r.size.height) * 1.0;
        const CGFloat s = MAX(d, MIN(W, H) * 0.14);
        r = CGRectMake(CGRectGetMidX(r) - s / 2, CGRectGetMidY(r) - s / 2, s, s);
    } else if (c.kind == PadStickL || c.kind == PadStickR) {
        const CGFloat s = MIN(W, H) * 0.34;
        r = CGRectMake(CGRectGetMidX(r) - s / 2, CGRectGetMidY(r) - s / 2, s, s);
    } else if (c.kind == PadMenu) {
        const CGFloat s = MIN(W, H) * 0.10;
        r = CGRectMake(CGRectGetMidX(r) - s / 2, CGRectGetMidY(r) - s / 2, s, s);
    } else if (c.button >= BTN_UP && c.button <= BTN_RIGHT) {
        const CGFloat s = MIN(W, H) * 0.13;
        r = CGRectMake(CGRectGetMidX(r) - s / 2, CGRectGetMidY(r) - s / 2, s, s);
    }
    return r;
}

- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    for (PadControl *c in _controls) {
        const CGRect r = [self frameFor:c];
        const CGFloat alpha = c.pressed || c.touch ? 0.55 : 0.22;
        if (c.kind == PadStickL || c.kind == PadStickR) {
            CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:1 alpha:0.35].CGColor);
            CGContextSetLineWidth(ctx, 2);
            CGContextStrokeEllipseInRect(ctx, r);
            const CGFloat k = r.size.width * 0.22;
            const CGPoint ctr = CGPointMake(CGRectGetMidX(r) + c.stick.x * r.size.width * 0.35, CGRectGetMidY(r) + c.stick.y * r.size.width * 0.35);
            CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:1 alpha:c.touch ? 0.6 : 0.3].CGColor);
            CGContextFillEllipseInRect(ctx, CGRectMake(ctr.x - k, ctr.y - k, 2 * k, 2 * k));
            continue;
        }
        CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:1 alpha:alpha].CGColor);
        if (c.round)
            CGContextFillEllipseInRect(ctx, r);
        else
            [[UIBezierPath bezierPathWithRoundedRect:r cornerRadius:10] fill];
        NSDictionary *attrs = @{ NSFontAttributeName : [UIFont boldSystemFontOfSize:MIN(r.size.height * 0.45, 18)], NSForegroundColorAttributeName : [UIColor colorWithWhite:1 alpha:0.85] };
        const CGSize ts = [c.label sizeWithAttributes:attrs];
        [c.label drawAtPoint:CGPointMake(CGRectGetMidX(r) - ts.width / 2, CGRectGetMidY(r) - ts.height / 2) withAttributes:attrs];
    }
}

- (PadControl *)controlAt:(CGPoint)p {
    PadControl *best = nil;
    for (PadControl *c in _controls) {
        CGRect r = [self frameFor:c];
        r = CGRectInset(r, -8, -8); // generous hit area
        if (CGRectContainsPoint(r, p))
            best = c;
    }
    return best;
}

- (void)applyPress:(PadControl *)c pressed:(BOOL)p {
    if (c.pressed == p)
        return;
    c.pressed = p;
    if (c.kind == PadMenu) {
        if (p && self.onMenu)
            self.onMenu();
        return;
    }
    if (c.kind == PadButton) {
        vita3k_ios::set_button(c.button, p);
        if (p)
            [_haptic impactOccurred];
    }
}

- (void)updateStick:(PadControl *)c with:(UITouch *)t {
    const CGRect r = [self frameFor:c];
    const CGPoint p = [t locationInView:self];
    CGFloat dx = (p.x - CGRectGetMidX(r)) / (r.size.width * 0.5);
    CGFloat dy = (p.y - CGRectGetMidY(r)) / (r.size.width * 0.5);
    const CGFloat len = hypot(dx, dy);
    if (len > 1) {
        dx /= len;
        dy /= len;
    }
    c.stick = CGPointMake(dx, dy);
    const int ax = c.kind == PadStickL ? AXIS_LX : AXIS_RX;
    vita3k_ios::set_axis(ax, (int16_t)(dx * 32767));
    vita3k_ios::set_axis(ax + 1, (int16_t)(dy * 32767));
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    for (UITouch *t in touches) {
        PadControl *c = [self controlAt:[t locationInView:self]];
        if (!c)
            continue;
        c.touch = t;
        if (c.kind == PadStickL || c.kind == PadStickR)
            [self updateStick:c with:t];
        else
            [self applyPress:c pressed:YES];
    }
    [self setNeedsDisplay];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    for (UITouch *t in touches) {
        for (PadControl *c in _controls) {
            if (c.touch != t)
                continue;
            if (c.kind == PadStickL || c.kind == PadStickR) {
                [self updateStick:c with:t];
            } else {
                // sliding across the d-pad / face buttons switches the pressed button
                PadControl *now = [self controlAt:[t locationInView:self]];
                if (now != c && now && now.kind == PadButton && c.kind == PadButton) {
                    [self applyPress:c pressed:NO];
                    c.touch = nil;
                    now.touch = t;
                    [self applyPress:now pressed:YES];
                }
            }
        }
    }
    [self setNeedsDisplay];
}

- (void)endTouches:(NSSet<UITouch *> *)touches {
    for (UITouch *t in touches) {
        for (PadControl *c in _controls) {
            if (c.touch != t)
                continue;
            c.touch = nil;
            if (c.kind == PadStickL || c.kind == PadStickR) {
                c.stick = CGPointZero;
                const int ax = c.kind == PadStickL ? AXIS_LX : AXIS_RX;
                vita3k_ios::set_axis(ax, 0);
                vita3k_ios::set_axis(ax + 1, 0);
            } else {
                [self applyPress:c pressed:NO];
            }
        }
    }
    [self setNeedsDisplay];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { [self endTouches:touches]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { [self endTouches:touches]; }

// Touches that miss every control fall through to the touch-screen view below.
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.hidden || self.alpha < 0.01)
        return nil;
    return [self controlAt:point] ? self : nil;
}

@end
