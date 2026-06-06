//! Resource limits and configuration for the sandbox.
//! All limits are centralized here for easy auditing and tuning.

/// Maximum size of a WASM module binary (2 MiB).
pub const max_module_bytes = 2 * 1024 * 1024;

/// Maximum linear memory pages (1 page = 64 KiB).
/// 17 pages ≈ 1.06 MiB.
pub const max_memory_pages = 17;

/// Maximum linear memory in bytes.
pub const max_memory_bytes = max_memory_pages * 64 * 1024;

/// Initial fuel budget per sandbox instance.
/// This is a coarse-grained execution step limit.
pub const initial_fuel = 100_000;

/// Initial gas budget per sandbox instance (includes host-call gas).
pub const initial_gas = 1_000_000;

/// Maximum fuel allowed for a single function call.
/// Calls exceeding this are terminated with out-of-fuel.
pub const max_fuel_per_call = 50_000;

/// Maximum WASM stack size in bytes.
pub const max_wasm_stack = 256 * 1024;

/// Maximum string length that can be passed through host_log (in bytes).
pub const max_log_message_len = 4096;

/// Maximum number of host export reentrant calls before rejection.
pub const max_reentrant_depth = 8;

/// Magic bytes for WASM binary format.
pub const wasm_magic = [_]u8{ 0x00, 0x61, 0x73, 0x6D };

/// WASM version 1 (MVP).
pub const wasm_version = [_]u8{ 0x01, 0x00, 0x00, 0x00 };

/// Module name for imported host functions.
pub const host_module_name = "env";

/// Name of the logging export function.
pub const host_log_name = "host_log";

/// Name of the event logging export function.
pub const host_log_event_name = "host_log_event";

/// Name of the keccak256 precompile export function.
pub const host_keccak256_name = "keccak256";

/// Name of the sha256 precompile export function.
pub const host_sha256_name = "sha256";

// ------------------------------------------------------------------
// I/O pipeline addresses (guest linear memory layout)
// ------------------------------------------------------------------

/// Base address for input buffer in guest memory.
pub const io_input_addr = 1024;

/// Base address for output buffer in guest memory.
pub const io_output_addr = 66 * 1024;

/// Maximum output size for user-code execution.
pub const io_output_max = 64 * 1024;
