# ZSandbox — Production-Grade WASM Sandbox for Zig

[![Zig](https://img.shields.io/badge/Zig-0.17%20(dev)-orange.svg)](https://ziglang.org)
[![Tests](https://img.shields.io/badge/tests-15%2F15%20passing-brightgreen.svg)]()
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

> A secure, gas-metered, multi-tenant WebAssembly sandbox kernel for **plugins**, **smart contracts**, and **user-uploaded code execution** — all on a single runtime.

---

## Table of Contents

- [Overview](#overview)
- [Features](#features)
- [Architecture](#architecture)
- [Security Model](#security-model)
- [Quick Start](#quick-start)
- [Usage Examples](#usage-examples)
- [Host Exports Reference](#host-exports-reference)
- [Gas Pricing](#gas-pricing)
- [Project Structure](#project-structure)
- [Contributing](#contributing)
- [License](#license)

---

## Overview

**ZSandbox** is a production-grade WebAssembly (WASM) sandbox built in Zig. It leverages [Wasmtime](https://wasmtime.dev/) (via its C API) as the execution engine and adds a comprehensive security, metering, and extension layer on top.

Three distinct usage scenarios are supported simultaneously:

| Scenario | Description |
|----------|-------------|
| **Plugin System** | Load/unload/reload sandboxed plugins with call statistics and fuel tracking. |
| **Smart Contracts** | Deploy contracts with persistent storage (in-memory or LMDB), cross-contract calls, event logs, and gas metering. |
| **User Code Execution** | Run untrusted user code with I/O pipelines, wall-clock timeouts, and resource limits. |

All three share the **same sandbox kernel** — a single `Sandbox` struct that encapsulates engine, store, module, linker, instance, gas metering, and memory safety.

---

## Features

### Security
- **Memory bounds checking** — All host callbacks validate guest memory pointers before read/write.
- **Gas exhaustion traps** — Host callback gas exhaustion immediately terminates guest execution via `wasm_trap_t`, never returns an error code.
- **Runtime argument validation** — Replaces `assert()` (stripped in release builds) with runtime checks that return traps on signature mismatch.
- **Global reentrancy / cycle detection** — Prevents A→B→A circular cross-contract calls.
- **Call depth limiting** — Max 16 frames; reentrancy detected across the global call stack.
- **WASM module validation** — Magic/version checks, import/export whitelisting, required-export verification.
- **Memory growth limits** — `wasmtime_store_limiter` caps linear memory at ~1.06 MiB.

### Metering
- **Instruction-level fuel** — Wasmtime native fuel consumption tracking.
- **Host-call gas** — EVM-inspired pricing for SLOAD, SSTORE, CALL, LOG, keccak256, sha256.
- **Cross-contract gas sharing** — Caller caps callee's gas budget to its remaining gas.

### Persistence
- **Dual state backends** — In-memory (`HashMap`) for testing, LMDB for production.
- **Transaction semantics** — `beginTx` / `commit` / `rollback` with atomic LMDB transactions.

### Performance
- **Module compilation cache** — Share a single `wasm_engine_t` and cache compiled `wasmtime_module_t` keyed by SHA-256 hash.
- **Concurrency-safe registries** — `PluginRegistry` and `ContractRegistry` protected by `std.atomic.Mutex`.

### Cryptographic Precompiles
- **keccak256** — 30 + 6×word gas (EVM-compatible)
- **sha256** — 60 + 12×word gas (EVM-compatible)

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        Host (Zig)                           │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐  │
│  │ Plugin      │  │ Contract    │  │ User Code Execution │  │
│  │ Registry    │  │ Registry    │  │ (I/O + Watchdog)    │  │
│  └──────┬──────┘  └──────┬──────┘  └──────────┬──────────┘  │
│         │                │                    │             │
│         └────────────────┴────────────────────┘             │
│                          │                                  │
│                    ┌─────┴─────┐                            │
│                    │  Sandbox  │ ← Gas Meter, Fuel Meter    │
│                    │  (Kernel) │   Call Stack, HostEnv      │
│                    └─────┬─────┘                            │
│                          │                                  │
│         ┌────────────────┼────────────────┐                │
│         ▼                ▼                ▼                │
│  ┌────────────┐  ┌────────────┐  ┌────────────────────┐   │
│  │ StateStore │  │ EventLog   │  │ ModuleCache        │   │
│  │ (Memory /  │  │            │  │ (Shared Engine +   │   │
│  │  LMDB)     │  │            │  │  Compiled Modules) │   │
│  └────────────┘  └────────────┘  └────────────────────┘   │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │              Wasmtime C API (Engine)                │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
                               │
                               ▼
                    ┌─────────────────────┐
                    │  Guest WASM Module  │
                    │  (Plugin / Contract)│
                    └─────────────────────┘
```

---

## Security Model

ZSandbox treats **all guest code as hostile**. The following defenses are enforced:

| Layer | Defense |
|-------|---------|
| **Module** | Size limit (2 MiB), magic/version validation, import/export whitelist, required-export check. |
| **Memory** | All host callbacks validate `ptr + len <= memory_size` before access. `wasmtime_store_limiter` prevents unbounded `memory.grow`. |
| **Execution** | Fuel + gas dual metering. Gas exhaustion returns `wasm_trap_t` (guest cannot continue). |
| **Reentrancy** | Per-sandbox depth limit (8) + global call-stack cycle detection. |
| **Host Callbacks** | Runtime argument-count/type validation (not `assert`). |
| **State** | LMDB transactions are atomic; `beginTx` / `rollback` on failure. |

---

## Quick Start

### Prerequisites

- **Zig** 0.17.0-dev (master)
- **Wasmtime** 33.0.0+ (C library)
- **LMDB** 0.9.33+ (for persistent state)

macOS (Homebrew):
```bash
brew install wasmtime lmdb
```

### Build

```bash
zig build
```

This compiles:
- 5 guest WASM modules (`sandbox`, `contract_counter`, `contract_composite`, `contract_crypto`, `contract_token`)
- 1 host executable (`host`)

### Run Demo

```bash
zig build run
```

### Run Tests

```bash
zig test src/tests.zig -lwasmtime -I/opt/homebrew/opt/lmdb/include \
  -L/opt/homebrew/opt/lmdb/lib -llmdb -I/opt/homebrew/include -L/opt/homebrew/lib
```

Or via the build system:
```bash
zig build test
```

---

## Usage Examples

### 1. Plugin System

```zig
const allocator = std.heap.page_allocator;

var registry = PluginRegistry.init(allocator);
defer registry.deinit();

// Load a plugin from WASM bytes
try registry.load("math", "1.0.0", wasm_bytes);

// Call a plugin function
const result = try registry.call("math", "sandbox_add", &[_]i32{ 10, 20 });
// result == 30

// List all plugins
const infos = try registry.list(allocator);
for (infos) |info| {
    std.log.info("{s} v{s} | calls={d}", .{ info.name, info.version, info.call_count });
}
```

### 2. Smart Contract

```zig
var reg = ContractRegistry.init(allocator);
defer reg.deinit();
contract_registry.g_registry = &reg; // for host callbacks

// Deploy contracts
try reg.deploy("math", math_wasm, &math_imports, &math_exports, &math_required);
try reg.deploy("composite", composite_wasm, &comp_imports, &comp_exports, &comp_required);

// Direct call
const r = try reg.call("math", "math", "sandbox_add", &[_]i32{ 3, 4 });

// Cross-contract call (composite calls math internally)
const cross = try reg.call("composite", "composite", "add_via_math", &[_]i32{ 10, 20 });
// cross == 30
```

### 3. User Code Execution

```zig
var sb = try Sandbox.init(allocator, wasm_bytes, &imports, &exports, &required);
defer sb.deinit();

var io_pipe = try IoPipeline.init(allocator, .{});
defer io_pipe.deinit();
sb.attachIo(&io_pipe);

var wd = Watchdog.init(5000); // 5 second timeout
sb.attachWatchdog(&wd);

// Execute with input/output
const output = try sb.callWithInput("process", "hello world");
```

### 4. Module Cache

```zig
var mod_cache = try ModuleCache.init(allocator);
defer mod_cache.deinit();

// First sandbox: compiles and caches
var sb1 = try Sandbox.initWithCache(allocator, wasm_bytes, &imports, &exports, &required, &mod_cache);

// Second sandbox: reuses compiled module
var sb2 = try Sandbox.initWithCache(allocator, wasm_bytes, &imports, &exports, &required, &mod_cache);
```

### 5. Cryptographic Precompiles

Guest code imports `env.keccak256` and `env.sha256`:

```zig
extern fn keccak256(data_ptr: i32, data_len: i32, out_ptr: i32) void;
extern fn sha256(data_ptr: i32, data_len: i32, out_ptr: i32) void;

export fn hash_both(data_ptr: i32, data_len: i32, keccak_out: i32, sha_out: i32) i32 {
    keccak256(data_ptr, data_len, keccak_out);
    sha256(data_ptr, data_len, sha_out);
    return 0;
}
```

Host-side: write data, call, read 32-byte hashes back:

```zig
try sb.writeToGuestMemory(1024, "hello");
_ = try sb.call("hash_both", &[_]i32{ 1024, 5, 2048, 2080 });
// keccak256("hello") at 2048, sha256("hello") at 2080
```

---

## Host Exports Reference

All host functions are exposed under the `env` module.

| Function | Signature | Gas | Description |
|----------|-----------|-----|-------------|
| `host_log` | `(ptr: i32, len: i32) -> void` | 0 | Log a message from guest to host. |
| `storage_read` | `(key_ptr, key_len, val_ptr, val_max) -> i32` | 200 (SLOAD) | Read value from contract state. Returns bytes written or 0/−1/−2. |
| `storage_write` | `(key_ptr, key_len, val_ptr, val_len) -> void` | 20,000/5,000 (SSTORE) | Write value to contract state. |
| `call_contract` | `(addr_ptr, addr_len, func_ptr, func_len, arg0, arg1) -> i32` | 700 (CALL) | Cross-contract call. Returns callee result. |
| `host_log_event` | `(name_ptr, name_len, data_ptr, data_len) -> void` | 375 (LOG) | Emit structured event. |
| `keccak256` | `(data_ptr, data_len, out_ptr) -> void` | 30 + 6×word | Compute Keccak-256 hash (32 bytes to out_ptr). |
| `sha256` | `(data_ptr, data_len, out_ptr) -> void` | 60 + 12×word | Compute SHA-256 hash (32 bytes to out_ptr). |

---

## Gas Pricing

Inspired by Ethereum EVM, adapted for WASM host calls.

| Operation | Gas Cost |
|-----------|----------|
| SLOAD (storage read) | 200 |
| SSTORE (new key) | 20,000 |
| SSTORE (modify existing) | 5,000 |
| CALL (cross-contract) | 700 |
| LOG (per topic) | 375 |
| keccak256 | 30 + 6 × ⌈data_len / 32⌉ |
| sha256 | 60 + 12 × ⌈data_len / 32⌉ |
| Memory page (64 KiB) | 6,400 |

Compute gas is approximated 1:1 with Wasmtime fuel. Total gas = fuel_consumed + host_gas_consumed.

---

## Project Structure

```
.
├── build.zig                    # Build configuration
├── sandbox.zig                  # Guest: basic sandbox (add, panic)
├── contract_counter.zig         # Guest: counter with storage + events
├── contract_composite.zig       # Guest: cross-contract caller
├── contract_crypto.zig          # Guest: keccak256/sha256 demo
├── contract_token.zig           # Guest: ERC-20 style token
│
├── src/
│   ├── main.zig                 # Host entry point / demo
│   ├── tests.zig                # Integration tests (15 tests)
│   │
│   ├── sandbox.zig              # Core sandbox manager
│   ├── sandbox_bindings.zig     # Wasmtime C API declarations
│   ├── sandbox_memory.zig       # Guest memory read helpers
│   ├── wasm_validator.zig       # Module validation
│   │
│   ├── fuel_meter.zig           # Instruction-level fuel tracking
│   ├── gas_meter.zig            # Host-call gas metering
│   ├── limits.zig               # Resource limits & config
│   │
│   ├── host_exports.zig         # Host callbacks exposed to guest
│   │
│   ├── extensions/
│   │   ├── plugin_registry.zig  # Plugin load/unload/call/reload
│   │   ├── contract_registry.zig # Contract deploy + cross-call dispatch
│   │   ├── state_store.zig      # Memory / LMDB state backends
│   │   ├── event_log.zig        # Structured event buffer
│   │   ├── io_pipeline.zig      # I/O buffers + Watchdog
│   │   └── module_cache.zig     # Compiled module cache
│   │
│   └── lmdb_bindings.zig        # LMDB C API declarations
│
└── README.md                    # This file
```

---

## Contributing

Contributions are welcome! Please:

1. Ensure `zig build` and all tests pass.
2. Follow existing Zig style (camelCase for functions, TitleCase for types).
3. Add tests for new features.
4. Update this README for user-visible changes.

Report security issues privately.

---

## License

MIT License — see [LICENSE](LICENSE) for details.

---

## Acknowledgments

- [Wasmtime](https://wasmtime.dev/) by Bytecode Alliance — the WASM engine
- [Zig](https://ziglang.org/) — the language
- Ethereum EVM — gas pricing inspiration
