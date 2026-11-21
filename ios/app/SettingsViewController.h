#import <UIKit/UIKit.h>

@interface SettingsViewController : UITableViewController
// titleId == nil -> global settings, otherwise per-game custom config
- (instancetype)initWithTitleId:(NSString *)titleId gameName:(NSString *)name;
@end
