//! Fuel metering for WASM execution.
//! Provides precise pre/post-call fuel accounting and enforces per-call limits.

const std = @import("std");
const c = @import("sandbox_bindings.zig");
const limits = @import("limits.zig");

const log = std.log.scoped(.fuel_meter);

pub const Error = error{
    FuelExhausted,
    FuelCheckFailed,
};

/// Tracks fuel consumption for a single sandbox instance.
pub const FuelMeter = struct {
    context: ?*c.wasmtime_context_t,
    total_consumed: u64,
    call_count: u64,

    pub fn init(ctx: ?*c.wasmtime_context_t) Error!FuelMeter {
        // Set the initial fuel budget on the store.
        const err = c.wasmtime_context_set_fuel(ctx, limits.initial_fuel);
        if (err != null) {
            log.err("Failed to set initial fuel: {d}", .{limits.initial_fuel});
            c.wasmtime_error_delete(err);
            return Error.FuelCheckFailed;
        }

        return .{
            .context = ctx,
            .total_consumed = 0,
            .call_count = 0,
        };
    }

    /// Call this immediately before invoking a guest function.
    /// Returns the fuel available before the call.
    pub fn beforeCall(self: *FuelMeter) Error!u64 {
        var fuel_before: u64 = 0;
        const err = c.wasmtime_context_get_fuel(self.context, &fuel_before);
        if (err != null) {
            c.wasmtime_error_delete(err);
            return Error.FuelCheckFailed;
        }

        if (fuel_before == 0) {
            log.err("Fuel exhausted before call", .{});
            return Error.FuelExhausted;
        }

        return fuel_before;
    }

    /// Call this immediately after a guest function returns.
    /// Returns the fuel consumed by the call.
    pub fn afterCall(self: *FuelMeter, fuel_before: u64) Error!u64 {
        var fuel_after: u64 = 0;
        const err = c.wasmtime_context_get_fuel(self.context, &fuel_after);
        if (err != null) {
            c.wasmtime_error_delete(err);
            return Error.FuelCheckFailed;
        }

        const consumed = fuel_before - fuel_after;
        self.total_consumed += consumed;
        self.call_count += 1;

        if (consumed > limits.max_fuel_per_call) {
            log.err("Call exceeded fuel limit: consumed={d} max={d}", .{ consumed, limits.max_fuel_per_call });
            return Error.FuelExhausted;
        }

        log.debug("Fuel consumed this call: {d}, remaining: {d}", .{ consumed, fuel_after });
        return consumed;
    }

    /// Get remaining fuel in the store.
    pub fn remaining(self: *FuelMeter) u64 {
        var fuel: u64 = 0;
        const err = c.wasmtime_context_get_fuel(self.context, &fuel);
        if (err != null) {
            c.wasmtime_error_delete(err);
            return 0;
        }
        return fuel;
    }

    /// Reset fuel to the initial budget.
    pub fn reset(self: *FuelMeter) Error!void {
        const err = c.wasmtime_context_set_fuel(self.context, limits.initial_fuel);
        if (err != null) {
            c.wasmtime_error_delete(err);
            return Error.FuelCheckFailed;
        }
        self.total_consumed = 0;
        self.call_count = 0;
    }
};
