//! Structured event log for smart contract execution.
//! Collects events emitted by guest contracts via host_log_event.

const std = @import("std");

const log = std.log.scoped(.event_log);

/// A single emitted event.
pub const Event = struct {
    contract: []const u8,
    name: []const u8,
    data: []const u8,

    pub fn format(
        self: Event,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("Event({s}.{s}: {s})", .{ self.contract, self.name, self.data });
    }
};

/// Buffer that collects events during contract execution.
pub const EventLog = struct {
    allocator: std.mem.Allocator,
    events: std.ArrayList(Event),

    pub fn init(allocator: std.mem.Allocator) EventLog {
        return .{
            .allocator = allocator,
            .events = std.ArrayList(Event).empty,
        };
    }

    pub fn deinit(self: *EventLog) void {
        for (self.events.items) |event| {
            self.allocator.free(event.contract);
            self.allocator.free(event.name);
            self.allocator.free(event.data);
        }
        self.events.deinit(self.allocator);
        self.* = undefined;
    }

    /// Emit a new event.
    pub fn emit(self: *EventLog, contract: []const u8, name: []const u8, data: []const u8) error{OutOfMemory}!void {
        const event = Event{
            .contract = try self.allocator.dupe(u8, contract),
            .name = try self.allocator.dupe(u8, name),
            .data = try self.allocator.dupe(u8, data),
        };
        try self.events.append(self.allocator, event);
        log.info("Event emitted: {s}.{s}: {s}", .{ contract, name, data });
    }

    /// Get all events.
    pub fn getAll(self: *const EventLog) []const Event {
        return self.events.items;
    }

    /// Get events filtered by contract name.
    pub fn getByContract(self: *const EventLog, contract: []const u8, allocator: std.mem.Allocator) error{OutOfMemory}![]Event {
        var filtered = std.ArrayList(Event).empty;
        errdefer filtered.deinit(allocator);
        for (self.events.items) |event| {
            if (std.mem.eql(u8, event.contract, contract)) {
                try filtered.append(allocator, event);
            }
        }
        return filtered.toOwnedSlice(allocator);
    }

    /// Get events filtered by event name.
    pub fn getByName(self: *const EventLog, name: []const u8, allocator: std.mem.Allocator) error{OutOfMemory}![]Event {
        var filtered = std.ArrayList(Event).empty;
        errdefer filtered.deinit(allocator);
        for (self.events.items) |event| {
            if (std.mem.eql(u8, event.name, name)) {
                try filtered.append(allocator, event);
            }
        }
        return filtered.toOwnedSlice(allocator);
    }

    /// Clear all events.
    pub fn clear(self: *EventLog) void {
        for (self.events.items) |event| {
            self.allocator.free(event.contract);
            self.allocator.free(event.name);
            self.allocator.free(event.data);
        }
        self.events.clearRetainingCapacity();
    }

    /// Number of events in the log.
    pub fn len(self: *const EventLog) usize {
        return self.events.items.len;
    }
};
