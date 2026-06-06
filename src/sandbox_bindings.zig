//! Minimal wasmtime C bindings for the sandbox.
//! These declarations are sufficient for loading, instantiating,
//! and executing WebAssembly modules with resource limits.

// ------------------------------------------------------------------
// Opaque handles
// ------------------------------------------------------------------

pub const wasm_config_t = opaque{};
pub const wasm_engine_t = opaque{};
pub const wasm_store_t = opaque{};
pub const wasmtime_context_t = opaque{};
pub const wasmtime_module_t = opaque{};
pub const wasmtime_linker_t = opaque{};
pub const wasmtime_error_t = opaque{};
pub const wasm_trap_t = opaque{};
pub const wasmtime_caller_t = opaque{};
pub const wasm_valtype_t = opaque{};
pub const wasm_functype_t = opaque{};

// ------------------------------------------------------------------
// Value types
// ------------------------------------------------------------------

pub const wasmtime_valkind_t = u8;
pub const WASM_I32: c_int = 0;
pub const WASM_I64: c_int = 1;
pub const WASM_F32: c_int = 2;
pub const WASM_F64: c_int = 3;

pub const wasmtime_anyref_t = extern struct {
    store_id: u64 = 0,
    __private1: u32 = 0,
    __private2: u32 = 0,
};

pub const wasmtime_externref_t = extern struct {
    store_id: u64 = 0,
    __private1: u32 = 0,
    __private2: u32 = 0,
};

pub const wasmtime_v128 = [16]u8;

pub const wasmtime_valunion_t = extern union {
    i32: i32,
    i64: i64,
    f32: f32,
    f64: f64,
    anyref: wasmtime_anyref_t,
    externref: wasmtime_externref_t,
    funcref: wasmtime_func_t,
    v128: wasmtime_v128,
};

pub const wasmtime_val_t = extern struct {
    kind: wasmtime_valkind_t = 0,
    of: wasmtime_valunion_t = @import("std").mem.zeroes(wasmtime_valunion_t),
};

// ------------------------------------------------------------------
// Function / Memory / Extern
// ------------------------------------------------------------------

pub const wasmtime_func_t = extern struct {
    store_id: u64 = 0,
    __private1: u32 = 0,
    __private2: u32 = 0,
};

pub const wasmtime_memory_t = extern struct {
    store_id: u64 = 0,
    __private1: u32 = 0,
    __private2: u32 = 0,
};

pub const wasmtime_extern_kind_t = u8;
pub const WASMTIME_EXTERN_FUNC: c_int = 0;
pub const WASMTIME_EXTERN_GLOBAL: c_int = 1;
pub const WASMTIME_EXTERN_TABLE: c_int = 2;
pub const WASMTIME_EXTERN_MEMORY: c_int = 3;

pub const wasmtime_extern_union_t = extern union {
    func: wasmtime_func_t,
    global: extern struct { store_id: u64 = 0, __private1: u32 = 0, __private2: u32 = 0 },
    table: extern struct { store_id: u64 = 0, __private1: u32 = 0, __private2: u32 = 0 },
    memory: wasmtime_memory_t,
};

pub const wasmtime_extern_t = extern struct {
    kind: wasmtime_extern_kind_t = 0,
    of: wasmtime_extern_union_t = @import("std").mem.zeroes(wasmtime_extern_union_t),
};

pub const wasmtime_instance_t = extern struct {
    store_id: u64 = 0,
    __private1: u32 = 0,
    __private2: u32 = 0,
};

// ------------------------------------------------------------------
// Vectors
// ------------------------------------------------------------------

pub const wasm_byte_vec_t = extern struct {
    size: usize = 0,
    data: [*c]u8 = null,
};
pub const wasm_name_t = wasm_byte_vec_t;

pub const wasm_valtype_vec_t = extern struct {
    size: usize = 0,
    data: [*c]?*wasm_valtype_t = null,
};

// ------------------------------------------------------------------
// Callback type
// ------------------------------------------------------------------

pub const wasmtime_func_callback_t = ?*const fn (
    env: ?*anyopaque,
    caller: ?*wasmtime_caller_t,
    args: [*c]const wasmtime_val_t,
    nargs: usize,
    results: [*c]wasmtime_val_t,
    nresults: usize,
) callconv(.c) ?*wasm_trap_t;

// ------------------------------------------------------------------
// C API functions
// ------------------------------------------------------------------

// Byte vec
pub extern fn wasm_byte_vec_delete([*c]wasm_byte_vec_t) void;

// Valtype vec
pub extern fn wasm_valtype_vec_new_empty(out: [*c]wasm_valtype_vec_t) void;
pub extern fn wasm_valtype_vec_new(out: [*c]wasm_valtype_vec_t, size: usize, data: [*c]?*wasm_valtype_t) void;
pub extern fn wasm_valtype_vec_delete(out: [*c]wasm_valtype_vec_t) void;

// Config
pub extern fn wasm_config_new() ?*wasm_config_t;
pub extern fn wasm_config_delete(?*wasm_config_t) void;
pub extern fn wasmtime_config_consume_fuel_set(?*wasm_config_t, bool) void;
pub extern fn wasmtime_config_max_wasm_stack_set(?*wasm_config_t, usize) void;
pub extern fn wasmtime_config_wasm_bulk_memory_set(?*wasm_config_t, bool) void;
pub extern fn wasmtime_config_wasm_multi_memory_set(?*wasm_config_t, bool) void;
pub extern fn wasmtime_config_wasm_memory64_set(?*wasm_config_t, bool) void;
pub extern fn wasmtime_config_wasm_simd_set(?*wasm_config_t, bool) void;
pub extern fn wasmtime_config_wasm_relaxed_simd_set(?*wasm_config_t, bool) void;
pub extern fn wasmtime_config_wasm_relaxed_simd_deterministic_set(?*wasm_config_t, bool) void;
pub extern fn wasmtime_config_wasm_threads_set(?*wasm_config_t, bool) void;
pub extern fn wasmtime_config_debug_info_set(?*wasm_config_t, bool) void;

// Engine
pub extern fn wasm_engine_new_with_config(?*wasm_config_t) ?*wasm_engine_t;
pub extern fn wasm_engine_delete(?*wasm_engine_t) void;

// Store
pub extern fn wasmtime_store_new(
    engine: ?*wasm_engine_t,
    data: ?*anyopaque,
    finalizer: ?*const fn (?*anyopaque) callconv(.c) void,
) ?*wasm_store_t;
pub extern fn wasmtime_store_limiter(
    store: ?*wasm_store_t,
    memory_size: i64,
    table_elements: i64,
    instances: i64,
    tables: i64,
    memories: i64,
) void;
pub extern fn wasmtime_store_delete(?*wasm_store_t) void;
pub extern fn wasmtime_store_context(store: ?*wasm_store_t) ?*wasmtime_context_t;
pub extern fn wasmtime_context_set_fuel(context: ?*wasmtime_context_t, fuel: u64) ?*wasmtime_error_t;
pub extern fn wasmtime_context_get_fuel(context: ?*wasmtime_context_t, fuel: [*c]u64) ?*wasmtime_error_t;

// Module
pub extern fn wasmtime_module_new(
    engine: ?*wasm_engine_t,
    wasm: [*c]const u8,
    wasm_len: usize,
    ret: [*c]?*wasmtime_module_t,
) ?*wasmtime_error_t;
pub extern fn wasmtime_module_delete(?*wasmtime_module_t) void;

// Linker
pub extern fn wasmtime_linker_new(engine: ?*wasm_engine_t) ?*wasmtime_linker_t;
pub extern fn wasmtime_linker_delete(?*wasmtime_linker_t) void;
pub extern fn wasmtime_linker_define_func(
    linker: ?*wasmtime_linker_t,
    module: [*c]const u8,
    module_len: usize,
    name: [*c]const u8,
    name_len: usize,
    ty: ?*const wasm_functype_t,
    cb: wasmtime_func_callback_t,
    data: ?*anyopaque,
    finalizer: ?*const fn (?*anyopaque) callconv(.c) void,
) ?*wasmtime_error_t;
pub extern fn wasmtime_linker_instantiate(
    linker: ?*const wasmtime_linker_t,
    store: ?*wasmtime_context_t,
    module: ?*const wasmtime_module_t,
    instance: [*c]wasmtime_instance_t,
    trap: [*c]?*wasm_trap_t,
) ?*wasmtime_error_t;

// Caller
pub extern fn wasmtime_caller_context(caller: ?*wasmtime_caller_t) ?*wasmtime_context_t;
pub extern fn wasmtime_caller_export_get(
    caller: ?*wasmtime_caller_t,
    name: [*c]const u8,
    name_len: usize,
    item: [*c]wasmtime_extern_t,
) bool;

// Extern / Memory
pub extern fn wasmtime_extern_delete(val: [*c]wasmtime_extern_t) void;
pub extern fn wasmtime_memory_data(
    store: ?*const wasmtime_context_t,
    memory: [*c]const wasmtime_memory_t,
) [*c]u8;
pub extern fn wasmtime_memory_data_size(
    store: ?*const wasmtime_context_t,
    memory: [*c]const wasmtime_memory_t,
) usize;

// Error / Trap
pub extern fn wasmtime_error_message(error_ptr: ?*const wasmtime_error_t, message: [*c]wasm_name_t) void;
pub extern fn wasmtime_error_delete(?*wasmtime_error_t) void;
pub extern fn wasm_trap_message(trap: ?*wasm_trap_t, message: [*c]wasm_name_t) void;
pub extern fn wasm_trap_delete(?*wasm_trap_t) void;
pub extern fn wasmtime_trap_new(msg: [*c]const u8, msg_len: usize) ?*wasm_trap_t;

// Instance exports
pub extern fn wasmtime_instance_export_get(
    store: ?*wasmtime_context_t,
    instance: [*c]const wasmtime_instance_t,
    name: [*c]const u8,
    name_len: usize,
    item: [*c]wasmtime_extern_t,
) bool;

// Function call
pub extern fn wasmtime_func_call(
    store: ?*wasmtime_context_t,
    func: [*c]const wasmtime_func_t,
    args: [*c]const wasmtime_val_t,
    nargs: usize,
    results: [*c]wasmtime_val_t,
    nresults: usize,
    trap: [*c]?*wasm_trap_t,
) ?*wasmtime_error_t;

// Function types
pub extern fn wasm_valtype_new(kind: wasmtime_valkind_t) ?*wasm_valtype_t;
pub extern fn wasm_valtype_delete(?*wasm_valtype_t) void;
pub extern fn wasm_functype_new(
    params: [*c]wasm_valtype_vec_t,
    results: [*c]wasm_valtype_vec_t,
) ?*wasm_functype_t;
pub extern fn wasm_functype_delete(?*wasm_functype_t) void;
