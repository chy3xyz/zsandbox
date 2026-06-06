//! Gas metering with operation-type pricing.
//! Wraps the instruction-level fuel meter and adds host-call gas costs.

const std = @import("std");
const c = @import("sandbox_bindings.zig");
const fuel = @import("fuel_meter.zig");

const log = std.log.scoped(.gas_meter);

pub const Error = error{
    GasExhausted,
    GasCheckFailed,
};

/// Per-operation-type gas costs.
/// Inspired by Ethereum EVM but adapted for WASM host calls.
pub const GasPriceTable = struct {
    sload: u64 = 200,      // storage read
    sstore: u64 = 20_000,  // storage write
    sstore_modify: u64 = 5_000, // modify existing storage
    call: u64 = 700,       // contract call
    create: u64 = 32_000,  // contract creation
    log: u64 = 375,        // event log (per topic)
    memory_page: u64 = 6_400, // memory expansion (per 64KB page)
    keccak256_base: u64 = 30,
    keccak256_word: u64 = 6,  // per 32-byte word
    sha256_base: u64 = 60,
    sha256_word: u64 = 12,     // per 32-byte word

    pub const default: GasPriceTable = .{};
};

/// Tracks both instruction fuel and host-call gas.
pub const GasMeter = struct {
    fuel_meter: fuel.FuelMeter,
    prices: GasPriceTable,
    host_gas_consumed: u64,
    total_gas_limit: u64,

    pub fn init(ctx: ?*c.wasmtime_context_t, prices: GasPriceTable, gas_limit: u64) Error!GasMeter {
        const fm = fuel.FuelMeter.init(ctx) catch |err| {
            switch (err) {
                error.FuelCheckFailed => return error.GasCheckFailed,
                error.FuelExhausted => return error.GasExhausted,
            }
        };
        // Scale fuel to gas: 1 fuel ≈ 1 gas for compute, but host ops are priced separately
        return .{
            .fuel_meter = fm,
            .prices = prices,
            .host_gas_consumed = 0,
            .total_gas_limit = gas_limit,
        };
    }

    /// Charge gas for a host operation.
    pub fn charge(self: *GasMeter, amount: u64) Error!void {
        const total = self.host_gas_consumed + amount;
        if (total > self.total_gas_limit) {
            log.err("Gas exhausted: host_gas={d} + charge={d} > limit={d}", .{
                self.host_gas_consumed, amount, self.total_gas_limit,
            });
            return Error.GasExhausted;
        }
        self.host_gas_consumed = total;
    }

    /// Convenience wrappers for common operations.
    pub fn chargeSload(self: *GasMeter) Error!void {
        return self.charge(self.prices.sload);
    }

    pub fn chargeSstore(self: *GasMeter, is_new: bool) Error!void {
        return self.charge(if (is_new) self.prices.sstore else self.prices.sstore_modify);
    }

    pub fn chargeCall(self: *GasMeter) Error!void {
        return self.charge(self.prices.call);
    }

    pub fn chargeLog(self: *GasMeter, topic_count: u64) Error!void {
        return self.charge(self.prices.log * topic_count);
    }

    pub fn chargeKeccak256(self: *GasMeter, data_len: u64) Error!void {
        const words = (data_len + 31) / 32;
        return self.charge(self.prices.keccak256_base + self.prices.keccak256_word * words);
    }

    pub fn chargeSha256(self: *GasMeter, data_len: u64) Error!void {
        const words = (data_len + 31) / 32;
        return self.charge(self.prices.sha256_base + self.prices.sha256_word * words);
    }

    /// Total gas consumed = fuel-based compute gas + host-call gas.
    pub fn totalConsumed(self: *const GasMeter) u64 {
        // Fuel remaining is tracked separately; we approximate compute gas
        // as the fuel actually consumed (1:1 mapping for simplicity).
        return self.fuel_meter.total_consumed + self.host_gas_consumed;
    }

    /// Remaining gas.
    pub fn remaining(self: *GasMeter) u64 {
        const used = self.totalConsumed();
        if (used >= self.total_gas_limit) return 0;
        return self.total_gas_limit - used;
    }

    /// Set a new gas limit (used for cross-contract call budget transfer).
    pub fn setLimit(self: *GasMeter, limit: u64) void {
        self.total_gas_limit = limit;
    }

    /// Reset all gas budgets.
    pub fn reset(self: *GasMeter) Error!void {
        try self.fuel_meter.reset();
        self.host_gas_consumed = 0;
    }

    /// Call before guest function invocation.
    pub fn beforeCall(self: *GasMeter) Error!u64 {
        return self.fuel_meter.beforeCall();
    }

    /// Call after guest function invocation.
    pub fn afterCall(self: *GasMeter, fuel_before: u64) Error!u64 {
        return self.fuel_meter.afterCall(fuel_before);
    }
};
