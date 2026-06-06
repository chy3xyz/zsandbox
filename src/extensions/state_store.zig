//! Smart-contract state storage with transaction semantics.
//! Supports both in-memory (testing) and LMDB (production persistence) backends.
//!
//! Memory ownership:
//!   - `get()` returns an OWNED copy. Caller MUST free with `allocator.free()`.
//!   - `set()` copies key/value internally.
//!   - `delete()` does not return data.
//!
//! Transaction semantics:
//!   - `beginTx()` starts a transaction.
//!   - All `set`/`delete` operations are buffered until `commit()`.
//!   - `rollback()` discards pending changes.
//!   - For LMDB, a single read-write transaction is held open during the tx lifetime.

const std = @import("std");
const lmdb = @import("../lmdb_bindings.zig");
const log = std.log.scoped(.state_store);

pub const Error = error{
    OutOfMemory,
    KeyTooLong,
    ValueTooLong,
    DbOpenFailed,
    DbWriteFailed,
    DbReadFailed,
    DbCloseFailed,
    TxInProgress,
    NoTxInProgress,
};

pub const Config = struct {
    max_key_len: usize = 256,
    max_value_len: usize = 64 * 1024,
};

// ------------------------------------------------------------------
// Backend trait
// ------------------------------------------------------------------

const Backend = union(enum) {
    memory: *MemoryBackend,
    lmdb: *LmdbBackend,

    pub fn get(self: Backend, key: []const u8, allocator: std.mem.Allocator) error{OutOfMemory}!?[]const u8 {
        return switch (self) {
            .memory => |b| b.get(key, allocator),
            .lmdb => |b| b.get(key, allocator),
        };
    }

    pub fn set(self: Backend, key: []const u8, value: []const u8) Error!void {
        return switch (self) {
            .memory => |b| b.set(key, value),
            .lmdb => |b| b.set(key, value),
        };
    }

    pub fn delete(self: Backend, key: []const u8) void {
        return switch (self) {
            .memory => |b| b.delete(key),
            .lmdb => |b| b.delete(key),
        };
    }

    pub fn beginTx(self: Backend) Error!void {
        return switch (self) {
            .memory => |b| b.beginTx(),
            .lmdb => |b| b.beginTx(),
        };
    }

    pub fn commit(self: Backend) Error!void {
        return switch (self) {
            .memory => |b| b.commit(),
            .lmdb => |b| b.commit(),
        };
    }

    pub fn rollback(self: Backend) void {
        return switch (self) {
            .memory => |b| b.rollback(),
            .lmdb => |b| b.rollback(),
        };
    }

    pub fn deinit(self: Backend) void {
        return switch (self) {
            .memory => |b| b.deinit(),
            .lmdb => |b| b.deinit(),
        };
    }
};

// ------------------------------------------------------------------
// Memory backend
// ------------------------------------------------------------------

const MemoryBackend = struct {
    allocator: std.mem.Allocator,
    committed: std.StringHashMap([]const u8),
    pending: std.StringHashMap([]const u8),
    in_tx: bool,

    fn init(allocator: std.mem.Allocator) MemoryBackend {
        return .{
            .allocator = allocator,
            .committed = std.StringHashMap([]const u8).init(allocator),
            .pending = std.StringHashMap([]const u8).init(allocator),
            .in_tx = false,
        };
    }

    /// Returns an OWNED copy. Caller must free with allocator.free().
    fn get(self: *MemoryBackend, key: []const u8, allocator: std.mem.Allocator) error{OutOfMemory}!?[]const u8 {
        if (self.pending.get(key)) |v| {
            return try allocator.dupe(u8, v);
        }
        if (self.committed.get(key)) |v| {
            return try allocator.dupe(u8, v);
        }
        return null;
    }

    fn set(self: *MemoryBackend, key: []const u8, value: []const u8) Error!void {
        const owned_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned_key);
        const owned_val = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(owned_val);

        const map = if (self.in_tx) &self.pending else &self.committed;
        const gop = try map.getOrPut(owned_key);
        if (gop.found_existing) {
            self.allocator.free(gop.key_ptr.*);
            self.allocator.free(gop.value_ptr.*);
            gop.key_ptr.* = owned_key;
            gop.value_ptr.* = owned_val;
        } else {
            gop.key_ptr.* = owned_key;
            gop.value_ptr.* = owned_val;
        }
    }

    fn delete(self: *MemoryBackend, key: []const u8) void {
        if (self.in_tx) {
            if (self.pending.fetchRemove(key)) |kv| {
                self.allocator.free(kv.key);
                self.allocator.free(kv.value);
            }
        }
        if (self.committed.fetchRemove(key)) |kv| {
            self.allocator.free(kv.key);
            self.allocator.free(kv.value);
        }
    }

    fn beginTx(self: *MemoryBackend) void {
        self.rollback();
        self.in_tx = true;
    }

    fn commit(self: *MemoryBackend) Error!void {
        if (!self.in_tx) return;
        var it = self.pending.iterator();
        while (it.next()) |entry| {
            const owned_key = try self.allocator.dupe(u8, entry.key_ptr.*);
            errdefer self.allocator.free(owned_key);
            const owned_val = try self.allocator.dupe(u8, entry.value_ptr.*);
            errdefer self.allocator.free(owned_val);

            const gop = try self.committed.getOrPut(owned_key);
            if (gop.found_existing) {
                self.allocator.free(gop.key_ptr.*);
                self.allocator.free(gop.value_ptr.*);
                gop.key_ptr.* = owned_key;
                gop.value_ptr.* = owned_val;
            } else {
                gop.key_ptr.* = owned_key;
                gop.value_ptr.* = owned_val;
            }
        }
        self.clearPending();
        self.in_tx = false;
    }

    fn rollback(self: *MemoryBackend) void {
        var it = self.pending.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.pending.clearRetainingCapacity();
        self.in_tx = false;
    }

    fn clearPending(self: *MemoryBackend) void {
        var it = self.pending.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.pending.clearRetainingCapacity();
    }

    fn deinit(self: *MemoryBackend) void {
        self.rollback();
        var it = self.committed.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.committed.deinit();
        self.pending.deinit();
    }
};

// ------------------------------------------------------------------
// LMDB backend
// ------------------------------------------------------------------

const LmdbBackend = struct {
    allocator: std.mem.Allocator,
    env: ?*lmdb.MDB_env,
    dbi: lmdb.MDB_dbi,
    path: []const u8,
    /// Active read-write transaction (non-null during a tx lifecycle).
    active_txn: ?*lmdb.MDB_txn,

    fn init(allocator: std.mem.Allocator, path: []const u8) Error!LmdbBackend {
        var env: ?*lmdb.MDB_env = null;
        var rc = lmdb.mdb_env_create(&env);
        if (rc != lmdb.MDB_SUCCESS) return Error.DbOpenFailed;
        errdefer lmdb.mdb_env_close(env);

        rc = lmdb.mdb_env_set_mapsize(env, 10 * 1024 * 1024); // 10MB
        if (rc != lmdb.MDB_SUCCESS) return Error.DbOpenFailed;

        // LMDB requires a null-terminated path
        const nt_path = try allocator.alloc(u8, path.len + 1);
        @memcpy(nt_path[0..path.len], path);
        nt_path[path.len] = 0;
        defer allocator.free(nt_path);
        rc = lmdb.mdb_env_open(env, @as([*:0]const u8, @ptrCast(nt_path.ptr)), lmdb.MDB_NOSUBDIR | lmdb.MDB_CREATE, 0o644);
        if (rc != lmdb.MDB_SUCCESS) {
            log.err("mdb_env_open failed: {s}", .{lmdb.mdb_strerror(rc)});
            return Error.DbOpenFailed;
        }

        var txn: ?*lmdb.MDB_txn = null;
        rc = lmdb.mdb_txn_begin(env, null, 0, &txn);
        if (rc != lmdb.MDB_SUCCESS) return Error.DbOpenFailed;
        errdefer lmdb.mdb_txn_abort(txn);

        var dbi: lmdb.MDB_dbi = 0;
        rc = lmdb.mdb_dbi_open(txn, null, lmdb.MDB_CREATE, &dbi);
        if (rc != lmdb.MDB_SUCCESS) return Error.DbOpenFailed;

        rc = lmdb.mdb_txn_commit(txn);
        if (rc != lmdb.MDB_SUCCESS) return Error.DbOpenFailed;

        return .{
            .allocator = allocator,
            .env = env,
            .dbi = dbi,
            .path = try allocator.dupe(u8, path),
            .active_txn = null,
        };
    }

    /// Returns an OWNED copy. Caller must free with allocator.free().
    fn get(self: *LmdbBackend, key: []const u8, allocator: std.mem.Allocator) error{OutOfMemory}!?[]const u8 {
        // If we have an active RW txn, read from it. Otherwise use a readonly txn.
        if (self.active_txn) |txn| {
            var k: lmdb.MDB_val = .{ .mv_size = key.len, .mv_data = @constCast(key.ptr) };
            var v: lmdb.MDB_val = .{ .mv_size = 0, .mv_data = null };
            const rc = lmdb.mdb_get(txn, self.dbi, &k, &v);
            if (rc == lmdb.MDB_NOTFOUND) return null;
            if (rc != lmdb.MDB_SUCCESS) return null;
            const result = try allocator.alloc(u8, v.mv_size);
            @memcpy(result, @as([*]u8, @ptrCast(v.mv_data.?))[0..v.mv_size]);
            return result;
        }

        var txn: ?*lmdb.MDB_txn = null;
        var rc = lmdb.mdb_txn_begin(self.env, null, lmdb.MDB_RDONLY, &txn);
        if (rc != lmdb.MDB_SUCCESS) return null;
        defer lmdb.mdb_txn_abort(txn);

        var k: lmdb.MDB_val = .{ .mv_size = key.len, .mv_data = @constCast(key.ptr) };
        var v: lmdb.MDB_val = .{ .mv_size = 0, .mv_data = null };

        rc = lmdb.mdb_get(txn, self.dbi, &k, &v);
        if (rc == lmdb.MDB_NOTFOUND) return null;
        if (rc != lmdb.MDB_SUCCESS) return null;

        const result = try allocator.alloc(u8, v.mv_size);
        @memcpy(result, @as([*]u8, @ptrCast(v.mv_data.?))[0..v.mv_size]);
        return result;
    }

    fn set(self: *LmdbBackend, key: []const u8, value: []const u8) Error!void {
        if (self.active_txn) |txn| {
            var k: lmdb.MDB_val = .{ .mv_size = key.len, .mv_data = @constCast(key.ptr) };
            var v: lmdb.MDB_val = .{ .mv_size = value.len, .mv_data = @constCast(value.ptr) };
            const rc = lmdb.mdb_put(txn, self.dbi, &k, &v, 0);
            if (rc != lmdb.MDB_SUCCESS) return Error.DbWriteFailed;
            return;
        }

        var txn: ?*lmdb.MDB_txn = null;
        var rc = lmdb.mdb_txn_begin(self.env, null, 0, &txn);
        if (rc != lmdb.MDB_SUCCESS) return Error.DbWriteFailed;
        errdefer lmdb.mdb_txn_abort(txn);

        var k: lmdb.MDB_val = .{ .mv_size = key.len, .mv_data = @constCast(key.ptr) };
        var v: lmdb.MDB_val = .{ .mv_size = value.len, .mv_data = @constCast(value.ptr) };

        rc = lmdb.mdb_put(txn, self.dbi, &k, &v, 0);
        if (rc != lmdb.MDB_SUCCESS) return Error.DbWriteFailed;

        rc = lmdb.mdb_txn_commit(txn);
        if (rc != lmdb.MDB_SUCCESS) return Error.DbWriteFailed;
    }

    fn delete(self: *LmdbBackend, key: []const u8) void {
        if (self.active_txn) |txn| {
            var k: lmdb.MDB_val = .{ .mv_size = key.len, .mv_data = @constCast(key.ptr) };
            _ = lmdb.mdb_del(txn, self.dbi, &k, null);
            return;
        }

        var txn: ?*lmdb.MDB_txn = null;
        var rc = lmdb.mdb_txn_begin(self.env, null, 0, &txn);
        if (rc != lmdb.MDB_SUCCESS) return;
        errdefer lmdb.mdb_txn_abort(txn);

        var k: lmdb.MDB_val = .{ .mv_size = key.len, .mv_data = @constCast(key.ptr) };
        rc = lmdb.mdb_del(txn, self.dbi, &k, null);
        if (rc != lmdb.MDB_SUCCESS and rc != lmdb.MDB_NOTFOUND) {
            lmdb.mdb_txn_abort(txn);
            return;
        }

        _ = lmdb.mdb_txn_commit(txn);
    }

    fn beginTx(self: *LmdbBackend) Error!void {
        if (self.active_txn != null) return Error.TxInProgress;
        var txn: ?*lmdb.MDB_txn = null;
        const rc = lmdb.mdb_txn_begin(self.env, null, 0, &txn);
        if (rc != lmdb.MDB_SUCCESS) return Error.DbOpenFailed;
        self.active_txn = txn;
    }

    fn commit(self: *LmdbBackend) Error!void {
        const txn = self.active_txn orelse return Error.NoTxInProgress;
        const rc = lmdb.mdb_txn_commit(txn);
        self.active_txn = null;
        if (rc != lmdb.MDB_SUCCESS) return Error.DbWriteFailed;
    }

    fn rollback(self: *LmdbBackend) void {
        const txn = self.active_txn orelse return;
        lmdb.mdb_txn_abort(txn);
        self.active_txn = null;
    }

    fn deinit(self: *LmdbBackend) void {
        if (self.active_txn) |txn| {
            lmdb.mdb_txn_abort(txn);
            self.active_txn = null;
        }
        lmdb.mdb_env_close(self.env);
        self.allocator.free(self.path);
    }
};

// ------------------------------------------------------------------
// StateStore (unified interface)
// ------------------------------------------------------------------

pub const StateStore = struct {
    allocator: std.mem.Allocator,
    backend: Backend,
    config: Config,

    pub fn initMemory(allocator: std.mem.Allocator, cfg: Config) Error!StateStore {
        const mem_backend = try allocator.create(MemoryBackend);
        mem_backend.* = MemoryBackend.init(allocator);
        return .{
            .allocator = allocator,
            .backend = .{ .memory = mem_backend },
            .config = cfg,
        };
    }

    pub fn initLmdb(allocator: std.mem.Allocator, cfg: Config, path: []const u8) Error!StateStore {
        const lmdb_backend = try allocator.create(LmdbBackend);
        lmdb_backend.* = try LmdbBackend.init(allocator, path);
        return .{
            .allocator = allocator,
            .backend = .{ .lmdb = lmdb_backend },
            .config = cfg,
        };
    }

    pub fn deinit(self: *StateStore) void {
        switch (self.backend) {
            .memory => |b| {
                b.deinit();
                self.allocator.destroy(b);
            },
            .lmdb => |b| {
                b.deinit();
                self.allocator.destroy(b);
            },
        }
        self.* = undefined;
    }

    /// Returns an OWNED copy of the value. Caller MUST free with `allocator.free()`.
    pub fn get(self: *StateStore, key: []const u8) error{OutOfMemory}!?[]const u8 {
        return try self.backend.get(key, self.allocator);
    }

    pub fn set(self: *StateStore, key: []const u8, value: []const u8) Error!void {
        if (key.len > self.config.max_key_len) return Error.KeyTooLong;
        if (value.len > self.config.max_value_len) return Error.ValueTooLong;
        return self.backend.set(key, value);
    }

    pub fn delete(self: *StateStore, key: []const u8) void {
        self.backend.delete(key);
    }

    pub fn beginTx(self: *StateStore) Error!void {
        return self.backend.beginTx();
    }

    pub fn commit(self: *StateStore) Error!void {
        return self.backend.commit();
    }

    pub fn rollback(self: *StateStore) void {
        self.backend.rollback();
    }
};
