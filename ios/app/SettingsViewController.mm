#import "SettingsViewController.h"

#include "vita3k_ios.h"

#include <functional>
#include <vector>

namespace {
struct Row {
    NSString *title;
    NSString *footer;
    enum Kind { Toggle, Stepper, Choice } kind;
    std::function<bool()> get_bool;
    std::function<void(bool)> set_bool;
    std::function<double()> get_num;
    std::function<void(double)> set_num;
    double min = 0, max = 1, step = 1;
    NSString *numFormat = @"%.0f";
    NSArray<NSString *> *choices;
    std::function<NSString *()> get_choice;
    std::function<void(NSString *)> set_choice;
};
struct Section {
    NSString *title;
    std::vector<Row> rows;
};
}

@implementation SettingsViewController {
    NSString *_titleId;
    vita3k_ios::Settings _s;
    std::vector<Section> _sections;
}

- (instancetype)initWithTitleId:(NSString *)titleId gameName:(NSString *)name {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _titleId = titleId;
        self.title = name ?: @"Settings";
        _s = vita3k_ios::get_settings(titleId ? titleId.UTF8String : "");
        [self buildSections];
    }
    return self;
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    vita3k_ios::save_settings(_titleId ? _titleId.UTF8String : "", _s);
}

- (Row)toggle:(NSString *)t footer:(NSString *)f ref:(bool *)p {
    Row r;
    r.title = t;
    r.footer = f;
    r.kind = Row::Toggle;
    r.get_bool = [p] { return *p; };
    r.set_bool = [p](bool v) { *p = v; };
    return r;
}

- (Row)stepper:(NSString *)t footer:(NSString *)f fmt:(NSString *)fmt min:(double)mn max:(double)mx step:(double)st get:(std::function<double()>)g set:(std::function<void(double)>)s {
    Row r;
    r.title = t;
    r.footer = f;
    r.kind = Row::Stepper;
    r.min = mn;
    r.max = mx;
    r.step = st;
    r.numFormat = fmt;
    r.get_num = g;
    r.set_num = s;
    return r;
}

- (void)buildSections {
    vita3k_ios::Settings *p = &_s;
    _sections.clear();

    Section gfx{ @"Graphics", {} };
    gfx.rows.push_back([self stepper:@"Resolution scale" footer:@"1x is native Vita resolution. Higher costs a lot of GPU time." fmt:@"%.2gx" min:1 max:4 step:0.5 get:[p] { return (double)p->resolution_multiplier; } set:[p](double v) { p->resolution_multiplier = (float)v; }]);
    gfx.rows.push_back([self toggle:@"V-Sync" footer:nil ref:&p->v_sync]);
    gfx.rows.push_back([self stepper:@"Anisotropic filtering" footer:nil fmt:@"%.0fx" min:1 max:16 step:1 get:[p] { return (double)p->anisotropic_filtering; } set:[p](double v) { p->anisotropic_filtering = (int)v; }]);
    gfx.rows.push_back([self toggle:@"Async pipeline compilation" footer:@"Compiles shaders in the background to avoid stutter." ref:&p->async_pipeline_compilation]);
    gfx.rows.push_back([self toggle:@"Shader cache" footer:nil ref:&p->shader_cache]);
    gfx.rows.push_back([self toggle:@"Texture cache" footer:nil ref:&p->texture_cache]);
    gfx.rows.push_back([self toggle:@"Disable surface sync" footer:@"Faster for most games, may break a few that read back the framebuffer." ref:&p->disable_surface_sync]);
    gfx.rows.push_back([self toggle:@"Stretch display area" footer:nil ref:&p->stretch_the_display_area]);
    gfx.rows.push_back([self toggle:@"Pixel perfect HD" footer:nil ref:&p->fullscreen_hd_res_pixel_perfect]);
    {
        Row r;
        r.title = @"Screen filter";
        r.kind = Row::Choice;
        r.choices = @[ @"Bilinear", @"FXAA", @"FSR", @"Nearest" ];
        r.get_choice = [p] { return [NSString stringWithUTF8String:p->screen_filter.c_str()]; };
        r.set_choice = [p](NSString *v) { p->screen_filter = v.UTF8String; };
        gfx.rows.push_back(r);
    }
    {
        Row r;
        r.title = @"Memory mapping";
        r.footer = @"double-buffer is the safest. Changing it requires restarting the game.";
        r.kind = Row::Choice;
        r.choices = @[ @"disabled", @"double-buffer", @"external-host", @"page-table", @"native-buffer" ];
        r.get_choice = [p] { return [NSString stringWithUTF8String:p->memory_mapping.c_str()]; };
        r.set_choice = [p](NSString *v) { p->memory_mapping = v.UTF8String; };
        gfx.rows.push_back(r);
    }
    _sections.push_back(gfx);

    Section cpu{ @"System", {} };
    cpu.rows.push_back([self toggle:@"CPU optimisation" footer:nil ref:&p->cpu_opt]);
    cpu.rows.push_back([self toggle:@"NGS audio" footer:nil ref:&p->ngs_enable]);
    cpu.rows.push_back([self toggle:@"PSTV mode" footer:nil ref:&p->pstv_mode]);
    cpu.rows.push_back([self toggle:@"High accuracy" footer:@"Slower; only for games with rendering glitches." ref:&p->high_accuracy]);
    cpu.rows.push_back([self toggle:@"FPS hack" footer:nil ref:&p->fps_hack]);
    cpu.rows.push_back([self stepper:@"Volume" footer:nil fmt:@"%.0f%%" min:0 max:100 step:5 get:[p] { return (double)p->audio_volume; } set:[p](double v) { p->audio_volume = (int)v; }]);
    _sections.push_back(cpu);

    if (!_titleId) {
        Section dbg{ @"Overlay", {} };
        dbg.rows.push_back([self toggle:@"Performance overlay" footer:@"Shows FPS and frame time while playing." ref:&p->perf_overlay]);
        _sections.push_back(dbg);
    }
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv {
    return (NSInteger)_sections.size();
}
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return (NSInteger)_sections[s].rows.size();
}
- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    return _sections[s].title;
}
- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    return s == (NSInteger)_sections.size() - 1 ? [NSString stringWithFormat:@"Vita3K %s", vita3k_ios::version_string().c_str()] : nil;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    Row &r = _sections[ip.section].rows[ip.row];
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.textLabel.text = r.title;
    cell.detailTextLabel.text = r.footer;
    cell.detailTextLabel.numberOfLines = 0;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    const NSInteger tag = ip.section * 1000 + ip.row;
    if (r.kind == Row::Toggle) {
        UISwitch *sw = [UISwitch new];
        sw.on = r.get_bool();
        sw.tag = tag;
        [sw addTarget:self action:@selector(switched:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
    } else if (r.kind == Row::Stepper) {
        UIStepper *st = [UIStepper new];
        st.minimumValue = r.min;
        st.maximumValue = r.max;
        st.stepValue = r.step;
        st.value = r.get_num();
        st.tag = tag;
        [st addTarget:self action:@selector(stepped:) forControlEvents:UIControlEventValueChanged];
        UILabel *l = [UILabel new];
        l.text = [NSString stringWithFormat:r.numFormat, r.get_num()];
        l.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightRegular];
        l.tag = 4242;
        UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[ l, st ]];
        stack.spacing = 10;
        stack.alignment = UIStackViewAlignmentCenter;
        [stack setFrame:CGRectMake(0, 0, 190, 32)];
        cell.accessoryView = stack;
    } else {
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        cell.detailTextLabel.text = r.get_choice();
    }
    return cell;
}

- (void)switched:(UISwitch *)sw {
    _sections[sw.tag / 1000].rows[sw.tag % 1000].set_bool(sw.on);
}

- (void)stepped:(UIStepper *)st {
    Row &r = _sections[st.tag / 1000].rows[st.tag % 1000];
    r.set_num(st.value);
    UILabel *l = [st.superview viewWithTag:4242];
    l.text = [NSString stringWithFormat:r.numFormat, st.value];
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    Row &r = _sections[ip.section].rows[ip.row];
    if (r.kind != Row::Choice)
        return;
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:r.title message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSString *c in r.choices) {
        [sheet addAction:[UIAlertAction actionWithTitle:c style:UIAlertActionStyleDefault handler:^(UIAlertAction *) {
            self->_sections[ip.section].rows[ip.row].set_choice(c);
            [tv reloadRowsAtIndexPaths:@[ ip ] withRowAnimation:UITableViewRowAnimationNone];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = [tv cellForRowAtIndexPath:ip];
    [self presentViewController:sheet animated:YES completion:nil];
}

@end
