#import <UIKit/UIKit.h>

@interface InstallHelper : NSObject
// Presents a document picker and installs whatever was chosen (PUP firmware, PKG, VPK/ZIP archive, RIF license)
+ (void)presentPickerFrom:(UIViewController *)vc completion:(void (^)(void))completion;
+ (void)installFileAtURL:(NSURL *)url from:(UIViewController *)vc completion:(void (^)(void))completion;
@end
