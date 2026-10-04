//! Static validation of WASM binaries before they reach the runtime.
//! Catches malformed or policy-violating modules early.

const std = @import("std");
const assert = std.debug.assert;
const limits = @import("limits.zig");

const log = std.log.scoped(.wasm_validator);

pub const Error = error{
    ModuleTooLarge,
    BadMagic,
    BadVersion,
    ImportNotAllowed,
    ExportNotAllowed,
    MissingRequiredExport,
    RequiredImportMissing,
};

/// Validate a raw WASM binary against policy.
///
/// Checks performed:
/// - Magic + version header
/// - Size limit
/// - Import whitelist (if non-null)
/// - Export whitelist (if non-null)
/// - Required exports present
pub fn validateModule(
    allocator: std.mem.Allocator,
    wasm_bytes: []const u8,
    allowed_imports: ?[]const []const u8,
    allowed_exports: ?[]const []const u8,
    required_exports: ?[]const []const u8,
) Error!void {
    if (wasm_bytes.len > limits.max_module_bytes) {
        log.warn("Module too large: {d} > {d}", .{ wasm_bytes.len, limits.max_module_bytes });
        return Error.ModuleTooLarge;
    }

    if (wasm_bytes.len < 8) {
        log.warn("Module too small", .{});
        return Error.BadMagic;
    }

    // Check magic
    if (!std.mem.eql(u8, wasm_bytes[0..4], &limits.wasm_magic)) {
        log.warn("Bad WASM magic", .{});
        return Error.BadMagic;
    }

    // Check version
    if (!std.mem.eql(u8, wasm_bytes[4..8], &limits.wasm_version)) {
        log.warn("Bad WASM version", .{});
        return Error.BadVersion;
    }

    // Parse imports and exports from the binary. The parsed name strings
    // are scratch data — use an arena so they are all released at once.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parse_alloc = arena.allocator();

    var imports = std.ArrayList([]const u8).empty;
    var exports = std.ArrayList([]const u8).empty;

    scanImportsExports(parse_alloc, wasm_bytes, &imports, &exports) catch |err| {
        log.warn("Failed to scan module: {s}", .{@errorName(err)});
        return Error.BadMagic; // reuse as generic parse error
    };

    // Check import whitelist
    if (allowed_imports) |whitelist| {
        for (imports.items) |imp| {
            var ok = false;
            for (whitelist) |w| {
                if (std.mem.eql(u8, imp, w)) {
                    ok = true;
                    break;
                }
            }
            if (!ok) {
                log.warn("Import not allowed: {s}", .{imp});
                return Error.ImportNotAllowed;
            }
        }
    }

    // Check export whitelist
    if (allowed_exports) |whitelist| {
        for (exports.items) |exp| {
            var ok = false;
            for (whitelist) |w| {
                if (std.mem.eql(u8, exp, w)) {
                    ok = true;
                    break;
                }
            }
            if (!ok) {
                log.warn("Export not allowed: {s}", .{exp});
                return Error.ExportNotAllowed;
            }
        }
    }

    // Check required exports
    if (required_exports) |required| {
        for (required) |req| {
            var found = false;
            for (exports.items) |exp| {
                if (std.mem.eql(u8, exp, req)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                log.warn("Missing required export: {s}", .{req});
                return Error.MissingRequiredExport;
            }
        }
    }

    log.info("Module validated: {d} imports, {d} exports", .{ imports.items.len, exports.items.len });
}

/// Lightweight scan of import and export names.
fn scanImportsExports(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    out_imports: *std.ArrayList([]const u8),
    out_exports: *std.ArrayList([]const u8),
) error{ OutOfMemory }!void {
    if (bytes.len < 8) return;

    var pos: usize = 8;

    while (pos < bytes.len) {
        if (pos >= bytes.len) break;
        const section_id = bytes[pos];
        pos += 1;

        // Read section size (LEB128)
        var section_size: u64 = 0;
        var shift: u6 = 0;
        while (true) {
            if (pos >= bytes.len) return;
            const b = bytes[pos];
            pos += 1;
            section_size |= @as(u64, b & 0x7f) << shift;
            if ((b & 0x80) == 0) break;
            shift += 7;
            if (shift > 63) return; // overflow
        }

        const section_end = pos + section_size;
        if (section_end > bytes.len) return;

        if (section_id == 2) {
            try parseImportSection(allocator, bytes[pos..section_end], out_imports);
        } else if (section_id == 7) {
            try parseExportSection(allocator, bytes[pos..section_end], out_exports);
        }

        pos = section_end;
    }
}

fn parseImportSection(
    allocator: std.mem.Allocator,
    section: []const u8,
    out: *std.ArrayList([]const u8),
) error{ OutOfMemory }!void {
    if (section.len == 0) return;
    var pos: usize = 0;

    const count = readLeb128U(section, &pos) catch return;

    var i: u64 = 0;
    while (i < count) : (i += 1) {
        const mod_name = readName(section, &pos) catch return;
        const field_name = readName(section, &pos) catch return;

        if (pos >= section.len) return;
        const kind = section[pos];
        pos += 1;

        switch (kind) {
            0x00 => pos += 1, // function: type index
            0x01 => { // table
                if (pos >= section.len) return;
                pos += 1; // elemtype
                if (pos >= section.len) return;
                const lim_flags = section[pos];
                pos += 1;
                _ = readLeb128U(section, &pos) catch return;
                if (lim_flags == 1) _ = readLeb128U(section, &pos) catch return;
            },
            0x02 => { // memory
                if (pos >= section.len) return;
                const lim_flags = section[pos];
                pos += 1;
                _ = readLeb128U(section, &pos) catch return;
                if (lim_flags == 1) _ = readLeb128U(section, &pos) catch return;
            },
            0x03 => pos += 2, // global: valtype + mutability
            else => return,
        }

        const full_name = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ mod_name, field_name });
        try out.append(allocator, full_name);
    }
}

fn parseExportSection(
    allocator: std.mem.Allocator,
    section: []const u8,
    out: *std.ArrayList([]const u8),
) error{ OutOfMemory }!void {
    if (section.len == 0) return;
    var pos: usize = 0;

    const count = readLeb128U(section, &pos) catch return;

    var i: u64 = 0;
    while (i < count) : (i += 1) {
        const name = readName(section, &pos) catch return;
        try out.append(allocator, name);

        if (pos >= section.len) return;
        pos += 2; // kind + index
    }
}

fn readName(buf: []const u8, pos: *usize) error{Overflow}![]const u8 {
    const len = readLeb128U(buf, pos) catch return "";
    if (pos.* + len > buf.len) return "";
    const name = buf[pos.* .. pos.* + len];
    pos.* += len;
    return name;
}

fn readLeb128U(buf: []const u8, pos: *usize) error{Overflow}!u64 {
    var result: u64 = 0;
    var shift: u6 = 0;
    while (true) {
        if (pos.* >= buf.len) return error.Overflow;
        const b = buf[pos.*];
        pos.* += 1;
        result |= @as(u64, b & 0x7f) << shift;
        if ((b & 0x80) == 0) break;
        shift += 7;
        if (shift > 63) return error.Overflow;
    }
    return result;
}
