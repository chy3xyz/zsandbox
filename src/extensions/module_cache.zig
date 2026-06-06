//! Module compilation cache.
//! Avoids recompiling identical WASM binaries by caching compiled wasmtime modules.
//! All modules share a single wasm_engine for memory efficiency.

const std = @import("std");
const c = @import("../sandbox_bindings.zig");

const log = std.log.scoped(.module_cache);

pub const Error = error{
    OutOfMemory,
    EngineInitFailed,
    ModuleCompilationFailed,
};

/// Cache of compiled WASM modules keyed by SHA-256 hash of the raw bytes.
pub const ModuleCache = struct {
    allocator: std.mem.Allocator,
    engine: *c.wasm_engine_t,
    modules: std.StringHashMap(*c.wasmtime_module_t),

    pub fn init(allocator: std.mem.Allocator) Error!ModuleCache {
        const config = c.wasm_config_new() orelse return Error.EngineInitFailed;
        c.wasmtime_config_consume_fuel_set(config, true);
        c.wasmtime_config_max_wasm_stack_set(config, 256 * 1024);
        c.wasmtime_config_wasm_threads_set(config, false);
        c.wasmtime_config_wasm_simd_set(config, false);
        c.wasmtime_config_wasm_relaxed_simd_set(config, false);
        c.wasmtime_config_wasm_relaxed_simd_deterministic_set(config, false);
        c.wasmtime_config_wasm_bulk_memory_set(config, true);
        c.wasmtime_config_wasm_multi_memory_set(config, false);
        c.wasmtime_config_wasm_memory64_set(config, false);
        c.wasmtime_config_debug_info_set(config, false);

        const engine = c.wasm_engine_new_with_config(config) orelse return Error.EngineInitFailed;

        return .{
            .allocator = allocator,
            .engine = engine,
            .modules = std.StringHashMap(*c.wasmtime_module_t).init(allocator),
        };
    }

    pub fn deinit(self: *ModuleCache) void {
        var it = self.modules.iterator();
        while (it.next()) |kv| {
            c.wasmtime_module_delete(kv.value_ptr.*);
            self.allocator.free(kv.key_ptr.*);
        }
        self.modules.deinit();
        c.wasm_engine_delete(self.engine);
        self.* = undefined;
    }

    /// Compile WASM bytes or return a cached module.
    pub fn compile(self: *ModuleCache, wasm_bytes: []const u8) Error!*c.wasmtime_module_t {
        var hash_buf: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(wasm_bytes, &hash_buf, .{});
        const hex = std.fmt.bytesToHex(hash_buf, .lower);
        const hash_key = try self.allocator.dupe(u8, &hex);

        if (self.modules.get(hash_key)) |mod| {
            self.allocator.free(hash_key);
            log.info("Module cache hit: {s}", .{hash_key});
            return mod;
        }

        var module: ?*c.wasmtime_module_t = null;
        const err = c.wasmtime_module_new(self.engine, wasm_bytes.ptr, wasm_bytes.len, &module);
        if (err != null) {
            defer c.wasmtime_error_delete(err);
            var msg: c.wasm_name_t = undefined;
            c.wasmtime_error_message(err, &msg);
            defer c.wasm_byte_vec_delete(&msg);
            log.err("Module compilation failed: {s}", .{msg.data[0..msg.size]});
            self.allocator.free(hash_key);
            return Error.ModuleCompilationFailed;
        }

        try self.modules.put(hash_key, module.?);
        log.info("Module cache miss, compiled and stored: {s}", .{hash_key});
        return module.?;
    }

    /// Get the shared engine for creating stores.
    pub fn getEngine(self: *const ModuleCache) *c.wasm_engine_t {
        return self.engine;
    }
};
