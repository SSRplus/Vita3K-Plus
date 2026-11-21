#import "AppDelegate.h"
#import "LibraryViewController.h"
#import "InstallHelper.h"

#include "vita3k_ios.h"
#include "ios_jit.h"

#import <AVFoundation/AVFoundation.h>

@implementation AppDelegate

+ (NSString *)storageDirectory {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *dir = [docs stringByAppendingPathComponent:@"Vita3K"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeDefault options:AVAudioSessionCategoryOptionMixWithOthers error:nil];
    [session setActive:YES error:nil];

    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.backgroundColor = UIColor.blackColor;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[LibraryViewController new]];
    nav.navigationBar.prefersLargeTitles = YES;
    self.window.rootViewController = nav;
    [self.window makeKeyAndVisible];
    return YES;
}

- (UIInterfaceOrientationMask)application:(UIApplication *)application supportedInterfaceOrientationsForWindow:(UIWindow *)window {
    return UIInterfaceOrientationMaskAllButUpsideDown;
}

- (void)applicationWillResignActive:(UIApplication *)application {
    vita3k_ios::set_background(true);
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
    vita3k_ios::set_background(false);
}

// "Open in Vita3K" from the Files app / share sheet
- (BOOL)application:(UIApplication *)app openURL:(NSURL *)url options:(NSDictionary<UIApplicationOpenURLOptionsKey, id> *)options {
    if (!url.isFileURL)
        return NO;
    UIViewController *top = self.window.rootViewController;
    while (top.presentedViewController)
        top = top.presentedViewController;
    [InstallHelper installFileAtURL:url from:top completion:nil];
    return YES;
}

@end
