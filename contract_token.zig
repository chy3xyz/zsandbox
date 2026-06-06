// contract_token.zig
// Simplified ERC-20 style token contract.

const std = @import("std");

// ------------------------------------------------------------------
// Host imports
// ------------------------------------------------------------------

extern fn host_log(ptr: u32, len: u32) void;
extern fn host_log_event(name_ptr: u32, name_len: u32, data_ptr: u32, data_len: u32) void;
extern fn storage_read(key_ptr: u32, key_len: u32, val_ptr: u32, val_max: u32) i32;
extern fn storage_write(key_ptr: u32, key_len: u32, val_ptr: u32, val_len: u32) void;

// ------------------------------------------------------------------
// Constants
// ------------------------------------------------------------------

const OWNER = "owner";

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

fn readBalance(addr: []const u8) i32 {
    var key_buf: [64]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "balance:{s}", .{addr}) catch return 0;
    
    var val_buf: [32]u8 = undefined;
    const n = storage_read(
        @intCast(@intFromPtr(key.ptr)),
        @intCast(key.len),
        @intCast(@intFromPtr(&val_buf)),
        @intCast(val_buf.len),
    );
    if (n <= 0) return 0;
    return parseInt(val_buf[0..@as(usize, @intCast(n))]);
}

fn writeBalance(addr: []const u8, val: i32) void {
    var key_buf: [64]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "balance:{s}", .{addr}) catch return;
    
    var val_buf: [32]u8 = undefined;
    const val_str = formatInt(&val_buf, val);
    
    storage_write(
        @intCast(@intFromPtr(key.ptr)),
        @intCast(key.len),
        @intCast(@intFromPtr(val_str.ptr)),
        @intCast(val_str.len),
    );
}

fn readTotalSupply() i32 {
    const key = "totalSupply";
    var val_buf: [32]u8 = undefined;
    const n = storage_read(
        @intCast(@intFromPtr(key.ptr)),
        @intCast(key.len),
        @intCast(@intFromPtr(&val_buf)),
        @intCast(val_buf.len),
    );
    if (n <= 0) return 0;
    return parseInt(val_buf[0..@as(usize, @intCast(n))]);
}

fn writeTotalSupply(val: i32) void {
    const key = "totalSupply";
    var val_buf: [32]u8 = undefined;
    const val_str = formatInt(&val_buf, val);
    
    storage_write(
        @intCast(@intFromPtr(key.ptr)),
        @intCast(key.len),
        @intCast(@intFromPtr(val_str.ptr)),
        @intCast(val_str.len),
    );
}

fn parseInt(buf: []const u8) i32 {
    var val: i32 = 0;
    for (buf) |c| {
        if (c < '0' or c > '9') break;
        val = val * 10 + @as(i32, c - '0');
    }
    return val;
}

fn formatInt(buf: []u8, val: i32) []const u8 {
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
    return buf[start..32];
}

fn readString(ptr: u32, len: u32) []const u8 {
    return @as([*]const u8, @ptrFromInt(@as(usize, ptr)))[0..@as(usize, len)];
}

// ------------------------------------------------------------------
// Exports
// ------------------------------------------------------------------

/// Mint tokens to the owner.
export fn mint(amount: i32) i32 {
    if (amount <= 0) return -1;
    
    const supply = readTotalSupply();
    const owner_bal = readBalance(OWNER);
    
    writeTotalSupply(supply + amount);
    writeBalance(OWNER, owner_bal + amount);
    
    var data_buf: [64]u8 = undefined;
    const data = std.fmt.bufPrint(&data_buf, "to={s},amount={d}", .{ OWNER, amount }) catch "mint";
    emitEvent("Mint", data);
    
    var msg_buf: [64]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "minted {d} to {s}", .{ amount, OWNER }) catch "mint";
    log(msg);
    
    return amount;
}

/// Transfer tokens from owner to recipient.
export fn transfer(to_ptr: u32, to_len: u32, amount: i32) i32 {
    if (amount <= 0) return -1;
    
    const to = readString(to_ptr, to_len);
    const owner_bal = readBalance(OWNER);
    
    if (owner_bal < amount) return -2; // insufficient balance
    
    const to_bal = readBalance(to);
    
    writeBalance(OWNER, owner_bal - amount);
    writeBalance(to, to_bal + amount);
    
    var data_buf: [128]u8 = undefined;
    const data = std.fmt.bufPrint(&data_buf, "from={s},to={s},amount={d}", .{ OWNER, to, amount }) catch "transfer";
    emitEvent("Transfer", data);
    
    var msg_buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "transferred {d} from {s} to {s}", .{ amount, OWNER, to }) catch "transfer";
    log(msg);
    
    return amount;
}

/// Query balance of an address.
export fn balanceOf(addr_ptr: u32, addr_len: u32) i32 {
    const addr = readString(addr_ptr, addr_len);
    return readBalance(addr);
}

/// Query total supply.
export fn totalSupply() i32 {
    return readTotalSupply();
}

// ------------------------------------------------------------------
// Panic handler
// ------------------------------------------------------------------

pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    _ = msg;
    while (true) {}
}
