#import "GameViewController.h"
#import "VirtualGamepadView.h"

#include "vita3k_ios.h"

#import <QuartzCore/CAMetalLayer.h>

// Backing view whose layer is the CAMetalLayer MoltenVK renders into. Touches are
// forwarded to the emulated front/rear touch panel.
@interface MetalView : UIView
@end
@implementation MetalView
+ (Class)layerClass {
    return [CAMetalLayer class];
}
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.multipleTouchEnabled = YES;
        self.opaque = YES;
        self.backgroundColor = UIColor.blackColor;
        self.contentScaleFactor = UIScreen.mainScreen.nativeScale;
        CAMetalLayer *l = (CAMetalLayer *)self.layer;
        l.opaque = YES;
        l.contentsScale = UIScreen.mainScreen.nativeScale;
        l.framebufferOnly = YES; // lets Metal use the fast, compressed path for the swapchain
        l.maximumDrawableCount = 3;
    }
    return self;
}
- (void)send:(NSSet<UITouch *> *)touches phase:(int)phase {
    const CGSize sz = self.bounds.size;
    if (sz.width < 1 || sz.height < 1)
        return;
    for (UITouch *t in touches) {
        const CGPoint p = [t locationInView:self];
        vita3k_ios::touch_event(phase, (int64_t)(uintptr_t)(__bridge void *)t, (float)(p.x / sz.width), (float)(p.y / sz.height), 1.0f);
    }
}
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { [self send:touches phase:0]; }
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { [self send:touches phase:1]; }
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { [self send:touches phase:2]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { [self send:touches phase:2]; }
@end

// Invisible responder that turns the iOS keyboard into Vita IME input
@interface ImeInputView : UIView <UIKeyInput>
@end
@implementation ImeInputView
- (BOOL)canBecomeFirstResponder { return YES; }
- (BOOL)hasText { return YES; }
- (void)insertText:(NSString *)text {
    if ([text isEqualToString:@"\n"])
        vita3k_ios::ime_submit();
    else
        vita3k_ios::ime_text_input(text.UTF8String);
}
- (void)deleteBackward { vita3k_ios::ime_backspace(); }
- (UIKeyboardType)keyboardType { return UIKeyboardTypeDefault; }
- (UITextAutocorrectionType)autocorrectionType { return UITextAutocorrectionTypeNo; }
- (UITextAutocapitalizationType)autocapitalizationType { return UITextAutocapitalizationTypeNone; }
@end

@implementation GameViewController {
    NSString *_titleId;
    MetalView *_metal;
    VirtualGamepadView *_pad;
    ImeInputView *_ime;
    BOOL _rear;
    BOOL _started;
}

- (instancetype)initWithTitleId:(NSString *)titleId {
    if ((self = [super init]))
        _titleId = titleId;
    return self;
}

- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures { return UIRectEdgeAll; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;

    _metal = [[MetalView alloc] initWithFrame:self.view.bounds];
    _metal.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:_metal];

    _pad = [[VirtualGamepadView alloc] initWithFrame:self.view.bounds];
    _pad.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    __weak GameViewController *weak = self;
    _pad.onMenu = ^{ [weak showMenu]; };
    [self.view addSubview:_pad];

    _ime = [[ImeInputView alloc] initWithFrame:CGRectMake(0, 0, 1, 1)];
    [self.view addSubview:_ime];

    UIApplication.sharedApplication.idleTimerDisabled = YES;
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (_started)
        return;
    _started = YES;
    [self updateSurface];
    [self updateRotation];

    vita3k_ios::SessionCallbacks cb;
    cb.on_exited = [weak = (__bridge void *)self](int code) {
        dispatch_async(dispatch_get_main_queue(), ^{
            GameViewController *s = (__bridge GameViewController *)weak;
            [s finish:code];
        });
    };
    cb.on_ime = [weak = (__bridge void *)self](const vita3k_ios::ImeSnapshot &snap) {
        const bool active = snap.active;
        dispatch_async(dispatch_get_main_queue(), ^{
            GameViewController *s = (__bridge GameViewController *)weak;
            if (!s)
                return;
            if (active)
                [s->_ime becomeFirstResponder];
            else
                [s->_ime resignFirstResponder];
            s->_pad.hidden = active;
        });
    };
    const CGSize px = [self pixelSize];
    if (!vita3k_ios::start_session(_titleId.UTF8String, (__bridge void *)_metal.layer, (int)px.width, (int)px.height, cb)) {
        [self finish:-1];
    }
}

- (CGSize)pixelSize {
    const CGFloat s = UIScreen.mainScreen.nativeScale;
    return CGSizeMake(round(self.view.bounds.size.width * s), round(self.view.bounds.size.height * s));
}

- (void)updateSurface {
    const CGSize px = [self pixelSize];
    ((CAMetalLayer *)_metal.layer).drawableSize = px;
    vita3k_ios::set_surface_size((int)px.width, (int)px.height);
}

- (void)updateRotation {
    const UIInterfaceOrientation o = self.view.window.windowScene.interfaceOrientation;
    // 1 = ROTATION_90 (home button right), 3 = ROTATION_270 (home button left)
    vita3k_ios::set_display_rotation(o == UIInterfaceOrientationLandscapeLeft ? 3 : 1);
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (_started) {
        [self updateSurface];
        [self updateRotation];
    }
}

- (void)showMenu {
    vita3k_ios::set_paused(true);
    UIAlertController *a = [UIAlertController alertControllerWithTitle:nil message:nil preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Resume" style:UIAlertActionStyleDefault handler:^(UIAlertAction *) { vita3k_ios::set_paused(false); }]];
    [a addAction:[UIAlertAction actionWithTitle:_rear ? @"Use front touch" : @"Use rear touch" style:UIAlertActionStyleDefault handler:^(UIAlertAction *) {
        self->_rear = !self->_rear;
        vita3k_ios::set_rear_touch(self->_rear);
        vita3k_ios::set_paused(false);
    }]];
    [a addAction:[UIAlertAction actionWithTitle:_pad.alpha > 0.5 ? @"Hide on-screen controls" : @"Show on-screen controls" style:UIAlertActionStyleDefault handler:^(UIAlertAction *) {
        self->_pad.alpha = self->_pad.alpha > 0.5 ? 0.0 : 1.0;
        self->_pad.userInteractionEnabled = self->_pad.alpha > 0.5;
        vita3k_ios::set_paused(false);
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Quit game" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *) {
        vita3k_ios::set_paused(false);
        vita3k_ios::stop_session();
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)finish:(int)code {
    UIApplication.sharedApplication.idleTimerDisabled = NO;
    UIViewController *presenting = self.presentingViewController;
    [self dismissViewControllerAnimated:YES completion:^{
        if (code != 0) {
            UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Game stopped" message:@"The game could not be started or stopped unexpectedly. See Documents/Vita3K/Vita3K.log." preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [presenting presentViewController:a animated:YES completion:nil];
        }
    }];
}

@end
