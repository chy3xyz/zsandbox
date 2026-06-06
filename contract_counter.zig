// contract_counter.zig
// Guest contract demonstrating storage operations with gas metering.

const std = @import("std");

// ------------------------------------------------------------------
// Host imports from env module
// ------------------------------------------------------------------

extern fn host_log(ptr: u32, len: u32) void;
extern fn host_log_event(name_ptr: u32, name_len: u32, data_ptr: u32, data_len: u32) void;
extern fn storage_read(key_ptr: u32, key_len: u32, val_ptr: u32, val_max: u32) i32;
extern fn storage_write(key_ptr: u32, key_len: u32, val_ptr: u32, val_len: u32) void;

// ------------------------------------------------------------------
// Helpers
// ------------------------------------------------------------------

fn log(msg: []const u8) void {
    host_log(@intCast(@intFromPtr(msg.ptr)), @intCast(msg.len));
}

fn emitEvent(name: []const u8, data: []const u8) void {
    host_log_event(
        @intCast(@intFromPtr(name.ptr)),
        @intCast(name.len),
        @intCast(@intFromPtr(data.ptr)),
        @intCast(data.len),
    );
}

fn readCounter() i32 {
    const key = "counter";
    var buf: [32]u8 = undefined;
    const n = storage_read(
        @intCast(@intFromPtr(key.ptr)),
        @intCast(key.len),
        @intCast(@intFromPtr(&buf)),
        @intCast(buf.len),
    );
    if (n <= 0) return 0;

    // Parse ASCII integer from buf[0..@as(usize, @intCast(n))]
    var val: i32 = 0;
    var i: usize = 0;
    const limit = @as(usize, @intCast(n));
    while (i < limit) : (i += 1) {
        const c = buf[i];
        if (c < '0' or c > '9') break;
        val = val * 10 + @as(i32, c - '0');
    }
    return val;
}

fn writeCounter(val: i32) void {
    const key = "counter";
    var buf: [32]u8 = undefined;

    // Format integer as ASCII (right-aligned in buf)
    var i: usize = 31;
    var v = val;
    if (v == 0) {
        buf[i] = '0';
        i -= 1;
    } else {
        while (v > 0) {
            buf[i] = @intCast('0' + @rem(v, 10));
            v = @divTrunc(v, 10);
            i -= 1;
        }
    }
    const start = i + 1;
    const len = 32 - start;

    storage_write(
        @intCast(@intFromPtr(key.ptr)),
        @intCast(key.len),
        @intCast(@intFromPtr(&buf[start])),
        @intCast(len),
    );
}

// ------------------------------------------------------------------
// Exports to host
// ------------------------------------------------------------------

/// Read counter from storage, increment, write back, log result.
export fn increment() i32 {
    const old_val = readCounter();
    const new_val = old_val + 1;
    writeCounter(new_val);

    var msg_buf: [64]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "counter: {d} -> {d}", .{ old_val, new_val }) catch "counter updated";
    log(msg);

    var event_buf: [64]u8 = undefined;
    const event_data = std.fmt.bufPrint(&event_buf, "old={d},new={d}", .{ old_val, new_val }) catch "updated";
    emitEvent("Incremented", event_data);

    return new_val;
}

// ------------------------------------------------------------------
// Panic handler
// ------------------------------------------------------------------

pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    _ = msg;
    while (true) {}
}
