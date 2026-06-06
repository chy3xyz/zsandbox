//! Plugin registry: load, unload, reload, and discover sandboxed plugins.
//! Note: this demo version is single-threaded. Production should add locking.

const std = @import("std");
const Sandbox = @import("../sandbox.zig").Sandbox;
const limits = @import("../limits.zig");

const log = std.log.scoped(.plugin_registry);

pub const Error = error{
    OutOfMemory,
    PluginNotFound,
    PluginAlreadyLoaded,
    LoadFailed,
    CallFailed,
};

/// Metadata attached to each loaded plugin.
pub const PluginMeta = struct {
    name: []const u8,
    version: []const u8,
    loaded_at: i64,
    call_count: std.atomic.Value(u64),
    total_fuel_consumed: std.atomic.Value(u64),

    pub fn init(name: []const u8, version: []const u8) PluginMeta {
        return .{
            .name = name,
            .version = version,
            .loaded_at = 0, // timestamps not available in this Zig version
            .call_count = std.atomic.Value(u64).init(0),
            .total_fuel_consumed = std.atomic.Value(u64).init(0),
        };
    }
};

/// A loaded plugin entry.
pub const PluginEntry = struct {
    sandbox: *Sandbox,
    meta: PluginMeta,
    dying: bool,
};

/// Registry of sandboxed plugins.
pub const PluginRegistry = struct {
    allocator: std.mem.Allocator,
    plugins: std.StringHashMap(*PluginEntry),
    mutex: std.atomic.Mutex,

    pub fn init(allocator: std.mem.Allocator) PluginRegistry {
        return .{
            .allocator = allocator,
            .plugins = std.StringHashMap(*PluginEntry).init(allocator),
            .mutex = .unlocked,
        };
    }

    fn lock(self: *PluginRegistry) void {
        while (!self.mutex.tryLock()) {
            std.atomic.spinLoopHint();
        }
    }

    fn unlock(self: *PluginRegistry) void {
        self.mutex.unlock();
    }

    pub fn deinit(self: *PluginRegistry) void {
        var it = self.plugins.valueIterator();
        while (it.next()) |entry_ptr| {
            const entry = entry_ptr.*;
            entry.sandbox.deinit();
            self.allocator.destroy(entry.sandbox);
            self.allocator.destroy(entry);
        }
        self.plugins.deinit();
        self.* = undefined;
    }

    /// Load a new plugin from WASM bytes.
    pub fn load(
        self: *PluginRegistry,
        name: []const u8,
        version: []const u8,
        wasm_bytes: []const u8,
    ) Error!void {
        self.lock();
        defer self.unlock();

        if (self.plugins.contains(name)) {
            log.err("Plugin already loaded: {s}", .{name});
            return Error.PluginAlreadyLoaded;
        }

        const allowed_imports = [_][]const u8{"env.host_log"};
        const allowed_exports = [_][]const u8{ "sandbox_add", "sandbox_panic", "memory", "__stack_pointer" };
        const required_exports = [_][]const u8{"sandbox_add"};

        const sb = try self.allocator.create(Sandbox);
        errdefer self.allocator.destroy(sb);

        sb.* = Sandbox.init(
            self.allocator,
            wasm_bytes,
            &allowed_imports,
            &allowed_exports,
            &required_exports,
        ) catch |err| {
            log.err("Failed to create sandbox for plugin {s}: {s}", .{ name, @errorName(err) });
            return Error.LoadFailed;
        };
        errdefer sb.deinit();

        const entry = try self.allocator.create(PluginEntry);
        entry.* = .{
            .sandbox = sb,
            .meta = PluginMeta.init(name, version),
            .dying = false,
        };

        try self.plugins.put(name, entry);
        log.info("Plugin loaded: {s} v{s}", .{ name, version });
    }

    /// Unload a plugin immediately.
    pub fn unload(self: *PluginRegistry, name: []const u8) Error!void {
        self.lock();
        defer self.unlock();

        const entry = self.plugins.fetchRemove(name) orelse {
            return Error.PluginNotFound;
        };
        entry.value.sandbox.deinit();
        self.allocator.destroy(entry.value.sandbox);
        self.allocator.destroy(entry.value);
        log.info("Plugin unloaded: {s}", .{name});
    }

    /// Hot reload: atomic replacement.
    pub fn reload(
        self: *PluginRegistry,
        name: []const u8,
        version: []const u8,
        wasm_bytes: []const u8,
    ) Error!void {
        self.lock();
        defer self.unlock();

        _ = self.plugins.get(name) orelse {
            return Error.PluginNotFound;
        };

        const allowed_imports = [_][]const u8{"env.host_log"};
        const allowed_exports = [_][]const u8{ "sandbox_add", "sandbox_panic", "memory", "__stack_pointer" };
        const required_exports = [_][]const u8{"sandbox_add"};

        const new_sb = try self.allocator.create(Sandbox);
        errdefer self.allocator.destroy(new_sb);

        new_sb.* = Sandbox.init(
            self.allocator,
            wasm_bytes,
            &allowed_imports,
            &allowed_exports,
            &required_exports,
        ) catch |err| {
            log.err("Reload failed for {s}: {s}", .{ name, @errorName(err) });
            return Error.LoadFailed;
        };
        errdefer new_sb.deinit();

        const new_entry = try self.allocator.create(PluginEntry);
        new_entry.* = .{
            .sandbox = new_sb,
            .meta = PluginMeta.init(name, version),
            .dying = false,
        };

        const old = self.plugins.fetchRemove(name).?.value;
        try self.plugins.put(name, new_entry);

        old.sandbox.deinit();
        self.allocator.destroy(old.sandbox);
        self.allocator.destroy(old);

        log.info("Plugin reloaded: {s} -> v{s}", .{ name, version });
    }

    /// Call a function on a loaded plugin.
    pub fn call(
        self: *PluginRegistry,
        name: []const u8,
        func: []const u8,
        args: []const i32,
    ) Error!i32 {
        self.lock();
        const entry = self.plugins.get(name) orelse {
            self.unlock();
            return Error.PluginNotFound;
        };
        if (entry.dying) {
            self.unlock();
            return Error.PluginNotFound;
        }
        // Copy sandbox pointer before releasing lock
        const sandbox_ptr = entry.sandbox;
        self.unlock();

        const fuel_before = sandbox_ptr.remainingFuel();
        const result = sandbox_ptr.call(func, args) catch |err| {
            log.err("Plugin call failed: {s}.{s} error={s}", .{ name, func, @errorName(err) });
            return Error.CallFailed;
        };
        const fuel_after = sandbox_ptr.remainingFuel();

        _ = entry.meta.call_count.fetchAdd(1, .monotonic);
        _ = entry.meta.total_fuel_consumed.fetchAdd(fuel_before - fuel_after, .monotonic);

        return result;
    }

    /// List all loaded plugins.
    pub fn list(self: *PluginRegistry, allocator: std.mem.Allocator) Error![]PluginInfo {
        self.lock();
        defer self.unlock();

        var infos = try allocator.alloc(PluginInfo, self.plugins.count());
        var i: usize = 0;
        var it = self.plugins.iterator();
        while (it.next()) |kv| : (i += 1) {
            infos[i] = .{
                .name = kv.key_ptr.*,
                .version = kv.value_ptr.*.meta.version,
                .call_count = kv.value_ptr.*.meta.call_count.load(.monotonic),
                .total_fuel = kv.value_ptr.*.meta.total_fuel_consumed.load(.monotonic),
            };
        }
        return infos;
    }
};

pub const PluginInfo = struct {
    name: []const u8,
    version: []const u8,
    call_count: u64,
    total_fuel: u64,
};
