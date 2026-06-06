//! Minimal LMDB C bindings for persistent state storage.

// Error codes
pub const MDB_SUCCESS: c_int = 0;
pub const MDB_NOTFOUND: c_int = -30798;

// Flags
pub const MDB_NOSUBDIR: c_uint = 0x4000;
pub const MDB_RDONLY: c_uint = 0x20000;
pub const MDB_CREATE: c_uint = 0x40000;

// Opaque handles
pub const MDB_env = opaque {};
pub const MDB_txn = opaque {};
pub const MDB_dbi = u32;

pub const MDB_val = extern struct {
    mv_size: usize,
    mv_data: ?*anyopaque,
};

pub extern fn mdb_env_create(env: ?*?*MDB_env) c_int;
pub extern fn mdb_env_open(env: ?*MDB_env, path: [*:0]const u8, flags: c_uint, mode: c_int) c_int;
pub extern fn mdb_env_close(env: ?*MDB_env) void;
pub extern fn mdb_env_set_mapsize(env: ?*MDB_env, size: usize) c_int;

pub extern fn mdb_txn_begin(env: ?*MDB_env, parent: ?*MDB_txn, flags: c_uint, txn: ?*?*MDB_txn) c_int;
pub extern fn mdb_txn_commit(txn: ?*MDB_txn) c_int;
pub extern fn mdb_txn_abort(txn: ?*MDB_txn) void;

pub extern fn mdb_dbi_open(txn: ?*MDB_txn, name: ?[*:0]const u8, flags: c_uint, dbi: ?*MDB_dbi) c_int;

pub extern fn mdb_put(txn: ?*MDB_txn, dbi: MDB_dbi, key: ?*MDB_val, data: ?*MDB_val, flags: c_uint) c_int;
pub extern fn mdb_get(txn: ?*MDB_txn, dbi: MDB_dbi, key: ?*MDB_val, data: ?*MDB_val) c_int;
pub extern fn mdb_del(txn: ?*MDB_txn, dbi: MDB_dbi, key: ?*MDB_val, data: ?*MDB_val) c_int;

pub extern fn mdb_strerror(err: c_int) [*:0]const u8;
