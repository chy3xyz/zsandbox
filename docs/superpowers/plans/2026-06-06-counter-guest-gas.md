# Counter Guest Contract with Per-Op Gas Logging — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create a new WASM guest contract (`contract_counter.zig`) that imports `env.storage_read/write` and `env.host_log`, exports `increment() → i32`, and demonstrates real per-operation gas consumption.

**Architecture:** A standalone WASM guest compiled alongside the existing `sandbox.zig` guest. The host loads it into a Sandbox, attaches a memory-backed StateStore, and calls `increment()`. Host storage callbacks log gas before/after each SLOAD/SSTORE charge.

**Tech Stack:** Zig 0.17, wasmtime C API, custom hand-written WASM imports/exports

---

## File Map

| File | Action | Responsibility |
|------|--------|---------------|
| `contract_counter.zig` | Create | New guest contract: imports storage_read/write/host_log, exports increment() |
| `build.zig` | Modify | Add second WASM target for contract_counter |
| `src/host_exports.zig` | Modify | Add gas before/after logging in storage callbacks |
| `src/main.zig` | Modify | Replace Scene 2a with counter demo |
| `src/tests.zig` | Modify | Add counter gas consumption test |

---

### Task 1: Create contract_counter.zig guest contract

**Files:**
- Create: `contract_counter.zig`

The guest runs in a WASM32 freestanding environment. It needs to declare imports from `env` and export `increment()`.

```zig
// contract_counter.zig
// Guest contract demonstrating storage operations with gas metering.

const std = @import("std");

// Host imports from env module
extern fn host_log(ptr: [*]const u8, len: usize) void;
extern fn storage_read(key_ptr: [*]const u8, key_len: usize, val_ptr: [*]u8, val_max: usize) i32;
extern fn storage_write(key_ptr: [*]const u8, key_len: usize, val_ptr: [*]const u8, val_len: usize) void;

fn log(msg: []const u8) void {
    host_log(msg.ptr, msg.len);
}

fn readCounter() i32 {
    const key = "counter";
    var buf: [32]u8 = undefined;
    const n = storage_read(key.ptr, key.len, &buf, buf.len);
    if (n <= 0) return 0;
    // Parse ASCII integer from buf[0..n]
    var val: i32 = 0;
    var i: usize = 0;
    while (i < @as(usize, @intCast(n))) : (i += 1) {
        const c = buf[i];
        if (c < '0' or c > '9') break;
        val = val * 10 + (c - '0');
    }
    return val;
}

fn writeCounter(val: i32) void {
    const key = "counter";
    var buf: [32]u8 = undefined;
    // Format integer as ASCII
    var i: usize = 31;
    var v = val;
    if (v == 0) {
        buf[i] = '0';
        i -= 1;
    } else {
        while (v > 0) : (v /= 10) {
            buf[i] = @intCast('0' + @mod(v, 10));
            i -= 1;
        }
    }
    const start = i + 1;
    const len = 32 - start;
    storage_write(key.ptr, key.len, buf[start..].ptr, len);
}

export fn increment() i32 {
    const old_val = readCounter();
    const new_val = old_val + 1;
    writeCounter(new_val);

    // Log the increment
    var msg_buf: [64]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "counter: {d} -> {d}", .{ old_val, new_val }) catch &msg_buf;
    log(msg);

    return new_val;
}
```

- [ ] **Step 1: Write contract_counter.zig** — Create the file with the code above.
- [ ] **Step 2: Verify it compiles as a standalone Zig file** — `zig fmt contract_counter.zig`

---

### Task 2: Add contract_counter to build.zig

**Files:**
- Modify: `build.zig`

Add a second WASM target for `contract_counter.zig`, identical configuration to the existing `sandbox` target.

```zig
    // ================================================================
    // 1b. Counter Contract (guest)
    // ================================================================
    const counter_mod = b.createModule(.{
        .root_source_file = b.path("contract_counter.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });

    const counter_lib = b.addExecutable(.{
        .name = "contract_counter",
        .root_module = counter_mod,
    });
    counter_lib.entry = .disabled;
    counter_lib.rdynamic = true;
    counter_lib.initial_memory = limits.max_memory_bytes;
    counter_lib.max_memory = limits.max_memory_bytes;
    b.installArtifact(counter_lib);
```

- [ ] **Step 1: Insert the counter WASM target into build.zig** — Place after the existing `sandbox` target (around line 27).
- [ ] **Step 2: Build both WASM targets** — `zig build`
- [ ] **Step 3: Verify both WASM files exist** — `ls zig-out/bin/` should show `sandbox.wasm` and `contract_counter.wasm`

---

### Task 3: Add gas logging to host storage callbacks

**Files:**
- Modify: `src/host_exports.zig`

In `hostStorageReadCallback`, add gas before/after logging:

```zig
pub fn hostStorageReadCallback(
    env: ?*anyopaque,
    caller: ?*c.wasmtime_caller_t,
    args: [*c]const c.wasmtime_val_t,
    nargs: usize,
    results: [*c]c.wasmtime_val_t,
    nresults: usize,
) callconv(.c) ?*c.wasm_trap_t {
    // ... existing code up to getting sb ...

    const sb = he.sandbox orelse {
        results[0] = .{ .kind = c.WASM_I32, .of = .{ .i32 = -1 } };
        return null;
    };

    // ADD: log gas before SLOAD
    const gas_before = sb.gas_meter.remaining();
    log.info("[SLOAD] gas_before={d}", .{gas_before});

    // Charge gas for SLOAD
    sb.gas_meter.chargeSload() catch {
        log.info("[SLOAD] OUT OF GAS", .{});
        results[0] = .{ .kind = c.WASM_I32, .of = .{ .i32 = -2 } };
        return null;
    };

    // ... rest of existing read logic ...

    // ADD: log gas after SLOAD
    const gas_after = sb.gas_meter.remaining();
    log.info("[SLOAD] gas_after={d}  consumed={d}", .{ gas_after, gas_before - gas_after });

    results[0] = .{ .kind = c.WASM_I32, .of = .{ .i32 = @intCast(out_len) } };
    return null;
}
```

In `hostStorageWriteCallback`, add similar logging around `chargeSstore`:

```zig
    // ADD: log gas before SSTORE
    const gas_before = sb.gas_meter.remaining();
    log.info("[SSTORE] gas_before={d}  is_new={any}", .{ gas_before, is_new });

    // Charge gas for SSTORE
    sb.gas_meter.chargeSstore(is_new) catch {
        log.info("[SSTORE] OUT OF GAS", .{});
        return null;
    };

    state.set(key, value) catch return null;

    // ADD: log gas after SSTORE
    const gas_after = sb.gas_meter.remaining();
    log.info("[SSTORE] gas_after={d}  consumed={d}", .{ gas_after, gas_before - gas_after });
```

- [ ] **Step 1: Add gas_before/gas_after logging to hostStorageReadCallback**
- [ ] **Step 2: Add gas_before/gas_after logging to hostStorageWriteCallback**
- [ ] **Step 3: Build** — `zig build`

---

### Task 4: Update main.zig Scene 2a with counter demo

**Files:**
- Modify: `src/main.zig`

Replace Scene 2a (memory state + gas) to load `contract_counter.wasm` and call `increment()` twice.

```zig
    // ================================================================
    // SCENE 2a: Smart Contract (Counter with Gas Logging)
    // ================================================================
    log.info("", .{});
    log.info("=== SCENE 2a: Smart Contract (Counter + Gas) ===", .{});

    const counter_wasm = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "zig-out/bin/contract_counter.wasm",
        alloc,
        .limited(limits.max_module_bytes),
    );
    defer alloc.free(counter_wasm);

    const counter_imports = [_][]const u8{"env.host_log", "env.storage_read", "env.storage_write"};
    const counter_exports = [_][]const u8{"increment"};
    const counter_required = [_][]const u8{"increment"};

    var counter = try sandbox.Sandbox.init(
        alloc,
        counter_wasm,
        &counter_imports,
        &counter_exports,
        &counter_required,
    );
    defer counter.deinit();
    counter.setAddress("0xCOUNTER");

    var counter_state = try StateStore.initMemory(alloc, .{});
    defer counter_state.deinit();
    counter.attachState(&counter_state);

    log.info("Initial gas: {d}", .{counter.remainingGas()});

    // First increment: SLOAD (key missing → 0) + SSTORE (new key → 20,000)
    const r1 = try counter.call("increment", &[_]i32{});
    log.info("increment() #1 = {d}, gas_remaining={d}", .{ r1, counter.remainingGas() });

    // Second increment: SLOAD (reads 1) + SSTORE (modify → 5,000)
    const r2 = try counter.call("increment", &[_]i32{});
    log.info("increment() #2 = {d}, gas_remaining={d}", .{ r2, counter.remainingGas() });

    const total_gas = counter.totalGasConsumed();
    log.info("Total gas consumed: {d}", .{total_gas});
    log.info("Expected: SLOAD(200) + SSTORE_NEW(20000) + SLOAD(200) + SSTORE_MODIFY(5000) = 25,400", .{});
```

- [ ] **Step 1: Add counter_wasm loading in main.zig**
- [ ] **Step 2: Replace Scene 2a body with counter demo code**
- [ ] **Step 3: Build and run** — `zig build run`
- [ ] **Step 4: Verify output shows per-op gas logging and correct final count (2)**

---

### Task 5: Add counter gas consumption test

**Files:**
- Modify: `src/tests.zig`

```zig
test "counter contract charges gas per storage op" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const wasm_bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "zig-out/bin/contract_counter.wasm",
        alloc,
        .limited(limits.max_module_bytes),
    );

    const allowed_imports = [_][]const u8{"env.host_log", "env.storage_read", "env.storage_write"};
    const allowed_exports = [_][]const u8{"increment"};
    const required_exports = [_][]const u8{"increment"};

    var sb = try sandbox.Sandbox.init(
        alloc,
        wasm_bytes,
        &allowed_imports,
        &allowed_exports,
        &required_exports,
    );
    defer sb.deinit();

    var state = try StateStore.initMemory(alloc, .{});
    defer state.deinit();
    sb.attachState(&state);

    const gas0 = sb.remainingGas();

    // First increment: SLOAD(200) + SSTORE_NEW(20000)
    const r1 = try sb.call("increment", &[_]i32{});
    try std.testing.expectEqual(@as(i32, 1), r1);

    const gas1 = sb.remainingGas();
    const consumed1 = gas0 - gas1;
    try std.testing.expectEqual(@as(u64, 20200), consumed1); // 200 + 20000

    // Second increment: SLOAD(200) + SSTORE_MODIFY(5000)
    const r2 = try sb.call("increment", &[_]i32{});
    try std.testing.expectEqual(@as(i32, 2), r2);

    const gas2 = sb.remainingGas();
    const consumed2 = gas1 - gas2;
    try std.testing.expectEqual(@as(u64, 5200), consumed2); // 200 + 5000

    // Total
    try std.testing.expectEqual(@as(u64, 25400), gas0 - gas2);
}
```

- [ ] **Step 1: Add test to src/tests.zig**
- [ ] **Step 2: Run test** — `zig test src/tests.zig`
- [ ] **Step 3: Verify all tests pass**

---

## Self-Review

**Spec coverage:**
- ✅ New guest contract (`contract_counter.zig`) — Task 1
- ✅ Second WASM target in build.zig — Task 2
- ✅ Gas before/after logging in callbacks — Task 3
- ✅ Scene 2a counter demo — Task 4
- ✅ Gas consumption test — Task 5

**Placeholder scan:**
- ✅ No TBD, TODO, or vague steps
- ✅ All code blocks contain complete code
- ✅ All commands have expected output

**Type consistency:**
- ✅ `increment()` returns `i32` in guest, host receives `i32`
- ✅ Gas values are `u64` throughout
- ✅ StateStore API matches existing (`initMemory`, `attachState`)
