//! Host-export function framework.
//! All functions exposed to the guest MUST be registered through this module.
//! Provides reentrancy guards, parameter validation, gas charging, and unified error handling.

const std = @import("std");
const c = @import("sandbox_bindings.zig");
const mem = @import("sandbox_memory.zig");
const limits = @import("limits.zig");
const Sandbox = @import("sandbox.zig").Sandbox;

const log = std.log.scoped(.host_exports);

// ------------------------------------------------------------------
// HostContext + HostEnv
// ------------------------------------------------------------------

/// Per-sandbox host state shared across callbacks.
pub const HostContext = struct {
    /// Tracks how deep we are in host callback reentrancy.
    reentrant_depth: std.atomic.Value(u32),

    pub fn init() HostContext {
        return .{
            .reentrant_depth = std.atomic.Value(u32).init(0),
        };
    }

    pub fn enter(self: *HostContext) bool {
        const depth = self.reentrant_depth.fetchAdd(1, .seq_cst);
        if (depth >= limits.max_reentrant_depth) {
            _ = self.reentrant_depth.fetchSub(1, .seq_cst);
            log.err("Max reentrant depth exceeded: {d}", .{depth});
            return false;
        }
        return true;
    }

    pub fn exit(self: *HostContext) void {
        _ = self.reentrant_depth.fetchSub(1, .seq_cst);
    }
};

/// Full environment passed to host callbacks. Contains both the context
/// guard and a pointer back to the sandbox for state/gas access.
pub const HostEnv = struct {
    ctx: HostContext,
    sandbox: ?*Sandbox,

    pub fn init() HostEnv {
        return .{
            .ctx = HostContext.init(),
            .sandbox = null,
        };
    }

    pub fn attachSandbox(self: *HostEnv, sb: *Sandbox) void {
        self.sandbox = sb;
    }
};

// ------------------------------------------------------------------
// Helpers: runtime validation + trap creation
// ------------------------------------------------------------------

/// Create a wasmtime trap with the given message.
/// Called when a security or resource violation is detected.
fn createTrap(msg: []const u8) ?*c.wasm_trap_t {
    return c.wasmtime_trap_new(msg.ptr, msg.len);
}

/// Validate callback argument count at runtime.
/// Replaces std.debug.assert() which is STRIPPED in ReleaseFast/ReleaseSafe builds.
fn checkArgs(nargs: usize, expected: usize, name: []const u8) ?*c.wasm_trap_t {
    if (nargs != expected) {
        log.err("Host callback {s}: expected {d} args, got {d}", .{ name, expected, nargs });
        return createTrap("invalid host call signature");
    }
    return null;
}

fn checkResults(nresults: usize, expected: usize, name: []const u8) ?*c.wasm_trap_t {
    if (nresults != expected) {
        log.err("Host callback {s}: expected {d} results, got {d}", .{ name, expected, nresults });
        return createTrap("invalid host call signature");
    }
    return null;
}

/// Get guest linear memory data pointer and size from caller.
fn getGuestMemory(caller: ?*c.wasmtime_caller_t) struct { data: ?[*]u8, size: usize } {
    const ctx = c.wasmtime_caller_context(caller);
    var item: c.wasmtime_extern_t = undefined;
    const found = c.wasmtime_caller_export_get(caller, "memory", "memory".len, &item);
    if (!found or item.kind != c.WASMTIME_EXTERN_MEMORY) return .{ .data = null, .size = 0 };
    defer c.wasmtime_extern_delete(&item);
    return .{
        .data = c.wasmtime_memory_data(ctx, &item.of.memory),
        .size = c.wasmtime_memory_data_size(ctx, &item.of.memory),
    };
}

/// Check if [ptr, ptr + len) is within guest memory bounds.
fn checkBounds(ptr: u32, len: usize, mem_size: usize, name: []const u8) ?*c.wasm_trap_t {
    const end = @as(u64, ptr) + len;
    if (end > mem_size) {
        log.err("{s} OOB: ptr={d} len={d} mem={d}", .{ name, ptr, len, mem_size });
        return createTrap("out of bounds memory access");
    }
    return null;
}

// ------------------------------------------------------------------
// host_log
// ------------------------------------------------------------------

pub fn hostLogCallback(
    env: ?*anyopaque,
    caller: ?*c.wasmtime_caller_t,
    args: [*c]const c.wasmtime_val_t,
    nargs: usize,
    _: [*c]c.wasmtime_val_t,
    nresults: usize,
) callconv(.c) ?*c.wasm_trap_t {
    if (checkArgs(nargs, 2, "host_log")) |trap| return trap;
    if (checkResults(nresults, 0, "host_log")) |trap| return trap;

    const he: *HostEnv = @ptrCast(@alignCast(env));
    if (!he.ctx.enter()) return null;
    defer he.ctx.exit();

    const ptr: u32 = @intCast(args[0].of.i32);
    const len: u32 = @intCast(args[1].of.i32);

    const guest_mem = getGuestMemory(caller);
    if (guest_mem.data == null) return createTrap("memory export not found");
    if (checkBounds(ptr, len, guest_mem.size, "host_log")) |trap| return trap;

    const callback_mem = mem.CallbackMemory.init(caller);
    const msg = callback_mem.readString(ptr, len, limits.max_log_message_len) catch |err| {
        log.err("host_log memory error: {s}", .{@errorName(err)});
        return createTrap("memory read error");
    };

    log.info("[sandbox] {s}", .{msg});
    return null;
}

// ------------------------------------------------------------------
// host_storage_read (smart-contract state)
// ------------------------------------------------------------------

pub fn hostStorageReadCallback(
    env: ?*anyopaque,
    caller: ?*c.wasmtime_caller_t,
    args: [*c]const c.wasmtime_val_t,
    nargs: usize,
    results: [*c]c.wasmtime_val_t,
    nresults: usize,
) callconv(.c) ?*c.wasm_trap_t {
    if (checkArgs(nargs, 4, "storage_read")) |trap| return trap;
    if (checkResults(nresults, 1, "storage_read")) |trap| return trap;

    const he: *HostEnv = @ptrCast(@alignCast(env));
    if (!he.ctx.enter()) {
        results[0] = .{ .kind = c.WASM_I32, .of = .{ .i32 = -1 } };
        return null;
    }
    defer he.ctx.exit();

    const key_ptr: u32 = @intCast(args[0].of.i32);
    const key_len: u32 = @intCast(args[1].of.i32);
    const val_ptr: u32 = @intCast(args[2].of.i32);
    const val_max: u32 = @intCast(args[3].of.i32);

    const sb = he.sandbox orelse {
        results[0] = .{ .kind = c.WASM_I32, .of = .{ .i32 = -1 } };
        return null;
    };

    // Log gas before SLOAD
    const gas_before = sb.gas_meter.remaining();
    log.info("[SLOAD] gas_before={d}", .{gas_before});

    // Charge gas for SLOAD — on exhaustion TRAP (do not return error code)
    sb.gas_meter.chargeSload() catch {
        log.info("[SLOAD] OUT OF GAS", .{});
        return createTrap("out of gas");
    };

    // Log gas after SLOAD
    const gas_after_sload = sb.gas_meter.remaining();
    log.info("[SLOAD] gas_after={d}  consumed={d}", .{ gas_after_sload, gas_before - gas_after_sload });

    const state = sb.state orelse {
        results[0] = .{ .kind = c.WASM_I32, .of = .{ .i32 = -1 } };
        return null;
    };

    const callback_mem = mem.CallbackMemory.init(caller);
    const key = callback_mem.readBytes(key_ptr, key_len, limits.max_log_message_len) catch {
        results[0] = .{ .kind = c.WASM_I32, .of = .{ .i32 = -1 } };
        return null;
    };

    const val = state.get(key) catch {
        results[0] = .{ .kind = c.WASM_I32, .of = .{ .i32 = -1 } };
        return null;
    };
    if (val == null) {
        results[0] = .{ .kind = c.WASM_I32, .of = .{ .i32 = 0 } };
        return null;
    }

    const v = val.?;
    defer state.allocator.free(v);
    const out_len = @min(v.len, val_max);

    // SECURITY: validate guest memory bounds BEFORE writing
    const guest_mem = getGuestMemory(caller);
    if (guest_mem.data == null) {
        results[0] = .{ .kind = c.WASM_I32, .of = .{ .i32 = -1 } };
        return null;
    }
    if (checkBounds(val_ptr, out_len, guest_mem.size, "storage_read")) |trap| return trap;

    @memcpy(guest_mem.data.?[val_ptr .. val_ptr + out_len], v[0..out_len]);

    results[0] = .{ .kind = c.WASM_I32, .of = .{ .i32 = @intCast(out_len) } };
    return null;
}

// ------------------------------------------------------------------
// host_storage_write (smart-contract state)
// ------------------------------------------------------------------

pub fn hostStorageWriteCallback(
    env: ?*anyopaque,
    caller: ?*c.wasmtime_caller_t,
    args: [*c]const c.wasmtime_val_t,
    nargs: usize,
    _: [*c]c.wasmtime_val_t,
    nresults: usize,
) callconv(.c) ?*c.wasm_trap_t {
    if (checkArgs(nargs, 4, "storage_write")) |trap| return trap;
    if (checkResults(nresults, 0, "storage_write")) |trap| return trap;

    const he: *HostEnv = @ptrCast(@alignCast(env));
    if (!he.ctx.enter()) return null;
    defer he.ctx.exit();

    const key_ptr: u32 = @intCast(args[0].of.i32);
    const key_len: u32 = @intCast(args[1].of.i32);
    const val_ptr: u32 = @intCast(args[2].of.i32);
    const val_len: u32 = @intCast(args[3].of.i32);

    const sb = he.sandbox orelse return null;

    // Validate key/value pointers are within guest memory
    const guest_mem = getGuestMemory(caller);
    if (guest_mem.data == null) return createTrap("memory export not found");
    if (checkBounds(key_ptr, key_len, guest_mem.size, "storage_write(key)")) |trap| return trap;
    if (checkBounds(val_ptr, val_len, guest_mem.size, "storage_write(val)")) |trap| return trap;

    const callback_mem = mem.CallbackMemory.init(caller);
    const key = callback_mem.readBytes(key_ptr, key_len, limits.max_log_message_len) catch return null;
    const value = callback_mem.readBytes(val_ptr, val_len, limits.max_log_message_len) catch return null;

    const state = sb.state orelse return null;
    const maybe_old = state.get(key) catch null;
    const is_new = maybe_old == null;
    if (maybe_old) |old| state.allocator.free(old);

    // Log gas before SSTORE
    const gas_before = sb.gas_meter.remaining();
    log.info("[SSTORE] gas_before={d}  is_new={any}", .{ gas_before, is_new });

    // Charge gas for SSTORE — on exhaustion TRAP
    sb.gas_meter.chargeSstore(is_new) catch {
        log.info("[SSTORE] OUT OF GAS", .{});
        return createTrap("out of gas");
    };

    // Log gas after SSTORE
    const gas_after = sb.gas_meter.remaining();
    log.info("[SSTORE] gas_after={d}  consumed={d}", .{ gas_after, gas_before - gas_after });

    state.set(key, value) catch return null;
    return null;
}

// ------------------------------------------------------------------
// host_log_event (structured event emission)
// ------------------------------------------------------------------

const registry = @import("extensions/contract_registry.zig");

pub fn hostLogEventCallback(
    env: ?*anyopaque,
    caller: ?*c.wasmtime_caller_t,
    args: [*c]const c.wasmtime_val_t,
    nargs: usize,
    _: [*c]c.wasmtime_val_t,
    nresults: usize,
) callconv(.c) ?*c.wasm_trap_t {
    if (checkArgs(nargs, 4, "host_log_event")) |trap| return trap;
    if (checkResults(nresults, 0, "host_log_event")) |trap| return trap;

    const he: *HostEnv = @ptrCast(@alignCast(env));
    if (!he.ctx.enter()) return null;
    defer he.ctx.exit();

    const name_ptr: u32 = @intCast(args[0].of.i32);
    const name_len: u32 = @intCast(args[1].of.i32);
    const data_ptr: u32 = @intCast(args[2].of.i32);
    const data_len: u32 = @intCast(args[3].of.i32);

    const sb = he.sandbox orelse return null;

    // Charge gas for LOG — on exhaustion TRAP
    sb.gas_meter.chargeLog(1) catch return createTrap("out of gas");

    // Validate pointers are within guest memory
    const guest_mem = getGuestMemory(caller);
    if (guest_mem.data == null) return createTrap("memory export not found");
    if (checkBounds(name_ptr, name_len, guest_mem.size, "host_log_event(name)")) |trap| return trap;
    if (checkBounds(data_ptr, data_len, guest_mem.size, "host_log_event(data)")) |trap| return trap;

    const callback_mem = mem.CallbackMemory.init(caller);
    const name = callback_mem.readBytes(name_ptr, name_len, limits.max_log_message_len) catch return null;
    const data = callback_mem.readBytes(data_ptr, data_len, limits.max_log_message_len) catch return null;

    // Emit to registry event log
    const reg = registry.g_registry orelse return null;
    reg.event_log.emit(sb.address, name, data) catch return null;

    return null;
}

// ------------------------------------------------------------------
// host_call_contract (cross-contract call)
// ------------------------------------------------------------------

pub fn hostCallContractCallback(
    env: ?*anyopaque,
    caller: ?*c.wasmtime_caller_t,
    args: [*c]const c.wasmtime_val_t,
    nargs: usize,
    results: [*c]c.wasmtime_val_t,
    nresults: usize,
) callconv(.c) ?*c.wasm_trap_t {
    if (checkArgs(nargs, 6, "call_contract")) |trap| return trap;
    if (checkResults(nresults, 1, "call_contract")) |trap| return trap;

    const he: *HostEnv = @ptrCast(@alignCast(env));
    if (!he.ctx.enter()) {
        results[0] = .{ .kind = c.WASM_I32, .of = .{ .i32 = -1 } };
        return null;
    }
    defer he.ctx.exit();

    const addr_ptr: u32 = @intCast(args[0].of.i32);
    const addr_len: u32 = @intCast(args[1].of.i32);
    const func_ptr: u32 = @intCast(args[2].of.i32);
    const func_len: u32 = @intCast(args[3].of.i32);
    const arg0: i32 = args[4].of.i32;
    const arg1: i32 = args[5].of.i32;

    const caller_sb = he.sandbox orelse {
        results[0] = .{ .kind = c.WASM_I32, .of = .{ .i32 = -1 } };
        return null;
    };

    // Charge gas for CALL — on exhaustion TRAP
    caller_sb.gas_meter.chargeCall() catch {
        return createTrap("out of gas");
    };

    // Validate string pointers are within guest memory
    const guest_mem = getGuestMemory(caller);
    if (guest_mem.data == null) return createTrap("memory export not found");
    if (checkBounds(addr_ptr, addr_len, guest_mem.size, "call_contract(addr)")) |trap| return trap;
    if (checkBounds(func_ptr, func_len, guest_mem.size, "call_contract(func)")) |trap| return trap;

    const callback_mem = mem.CallbackMemory.init(caller);
    const addr = callback_mem.readBytes(addr_ptr, addr_len, 256) catch {
        results[0] = .{ .kind = c.WASM_I32, .of = .{ .i32 = -1 } };
        return null;
    };
    const func_name = callback_mem.readBytes(func_ptr, func_len, 256) catch {
        results[0] = .{ .kind = c.WASM_I32, .of = .{ .i32 = -1 } };
        return null;
    };

    // Push call frame on caller's stack
    caller_sb.call_stack.push(addr, func_name) catch {
        results[0] = .{ .kind = c.WASM_I32, .of = .{ .i32 = -3 } };
        return null;
    };
    defer caller_sb.call_stack.pop();

    log.info("Cross-contract call: {s}.{s}({d}, {d})", .{ addr, func_name, arg0, arg1 });

    // Look up target contract in global registry
    const reg = registry.g_registry orelse {
        log.err("No contract registry available", .{});
        results[0] = .{ .kind = c.WASM_I32, .of = .{ .i32 = -4 } };
        return null;
    };

    const target_entry = reg.get(addr) orelse {
        log.err("Target contract not found: {s}", .{addr});
        results[0] = .{ .kind = c.WASM_I32, .of = .{ .i32 = -5 } };
        return null;
    };

    // Global cycle detection: prevent A->B->A reentrancy
    if (registry.g_call_stack) |stack| {
        for (stack.items) |active_addr| {
            if (std.mem.eql(u8, active_addr, addr)) {
                log.err("Call cycle detected: {s} already active in global call stack", .{addr});
                return createTrap("call cycle detected");
            }
        }
        stack.append(std.heap.page_allocator, addr) catch {
            results[0] = .{ .kind = c.WASM_I32, .of = .{ .i32 = -3 } };
            return null;
        };
        defer _ = stack.pop();
    }

    // Cap target's gas limit to caller's remaining gas
    const caller_remaining = caller_sb.remainingGas();
    target_entry.sandbox.setGasLimit(caller_remaining);

    // Execute target function
    const target_result = target_entry.sandbox.call(func_name, &[_]i32{ arg0, arg1 }) catch |err| {
        log.err("Target contract call failed: {s}.{s} error={s}", .{ addr, func_name, @errorName(err) });
        results[0] = .{ .kind = c.WASM_I32, .of = .{ .i32 = -6 } };
        return null;
    };

    // Accumulate callee's consumed gas into caller's gas meter
    const callee_consumed = target_entry.sandbox.totalGasConsumed();
    caller_sb.gas_meter.charge(callee_consumed) catch {
        log.info("Cross-call gas accumulation exhausted caller", .{});
        // Still return the result; gas exhaustion is tracked but result is valid
    };

    log.info("Cross-contract call result: {d} (callee gas={d})", .{ target_result, callee_consumed });
    results[0] = .{ .kind = c.WASM_I32, .of = .{ .i32 = target_result } };
    return null;
}

// ------------------------------------------------------------------
// host_keccak256 (cryptographic precompile)
// ------------------------------------------------------------------

pub fn hostKeccak256Callback(
    env: ?*anyopaque,
    caller: ?*c.wasmtime_caller_t,
    args: [*c]const c.wasmtime_val_t,
    nargs: usize,
    _: [*c]c.wasmtime_val_t,
    nresults: usize,
) callconv(.c) ?*c.wasm_trap_t {
    if (checkArgs(nargs, 3, "keccak256")) |trap| return trap;
    if (checkResults(nresults, 0, "keccak256")) |trap| return trap;

    const he: *HostEnv = @ptrCast(@alignCast(env));
    if (!he.ctx.enter()) return null;
    defer he.ctx.exit();

    const data_ptr: u32 = @intCast(args[0].of.i32);
    const data_len: u32 = @intCast(args[1].of.i32);
    const out_ptr: u32 = @intCast(args[2].of.i32);

    const sb = he.sandbox orelse return null;

    // Charge gas for keccak256
    sb.gas_meter.chargeKeccak256(data_len) catch return createTrap("out of gas");

    // Validate guest memory bounds
    const guest_mem = getGuestMemory(caller);
    if (guest_mem.data == null) return createTrap("memory export not found");
    if (checkBounds(data_ptr, data_len, guest_mem.size, "keccak256(data)")) |trap| return trap;
    if (checkBounds(out_ptr, 32, guest_mem.size, "keccak256(out)")) |trap| return trap;

    const data = guest_mem.data.?[data_ptr .. data_ptr + data_len];
    var hash_out: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(data, &hash_out, .{});

    @memcpy(guest_mem.data.?[out_ptr .. out_ptr + 32], &hash_out);
    return null;
}

// ------------------------------------------------------------------
// host_sha256 (cryptographic precompile)
// ------------------------------------------------------------------

pub fn hostSha256Callback(
    env: ?*anyopaque,
    caller: ?*c.wasmtime_caller_t,
    args: [*c]const c.wasmtime_val_t,
    nargs: usize,
    _: [*c]c.wasmtime_val_t,
    nresults: usize,
) callconv(.c) ?*c.wasm_trap_t {
    if (checkArgs(nargs, 3, "sha256")) |trap| return trap;
    if (checkResults(nresults, 0, "sha256")) |trap| return trap;

    const he: *HostEnv = @ptrCast(@alignCast(env));
    if (!he.ctx.enter()) return null;
    defer he.ctx.exit();

    const data_ptr: u32 = @intCast(args[0].of.i32);
    const data_len: u32 = @intCast(args[1].of.i32);
    const out_ptr: u32 = @intCast(args[2].of.i32);

    const sb = he.sandbox orelse return null;

    // Charge gas for sha256
    sb.gas_meter.chargeSha256(data_len) catch return createTrap("out of gas");

    // Validate guest memory bounds
    const guest_mem = getGuestMemory(caller);
    if (guest_mem.data == null) return createTrap("memory export not found");
    if (checkBounds(data_ptr, data_len, guest_mem.size, "sha256(data)")) |trap| return trap;
    if (checkBounds(out_ptr, 32, guest_mem.size, "sha256(out)")) |trap| return trap;

    const data = guest_mem.data.?[data_ptr .. data_ptr + data_len];
    var hash_out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &hash_out, .{});

    @memcpy(guest_mem.data.?[out_ptr .. out_ptr + 32], &hash_out);
    return null;
}

// ------------------------------------------------------------------
// Helper: build functype for host_log
// ------------------------------------------------------------------

pub fn createHostLogType(_: std.mem.Allocator) ?*c.wasm_functype_t {
    const p1 = c.wasm_valtype_new(c.WASM_I32);
    const p2 = c.wasm_valtype_new(c.WASM_I32);

    var param_types = [2]?*c.wasm_valtype_t{ p1, p2 };
    var params: c.wasm_valtype_vec_t = undefined;
    c.wasm_valtype_vec_new(&params, 2, &param_types);
    defer c.wasm_valtype_vec_delete(&params);

    var results_vec: c.wasm_valtype_vec_t = undefined;
    c.wasm_valtype_vec_new_empty(&results_vec);
    defer c.wasm_valtype_vec_delete(&results_vec);

    const ty = c.wasm_functype_new(&params, &results_vec);
    return ty;
}

/// Build functype for (i32, i32, i32, i32) -> i32
pub fn createHostFunc4R1Type(_: std.mem.Allocator) ?*c.wasm_functype_t {
    const p1 = c.wasm_valtype_new(c.WASM_I32);
    const p2 = c.wasm_valtype_new(c.WASM_I32);
    const p3 = c.wasm_valtype_new(c.WASM_I32);
    const p4 = c.wasm_valtype_new(c.WASM_I32);
    const r1 = c.wasm_valtype_new(c.WASM_I32);

    var param_types = [4]?*c.wasm_valtype_t{ p1, p2, p3, p4 };
    var params: c.wasm_valtype_vec_t = undefined;
    c.wasm_valtype_vec_new(&params, 4, &param_types);
    defer c.wasm_valtype_vec_delete(&params);

    var result_types = [1]?*c.wasm_valtype_t{r1};
    var results_vec: c.wasm_valtype_vec_t = undefined;
    c.wasm_valtype_vec_new(&results_vec, 1, &result_types);
    defer c.wasm_valtype_vec_delete(&results_vec);

    const ty = c.wasm_functype_new(&params, &results_vec);
    return ty;
}

/// Build functype for (i32, i32, i32, i32) -> ()
pub fn createHostFunc4R0Type(_: std.mem.Allocator) ?*c.wasm_functype_t {
    const p1 = c.wasm_valtype_new(c.WASM_I32);
    const p2 = c.wasm_valtype_new(c.WASM_I32);
    const p3 = c.wasm_valtype_new(c.WASM_I32);
    const p4 = c.wasm_valtype_new(c.WASM_I32);

    var param_types = [4]?*c.wasm_valtype_t{ p1, p2, p3, p4 };
    var params: c.wasm_valtype_vec_t = undefined;
    c.wasm_valtype_vec_new(&params, 4, &param_types);
    defer c.wasm_valtype_vec_delete(&params);

    var results_vec: c.wasm_valtype_vec_t = undefined;
    c.wasm_valtype_vec_new_empty(&results_vec);
    defer c.wasm_valtype_vec_delete(&results_vec);

    const ty = c.wasm_functype_new(&params, &results_vec);
    return ty;
}

/// Build functype for (i32, i32, i32, i32, i32, i32) -> i32
pub fn createHostFunc6R1Type(_: std.mem.Allocator) ?*c.wasm_functype_t {
    const p1 = c.wasm_valtype_new(c.WASM_I32);
    const p2 = c.wasm_valtype_new(c.WASM_I32);
    const p3 = c.wasm_valtype_new(c.WASM_I32);
    const p4 = c.wasm_valtype_new(c.WASM_I32);
    const p5 = c.wasm_valtype_new(c.WASM_I32);
    const p6 = c.wasm_valtype_new(c.WASM_I32);
    const r1 = c.wasm_valtype_new(c.WASM_I32);

    var param_types = [6]?*c.wasm_valtype_t{ p1, p2, p3, p4, p5, p6 };
    var params: c.wasm_valtype_vec_t = undefined;
    c.wasm_valtype_vec_new(&params, 6, &param_types);
    defer c.wasm_valtype_vec_delete(&params);

    var result_types = [1]?*c.wasm_valtype_t{r1};
    var results_vec: c.wasm_valtype_vec_t = undefined;
    c.wasm_valtype_vec_new(&results_vec, 1, &result_types);
    defer c.wasm_valtype_vec_delete(&results_vec);

    const ty = c.wasm_functype_new(&params, &results_vec);
    return ty;
}

/// Build functype for (i32, i32, i32) -> ()
pub fn createHostFunc3R0Type(_: std.mem.Allocator) ?*c.wasm_functype_t {
    const p1 = c.wasm_valtype_new(c.WASM_I32);
    const p2 = c.wasm_valtype_new(c.WASM_I32);
    const p3 = c.wasm_valtype_new(c.WASM_I32);

    var param_types = [3]?*c.wasm_valtype_t{ p1, p2, p3 };
    var params: c.wasm_valtype_vec_t = undefined;
    c.wasm_valtype_vec_new(&params, 3, &param_types);
    defer c.wasm_valtype_vec_delete(&params);

    var results_vec: c.wasm_valtype_vec_t = undefined;
    c.wasm_valtype_vec_new_empty(&results_vec);
    defer c.wasm_valtype_vec_delete(&results_vec);

    const ty = c.wasm_functype_new(&params, &results_vec);
    return ty;
}
