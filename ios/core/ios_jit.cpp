// Vita3K iOS port
#include "ios_jit.h"

#include <libkern/OSCacheControl.h>
#include <sys/mman.h>
#include <unistd.h>

#include <chrono>
#include <cstring>
#include <thread>

extern "C" int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);

namespace vita3k_ios::jit {

namespace {

constexpr unsigned int CS_OPS_STATUS = 0;
constexpr uint32_t CS_DEBUGGED = 0x10000000;
constexpr uint32_t CS_JIT_ALLOW_FLAGS = 0x0; // reserved for future flags

// mov w0, #0x1234 ; ret
constexpr uint32_t k_probe_code[] = { 0x52824680u, 0xd65f03c0u };
constexpr int k_probe_result = 0x1234;

bool run_probe_on(void *mem) {
    std::memcpy(mem, k_probe_code, sizeof(k_probe_code));
    sys_icache_invalidate(mem, sizeof(k_probe_code));
    auto fn = reinterpret_cast<int (*)()>(mem);
    return fn() == k_probe_result;
}

bool try_map(int extra_flags) {
    const size_t size = static_cast<size_t>(getpagesize());
    void *mem = mmap(nullptr, size, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_ANON | MAP_PRIVATE | extra_flags, -1, 0);
    if (mem == MAP_FAILED)
        return false;
    const bool ok = run_probe_on(mem);
    munmap(mem, size);
    return ok;
}

} // namespace

Status probe() {
    Status status;

    uint32_t flags = 0;
    if (csops(getpid(), CS_OPS_STATUS, &flags, sizeof(flags)) == 0) {
        status.cs_flags = flags;
        status.cs_debugged = (flags & CS_DEBUGGED) != 0;
    }
    (void)CS_JIT_ALLOW_FLAGS;

    if (try_map(MAP_JIT)) {
        status.strategy = Strategy::MapJitRWX;
        status.entitled_dynamic_codesigning_guess = true;
        status.description = "JIT ready (MAP_JIT, dynamic-codesigning entitlement)";
    } else if (try_map(0)) {
        status.strategy = Strategy::PlainRWX;
        status.description = status.cs_debugged
            ? "JIT ready (RWX mapping, CS_DEBUGGED is set)"
            : "JIT ready (RWX mapping)";
    } else {
        status.strategy = Strategy::None;
        status.description = status.cs_debugged
            ? "JIT unavailable: CS_DEBUGGED is set but RWX mapping is still refused"
            : "JIT unavailable: enable JIT for this app (TrollStore build already has the entitlement)";
    }
    return status;
}

Status wait_for_jit(int timeout_ms) {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout_ms);
    Status status = probe();
    while (!status.available() && std::chrono::steady_clock::now() < deadline) {
        std::this_thread::sleep_for(std::chrono::milliseconds(250));
        status = probe();
    }
    return status;
}

std::string trollstore_enable_url(const std::string &bundle_id) {
    return "apple-magnifier://enable-jit?bundle-id=" + bundle_id;
}

} // namespace vita3k_ios::jit
