// Vita3K iOS port - emulator session bridge (derived from the Android JNI bridge).
#include "vita3k_ios.h"

#include "ios_jit.h"

#include <app/functions.h>
#include <app/session_controller.h>
#include <archive.h>
#include <audio/state.h>
#include <compat/functions.h>
#include <compat/state.h>
#include <config/functions.h>
#include <config/settings.h>
#include <config/version.h>
#include <ctrl/functions.h>
#include <dialog/state.h>
#include <emuenv/state.h>
#include <ime/functions.h>
#include <ime/keyboard.h>
#include <ime/state.h>
#include <io/state.h>
#include <modules/module_parent.h>
#include <motion/event_handler.h>
#include <motion/functions.h>
#include <packages/functions.h>
#include <packages/license.h>
#include <packages/pkg.h>
#include <renderer/functions.h>
#include <renderer/state.h>
#include <rif2zrif.h>
#include <touch/functions.h>
#include <util/fs.h>
#include <util/log.h>
#include <util/string_utils.h>

#define SDL_MAIN_HANDLED
#include <SDL3/SDL.h>
#include <SDL3/SDL_main.h>

#include <dlfcn.h>
#include <pthread.h>
#include <pthread/qos.h>

#include <algorithm>
#include <atomic>
#include <cstdio>
#include <cstring>
#include <deque>
#include <mutex>
#include <optional>
#include <thread>

namespace {

struct TouchItem {
    int phase;
    int64_t finger;
    float x, y, pressure;
};

struct IosState {
    std::unique_ptr<EmuEnvState> emuenv;
    std::unique_ptr<app::AppSessionController> controller;
    Root root_paths;

    // session
    pthread_t thread{};
    std::atomic<bool> thread_alive{ false };
    std::atomic<bool> stop_requested{ false };
    vita3k_ios::SessionCallbacks callbacks;
    std::string title_id;
    void *metal_layer = nullptr;

    std::atomic<int> surface_w{ 960 };
    std::atomic<int> surface_h{ 544 };

    std::mutex input_mutex;
    std::deque<TouchItem> touch_queue;
    SDL_Joystick *vjoy = nullptr;
    SDL_JoystickID vjoy_id = 0;
};

IosState g;

// ---------------------------------------------------------------- frame host
class IOSFrameHost final : public renderer::FrameHost {
public:
    renderer::DisplayHandle handle() const override {
        return renderer::IOSDisplayHandle{ g.metal_layer };
    }
    int drawable_width() const override {
        return g.surface_w.load(std::memory_order_relaxed);
    }
    int drawable_height() const override {
        return g.surface_h.load(std::memory_order_relaxed);
    }
    std::vector<std::string> font_dirs() const override {
        return { "/System/Library/Fonts/Core/", "/System/Library/Fonts/CoreUI/", "/System/Library/Fonts/LanguageSupport/", "/System/Library/Fonts/" };
    }
};

// ---------------------------------------------------------------- ime helpers
bool ime_dialog_active(const EmuEnvState &e) {
    return e.common_dialog.type == IME_DIALOG && e.common_dialog.status == SCE_COMMON_DIALOG_STATUS_RUNNING;
}
bool any_ime_active(const EmuEnvState &e) {
    return e.ime.state || ime_dialog_active(e);
}

void finish_ime_dialog(EmuEnvState &e) {
    auto &dialog = e.common_dialog;
    auto &ime = e.ime;
    std::lock_guard<std::recursive_mutex> dl(dialog.mutex);
    std::lock_guard<std::mutex> il(ime.mutex);
    const size_t n = std::min(static_cast<size_t>(ime.str.length()), static_cast<size_t>(dialog.ime.max_length));
    if (dialog.ime.result) {
        std::memcpy(dialog.ime.result, ime.str.c_str(), n * sizeof(uint16_t));
        dialog.ime.result[n] = 0;
    }
    const std::string utf8 = string_utils::utf16_to_utf8(ime.str);
    std::snprintf(dialog.ime.text, sizeof(dialog.ime.text), "%s", utf8.c_str());
    dialog.ime.status = SCE_IME_DIALOG_BUTTON_ENTER;
    dialog.status = SCE_COMMON_DIALOG_STATUS_FINISHED;
    dialog.result = SCE_COMMON_DIALOG_RESULT_OK;
}

void cancel_ime_dialog(EmuEnvState &e) {
    auto &dialog = e.common_dialog;
    if (!dialog.ime.cancelable)
        return;
    std::lock_guard<std::recursive_mutex> dl(dialog.mutex);
    dialog.ime.status = SCE_IME_DIALOG_BUTTON_CLOSE;
    dialog.status = SCE_COMMON_DIALOG_STATUS_FINISHED;
    dialog.result = SCE_COMMON_DIALOG_RESULT_USER_CANCELED;
}

vita3k_ios::ImeSnapshot make_ime_snapshot() {
    vita3k_ios::ImeSnapshot snap;
    auto *e = g.emuenv.get();
    if (!e)
        return snap;
    const bool dialog = ime_dialog_active(*e);
    const bool sce = e->ime.state;
    if (!dialog && !sce)
        return snap;
    snap.active = true;
    snap.dialog = dialog;
    std::lock_guard<std::recursive_mutex> dl(e->common_dialog.mutex);
    std::lock_guard<std::mutex> il(e->ime.mutex);
    snap.text = string_utils::utf16_to_utf8(e->ime.str);
    snap.multiline = dialog ? e->common_dialog.ime.multiline : ((e->ime.param.option & SCE_IME_OPTION_MULTILINE) != 0);
    snap.enter_label = e->ime.enter_label;
    return snap;
}

// ---------------------------------------------------------------- virtual joystick
void detach_virtual_controller() {
    std::lock_guard<std::mutex> lock(g.input_mutex);
    if (g.vjoy) {
        SDL_CloseJoystick(g.vjoy);
        g.vjoy = nullptr;
    }
    if (g.vjoy_id) {
        SDL_DetachVirtualJoystick(g.vjoy_id);
        g.vjoy_id = 0;
    }
}

void attach_virtual_controller() {
    detach_virtual_controller();
    SDL_VirtualJoystickDesc desc;
    SDL_INIT_INTERFACE(&desc);
    desc.type = SDL_JOYSTICK_TYPE_GAMEPAD;
    desc.naxes = SDL_GAMEPAD_AXIS_COUNT;
    desc.nbuttons = SDL_GAMEPAD_BUTTON_COUNT;
    desc.name = "Vita3K Virtual Controller";
    const SDL_JoystickID id = SDL_AttachVirtualJoystick(&desc);
    if (!id) {
        LOG_ERROR("Could not create virtual controller: {}", SDL_GetError());
        return;
    }
    SDL_Joystick *joy = SDL_OpenJoystick(id);
    std::lock_guard<std::mutex> lock(g.input_mutex);
    g.vjoy_id = id;
    g.vjoy = joy;
}

// ---------------------------------------------------------------- init
bool init_session(const fs::path &storage, const fs::path &resources) {
    try {
        Root &root = g.root_paths;
        root.set_static_assets_path(resources);
        root.set_vita_fs_path(storage / "vita" / "");
        root.set_log_path(storage);
        root.set_config_path(storage);
        root.set_shared_path(storage);
        root.set_cache_path(storage / "cache" / "");
        root.set_patch_path(storage / "patch" / "");

        fs::create_directories(root.get_vita_fs_path());
        fs::create_directories(root.get_config_path());
        fs::create_directories(root.get_cache_path());
        fs::create_directories(root.get_log_path() / "shaderlog");
        fs::create_directories(root.get_log_path() / "texturelog");
        fs::create_directories(root.get_patch_path());
        fs::create_directories(root.get_shared_path() / "textures");

        if (logging::init(root, true) != Success)
            return false;
        LOG_INFO("{}", window_title);

        g.emuenv = std::make_unique<EmuEnvState>();

        Config cfg{};
        char arg0[] = "vita3k";
        char *argv[] = { arg0, nullptr };
        if (config::init_config(cfg, 1, argv, root) != Success) {
            LOG_ERROR("Failed to initialise config.");
            g.emuenv.reset();
            return false;
        }
        // MoltenVK has no validation layer
        cfg.current_config.validation_layer = false;
        fs::create_directories(cfg.get_vita_fs_path());

        if (!app::init(*g.emuenv, cfg, root)) {
            LOG_ERROR("Failed to initialise emulated environment.");
            g.emuenv.reset();
            return false;
        }

        g.emuenv->vulkan_device_info = std::make_unique<renderer::VulkanDeviceInfo>(renderer::enumerate_vulkan_devices());

        if (g.emuenv->cfg.controller_binds.empty() || g.emuenv->cfg.controller_binds.size() != 15
            || g.emuenv->cfg.controller_axis_binds.empty() || g.emuenv->cfg.controller_axis_binds.size() != 6)
            app::reset_controller_binding(*g.emuenv);

        init_libraries(*g.emuenv);

        if (!app::init_apps_list(*g.emuenv))
            LOG_ERROR("Failed to initialise apps list.");
        app::load_users(*g.emuenv);
        if (!app::ensure_current_user(*g.emuenv)) {
            LOG_ERROR("Failed to initialize active user.");
            return false;
        }
        compat::load_from_disk(g.emuenv->compat, std::filesystem::path(g.emuenv->cache_path.string()));
        g.controller = std::make_unique<app::AppSessionController>(*g.emuenv);
        return true;
    } catch (const std::exception &e) {
        LOG_ERROR("iOS initialisation failed: {}", e.what());
        g.emuenv.reset();
        return false;
    }
}

std::optional<app::AppEntry> find_app(const std::string &title_id) {
    if (!g.emuenv)
        return std::nullopt;
    const auto apps = app::get_apps(*g.emuenv);
    const auto it = std::find_if(apps.begin(), apps.end(), [&](const app::AppEntry &a) { return a.title_id == title_id; });
    if (it == apps.end())
        return std::nullopt;
    return *it;
}

bool remove_if_exists(const fs::path &p) {
    boost::system::error_code ec;
    if (!fs::exists(p, ec))
        return false;
    fs::remove_all(p, ec);
    return !ec;
}

// ---------------------------------------------------------------- session thread
void drain_touch(EmuEnvState &e) {
    std::deque<TouchItem> items;
    {
        std::lock_guard<std::mutex> lock(g.input_mutex);
        items.swap(g.touch_queue);
    }
    for (const auto &it : items) {
        SDL_TouchFingerEvent ev{};
        ev.type = it.phase == 0 ? SDL_EVENT_FINGER_DOWN : (it.phase == 1 ? SDL_EVENT_FINGER_MOTION : SDL_EVENT_FINGER_UP);
        ev.touchID = 1;
        ev.fingerID = static_cast<SDL_FingerID>(it.finger + 1);
        ev.x = it.x;
        ev.y = it.y;
        ev.pressure = it.pressure;
        handle_touch_event(e.touch, ev);
        e.ctrl.overlay_mouse.x.store(it.x * 960.f, std::memory_order_relaxed);
        e.ctrl.overlay_mouse.y.store(it.y * 544.f, std::memory_order_relaxed);
        e.ctrl.overlay_mouse.pressed.store(it.phase != 2, std::memory_order_relaxed);
    }
}

void reset_audio(EmuEnvState &e) {
    if (!e.audio.adapter)
        return;
    e.audio.adapter.reset();
    e.audio.audio_backend.clear();
}

int run_session(std::string title_id) {
    auto &e = *g.emuenv;
    auto &ctl = *g.controller;
    IOSFrameHost host;
    AppLaunchRequest request{ .app_path = title_id };
    int exit_code = 0;
    bool relaunch = false;

    do {
        relaunch = false;
        std::optional<AppLaunchRequest> pending;

        const auto cleanup = [&](app::AppSessionStopReason reason) {
            detach_virtual_controller();
            ctl.stop(reason);
            reset_audio(e);
            SDL_Quit();
        };

        SDL_SetMainReady();
        if (!SDL_Init(SDL_INIT_AUDIO | SDL_INIT_GAMEPAD | SDL_INIT_HAPTIC | SDL_INIT_SENSOR)) {
            LOG_ERROR("SDL_Init failed: {}", SDL_GetError());
            exit_code = -1;
            cleanup(app::AppSessionStopReason::LaunchFailure);
            break;
        }
        attach_virtual_controller();
        refresh_controllers(e.ctrl, e);

        if (!ctl.begin_launch(request, request.reason != AppLaunchReason::LoadExec)) {
            LOG_ERROR("Could not find app '{}'.", request.app_path);
            exit_code = -1;
            cleanup(app::AppSessionStopReason::LaunchFailure);
            break;
        }
        if (!ctl.initialize_renderer(host)) {
            LOG_ERROR("Failed to initialise renderer.");
            exit_code = -1;
            cleanup(app::AppSessionStopReason::LaunchFailure);
            break;
        }
        if (!ctl.initialize_runtime()) {
            LOG_ERROR("Failed late initialisation.");
            exit_code = -1;
            cleanup(app::AppSessionStopReason::LaunchFailure);
            break;
        }
        if (!ctl.load_and_run()) {
            LOG_ERROR("Failed to load or start the app.");
            exit_code = -1;
            cleanup(app::AppSessionStopReason::LaunchFailure);
            break;
        }
        if (auto r = e.take_app_launch_request())
            pending = std::move(r);

        if (g.callbacks.on_started)
            g.callbacks.on_started(e.current_app_title);

        app::LaunchRuntimeMetrics metrics{};
        bool running = !pending.has_value();
        while (running) {
            SDL_Event ev;
            while (SDL_PollEvent(&ev)) {
                switch (ev.type) {
                case SDL_EVENT_QUIT:
                    running = false;
                    break;
                case SDL_EVENT_GAMEPAD_ADDED:
                case SDL_EVENT_GAMEPAD_REMOVED:
                    refresh_controllers(e.ctrl, e);
                    break;
                case SDL_EVENT_GAMEPAD_TOUCHPAD_DOWN:
                case SDL_EVENT_GAMEPAD_TOUCHPAD_MOTION:
                case SDL_EVENT_GAMEPAD_TOUCHPAD_UP:
                    handle_touchpad_event(e.touch, ev.gtouchpad);
                    break;
                case SDL_EVENT_GAMEPAD_SENSOR_UPDATE:
                    handle_motion_event(e, ev.gsensor.sensor, ev.gsensor);
                    break;
                case SDL_EVENT_SENSOR_UPDATE:
                    handle_motion_event(e, SDL_GetSensorTypeForID(ev.sensor.which), ev.sensor);
                    break;
                default:
                    break;
                }
            }
            drain_touch(e);

            if (g.stop_requested.load())
                running = false;
            if (!pending) {
                if (auto r = e.take_app_launch_request()) {
                    pending = std::move(r);
                    running = false;
                }
            }
            app::update_runtime_metrics(e, metrics);
            if (!ctl.is_running())
                running = false;
            if (running)
                SDL_Delay(4); // low latency touch, negligible cost
        }

        if (pending && !g.stop_requested.load()) {
            request = std::move(*pending);
            relaunch = true;
        }
        cleanup(relaunch ? app::AppSessionStopReason::Relaunch : app::AppSessionStopReason::UserRequest);
    } while (relaunch);

    return exit_code;
}

void *session_entry(void *) {
    pthread_setname_np("Vita3K.session");
    const int code = run_session(g.title_id);
    g.thread_alive.store(false);
    if (g.callbacks.on_exited)
        g.callbacks.on_exited(code);
    return nullptr;
}

Config::CurrentConfig &active_config() {
    return g.emuenv->cfg.current_config;
}

void to_settings(const Config::CurrentConfig &c, vita3k_ios::Settings &s) {
    s.cpu_opt = c.cpu_opt;
    s.ngs_enable = c.ngs_enable;
    s.pstv_mode = c.pstv_mode;
    s.audio_volume = c.audio_volume;
    s.resolution_multiplier = c.resolution_multiplier;
    s.v_sync = c.v_sync;
    s.anisotropic_filtering = c.anisotropic_filtering;
    s.async_pipeline_compilation = c.async_pipeline_compilation;
    s.shader_cache = c.shader_cache;
    s.texture_cache = c.texture_cache;
    s.disable_surface_sync = c.disable_surface_sync;
    s.fps_hack = c.fps_hack;
    s.stretch_the_display_area = c.stretch_the_display_area;
    s.fullscreen_hd_res_pixel_perfect = c.fullscreen_hd_res_pixel_perfect;
    s.high_accuracy = c.high_accuracy;
    s.screen_filter = c.screen_filter;
    s.memory_mapping = c.memory_mapping;
    s.sys_lang = c.sys_lang;
}

void from_settings(const vita3k_ios::Settings &s, Config::CurrentConfig &c) {
    c.cpu_opt = s.cpu_opt;
    c.ngs_enable = s.ngs_enable;
    c.pstv_mode = s.pstv_mode;
    c.audio_volume = s.audio_volume;
    c.resolution_multiplier = s.resolution_multiplier;
    c.v_sync = s.v_sync;
    c.anisotropic_filtering = s.anisotropic_filtering;
    c.async_pipeline_compilation = s.async_pipeline_compilation;
    c.shader_cache = s.shader_cache;
    c.texture_cache = s.texture_cache;
    c.disable_surface_sync = s.disable_surface_sync;
    c.fps_hack = s.fps_hack;
    c.stretch_the_display_area = s.stretch_the_display_area;
    c.fullscreen_hd_res_pixel_perfect = s.fullscreen_hd_res_pixel_perfect;
    c.high_accuracy = s.high_accuracy;
    c.screen_filter = s.screen_filter;
    c.memory_mapping = s.memory_mapping;
    c.sys_lang = s.sys_lang;
    c.validation_layer = false;
}

} // namespace

// ---------------------------------------------------------------- ime:: hooks used by SceIme / SceCommonDialog
namespace ime {

void set_sdl_window(SDL_Window *) {
}

void set_keyboard_active(bool) {
    if (g.callbacks.on_ime)
        g.callbacks.on_ime(make_ime_snapshot());
}

void notify_ime_state_changed() {
    if (g.callbacks.on_ime)
        g.callbacks.on_ime(make_ime_snapshot());
}

} // namespace ime

// ---------------------------------------------------------------- public API
namespace vita3k_ios {

bool initialize(const std::string &storage_dir, const std::string &resources_dir) {
    if (g.emuenv)
        return true;
    // Load the bundled MoltenVK by absolute path so the Vulkan loader finds it regardless of rpath rules
    const std::string mvk = (fs::path(resources_dir) / "Frameworks" / "libMoltenVK.dylib").string();
    if (!dlopen(mvk.c_str(), RTLD_NOW | RTLD_GLOBAL))
        fprintf(stderr, "Could not preload MoltenVK from %s: %s\n", mvk.c_str(), dlerror());
    return init_session(fs::path(storage_dir) / "", fs::path(resources_dir) / "");
}

bool is_initialized() {
    return g.emuenv != nullptr;
}

bool has_firmware() {
    return g.emuenv && app::has_firmware_installed(*g.emuenv);
}

void refresh_apps() {
    if (g.emuenv)
        app::scan_apps(*g.emuenv);
}

std::vector<AppInfo> list_apps() {
    std::vector<AppInfo> out;
    if (!g.emuenv)
        return out;
    const auto apps = app::get_apps(*g.emuenv);
    const auto times = app::get_user_app_times(*g.emuenv);
    for (const auto &a : apps) {
        AppInfo info;
        info.title_id = a.title_id;
        info.title = a.title;
        info.category = a.category;
        info.app_ver = a.app_ver;
        const fs::path icon = a.icon_path;
        info.icon_path = a.icon_path.empty() ? std::string()
                                             : (icon.is_absolute() ? icon.generic_string() : (g.emuenv->vita_fs_path / icon).generic_string());
        info.has_custom_config = config::has_custom_config(g.emuenv->config_path, a.path);
        const auto it = times.find(a.path);
        if (it != times.end()) {
            info.last_played = static_cast<int64_t>(it->second.last_time_used);
            info.playtime = it->second.time_used;
        }
        out.push_back(std::move(info));
    }
    return out;
}

bool delete_app(const std::string &title_id) {
    if (!g.emuenv || session_active())
        return false;
    const auto a = find_app(title_id);
    if (!a)
        return false;
    app::delete_app(*g.emuenv, a->path);
    return true;
}

bool delete_shader_cache(const std::string &title_id) {
    return g.emuenv && remove_if_exists(g.emuenv->cache_path / "shaders" / title_id);
}

bool delete_savedata(const std::string &title_id) {
    if (!g.emuenv)
        return false;
    const auto a = find_app(title_id);
    return a && remove_if_exists(g.emuenv->vita_fs_path / "ux0/user" / g.emuenv->io.user_id / "savedata" / a->savedata);
}

std::string install_firmware(const std::string &pup_path, const ProgressFn &progress) {
    if (!g.emuenv)
        return {};
    const std::string version = install_pup(g.emuenv->vita_fs_path, fs::path(pup_path), [&](uint32_t p) {
        if (progress)
            progress(static_cast<int>(p), "Installing firmware...");
    });
    if (!version.empty())
        app::scan_apps(*g.emuenv);
    return version;
}

bool install_pkg(const std::string &path, const std::string &zrif, const ProgressFn &progress) {
    if (!g.emuenv)
        return false;
    std::string z = zrif;
    const bool ok = ::install_pkg(fs::path(path), *g.emuenv, z, [&](float p) {
        if (progress)
            progress(static_cast<int>(p), "Installing package...");
    });
    if (ok)
        app::scan_apps(*g.emuenv);
    return ok;
}

bool install_archive(const std::string &path, const ProgressFn &progress) {
    if (!g.emuenv)
        return false;
    const auto progress_fn = [&](ArchiveContents c) {
        int percent = 0;
        if (c.progress.has_value())
            percent = static_cast<int>(c.progress.value());
        else if (c.count.has_value() && c.current.has_value() && c.count.value() > 0)
            percent = static_cast<int>((static_cast<float>(c.current.value()) / c.count.value()) * 100.0f);
        if (progress)
            progress(percent, "Installing archive...");
    };
    const auto reinstall = [](const std::string &, const std::string &) -> bool { return true; };
    const auto result = ::install_archive(*g.emuenv, fs::path(path), progress_fn, reinstall);
    if (!result.empty())
        app::scan_apps(*g.emuenv);
    return !result.empty();
}

bool install_license(const std::string &rif_path) {
    return g.emuenv && copy_license(*g.emuenv, fs::path(rif_path));
}

std::string find_pkg_zrif(const std::string &pkg_path) {
    if (!g.emuenv)
        return {};
    return ::find_pkg_zrif(fs::path(pkg_path), g.emuenv->vita_fs_path);
}

Settings get_settings(const std::string &title_id) {
    Settings s;
    if (!g.emuenv)
        return s;
    Config::CurrentConfig cc = g.emuenv->cfg.current_config;
    if (!title_id.empty()) {
        const auto a = find_app(title_id);
        const std::string path = a ? a->path : title_id;
        Config::CurrentConfig custom = cc;
        if (config::load_custom_config(custom, g.emuenv->config_path, path))
            cc = custom;
    }
    to_settings(cc, s);
    s.perf_overlay = g.emuenv->cfg.performance_overlay;
    return s;
}

bool save_settings(const std::string &title_id, const Settings &s) {
    if (!g.emuenv)
        return false;
    Config desired;
    desired = g.emuenv->cfg;
    from_settings(s, desired.current_config);
    desired.performance_overlay = s.perf_overlay;
    std::string scope;
    if (!title_id.empty()) {
        const auto a = find_app(title_id);
        scope = a ? a->path : title_id;
    }
    app::commit_settings(*g.emuenv, desired, scope);
    return true;
}

bool start_session(const std::string &title_id, void *metal_layer, int w, int h, const SessionCallbacks &cb) {
    if (!g.emuenv || !g.controller || g.thread_alive.load())
        return false;
    const jit::Status jit_status = jit::probe();
    if (!jit_status.available()) {
        LOG_ERROR("{}", jit_status.description);
        return false;
    }
    g.callbacks = cb;
    g.title_id = title_id;
    g.metal_layer = metal_layer;
    g.surface_w = w;
    g.surface_h = h;
    g.stop_requested = false;

    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setstacksize(&attr, 8 * 1024 * 1024);
    // Emulation threads inherit this QoS: keeps the game on the performance cores
    pthread_attr_set_qos_class_np(&attr, QOS_CLASS_USER_INTERACTIVE, 0);
    g.thread_alive = true;
    const int rc = pthread_create(&g.thread, &attr, session_entry, nullptr);
    pthread_attr_destroy(&attr);
    if (rc != 0) {
        g.thread_alive = false;
        return false;
    }
    pthread_detach(g.thread);
    return true;
}

void stop_session() {
    if (!g.thread_alive.load())
        return;
    g.stop_requested = true;
}

bool session_active() {
    return g.thread_alive.load();
}

bool session_paused() {
    return g.controller && g.controller->is_running() && g.controller->is_paused();
}

void set_paused(bool paused) {
    if (g.controller && g.controller->is_running())
        g.controller->set_pause_reason(app::AppSessionPauseReason::User, paused);
}

void set_background(bool bg) {
    if (g.controller && g.controller->is_running())
        g.controller->set_pause_reason(app::AppSessionPauseReason::Background, bg);
}

void set_surface_size(int w, int h) {
    g.surface_w = w;
    g.surface_h = h;
}

void set_display_rotation(int rotation) {
    if (g.emuenv)
        ::set_display_rotation(g.emuenv->motion, rotation);
}

void set_rear_touch(bool rear) {
    if (g.emuenv)
        set_rear_touchscreen(g.emuenv->touch, rear);
}

void touch_event(int phase, int64_t finger_id, float nx, float ny, float pressure) {
    std::lock_guard<std::mutex> lock(g.input_mutex);
    g.touch_queue.push_back({ phase, finger_id, nx, ny, pressure });
}

void set_button(int button, bool pressed) {
    std::lock_guard<std::mutex> lock(g.input_mutex);
    if (g.vjoy)
        SDL_SetJoystickVirtualButton(g.vjoy, button, pressed);
}

void set_trigger(int axis, bool pressed) {
    set_axis(axis, pressed ? SDL_MAX_SINT16 : 0);
}

void set_axis(int axis, int16_t value) {
    std::lock_guard<std::mutex> lock(g.input_mutex);
    if (g.vjoy)
        SDL_SetJoystickVirtualAxis(g.vjoy, axis, value);
}

bool ime_active() {
    return g.emuenv && g.controller && g.controller->is_running() && any_ime_active(*g.emuenv);
}

void ime_text_input(const std::string &utf8) {
    if (!ime_active())
        return;
    std::string filtered;
    for (char c : utf8)
        if (c != '\n' && c != '\r')
            filtered.push_back(c);
    if (filtered.empty())
        return;
    {
        std::lock_guard<std::mutex> lock(g.emuenv->ime.mutex);
        ime_commit_text(g.emuenv->ime, string_utils::utf8_to_utf16(filtered));
    }
    ime::notify_ime_state_changed();
}

void ime_backspace() {
    if (!ime_active())
        return;
    {
        std::lock_guard<std::mutex> lock(g.emuenv->ime.mutex);
        ::ime_backspace(g.emuenv->ime);
    }
    ime::notify_ime_state_changed();
}

void ime_submit() {
    if (!ime_active())
        return;
    if (ime_dialog_active(*g.emuenv)) {
        finish_ime_dialog(*g.emuenv);
    } else {
        std::lock_guard<std::mutex> lock(g.emuenv->ime.mutex);
        g.emuenv->ime.event_id = SCE_IME_EVENT_PRESS_ENTER;
    }
    ime::notify_ime_state_changed();
}

void ime_dismiss() {
    if (!ime_active())
        return;
    if (ime_dialog_active(*g.emuenv)) {
        cancel_ime_dialog(*g.emuenv);
    } else {
        std::lock_guard<std::mutex> lock(g.emuenv->ime.mutex);
        g.emuenv->ime.event_id = SCE_IME_EVENT_PRESS_CLOSE;
    }
    ime::notify_ime_state_changed();
}

std::string version_string() {
    return std::string(app_version) + "-" + std::to_string(app_number) + "-" + app_hash;
}

std::string log_path() {
    return g.emuenv ? g.emuenv->log_path.string() : std::string();
}

} // namespace vita3k_ios
