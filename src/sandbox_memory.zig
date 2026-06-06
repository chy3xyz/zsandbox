//! Safe accessor for guest (WASM) linear memory.
//! All host callbacks MUST route memory access through this module
//! to enforce bounds checking and prevent TOCTOU issues.

const std = @import("std");
const assert = std.debug.assert;
const c = @import("sandbox_bindings.zig");
const limits = @import("limits.zig");

const log = std.log.scoped(.sandbox_memory);

pub const Error = error{
    OutOfBounds,
    NullPointer,
    MessageTooLong,
};

/// Context held per-sandbox to access guest memory safely.
pub const SandboxMemory = struct {
    context: ?*c.wasmtime_context_t,

    pub fn init(ctx: ?*c.wasmtime_context_t) SandboxMemory {
        return .{ .context = ctx };
    }

    /// Read a slice of bytes from guest memory.
    /// Returns an error if the range is out of bounds.
    pub fn readBytes(self: SandboxMemory, ptr: u32, len: u32, max_len: u32) Error![]const u8 {
        if (len == 0) return &[_]u8{};
        if (len > max_len) return Error.MessageTooLong;

        const mem = try self.getMemory();
        const data_size = c.wasmtime_memory_data_size(self.context, &mem);
        const data: [*]u8 = c.wasmtime_memory_data(self.context, &mem);

        const end = @as(u64, ptr) + @as(u64, len);
        if (end > data_size) {
            log.err("readBytes OOB: ptr={d} len={d} mem={d}", .{ ptr, len, data_size });
            return Error.OutOfBounds;
        }

        return data[ptr..@intCast(end)];
    }

    /// Read a null-terminated or length-delimited string from guest memory.
    pub fn readString(self: SandboxMemory, ptr: u32, len: u32, max_len: u32) Error![]const u8 {
        const bytes = try self.readBytes(ptr, len, max_len);
        // Basic UTF-8 validation is optional but recommended for production.
        // For now we accept any byte sequence.
        return bytes;
    }

    /// Write bytes into guest memory.
    pub fn writeBytes(self: SandboxMemory, ptr: u32, data: []const u8) Error!void {
        if (data.len == 0) return;

        const mem = try self.getMemory();
        const mem_size = c.wasmtime_memory_data_size(self.context, &mem);
        const mem_data: [*]u8 = c.wasmtime_memory_data(self.context, &mem);

        const end = @as(u64, ptr) + @as(u64, data.len);
        if (end > mem_size) {
            log.err("writeBytes OOB: ptr={d} len={d} mem={d}", .{ ptr, data.len, mem_size });
            return Error.OutOfBounds;
        }

        @memcpy(mem_data[ptr..@intCast(end)], data);
    }

    /// Get the size of guest linear memory in bytes.
    pub fn size(self: SandboxMemory) u64 {
        const mem = self.getMemory() catch return 0;
        return c.wasmtime_memory_data_size(self.context, &mem);
    }

    /// Internal: retrieve the default exported memory of the guest.
    fn getMemory(_: SandboxMemory) Error!c.wasmtime_memory_t {
        // Note: This is a convenience for single-memory modules.
        // For multi-memory, caller should specify which memory.
        const item: c.wasmtime_extern_t = undefined;
        _ = item;

        // We need the caller context here, but for host exports
        // the caller provides its own context. In practice, this
        // function is called from within a callback where we have
        // the caller handle. The caller wrapper passes the context
        // directly, so we use the stored context to look up memory.
        //
        // For the general case (outside callbacks), we need the
        // instance handle. This simplified version assumes the
        // callback pattern where context is sufficient.

        // Actually, wasmtime_caller_export_get needs a caller handle,
        // but we only have the store context here. For the public
        // SandboxMemory API, we need to look up memory differently.
        //
        // We'll look up memory via the instance in the Sandbox
        // struct. For now, this is a placeholder.
        _ = item;
        @panic("SandboxMemory.getMemory: use the callback-bound accessor");
    }
};

/// Callback-bound memory accessor.
/// Created inside a host callback where we have the caller handle.
pub const CallbackMemory = struct {
    caller: ?*c.wasmtime_caller_t,
    context: ?*c.wasmtime_context_t,

    pub fn init(caller_handle: ?*c.wasmtime_caller_t) CallbackMemory {
        return .{
            .caller = caller_handle,
            .context = c.wasmtime_caller_context(caller_handle),
        };
    }

    pub fn readBytes(self: CallbackMemory, ptr: u32, len: u32, max_len: u32) Error![]const u8 {
        if (len == 0) return &[_]u8{};
        if (len > max_len) return Error.MessageTooLong;

        var item: c.wasmtime_extern_t = undefined;
        const found = c.wasmtime_caller_export_get(self.caller, "memory", "memory".len, &item);
        if (!found or item.kind != c.WASMTIME_EXTERN_MEMORY) {
            log.err("readBytes: memory export not found", .{});
            return Error.NullPointer;
        }
        defer c.wasmtime_extern_delete(&item);

        const mem = item.of.memory;
        const data_size = c.wasmtime_memory_data_size(self.context, &mem);
        const data: [*]u8 = c.wasmtime_memory_data(self.context, &mem);

        const end = @as(u64, ptr) + @as(u64, len);
        if (end > data_size) {
            log.err("readBytes OOB: ptr={d} len={d} mem={d}", .{ ptr, len, data_size });
            return Error.OutOfBounds;
        }

        return data[ptr..@intCast(end)];
    }

    pub fn readString(self: CallbackMemory, ptr: u32, len: u32, max_len: u32) Error![]const u8 {
        return self.readBytes(ptr, len, max_len);
    }

    pub fn size(self: CallbackMemory) u64 {
        var item: c.wasmtime_extern_t = undefined;
        const found = c.wasmtime_caller_export_get(self.caller, "memory", "memory".len, &item);
        if (!found or item.kind != c.WASMTIME_EXTERN_MEMORY) return 0;
        defer c.wasmtime_extern_delete(&item);
        return c.wasmtime_memory_data_size(self.context, &item.of.memory);
    }
};
