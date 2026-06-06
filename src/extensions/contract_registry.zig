//! Contract registry: deploy, manage, and dispatch cross-contract calls.
//! Each contract has its own Sandbox + StateStore.
//! Gas is shared across calls: caller accumulates callee's consumed gas.

const std = @import("std");
const Sandbox = @import("../sandbox.zig").Sandbox;
const StateStore = @import("state_store.zig").StateStore;
const EventLog = @import("event_log.zig").EventLog;
const limits = @import("../limits.zig");

const log = std.log.scoped(.contract_registry);

pub const Error = error{
    OutOfMemory,
    ContractNotFound,
    ContractAlreadyDeployed,
    DeployFailed,
    CallFailed,
    CallDepthExceeded,
    ReentrancyDetected,
};

/// Global registry reference for host callbacks.
/// Set by the host after creating the registry.
pub var g_registry: ?*ContractRegistry = null;

/// Global call stack for cross-contract cycle detection.
/// Tracks addresses currently in an active cross-contract call chain.
/// Used by hostCallContractCallback to detect A->B->A reentrancy.
pub var g_call_stack: ?*std.ArrayList([]const u8) = null;

/// A deployed contract entry.
pub const ContractEntry = struct {
    sandbox: *Sandbox,
    state: *StateStore,
};

/// Registry of deployed smart contracts.
pub const ContractRegistry = struct {
    allocator: std.mem.Allocator,
    contracts: std.StringHashMap(*ContractEntry),
    event_log: EventLog,
    mutex: std.atomic.Mutex,

    pub fn init(allocator: std.mem.Allocator) ContractRegistry {
        if (g_call_stack == null) {
            const stack = std.heap.page_allocator.create(std.ArrayList([]const u8)) catch unreachable;
            stack.* = std.ArrayList([]const u8).empty;
            g_call_stack = stack;
        }
        return .{
            .allocator = allocator,
            .contracts = std.StringHashMap(*ContractEntry).init(allocator),
            .event_log = EventLog.init(allocator),
            .mutex = .unlocked,
        };
    }

    fn lock(self: *ContractRegistry) void {
        while (!self.mutex.tryLock()) {
            std.atomic.spinLoopHint();
        }
    }

    fn unlock(self: *ContractRegistry) void {
        self.mutex.unlock();
    }

    pub fn deinit(self: *ContractRegistry) void {
        var it = self.contracts.valueIterator();
        while (it.next()) |entry_ptr| {
            const entry = entry_ptr.*;
            entry.sandbox.deinit();
            self.allocator.destroy(entry.sandbox);
            entry.state.deinit();
            self.allocator.destroy(entry.state);
            self.allocator.destroy(entry);
        }
        self.contracts.deinit();
        self.event_log.deinit();
        if (g_call_stack) |stack| {
            stack.deinit(std.heap.page_allocator);
            std.heap.page_allocator.destroy(stack);
            g_call_stack = null;
        }
        self.* = undefined;
    }

    /// Deploy a contract from WASM bytes.
    pub fn deploy(
        self: *ContractRegistry,
        name: []const u8,
        wasm_bytes: []const u8,
        allowed_imports: ?[]const []const u8,
        allowed_exports: ?[]const []const u8,
        required_exports: ?[]const []const u8,
    ) Error!void {
        self.lock();
        defer self.unlock();

        if (self.contracts.contains(name)) {
            log.err("Contract already deployed: {s}", .{name});
            return Error.ContractAlreadyDeployed;
        }

        const sb = try self.allocator.create(Sandbox);
        errdefer self.allocator.destroy(sb);

        sb.* = Sandbox.init(
            self.allocator,
            wasm_bytes,
            allowed_imports,
            allowed_exports,
            required_exports,
        ) catch |err| {
            log.err("Failed to create sandbox for contract {s}: {s}", .{ name, @errorName(err) });
            return Error.DeployFailed;
        };
        errdefer sb.deinit();

        const state = try self.allocator.create(StateStore);
        errdefer self.allocator.destroy(state);
        state.* = StateStore.initMemory(self.allocator, .{}) catch |err| {
            log.err("Failed to create state for contract {s}: {s}", .{ name, @errorName(err) });
            return Error.DeployFailed;
        };
        errdefer state.deinit();

        sb.attachState(state);
        sb.setAddress(name);

        const entry = try self.allocator.create(ContractEntry);
        entry.* = .{
            .sandbox = sb,
            .state = state,
        };

        try self.contracts.put(name, entry);
        log.info("Contract deployed: {s}", .{name});
    }

    /// Call a function on a contract.
    /// For direct calls (no cross-contract), caller_name and target_name can be the same.
    pub fn call(
        self: *ContractRegistry,
        caller_name: []const u8,
        target_name: []const u8,
        func: []const u8,
        args: []const i32,
    ) Error!i32 {
        self.lock();
        const caller_entry = self.contracts.get(caller_name) orelse {
            self.unlock();
            log.err("Caller contract not found: {s}", .{caller_name});
            return Error.ContractNotFound;
        };
        const target_entry = self.contracts.get(target_name) orelse {
            self.unlock();
            log.err("Target contract not found: {s}", .{target_name});
            return Error.ContractNotFound;
        };
        // Copy sandbox pointers before releasing lock
        const caller_sb = caller_entry.sandbox;
        const target_sb = target_entry.sandbox;
        self.unlock();

        // For cross-contract calls, charge CALL gas and manage call stack
        const is_cross = !std.mem.eql(u8, caller_name, target_name);
        if (is_cross) {
            // Charge CALL gas on caller
            caller_sb.gas_meter.chargeCall() catch {
                log.err("Out of gas for cross-contract call: {s} -> {s}", .{ caller_name, target_name });
                return Error.CallFailed;
            };

            // Push call frame
            caller_sb.call_stack.push(target_name, func) catch |err| {
                log.err("Call stack push failed: {s}", .{@errorName(err)});
                return switch (err) {
                    error.CallDepthExceeded => Error.CallDepthExceeded,
                    error.ReentrancyDetected => Error.ReentrancyDetected,
                    else => Error.CallFailed,
                };
            };
            defer caller_sb.call_stack.pop();

            // Cap target's gas limit to caller's remaining gas
            const caller_remaining = caller_sb.remainingGas();
            target_sb.setGasLimit(caller_remaining);
            log.info("Cross-call: {s}.{s} -> {s}.{s}  gas_limit={d}", .{
                caller_name, func, target_name, func, caller_remaining,
            });
        }

        // Execute target function
        const result = target_sb.call(func, args) catch |err| {
            log.err("Contract call failed: {s}.{s} error={s}", .{ target_name, func, @errorName(err) });
            return Error.CallFailed;
        };

        if (is_cross) {
            // Accumulate callee's consumed gas into caller's gas meter
            const callee_consumed = target_sb.totalGasConsumed();
            log.info("Cross-call completed: callee consumed={d}", .{callee_consumed});
        }

        return result;
    }

    /// Get a contract's sandbox by name (for host callbacks).
    pub fn get(self: *ContractRegistry, name: []const u8) ?*ContractEntry {
        self.lock();
        defer self.unlock();
        return self.contracts.get(name);
    }
};
