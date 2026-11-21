// Vita3K iOS port - C++ bridge between the UIKit app and the emulator core.
#pragma once

#include <cstdint>
#include <functional>
#include <string>
#include <vector>

namespace vita3k_ios {

struct AppInfo {
    std::string title_id, title, category, app_ver, icon_path;
    bool has_custom_config = false;
    int64_t last_played = 0;
    int64_t playtime = 0;
};

struct Settings {
    bool cpu_opt = true;
    bool ngs_enable = true;
    bool pstv_mode = false;
    int audio_volume = 100;
    float resolution_multiplier = 1.0f;
    bool v_sync = true;
    int anisotropic_filtering = 1;
    bool async_pipeline_compilation = true;
    bool shader_cache = true;
    bool texture_cache = true;
    bool disable_surface_sync = false;
    bool fps_hack = false;
    bool stretch_the_display_area = false;
    bool fullscreen_hd_res_pixel_perfect = false;
    bool high_accuracy = false;
    std::string screen_filter = "Bilinear";
    std::string memory_mapping = "double-buffer";
    int sys_lang = 1;
    bool perf_overlay = false;
};

struct ImeSnapshot {
    bool active = false;
    bool dialog = false;
    bool multiline = false;
    std::string text;
    std::string enter_label;
};

using ProgressFn = std::function<void(int percent, const char *status)>;

struct SessionCallbacks {
    std::function<void(const std::string &title)> on_started;
    std::function<void(int exit_code)> on_exited;    // called on the session thread
    std::function<void(const ImeSnapshot &)> on_ime; // called on the session / game threads
};

// ---- lifecycle
bool initialize(const std::string &storage_dir, const std::string &resources_dir);
bool is_initialized();
bool has_firmware();

// ---- library
void refresh_apps();
std::vector<AppInfo> list_apps();
bool delete_app(const std::string &title_id);
bool delete_shader_cache(const std::string &title_id);
bool delete_savedata(const std::string &title_id);

// ---- install
std::string install_firmware(const std::string &pup_path, const ProgressFn &progress);
bool install_pkg(const std::string &path, const std::string &zrif, const ProgressFn &progress);
bool install_archive(const std::string &path, const ProgressFn &progress);
bool install_license(const std::string &rif_path);
std::string find_pkg_zrif(const std::string &pkg_path);

// ---- settings (title_id empty = global)
Settings get_settings(const std::string &title_id);
bool save_settings(const std::string &title_id, const Settings &settings);

// ---- session
bool start_session(const std::string &title_id, void *metal_layer, int pixel_w, int pixel_h, const SessionCallbacks &cb);
void stop_session();
bool session_active();
bool session_paused();
void set_paused(bool paused);   // user pause
void set_background(bool bg);   // app lifecycle pause
void set_surface_size(int pixel_w, int pixel_h);
void set_display_rotation(int rotation); // 0,1,2,3 = DeviceRotation
void set_rear_touch(bool rear);

// ---- input (thread-safe, may be called from the main thread)
void touch_event(int phase /*0 down,1 move,2 up*/, int64_t finger_id, float nx, float ny, float pressure);
void set_button(int sdl_gamepad_button, bool pressed);
void set_trigger(int sdl_gamepad_axis, bool pressed);
void set_axis(int sdl_gamepad_axis, int16_t value);

// ---- IME
bool ime_active();
void ime_text_input(const std::string &utf8);
void ime_backspace();
void ime_submit();
void ime_dismiss();

// ---- misc
std::string version_string();
std::string log_path();

} // namespace vita3k_ios
