//! User-code execution pipeline: input/output buffers + wall-clock timeout.

const std = @import("std");
const log = std.log.scoped(.io_pipeline);

pub const Error = error{
    OutOfMemory,
    InputTooLarge,
    OutputTooLarge,
    TimedOut,
};

pub const Config = struct {
    max_input: usize = 64 * 1024,
    max_output: usize = 64 * 1024,
};

/// Per-sandbox I/O channel for user code execution.
pub const IoPipeline = struct {
    allocator: std.mem.Allocator,
    input: []u8,
    output: []u8,
    output_written: usize,
    config: Config,

    pub fn init(allocator: std.mem.Allocator, cfg: Config) Error!IoPipeline {
        const input = try allocator.alloc(u8, cfg.max_input);
        errdefer allocator.free(input);
        const output = try allocator.alloc(u8, cfg.max_output);
        errdefer allocator.free(output);

        return .{
            .allocator = allocator,
            .input = input,
            .output = output,
            .output_written = 0,
            .config = cfg,
        };
    }

    pub fn deinit(self: *IoPipeline) void {
        self.allocator.free(self.input);
        self.allocator.free(self.output);
        self.* = undefined;
    }

    /// Set the input payload before calling guest code.
    pub fn setInput(self: *IoPipeline, data: []const u8) Error!void {
        if (data.len > self.config.max_input) return Error.InputTooLarge;
        @memcpy(self.input[0..data.len], data);
    }

    /// Get the output payload after guest code returns.
    pub fn getOutput(self: *const IoPipeline) []const u8 {
        return self.output[0..self.output_written];
    }

    /// Host callback: guest reads input.
    pub fn hostReadInput(self: *IoPipeline, dst_ptr: [*]u8, max_len: u32) u32 {
        const len = @min(max_len, @as(u32, @intCast(self.input.len)));
        @memcpy(dst_ptr[0..len], self.input[0..len]);
        return len;
    }

    /// Host callback: guest writes output.
    pub fn hostWriteOutput(self: *IoPipeline, src_ptr: [*]const u8, len: u32) Error!void {
        if (len > self.config.max_output) return Error.OutputTooLarge;
        @memcpy(self.output[0..len], src_ptr[0..len]);
        self.output_written = len;
    }
};

// ------------------------------------------------------------------
// Wall-clock watchdog
// ------------------------------------------------------------------

pub const Watchdog = struct {
    timeout_ms: u64,
    start_time_ms: i64,

    pub fn init(timeout_ms: u64) Watchdog {
        return .{
            .timeout_ms = timeout_ms,
            .start_time_ms = nowMs(),
        };
    }

    /// Check if the watchdog has expired based on wall-clock time.
    pub fn isExpired(self: *const Watchdog) bool {
        const elapsed_ms = nowMs() - self.start_time_ms;
        return elapsed_ms > @as(i64, @intCast(self.timeout_ms));
    }

    pub fn check(self: *const Watchdog) Error!void {
        if (self.isExpired()) {
            log.err("Watchdog timeout after {d}ms", .{self.timeout_ms});
            return Error.TimedOut;
        }
    }

    /// Reset the watchdog timer.
    pub fn reset(self: *Watchdog) void {
        self.start_time_ms = nowMs();
    }
};

/// Get current time in milliseconds using monotonic clock.
fn nowMs() i64 {
    var ts: std.c.timespec = undefined;
    const rc = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    if (rc != 0) return 0;
    return @as(i64, ts.sec) * 1000 + @divTrunc(ts.nsec, std.time.ns_per_ms);
}
