// contract_composite.zig
// Guest contract that demonstrates cross-contract calls.

const std = @import("std");

// ------------------------------------------------------------------
// Host imports from env module
// ------------------------------------------------------------------

extern fn host_log(ptr: u32, len: u32) void;
extern fn host_log_event(name_ptr: u32, name_len: u32, data_ptr: u32, data_len: u32) void;
extern fn call_contract(
    addr_ptr: u32,
    addr_len: u32,
    func_ptr: u32,
    func_len: u32,
    arg0: i32,
    arg1: i32,
) i32;

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

// ------------------------------------------------------------------
// Exports to host
// ------------------------------------------------------------------

/// Call math contract's sandbox_add via cross-contract call.
export fn add_via_math(a: i32, b: i32) i32 {
    const addr = "math";
    const func = "sandbox_add";

    var msg_buf: [64]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "composite: calling math.add({d}, {d})", .{ a, b }) catch "composite: calling math";
    log(msg);

    var init_buf: [64]u8 = undefined;
    const init_data = std.fmt.bufPrint(&init_buf, "target=math,func={s},a={d},b={d}", .{ func, a, b }) catch "cross-call";
    emitEvent("CrossCallInitiated", init_data);

    const result = call_contract(
        @intCast(@intFromPtr(addr.ptr)),
        @intCast(addr.len),
        @intCast(@intFromPtr(func.ptr)),
        @intCast(func.len),
        a,
        b,
    );

    var result_buf: [64]u8 = undefined;
    const result_msg = std.fmt.bufPrint(&result_buf, "composite: math.add returned {d}", .{result}) catch "composite: got result";
    log(result_msg);

    var complete_buf: [64]u8 = undefined;
    const complete_data = std.fmt.bufPrint(&complete_buf, "result={d}", .{result}) catch "done";
    emitEvent("CrossCallCompleted", complete_data);

    return result;
}

// ------------------------------------------------------------------
// Panic handler
// ------------------------------------------------------------------

pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    _ = msg;
    while (true) {}
}
