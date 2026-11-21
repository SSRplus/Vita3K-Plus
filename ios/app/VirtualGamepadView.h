#import <UIKit/UIKit.h>

// Translucent on-screen PS Vita controls (d-pad, face buttons, shoulders, sticks, start/select).
@interface VirtualGamepadView : UIView
@property(nonatomic, copy) void (^onMenu)(void);
@end
