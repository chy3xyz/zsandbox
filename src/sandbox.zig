//! Production-grade WASM sandbox manager.
//! Encapsulates engine, store, module, linker, instance, gas metering,
//! memory safety, call-stack tracking, and extension slots.

const std = @import("std");
const assert = std.debug.assert;
const c = @import("sandbox_bindings.zig");
const limits = @import("limits.zig");
const mem = @import("sandbox_memory.zig");
const fuel = @import("fuel_meter.zig");
const gas = @import("gas_meter.zig");
const validator = @import("wasm_validator.zig");
const exports = @import("host_exports.zig");
const StateStore = @import("extensions/state_store.zig").StateStore;
const IoPipeline = @import("extensions/io_pipeline.zig").IoPipeline;
const Watchdog = @import("extensions/io_pipeline.zig").Watchdog;
const ModuleCache = @import("extensions/module_cache.zig").ModuleCache;

const log = std.log.scoped(.sandbox);

// ------------------------------------------------------------------
// Error types
// ------------------------------------------------------------------

pub const SandboxError = error{
    OutOfMemory,
    EngineInitFailed,
    StoreInitFailed,
    ModuleLoadFailed,
    ModuleValidationFailed,
    InstantiationFailed,
    FunctionNotFound,
    FunctionCallFailed,
    TrapOccurred,
    FuelExhausted,
    GasExhausted,
    ExportTypeMismatch,
    IoError,
    TimedOut,
    CallDepthExceeded,
    ReentrancyDetected,
};

// ------------------------------------------------------------------
// Call stack tracking (for cross-contract calls)
// ------------------------------------------------------------------

pub const CallFrame = struct {
    contract_addr: []const u8,
    function: []const u8,
};

pub const CallStack = struct {
    frames: [max_call_depth]CallFrame,
    len: u32,

    pub const max_call_depth = 16;

    pub fn init() CallStack {
        return .{
            .frames = undefined,
            .len = 0,
        };
    }

    pub fn push(self: *CallStack, addr: []const u8, func: []const u8) SandboxError!void {
        if (self.len >= max_call_depth) {
            log.err("Call depth exceeded: {d}", .{self.len});
            return SandboxError.CallDepthExceeded;
        }
        // Check for reentrancy (same contract already in stack)
        for (self.frames[0..self.len]) |frame| {
            if (std.mem.eql(u8, frame.contract_addr, addr)) {
                log.err("Reentrancy detected: {s}", .{addr});
                return SandboxError.ReentrancyDetected;
            }
        }
        self.frames[self.len] = .{ .contract_addr = addr, .function = func };
        self.len += 1;
    }

    pub fn pop(self: *CallStack) void {
        assert(self.len > 0);
        self.len -= 1;
    }

    pub fn isEmpty(self: *const CallStack) bool {
        return self.len == 0;
    }
};

// ------------------------------------------------------------------
// Sandbox
// ------------------------------------------------------------------

pub const Sandbox = struct {
    allocator: std.mem.Allocator,
    engine: *c.wasm_engine_t,
    store: *c.wasm_store_t,
    context: ?*c.wasmtime_context_t,
    module: *c.wasmtime_module_t,
    linker: *c.wasmtime_linker_t,
    instance: c.wasmtime_instance_t,
    fuel_meter: fuel.FuelMeter,
    gas_meter: gas.GasMeter,
    host_env: *exports.HostEnv,

    // === Ownership flags (for module cache sharing) ===
    owns_engine: bool,
    owns_module: bool,

    // === Extension slots (optional, set after init) ===
    state: ?*StateStore,
    io: ?*IoPipeline,
    watchdog: ?*Watchdog,

    // === Call stack (for cross-contract calls) ===
    call_stack: CallStack,
    address: []const u8, // own contract address

    /// Open a sandbox from raw WASM bytes (backwards-compatible, no cache).
    pub fn init(
        allocator: std.mem.Allocator,
        wasm_bytes: []const u8,
        allowed_imports: ?[]const []const u8,
        allowed_exports: ?[]const []const u8,
        required_exports: ?[]const []const u8,
    ) SandboxError!Sandbox {
        return initAdvanced(allocator, wasm_bytes, allowed_imports, allowed_exports, required_exports, null);
    }

    /// Open a sandbox using a shared module cache for compiled modules.
    pub fn initWithCache(
        allocator: std.mem.Allocator,
        wasm_bytes: []const u8,
        allowed_imports: ?[]const []const u8,
        allowed_exports: ?[]const []const u8,
        required_exports: ?[]const []const u8,
        module_cache: *ModuleCache,
    ) SandboxError!Sandbox {
        return initAdvanced(allocator, wasm_bytes, allowed_imports, allowed_exports, required_exports, module_cache);
    }

    fn initAdvanced(
        allocator: std.mem.Allocator,
        wasm_bytes: []const u8,
        allowed_imports: ?[]const []const u8,
        allowed_exports: ?[]const []const u8,
        required_exports: ?[]const []const u8,
        module_cache: ?*ModuleCache,
    ) SandboxError!Sandbox {
        validator.validateModule(allocator, wasm_bytes, allowed_imports, allowed_exports, required_exports) catch |err| {
            log.warn("Module validation failed: {s}", .{@errorName(err)});
            return SandboxError.ModuleValidationFailed;
        };

        const owns_engine = module_cache == null;
        const owns_module = module_cache == null;

        var engine: *c.wasm_engine_t = undefined;
        var module: *c.wasmtime_module_t = undefined;

        if (module_cache) |cache| {
            engine = cache.getEngine();
            module = cache.compile(wasm_bytes) catch |err| {
                log.err("Module cache compile failed: {s}", .{@errorName(err)});
                return SandboxError.ModuleLoadFailed;
            };
        } else {
            const config = c.wasm_config_new() orelse return SandboxError.EngineInitFailed;
            c.wasmtime_config_consume_fuel_set(config, true);
            c.wasmtime_config_max_wasm_stack_set(config, limits.max_wasm_stack);
            c.wasmtime_config_wasm_threads_set(config, false);
            c.wasmtime_config_wasm_simd_set(config, false);
            c.wasmtime_config_wasm_relaxed_simd_set(config, false);
            c.wasmtime_config_wasm_relaxed_simd_deterministic_set(config, false);
            c.wasmtime_config_wasm_bulk_memory_set(config, true);
            c.wasmtime_config_wasm_multi_memory_set(config, false);
            c.wasmtime_config_wasm_memory64_set(config, false);
            c.wasmtime_config_debug_info_set(config, false);

            engine = c.wasm_engine_new_with_config(config) orelse return SandboxError.EngineInitFailed;
            errdefer c.wasm_engine_delete(engine);

            var mod_ptr: ?*c.wasmtime_module_t = null;
            {
                const err = c.wasmtime_module_new(engine, wasm_bytes.ptr, wasm_bytes.len, &mod_ptr);
                if (err != null) {
                    defer c.wasmtime_error_delete(err);
                    var msg: c.wasm_name_t = undefined;
                    c.wasmtime_error_message(err, &msg);
                    defer c.wasm_byte_vec_delete(&msg);
                    log.err("Module compilation failed: {s}", .{msg.data[0..msg.size]});
                    return SandboxError.ModuleLoadFailed;
                }
            }
            module = mod_ptr.?;
            errdefer c.wasmtime_module_delete(module);
        }

        const store = c.wasmtime_store_new(engine, null, null) orelse return SandboxError.StoreInitFailed;
        errdefer c.wasmtime_store_delete(store);
        // Enforce memory growth limits at the store level.
        c.wasmtime_store_limiter(store, @intCast(limits.max_memory_bytes), -1, -1, -1, -1);

        const context = c.wasmtime_store_context(store);

        var fuel_meter_instance = fuel.FuelMeter.init(context) catch |err| {
            log.err("Fuel meter init failed: {s}", .{@errorName(err)});
            return SandboxError.FuelExhausted;
        };

        var gas_meter_instance = gas.GasMeter.init(context, gas.GasPriceTable.default, limits.initial_gas) catch |err| {
            log.err("Gas meter init failed: {s}", .{@errorName(err)});
            return SandboxError.GasExhausted;
        };

        const linker = c.wasmtime_linker_new(engine) orelse return SandboxError.EngineInitFailed;
        errdefer c.wasmtime_linker_delete(linker);

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        const log_ty = exports.createHostLogType(arena_alloc);
        if (log_ty == null) return SandboxError.EngineInitFailed;
        defer c.wasm_functype_delete(log_ty);

        const host_env = try allocator.create(exports.HostEnv);
        errdefer allocator.destroy(host_env);
        host_env.* = exports.HostEnv.init();

        {
            const err = c.wasmtime_linker_define_func(
                linker,
                limits.host_module_name.ptr,
                limits.host_module_name.len,
                limits.host_log_name.ptr,
                limits.host_log_name.len,
                log_ty,
                exports.hostLogCallback,
                host_env,
                null,
            );
            if (err != null) {
                defer c.wasmtime_error_delete(err);
                var msg: c.wasm_name_t = undefined;
                c.wasmtime_error_message(err, &msg);
                defer c.wasm_byte_vec_delete(&msg);
                log.err("Failed to define host_log: {s}", .{msg.data[0..msg.size]});
                return SandboxError.EngineInitFailed;
            }
        }

        // Register host_storage_read
        const read_ty = exports.createHostFunc4R1Type(arena_alloc);
        if (read_ty == null) return SandboxError.EngineInitFailed;
        defer c.wasm_functype_delete(read_ty);
        {
            const err = c.wasmtime_linker_define_func(
                linker,
                limits.host_module_name.ptr,
                limits.host_module_name.len,
                "storage_read",
                "storage_read".len,
                read_ty,
                exports.hostStorageReadCallback,
                host_env,
                null,
            );
            if (err != null) {
                defer c.wasmtime_error_delete(err);
                var msg: c.wasm_name_t = undefined;
                c.wasmtime_error_message(err, &msg);
                defer c.wasm_byte_vec_delete(&msg);
                log.err("Failed to define host_storage_read: {s}", .{msg.data[0..msg.size]});
                return SandboxError.EngineInitFailed;
            }
        }

        // Register host_storage_write
        const write_ty = exports.createHostFunc4R0Type(arena_alloc);
        if (write_ty == null) return SandboxError.EngineInitFailed;
        defer c.wasm_functype_delete(write_ty);
        {
            const err = c.wasmtime_linker_define_func(
                linker,
                limits.host_module_name.ptr,
                limits.host_module_name.len,
                "storage_write",
                "storage_write".len,
                write_ty,
                exports.hostStorageWriteCallback,
                host_env,
                null,
            );
            if (err != null) {
                defer c.wasmtime_error_delete(err);
                var msg: c.wasm_name_t = undefined;
                c.wasmtime_error_message(err, &msg);
                defer c.wasm_byte_vec_delete(&msg);
                log.err("Failed to define host_storage_write: {s}", .{msg.data[0..msg.size]});
                return SandboxError.EngineInitFailed;
            }
        }

        // Register host_call_contract
        const call_ty = exports.createHostFunc6R1Type(arena_alloc);
        if (call_ty == null) return SandboxError.EngineInitFailed;
        defer c.wasm_functype_delete(call_ty);
        {
            const err = c.wasmtime_linker_define_func(
                linker,
                limits.host_module_name.ptr,
                limits.host_module_name.len,
                "call_contract",
                "call_contract".len,
                call_ty,
                exports.hostCallContractCallback,
                host_env,
                null,
            );
            if (err != null) {
                defer c.wasmtime_error_delete(err);
                var msg: c.wasm_name_t = undefined;
                c.wasmtime_error_message(err, &msg);
                defer c.wasm_byte_vec_delete(&msg);
                log.err("Failed to define host_call_contract: {s}", .{msg.data[0..msg.size]});
                return SandboxError.EngineInitFailed;
            }
        }

        // Register host_log_event
        const event_ty = exports.createHostFunc4R0Type(arena_alloc);
        if (event_ty == null) return SandboxError.EngineInitFailed;
        defer c.wasm_functype_delete(event_ty);
        {
            const err = c.wasmtime_linker_define_func(
                linker,
                limits.host_module_name.ptr,
                limits.host_module_name.len,
                limits.host_log_event_name.ptr,
                limits.host_log_event_name.len,
                event_ty,
                exports.hostLogEventCallback,
                host_env,
                null,
            );
            if (err != null) {
                defer c.wasmtime_error_delete(err);
                var msg: c.wasm_name_t = undefined;
                c.wasmtime_error_message(err, &msg);
                defer c.wasm_byte_vec_delete(&msg);
                log.err("Failed to define host_log_event: {s}", .{msg.data[0..msg.size]});
                return SandboxError.EngineInitFailed;
            }
        }

        // Register keccak256 precompile
        const keccak_ty = exports.createHostFunc3R0Type(arena_alloc);
        if (keccak_ty == null) return SandboxError.EngineInitFailed;
        defer c.wasm_functype_delete(keccak_ty);
        {
            const err = c.wasmtime_linker_define_func(
                linker,
                limits.host_module_name.ptr,
                limits.host_module_name.len,
                limits.host_keccak256_name.ptr,
                limits.host_keccak256_name.len,
                keccak_ty,
                exports.hostKeccak256Callback,
                host_env,
                null,
            );
            if (err != null) {
                defer c.wasmtime_error_delete(err);
                var msg: c.wasm_name_t = undefined;
                c.wasmtime_error_message(err, &msg);
                defer c.wasm_byte_vec_delete(&msg);
                log.err("Failed to define keccak256: {s}", .{msg.data[0..msg.size]});
                return SandboxError.EngineInitFailed;
            }
        }

        // Register sha256 precompile
        const sha256_ty = exports.createHostFunc3R0Type(arena_alloc);
        if (sha256_ty == null) return SandboxError.EngineInitFailed;
        defer c.wasm_functype_delete(sha256_ty);
        {
            const err = c.wasmtime_linker_define_func(
                linker,
                limits.host_module_name.ptr,
                limits.host_module_name.len,
                limits.host_sha256_name.ptr,
                limits.host_sha256_name.len,
                sha256_ty,
                exports.hostSha256Callback,
                host_env,
                null,
            );
            if (err != null) {
                defer c.wasmtime_error_delete(err);
                var msg: c.wasm_name_t = undefined;
                c.wasmtime_error_message(err, &msg);
                defer c.wasm_byte_vec_delete(&msg);
                log.err("Failed to define sha256: {s}", .{msg.data[0..msg.size]});
                return SandboxError.EngineInitFailed;
            }
        }

        var instance: c.wasmtime_instance_t = undefined;
        var trap: ?*c.wasm_trap_t = null;
        {
            const err = c.wasmtime_linker_instantiate(linker, context, module, &instance, &trap);
            if (err != null) {
                defer c.wasmtime_error_delete(err);
                var msg: c.wasm_name_t = undefined;
                c.wasmtime_error_message(err, &msg);
                defer c.wasm_byte_vec_delete(&msg);
                log.err("Instantiation failed: {s}", .{msg.data[0..msg.size]});
                return SandboxError.InstantiationFailed;
            }
            if (trap != null) {
                defer c.wasm_trap_delete(trap);
                var msg: c.wasm_name_t = undefined;
                c.wasm_trap_message(trap, &msg);
                defer c.wasm_byte_vec_delete(&msg);
                log.err("Instantiation trap: {s}", .{msg.data[0..msg.size]});
                return SandboxError.TrapOccurred;
            }
        }

        log.info("Sandbox initialized: fuel={d} gas={d}", .{ fuel_meter_instance.remaining(), gas_meter_instance.remaining() });

        const sb = Sandbox{
            .allocator = allocator,
            .engine = engine,
            .store = store,
            .context = context,
            .module = module,
            .linker = linker,
            .instance = instance,
            .fuel_meter = fuel_meter_instance,
            .gas_meter = gas_meter_instance,
            .host_env = host_env,
            .owns_engine = owns_engine,
            .owns_module = owns_module,
            .state = null,
            .io = null,
            .watchdog = null,
            .call_stack = CallStack.init(),
            .address = "",
        };
        // Note: host_env.sandbox is set in call() to avoid dangling pointer
        // from stack-local &sb during init().
        return sb;
    }

    pub fn deinit(self: *Sandbox) void {
        if (self.owns_module) c.wasmtime_module_delete(self.module);
        c.wasmtime_linker_delete(self.linker);
        c.wasmtime_store_delete(self.store);
        if (self.owns_engine) c.wasm_engine_delete(self.engine);
        self.allocator.destroy(self.host_env);
        self.* = undefined;
    }

    pub fn setAddress(self: *Sandbox, addr: []const u8) void {
        self.address = addr;
    }

    /// Call an exported function by name with i32 arguments.
    pub fn call(self: *Sandbox, name: []const u8, args: []const i32) SandboxError!i32 {
        // Update host_env sandbox pointer to our current (stable) address.
        // This avoids dangling pointers from stack-local &sb during init().
        self.host_env.sandbox = self;

        var func_extern: c.wasmtime_extern_t = undefined;
        const found = c.wasmtime_instance_export_get(self.context, &self.instance, name.ptr, name.len, &func_extern);
        if (!found or func_extern.kind != c.WASMTIME_EXTERN_FUNC) {
            log.err("Export not found or not a function: {s}", .{name});
            return SandboxError.FunctionNotFound;
        }

        const func = func_extern.of.func;

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        const wasm_args = try arena_alloc.alloc(c.wasmtime_val_t, args.len);
        for (args, 0..) |arg, i| {
            wasm_args[i] = .{
                .kind = c.WASM_I32,
                .of = .{ .i32 = arg },
            };
        }

        var result: [1]c.wasmtime_val_t = undefined;

        const fuel_before = self.fuel_meter.beforeCall() catch |err| {
            log.err("Fuel check failed before call: {s}", .{@errorName(err)});
            return SandboxError.FuelExhausted;
        };

        log.info("Calling {s}({any}) fuel_before={d} gas_remaining={d}", .{
            name, args, fuel_before, self.gas_meter.remaining(),
        });

        var trap: ?*c.wasm_trap_t = null;
        const err = c.wasmtime_func_call(
            self.context,
            &func,
            wasm_args.ptr,
            wasm_args.len,
            &result,
            1,
            &trap,
        );

        const consumed = self.fuel_meter.afterCall(fuel_before) catch |fuel_err| blk: {
            log.err("Fuel check failed after call: {s}", .{@errorName(fuel_err)});
            break :blk 0;
        };
        log.info("Call consumed fuel: {d} gas_remaining={d}", .{ consumed, self.gas_meter.remaining() });

        if (err != null) {
            defer c.wasmtime_error_delete(err);
            var msg: c.wasm_name_t = undefined;
            c.wasmtime_error_message(err, &msg);
            defer c.wasm_byte_vec_delete(&msg);
            log.err("Function call error: {s}", .{msg.data[0..msg.size]});
            return SandboxError.FunctionCallFailed;
        }

        if (trap != null) {
            defer c.wasm_trap_delete(trap);
            var msg: c.wasm_name_t = undefined;
            c.wasm_trap_message(trap, &msg);
            defer c.wasm_byte_vec_delete(&msg);
            log.err("Function trap: {s}", .{msg.data[0..msg.size]});
            return SandboxError.TrapOccurred;
        }

        if (result[0].kind != c.WASM_I32) {
            log.err("Unexpected result type: {d}", .{result[0].kind});
            return SandboxError.ExportTypeMismatch;
        }

        return result[0].of.i32;
    }

    /// User-code execution: write input, call function, read output.
    pub fn callWithInput(
        self: *Sandbox,
        func: []const u8,
        input: []const u8,
    ) SandboxError![]const u8 {
        const io_pipe = self.io orelse {
            log.err("No I/O pipeline attached", .{});
            return SandboxError.IoError;
        };

        io_pipe.setInput(input) catch |err| {
            log.err("I/O setInput failed: {s}", .{@errorName(err)});
            return SandboxError.IoError;
        };

        const result = try self.call(func, &[_]i32{
            @intCast(limits.io_input_addr),
            @intCast(input.len),
            @intCast(limits.io_output_addr),
            @intCast(limits.io_output_max),
        });

        _ = result;
        return io_pipe.getOutput();
    }

    pub fn remainingFuel(self: *Sandbox) u64 {
        return self.fuel_meter.remaining();
    }

    pub fn remainingGas(self: *Sandbox) u64 {
        return self.gas_meter.remaining();
    }

    pub fn setGasLimit(self: *Sandbox, limit: u64) void {
        self.gas_meter.setLimit(limit);
    }

    pub fn totalFuelConsumed(self: *const Sandbox) u64 {
        return self.fuel_meter.total_consumed;
    }

    pub fn totalGasConsumed(self: *const Sandbox) u64 {
        return self.gas_meter.totalConsumed();
    }

    pub fn resetFuel(self: *Sandbox) SandboxError!void {
        self.fuel_meter.reset() catch |err| {
            log.err("Fuel reset failed: {s}", .{@errorName(err)});
            return SandboxError.FuelExhausted;
        };
    }

    pub fn resetGas(self: *Sandbox) SandboxError!void {
        self.gas_meter.reset() catch |err| {
            log.err("Gas reset failed: {s}", .{@errorName(err)});
            return SandboxError.GasExhausted;
        };
    }

    pub fn attachState(self: *Sandbox, state: *StateStore) void {
        self.state = state;
    }

    pub fn attachIo(self: *Sandbox, io: *IoPipeline) void {
        self.io = io;
    }

    pub fn attachWatchdog(self: *Sandbox, wd: *Watchdog) void {
        self.watchdog = wd;
    }

    /// Write bytes into guest linear memory.
    pub fn writeToGuestMemory(self: *Sandbox, ptr: u32, data: []const u8) SandboxError!void {
        var item: c.wasmtime_extern_t = undefined;
        const found = c.wasmtime_instance_export_get(self.context, &self.instance, "memory", "memory".len, &item);
        if (!found or item.kind != c.WASMTIME_EXTERN_MEMORY) {
            log.err("writeToGuestMemory: memory export not found", .{});
            return SandboxError.IoError;
        }
        defer c.wasmtime_extern_delete(&item);

        const memory = item.of.memory;
        const mem_size = c.wasmtime_memory_data_size(self.context, &memory);
        const mem_data: [*]u8 = c.wasmtime_memory_data(self.context, &memory);

        const end = @as(u64, ptr) + @as(u64, data.len);
        if (end > mem_size) {
            log.err("writeToGuestMemory OOB: ptr={d} len={d} mem={d}", .{ ptr, data.len, mem_size });
            return SandboxError.IoError;
        }

        @memcpy(mem_data[ptr..@intCast(end)], data);
    }
};
