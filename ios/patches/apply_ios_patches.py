#!/usr/bin/env python3
"""Patches third-party sources (git submodules) for the iOS build.

Run from the repository root before configuring:  python3 ios/patches/apply_ios_patches.py
The script is idempotent and fails loudly if an upstream file changed in a way
that makes a replacement impossible, so a silent mis-patch can never ship.
"""
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]


def replace_once(text: str, old: str, new: str, what: str) -> str:
    if new in text:
        return text  # already applied
    if text.count(old) != 1:
        sys.exit(f"error: cannot apply patch '{what}': expected exactly one match, found {text.count(old)}")
    return text.replace(old, new)


def patch_oaknut_code_block() -> None:
    path = ROOT / "external/dynarmic/externals/oaknut/include/oaknut/code_block.hpp"
    if not path.exists():
        sys.exit(f"error: {path} not found (submodules not checked out?)")
    s = path.read_text()

    # 1) iOS allocation strategy: persistent RWX (MAP_JIT -> plain RWX -> RX + mprotect toggling)
    s = replace_once(
        s,
        "#    if TARGET_OS_IPHONE\n"
        "        m_memory = (std::uint32_t*)mmap(nullptr, size, PROT_READ | PROT_EXEC, MAP_ANON | MAP_PRIVATE, -1, 0);\n",
        "#    if TARGET_OS_IPHONE\n"
        "        // iOS: a persistent RWX mapping means emitting code never needs an mprotect round trip\n"
        "        // (each one is a syscall plus a TLB/pmap change). MAP_JIT works with the\n"
        "        // dynamic-codesigning entitlement, plain RWX works once CS_DEBUGGED is set.\n"
        "        m_memory = (std::uint32_t*)mmap(nullptr, size, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_ANON | MAP_PRIVATE | MAP_JIT, -1, 0);\n"
        "        if (m_memory == (std::uint32_t*)MAP_FAILED)\n"
        "            m_memory = (std::uint32_t*)mmap(nullptr, size, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_ANON | MAP_PRIVATE, -1, 0);\n"
        "        if (m_memory == (std::uint32_t*)MAP_FAILED) {\n"
        "            m_memory = (std::uint32_t*)mmap(nullptr, size, PROT_READ | PROT_EXEC, MAP_ANON | MAP_PRIVATE, -1, 0);\n"
        "            m_toggle_protection = true;\n"
        "        }\n",
        "iOS CodeBlock allocation",
    )

    # 2) mmap reports failure with MAP_FAILED, not nullptr
    s = replace_once(
        s,
        "        if (m_memory == nullptr)\n            throw std::bad_alloc{};\n",
        "#if !defined(_WIN32)\n"
        "        if (m_memory == (std::uint32_t*)MAP_FAILED)\n"
        "            m_memory = nullptr;\n"
        "#endif\n"
        "        if (m_memory == nullptr)\n            throw std::bad_alloc{};\n",
        "MAP_FAILED check",
    )

    # 3) only toggle protections when the RWX mapping was not available
    s = replace_once(
        s,
        "#elif defined(__APPLE__) || defined(__NetBSD__) || defined(__OpenBSD__)\n"
        "        mprotect(m_memory, m_size, PROT_READ | PROT_EXEC);\n",
        "#elif defined(__APPLE__)\n"
        "        if (m_toggle_protection)\n"
        "            mprotect(m_memory, m_size, PROT_READ | PROT_EXEC);\n"
        "#elif defined(__NetBSD__) || defined(__OpenBSD__)\n"
        "        mprotect(m_memory, m_size, PROT_READ | PROT_EXEC);\n",
        "protect()",
    )
    s = replace_once(
        s,
        "#elif defined(__APPLE__) || defined(__NetBSD__) || defined(__OpenBSD__)\n"
        "        mprotect(m_memory, m_size, PROT_READ | PROT_WRITE);\n",
        "#elif defined(__APPLE__)\n"
        "        if (m_toggle_protection)\n"
        "            mprotect(m_memory, m_size, PROT_READ | PROT_WRITE);\n"
        "#elif defined(__NetBSD__) || defined(__OpenBSD__)\n"
        "        mprotect(m_memory, m_size, PROT_READ | PROT_WRITE);\n",
        "unprotect()",
    )

    # 4) member
    s = replace_once(
        s,
        "    std::uint32_t* m_memory;\n    std::size_t m_size = 0;\n",
        "    std::uint32_t* m_memory;\n    std::size_t m_size = 0;\n    bool m_toggle_protection = false;\n",
        "m_toggle_protection member",
    )
    path.write_text(s)
    print(f"patched {path.relative_to(ROOT)}")


if __name__ == "__main__":
    patch_oaknut_code_block()
