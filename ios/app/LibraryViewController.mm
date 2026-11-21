#import "LibraryViewController.h"
#import "AppDelegate.h"
#import "GameViewController.h"
#import "InstallHelper.h"
#import "SettingsViewController.h"

#include "vita3k_ios.h"
#include "ios_jit.h"

#include <algorithm>
#include <vector>

@interface GameCell : UICollectionViewCell
@property(nonatomic, strong) UIImageView *icon;
@property(nonatomic, strong) UILabel *title;
@end

@implementation GameCell
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _icon = [UIImageView new];
        _icon.contentMode = UIViewContentModeScaleAspectFill;
        _icon.clipsToBounds = YES;
        _icon.layer.cornerRadius = 14;
        _icon.backgroundColor = UIColor.secondarySystemFillColor;
        _icon.translatesAutoresizingMaskIntoConstraints = NO;
        _title = [UILabel new];
        _title.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
        _title.numberOfLines = 2;
        _title.textAlignment = NSTextAlignmentCenter;
        _title.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_icon];
        [self.contentView addSubview:_title];
        [NSLayoutConstraint activateConstraints:@[
            [_icon.topAnchor constraintEqualToAnchor:self.contentView.topAnchor],
            [_icon.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
            [_icon.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
            [_icon.heightAnchor constraintEqualToAnchor:_icon.widthAnchor],
            [_title.topAnchor constraintEqualToAnchor:_icon.bottomAnchor constant:6],
            [_title.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
            [_title.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
        ]];
    }
    return self;
}
@end

@interface LibraryViewController () <UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, UISearchResultsUpdating>
@property(nonatomic, strong) UICollectionView *grid;
@property(nonatomic, strong) UILabel *emptyLabel;
@property(nonatomic, strong) UIActivityIndicatorView *spinner;
@property(nonatomic, strong) NSCache<NSString *, UIImage *> *iconCache;
@end

@implementation LibraryViewController {
    std::vector<vita3k_ios::AppInfo> _all;
    std::vector<vita3k_ios::AppInfo> _shown;
    NSString *_filter;
    BOOL _ready;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Vita3K";
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.iconCache = [NSCache new];

    UICollectionViewFlowLayout *layout = [UICollectionViewFlowLayout new];
    layout.sectionInset = UIEdgeInsetsMake(12, 16, 24, 16);
    layout.minimumInteritemSpacing = 12;
    layout.minimumLineSpacing = 18;
    self.grid = [[UICollectionView alloc] initWithFrame:self.view.bounds collectionViewLayout:layout];
    self.grid.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.grid.backgroundColor = UIColor.clearColor;
    self.grid.dataSource = self;
    self.grid.delegate = self;
    [self.grid registerClass:GameCell.class forCellWithReuseIdentifier:@"cell"];
    [self.view addSubview:self.grid];

    self.emptyLabel = [UILabel new];
    self.emptyLabel.numberOfLines = 0;
    self.emptyLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyLabel.textColor = UIColor.secondaryLabelColor;
    self.emptyLabel.text = @"No games yet.\nTap + to install firmware (PUP), games (PKG / VPK / ZIP) and licenses.\nYou can also drop files into Files > Vita3K.";
    self.emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.emptyLabel];
    [NSLayoutConstraint activateConstraints:@[
        [self.emptyLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.emptyLabel.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [self.emptyLabel.widthAnchor constraintEqualToAnchor:self.view.widthAnchor multiplier:0.8],
    ]];
    self.emptyLabel.hidden = YES;

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    self.spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.spinner];
    [NSLayoutConstraint activateConstraints:@[
        [self.spinner.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.spinner.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
    ]];

    UISearchController *search = [[UISearchController alloc] initWithSearchResultsController:nil];
    search.searchResultsUpdater = self;
    search.obscuresBackgroundDuringPresentation = NO;
    self.navigationItem.searchController = search;

    self.navigationItem.rightBarButtonItems = @[
        [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"plus"] style:UIBarButtonItemStylePlain target:self action:@selector(installTapped)],
        [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"gearshape"] style:UIBarButtonItemStylePlain target:self action:@selector(settingsTapped)],
    ];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"bolt.horizontal.circle"] style:UIBarButtonItemStylePlain target:self action:@selector(jitTapped)];

    [self bootEmulator];
}

- (void)bootEmulator {
    [self.spinner startAnimating];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *res = NSBundle.mainBundle.resourcePath;
        const bool ok = vita3k_ios::initialize([AppDelegate storageDirectory].UTF8String, res.UTF8String);
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.spinner stopAnimating];
            if (!ok) {
                [self alert:@"Initialisation failed" message:@"The emulator core could not start. Check Documents/Vita3K/log for details."];
                return;
            }
            self->_ready = YES;
            [self reload];
            [self updateJitIcon];
            if (!vita3k_ios::has_firmware())
                [self alert:@"Firmware missing" message:@"Install the PS Vita firmware (PSP2UPDAT.PUP) with the + button before playing."];
        });
    });
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (_ready)
        [self reload];
}

- (void)reload {
    _all = vita3k_ios::list_apps();
    std::sort(_all.begin(), _all.end(), [](const auto &a, const auto &b) {
        if (a.last_played != b.last_played)
            return a.last_played > b.last_played;
        return a.title < b.title;
    });
    [self applyFilter];
}

- (void)applyFilter {
    _shown.clear();
    for (const auto &a : _all) {
        if (_filter.length) {
            NSString *t = [NSString stringWithUTF8String:a.title.c_str()] ?: @"";
            NSString *tid = [NSString stringWithUTF8String:a.title_id.c_str()] ?: @"";
            if ([t rangeOfString:_filter options:NSCaseInsensitiveSearch].location == NSNotFound && [tid rangeOfString:_filter options:NSCaseInsensitiveSearch].location == NSNotFound)
                continue;
        }
        _shown.push_back(a);
    }
    self.emptyLabel.hidden = !_shown.empty() || !_ready;
    [self.grid reloadData];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)sc {
    _filter = sc.searchBar.text;
    [self applyFilter];
}

- (void)alert:(NSString *)title message:(NSString *)message {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

#pragma mark - Actions

- (void)installTapped {
    [InstallHelper presentPickerFrom:self completion:^{ [self reload]; }];
}

- (void)settingsTapped {
    [self.navigationController pushViewController:[[SettingsViewController alloc] initWithTitleId:nil gameName:nil] animated:YES];
}

- (void)updateJitIcon {
    const auto st = vita3k_ios::jit::probe();
    self.navigationItem.leftBarButtonItem.tintColor = st.available() ? UIColor.systemGreenColor : UIColor.systemRedColor;
}

- (void)jitTapped {
    const auto st = vita3k_ios::jit::probe();
    [self updateJitIcon];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:st.available() ? @"JIT is enabled" : @"JIT is not enabled"
                                                               message:[NSString stringWithUTF8String:st.description.c_str()]
                                                        preferredStyle:UIAlertControllerStyleAlert];
    if (!st.available()) {
        [a addAction:[UIAlertAction actionWithTitle:@"Enable with TrollStore" style:UIAlertActionStyleDefault handler:^(UIAlertAction *) { [self requestTrollStoreJit]; }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"Close" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)requestTrollStoreJit {
    NSString *bid = NSBundle.mainBundle.bundleIdentifier;
    NSURL *url = [NSURL URLWithString:[NSString stringWithUTF8String:vita3k_ios::jit::trollstore_enable_url(bid.UTF8String).c_str()]];
    [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        vita3k_ios::jit::wait_for_jit(15000);
        dispatch_async(dispatch_get_main_queue(), ^{ [self updateJitIcon]; });
    });
}

#pragma mark - Collection view

- (NSInteger)collectionView:(UICollectionView *)cv numberOfItemsInSection:(NSInteger)section {
    return (NSInteger)_shown.size();
}

- (CGSize)collectionView:(UICollectionView *)cv layout:(UICollectionViewLayout *)layout sizeForItemAtIndexPath:(NSIndexPath *)ip {
    const CGFloat avail = cv.bounds.size.width - 32;
    const int cols = MAX(3, (int)(avail / 130));
    const CGFloat w = floor((avail - 12 * (cols - 1)) / cols);
    return CGSizeMake(w, w + 40);
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)cv cellForItemAtIndexPath:(NSIndexPath *)ip {
    GameCell *cell = [cv dequeueReusableCellWithReuseIdentifier:@"cell" forIndexPath:ip];
    const auto &a = _shown[ip.item];
    cell.title.text = [NSString stringWithUTF8String:a.title.c_str()];
    cell.icon.image = nil;
    NSString *path = [NSString stringWithUTF8String:a.icon_path.c_str()];
    if (path.length) {
        UIImage *img = [self.iconCache objectForKey:path];
        if (img) {
            cell.icon.image = img;
        } else {
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                UIImage *loaded = [UIImage imageWithContentsOfFile:path];
                if (!loaded)
                    return;
                [self.iconCache setObject:loaded forKey:path];
                dispatch_async(dispatch_get_main_queue(), ^{
                    if ([[cv indexPathsForVisibleItems] containsObject:ip])
                        ((GameCell *)[cv cellForItemAtIndexPath:ip]).icon.image = loaded;
                });
            });
        }
    }
    return cell;
}

- (void)collectionView:(UICollectionView *)cv didSelectItemAtIndexPath:(NSIndexPath *)ip {
    const auto &a = _shown[ip.item];
    NSString *tid = [NSString stringWithUTF8String:a.title_id.c_str()];
    [self launch:tid];
}

- (void)launch:(NSString *)titleId {
    auto st = vita3k_ios::jit::probe();
    if (!st.available()) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"JIT required" message:@"The PS Vita CPU is emulated with a JIT compiler. Enable JIT for this app first." preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"Enable with TrollStore" style:UIAlertActionStyleDefault handler:^(UIAlertAction *) {
            NSString *bid = NSBundle.mainBundle.bundleIdentifier;
            NSURL *url = [NSURL URLWithString:[NSString stringWithUTF8String:vita3k_ios::jit::trollstore_enable_url(bid.UTF8String).c_str()]];
            [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                auto s = vita3k_ios::jit::wait_for_jit(15000);
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self updateJitIcon];
                    if (s.available())
                        [self launch:titleId];
                });
            });
        }]];
        [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }
    GameViewController *game = [[GameViewController alloc] initWithTitleId:titleId];
    game.modalPresentationStyle = UIModalPresentationFullScreen;
    [self presentViewController:game animated:YES completion:nil];
}

- (UIContextMenuConfiguration *)collectionView:(UICollectionView *)cv contextMenuConfigurationForItemAtIndexPath:(NSIndexPath *)ip point:(CGPoint)point {
    const auto a = _shown[ip.item];
    NSString *tid = [NSString stringWithUTF8String:a.title_id.c_str()];
    NSString *name = [NSString stringWithUTF8String:a.title.c_str()];
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(NSArray<UIMenuElement *> *) {
        UIAction *play = [UIAction actionWithTitle:@"Play" image:[UIImage systemImageNamed:@"play.fill"] identifier:nil handler:^(UIAction *) { [self launch:tid]; }];
        UIAction *cfg = [UIAction actionWithTitle:@"Game settings" image:[UIImage systemImageNamed:@"slider.horizontal.3"] identifier:nil handler:^(UIAction *) {
            [self.navigationController pushViewController:[[SettingsViewController alloc] initWithTitleId:tid gameName:name] animated:YES];
        }];
        UIAction *shader = [UIAction actionWithTitle:@"Clear shader cache" image:[UIImage systemImageNamed:@"trash"] identifier:nil handler:^(UIAction *) {
            vita3k_ios::delete_shader_cache(tid.UTF8String);
        }];
        UIAction *save = [UIAction actionWithTitle:@"Delete save data" image:[UIImage systemImageNamed:@"externaldrive.badge.minus"] identifier:nil handler:^(UIAction *) {
            vita3k_ios::delete_savedata(tid.UTF8String);
        }];
        save.attributes = UIMenuElementAttributesDestructive;
        UIAction *del = [UIAction actionWithTitle:@"Delete game" image:[UIImage systemImageNamed:@"xmark.bin"] identifier:nil handler:^(UIAction *) {
            vita3k_ios::delete_app(tid.UTF8String);
            [self reload];
        }];
        del.attributes = UIMenuElementAttributesDestructive;
        return [UIMenu menuWithTitle:name children:@[ play, cfg, shader, save, del ]];
    }];
}

@end
