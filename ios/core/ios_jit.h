// Vita3K iOS port
// JIT capability detection for iOS (TrollStore / entitlement / debugger based).
#pragma once

#include <cstdint>
#include <string>

namespace vita3k_ios::jit {

enum class Strategy {
    None,        // no executable writable memory can be obtained: dynarmic cannot run
    MapJitRWX,   // MAP_JIT + dynamic-codesigning entitlement (TrollStore signed build)
    PlainRWX,    // plain RWX anonymous mapping (CS_DEBUGGED set: debugger / JIT enabler attached)
};

struct Status {
    Strategy strategy = Strategy::None;
    bool cs_debugged = false;
    bool entitled_dynamic_codesigning_guess = false;
    uint32_t cs_flags = 0;
    std::string description;

    bool available() const {
        return strategy != Strategy::None;
    }
};

// Maps a small RWX page, writes a `ret`, flushes the icache and calls it.
// Never crashes: if the kernel refuses the mapping the strategy is None.
Status probe();

// Waits (polling probe()) until JIT becomes available or the timeout elapses.
// Used after asking TrollStore / StikDebug / JitStreamer to enable JIT for this process.
Status wait_for_jit(int timeout_ms);

// "apple-magnifier://enable-jit?bundle-id=<id>" (the TrollStore JIT enabler URL scheme)
std::string trollstore_enable_url(const std::string &bundle_id);

} // namespace vita3k_ios::jit
