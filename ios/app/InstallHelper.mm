#import "InstallHelper.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include "vita3k_ios.h"

@interface InstallHelper () <UIDocumentPickerDelegate>
@property(nonatomic, weak) UIViewController *presenter;
@property(nonatomic, copy) void (^completion)(void);
@end

static InstallHelper *s_active;

@implementation InstallHelper

+ (void)presentPickerFrom:(UIViewController *)vc completion:(void (^)(void))completion {
    InstallHelper *h = [InstallHelper new];
    h.presenter = vc;
    h.completion = completion;
    s_active = h;
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[ UTTypeItem ] asCopy:YES];
    picker.allowsMultipleSelection = YES;
    picker.delegate = h;
    [vc presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSMutableArray *queue = [urls mutableCopy];
    [self processQueue:queue];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    s_active = nil;
}

- (void)processQueue:(NSMutableArray<NSURL *> *)queue {
    if (queue.count == 0) {
        if (self.completion)
            self.completion();
        s_active = nil;
        return;
    }
    NSURL *url = queue.firstObject;
    [queue removeObjectAtIndex:0];
    [InstallHelper installFileAtURL:url from:self.presenter completion:^{
        [self processQueue:queue];
    }];
}

+ (void)installFileAtURL:(NSURL *)url from:(UIViewController *)vc completion:(void (^)(void))completion {
    NSString *path = url.path;
    NSString *ext = path.pathExtension.lowercaseString;

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Installing" message:path.lastPathComponent preferredStyle:UIAlertControllerStyleAlert];
    [vc presentViewController:alert animated:YES completion:nil];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        std::string p = path.UTF8String;
        auto report = [alert, path](int percent, const char *status) {
            NSString *msg = [NSString stringWithFormat:@"%@\n%s %d%%", path.lastPathComponent, status, percent];
            dispatch_async(dispatch_get_main_queue(), ^{ alert.message = msg; });
        };

        bool ok = false;
        std::string detail;
        bool needs_zrif = false;

        if ([ext isEqualToString:@"pup"]) {
            const std::string version = vita3k_ios::install_firmware(p, report);
            ok = !version.empty();
            detail = ok ? "Firmware " + version + " installed" : "Firmware installation failed";
        } else if ([ext isEqualToString:@"pkg"]) {
            std::string zrif = vita3k_ios::find_pkg_zrif(p);
            if (zrif.empty())
                needs_zrif = true;
            else {
                ok = vita3k_ios::install_pkg(p, zrif, report);
                detail = ok ? "Package installed" : "Package installation failed";
            }
        } else if ([ext isEqualToString:@"rif"] || [path.lastPathComponent.lowercaseString isEqualToString:@"work.bin"]) {
            ok = vita3k_ios::install_license(p);
            detail = ok ? "License installed" : "License installation failed";
        } else {
            ok = vita3k_ios::install_archive(p, report);
            detail = ok ? "Archive installed" : "Unsupported or invalid archive";
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            [alert dismissViewControllerAnimated:YES completion:^{
                if (needs_zrif) {
                    UIAlertController *ask = [UIAlertController alertControllerWithTitle:@"zRIF required" message:@"Paste the zRIF license string for this package (leave empty for free content)." preferredStyle:UIAlertControllerStyleAlert];
                    [ask addTextFieldWithConfigurationHandler:^(UITextField *tf) { tf.placeholder = @"zRIF"; }];
                    [ask addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *) { if (completion) completion(); }]];
                    [ask addAction:[UIAlertAction actionWithTitle:@"Install" style:UIAlertActionStyleDefault handler:^(UIAlertAction *) {
                        std::string zrif = ask.textFields.firstObject.text.UTF8String ?: "";
                        UIAlertController *busy = [UIAlertController alertControllerWithTitle:@"Installing" message:path.lastPathComponent preferredStyle:UIAlertControllerStyleAlert];
                        [vc presentViewController:busy animated:YES completion:nil];
                        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                            auto rep = [busy, path](int percent, const char *status) {
                                NSString *msg = [NSString stringWithFormat:@"%@\n%s %d%%", path.lastPathComponent, status, percent];
                                dispatch_async(dispatch_get_main_queue(), ^{ busy.message = msg; });
                            };
                            const bool done = vita3k_ios::install_pkg(p, zrif, rep);
                            dispatch_async(dispatch_get_main_queue(), ^{
                                [busy dismissViewControllerAnimated:YES completion:^{
                                    UIAlertController *res = [UIAlertController alertControllerWithTitle:done ? @"Done" : @"Failed" message:done ? @"Package installed" : @"Package installation failed" preferredStyle:UIAlertControllerStyleAlert];
                                    [res addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *) { if (completion) completion(); }]];
                                    [vc presentViewController:res animated:YES completion:nil];
                                }];
                            });
                        });
                    }]];
                    [vc presentViewController:ask animated:YES completion:nil];
                    return;
                }
                UIAlertController *res = [UIAlertController alertControllerWithTitle:ok ? @"Done" : @"Failed" message:[NSString stringWithUTF8String:detail.c_str()] preferredStyle:UIAlertControllerStyleAlert];
                [res addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *) { if (completion) completion(); }]];
                [vc presentViewController:res animated:YES completion:nil];
            }];
        });
    });
}

@end
