const std = @import("std");

// ------------------------------------------------------------------
// Imports from host (white-listed interface)
// ------------------------------------------------------------------

extern fn host_log(ptr: u32, len: u32) void;

// ------------------------------------------------------------------
// Exports to host
// ------------------------------------------------------------------

/// Add two i32 values and log the call.
export fn sandbox_add(a: i32, b: i32) i32 {
    const msg = "sandbox: add called";
    host_log(@intCast(@intFromPtr(msg.ptr)), @intCast(msg.len));
    return a + b;
}

/// Intentional unreachable for crash-isolation testing.
export fn sandbox_panic() void {
    unreachable;
}

// ------------------------------------------------------------------
// Panic handler: prevents host crash on guest panic.
// ------------------------------------------------------------------

pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    _ = msg;
    // Loop forever instead of aborting, so wasmtime can trap cleanly.
    while (true) {}
}
