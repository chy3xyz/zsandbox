//! Integration tests for the WASM sandbox.

const std = @import("std");
const c = @import("sandbox_bindings.zig");
const sandbox = @import("sandbox.zig");
const validator = @import("wasm_validator.zig");
const limits = @import("limits.zig");
const StateStore = @import("extensions/state_store.zig").StateStore;
const contract_registry = @import("extensions/contract_registry.zig");
const ContractRegistry = contract_registry.ContractRegistry;
const ModuleCache = @import("extensions/module_cache.zig").ModuleCache;

// ------------------------------------------------------------------
// WASM Validator Tests
// ------------------------------------------------------------------

test "validator rejects empty module" {
    const empty = &[_]u8{};
    const result = validator.validateModule(
        std.testing.allocator,
        empty,
        null,
        null,
        null,
    );
    try std.testing.expectError(validator.Error.BadMagic, result);
}

test "validator rejects bad magic" {
    const bad = &[_]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x00, 0x00, 0x00 };
    const result = validator.validateModule(
        std.testing.allocator,
        bad,
        null,
        null,
        null,
    );
    try std.testing.expectError(validator.Error.BadMagic, result);
}

test "validator rejects bad version" {
    const bad = &[_]u8{ 0x00, 0x61, 0x73, 0x6D, 0x02, 0x00, 0x00, 0x00 };
    const result = validator.validateModule(
        std.testing.allocator,
        bad,
        null,
        null,
        null,
    );
    try std.testing.expectError(validator.Error.BadVersion, result);
}

test "validator accepts minimal valid module" {
    // Minimal valid WASM: magic + version + no sections
    const minimal = &[_]u8{
        0x00, 0x61, 0x73, 0x6D, // magic
        0x01, 0x00, 0x00, 0x00, // version 1
    };
    try validator.validateModule(
        std.testing.allocator,
        minimal,
        null,
        null,
        null,
    );
}

test "validator rejects oversized module" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const oversized = try alloc.alloc(u8, limits.max_module_bytes + 1);
    @memcpy(oversized[0..4], &limits.wasm_magic);
    @memcpy(oversized[4..8], &limits.wasm_version);

    const result = validator.validateModule(
        std.testing.allocator,
        oversized,
        null,
        null,
        null,
    );
    try std.testing.expectError(validator.Error.ModuleTooLarge, result);
}

// ------------------------------------------------------------------
// End-to-End Sandbox Tests
// ------------------------------------------------------------------

/// Load the compiled sandbox.wasm bytes.
fn loadSandboxWasm(alloc: std.mem.Allocator, io: std.Io) ![]const u8 {
    return try std.Io.Dir.cwd().readFileAlloc(
        io,
        "zig-out/bin/sandbox.wasm",
        alloc,
        .limited(limits.max_module_bytes),
    );
}

test "sandbox end-to-end: create and call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const wasm_bytes = try loadSandboxWasm(alloc, io);

    const allowed_imports = [_][]const u8{"env.host_log"};
    const allowed_exports = [_][]const u8{ "sandbox_add", "sandbox_panic", "memory", "__stack_pointer" };
    const required_exports = [_][]const u8{"sandbox_add"};

    var sb = try sandbox.Sandbox.init(
        alloc,
        wasm_bytes,
        &allowed_imports,
        &allowed_exports,
        &required_exports,
    );
    defer sb.deinit();

    // Call sandbox_add(5, 7)
    const result = try sb.call("sandbox_add", &[_]i32{ 5, 7 });
    try std.testing.expectEqual(@as(i32, 12), result);

    // Verify fuel was consumed
    try std.testing.expect(sb.totalFuelConsumed() > 0);
    try std.testing.expect(sb.remainingFuel() < limits.initial_fuel);
}

test "sandbox fuel reset works" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const wasm_bytes = try loadSandboxWasm(alloc, io);

    const allowed_imports = [_][]const u8{"env.host_log"};
    const allowed_exports = [_][]const u8{ "sandbox_add", "sandbox_panic", "memory", "__stack_pointer" };
    const required_exports = [_][]const u8{"sandbox_add"};

    var sb = try sandbox.Sandbox.init(
        alloc,
        wasm_bytes,
        &allowed_imports,
        &allowed_exports,
        &required_exports,
    );
    defer sb.deinit();

    // Consume some fuel
    _ = try sb.call("sandbox_add", &[_]i32{ 1, 2 });
    const before_reset = sb.remainingFuel();
    try std.testing.expect(before_reset < limits.initial_fuel);

    // Reset
    try sb.resetFuel();
    try std.testing.expectEqual(limits.initial_fuel, sb.remainingFuel());
}

test "sandbox rejects unknown import" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const wasm_bytes = try loadSandboxWasm(alloc, io);

    // Only allow no imports
    const allowed_imports = [_][]const u8{};
    const allowed_exports = [_][]const u8{ "sandbox_add", "sandbox_panic", "memory", "__stack_pointer" };
    const required_exports = [_][]const u8{"sandbox_add"};

    const result = sandbox.Sandbox.init(
        alloc,
        wasm_bytes,
        &allowed_imports,
        &allowed_exports,
        &required_exports,
    );
    try std.testing.expectError(sandbox.SandboxError.ModuleValidationFailed, result);
}

test "sandbox rejects missing required export" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const wasm_bytes = try loadSandboxWasm(alloc, io);

    const allowed_imports = [_][]const u8{"env.host_log"};
    const allowed_exports = [_][]const u8{ "sandbox_add", "sandbox_panic", "memory", "__stack_pointer" };
    const required_exports = [_][]const u8{"nonexistent"};

    const result = sandbox.Sandbox.init(
        alloc,
        wasm_bytes,
        &allowed_imports,
        &allowed_exports,
        &required_exports,
    );
    try std.testing.expectError(sandbox.SandboxError.ModuleValidationFailed, result);
}

test "counter contract charges gas per storage op" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const wasm_bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "zig-out/bin/contract_counter.wasm",
        alloc,
        .limited(limits.max_module_bytes),
    );

    const allowed_imports = [_][]const u8{ "env.host_log", "env.host_log_event", "env.storage_read", "env.storage_write" };
    const allowed_exports = [_][]const u8{ "increment", "memory", "__stack_pointer" };
    const required_exports = [_][]const u8{"increment"};

    var sb = try sandbox.Sandbox.init(
        alloc,
        wasm_bytes,
        &allowed_imports,
        &allowed_exports,
        &required_exports,
    );
    defer sb.deinit();

    var state = try StateStore.initMemory(alloc, .{});
    defer state.deinit();
    sb.attachState(&state);

    const gas0 = sb.remainingGas();

    // First increment: SLOAD(200) + SSTORE_NEW(20000) + LOG(375)
    const r1 = try sb.call("increment", &[_]i32{});
    try std.testing.expectEqual(@as(i32, 1), r1);

    const gas1 = sb.remainingGas();
    const consumed1 = gas0 - gas1;
    try std.testing.expectEqual(@as(u64, 20575), consumed1);

    // Second increment: SLOAD(200) + SSTORE_MODIFY(5000) + LOG(375)
    const r2 = try sb.call("increment", &[_]i32{});
    try std.testing.expectEqual(@as(i32, 2), r2);

    const gas2 = sb.remainingGas();
    const consumed2 = gas1 - gas2;
    try std.testing.expectEqual(@as(u64, 5575), consumed2);

    // Total: 20575 + 5575 = 26150
    try std.testing.expectEqual(@as(u64, 26150), gas0 - gas2);
}

test "cross-contract call: composite calls math" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const math_wasm = try loadSandboxWasm(alloc, io);
    const composite_wasm = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "zig-out/bin/contract_composite.wasm",
        alloc,
        .limited(limits.max_module_bytes),
    );

    var reg = ContractRegistry.init(alloc);
    defer reg.deinit();
    contract_registry.g_registry = &reg;

    const math_imports = [_][]const u8{"env.host_log"};
    const math_exports = [_][]const u8{ "sandbox_add", "sandbox_panic", "memory", "__stack_pointer" };
    const math_required = [_][]const u8{"sandbox_add"};
    try reg.deploy("math", math_wasm, &math_imports, &math_exports, &math_required);

    const comp_imports = [_][]const u8{ "env.host_log", "env.host_log_event", "env.call_contract" };
    const comp_exports = [_][]const u8{ "add_via_math", "memory", "__stack_pointer" };
    const comp_required = [_][]const u8{"add_via_math"};
    try reg.deploy("composite", composite_wasm, &comp_imports, &comp_exports, &comp_required);

    // Cross-contract call: composite.add_via_math(10, 20) → math.add(10, 20) = 30
    const result = try reg.call("composite", "composite", "add_via_math", &[_]i32{ 10, 20 });
    try std.testing.expectEqual(@as(i32, 30), result);

    // Verify events were emitted
    try std.testing.expectEqual(@as(usize, 2), reg.event_log.len());
    const events = reg.event_log.getAll();
    try std.testing.expectEqualStrings("composite", events[0].contract);
    try std.testing.expectEqualStrings("CrossCallInitiated", events[0].name);
    try std.testing.expectEqualStrings("composite", events[1].contract);
    try std.testing.expectEqualStrings("CrossCallCompleted", events[1].name);
}

test "event log: counter emits Incremented event" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const counter_wasm = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "zig-out/bin/contract_counter.wasm",
        alloc,
        .limited(limits.max_module_bytes),
    );

    var reg = ContractRegistry.init(alloc);
    defer reg.deinit();
    contract_registry.g_registry = &reg;

    const ctr_imports = [_][]const u8{ "env.host_log", "env.host_log_event", "env.storage_read", "env.storage_write" };
    const ctr_exports = [_][]const u8{ "increment", "memory", "__stack_pointer" };
    const ctr_required = [_][]const u8{"increment"};
    try reg.deploy("counter", counter_wasm, &ctr_imports, &ctr_exports, &ctr_required);

    // Call increment twice
    _ = try reg.call("counter", "counter", "increment", &[_]i32{});
    _ = try reg.call("counter", "counter", "increment", &[_]i32{});

    // Verify events
    try std.testing.expectEqual(@as(usize, 2), reg.event_log.len());
    const events = reg.event_log.getAll();
    try std.testing.expectEqualStrings("counter", events[0].contract);
    try std.testing.expectEqualStrings("Incremented", events[0].name);
    try std.testing.expectEqualStrings("counter", events[1].contract);
    try std.testing.expectEqualStrings("Incremented", events[1].name);
}

test "token contract: mint and transfer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const token_wasm = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "zig-out/bin/contract_token.wasm",
        alloc,
        .limited(limits.max_module_bytes),
    );

    var reg = ContractRegistry.init(alloc);
    defer reg.deinit();
    contract_registry.g_registry = &reg;

    const token_imports = [_][]const u8{ "env.host_log", "env.host_log_event", "env.storage_read", "env.storage_write" };
    const token_exports = [_][]const u8{ "mint", "transfer", "balanceOf", "totalSupply", "memory", "__stack_pointer" };
    const token_required = [_][]const u8{ "mint", "transfer", "balanceOf", "totalSupply" };
    try reg.deploy("token", token_wasm, &token_imports, &token_exports, &token_required);

    // Mint 1000 to owner
    const minted = try reg.call("token", "token", "mint", &[_]i32{1000});
    try std.testing.expectEqual(@as(i32, 1000), minted);

    // Write address strings to guest memory
    const token_entry = reg.get("token").?;
    try token_entry.sandbox.writeToGuestMemory(1024, "owner");
    try token_entry.sandbox.writeToGuestMemory(2048, "Bob");

    // Transfer 100 to Bob
    const transferred = try reg.call("token", "token", "transfer", &[_]i32{ 2048, 3, 100 });
    try std.testing.expectEqual(@as(i32, 100), transferred);

    // Check owner balance = 900
    const owner_bal = try reg.call("token", "token", "balanceOf", &[_]i32{ 1024, 5 });
    try std.testing.expectEqual(@as(i32, 900), owner_bal);

    // Check Bob balance = 100
    const bob_bal = try reg.call("token", "token", "balanceOf", &[_]i32{ 2048, 3 });
    try std.testing.expectEqual(@as(i32, 100), bob_bal);

    // Check total supply = 1000
    const supply = try reg.call("token", "token", "totalSupply", &[_]i32{});
    try std.testing.expectEqual(@as(i32, 1000), supply);

    // Verify events
    try std.testing.expectEqual(@as(usize, 2), reg.event_log.len());
    const events = reg.event_log.getAll();
    try std.testing.expectEqualStrings("token", events[0].contract);
    try std.testing.expectEqualStrings("Mint", events[0].name);
    try std.testing.expectEqualStrings("token", events[1].contract);
    try std.testing.expectEqualStrings("Transfer", events[1].name);
}

test "module cache reuses compiled modules" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const wasm_bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "zig-out/bin/sandbox.wasm",
        alloc,
        .limited(limits.max_module_bytes),
    );

    const allowed_imports = [_][]const u8{"env.host_log"};
    const allowed_exports = [_][]const u8{ "sandbox_add", "sandbox_panic", "memory", "__stack_pointer" };
    const required_exports = [_][]const u8{"sandbox_add"};

    var mod_cache = try ModuleCache.init(alloc);
    defer mod_cache.deinit();

    // First sandbox: cold miss
    var sb1 = try sandbox.Sandbox.initWithCache(
        alloc, wasm_bytes, &allowed_imports, &allowed_exports, &required_exports, &mod_cache,
    );
    defer sb1.deinit();
    const r1 = try sb1.call("sandbox_add", &[_]i32{ 1, 2 });
    try std.testing.expectEqual(@as(i32, 3), r1);

    // Second sandbox: warm hit (same module reused)
    var sb2 = try sandbox.Sandbox.initWithCache(
        alloc, wasm_bytes, &allowed_imports, &allowed_exports, &required_exports, &mod_cache,
    );
    defer sb2.deinit();
    const r2 = try sb2.call("sandbox_add", &[_]i32{ 10, 20 });
    try std.testing.expectEqual(@as(i32, 30), r2);

    // Cache should have exactly 1 entry
    try std.testing.expectEqual(@as(usize, 1), mod_cache.modules.count());
}

test "crypto precompiles: keccak256 and sha256" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const crypto_wasm = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "zig-out/bin/contract_crypto.wasm",
        alloc,
        .limited(limits.max_module_bytes),
    );

    const crypto_imports = [_][]const u8{ "env.host_log", "env.keccak256", "env.sha256" };
    const crypto_exports = [_][]const u8{ "hash_both", "copy_string", "memory", "__stack_pointer" };
    const crypto_required = [_][]const u8{"hash_both"};

    var sb = try sandbox.Sandbox.init(
        alloc,
        crypto_wasm,
        &crypto_imports,
        &crypto_exports,
        &crypto_required,
    );
    defer sb.deinit();

    // Write "hello" to guest memory at 1024
    try sb.writeToGuestMemory(1024, "hello");

    // hash_both(data_ptr=1024, data_len=5, keccak_out=2048, sha256_out=2080)
    const result = try sb.call("hash_both", &[_]i32{ 1024, 5, 2048, 2080 });
    try std.testing.expectEqual(@as(i32, 0), result);

    // Read back hashes
    var keccak_buf: [32]u8 = undefined;
    var sha_buf: [32]u8 = undefined;
    var item: c.wasmtime_extern_t = undefined;
    const found = c.wasmtime_instance_export_get(sb.context, &sb.instance, "memory", "memory".len, &item);
    try std.testing.expect(found and item.kind == c.WASMTIME_EXTERN_MEMORY);
    defer c.wasmtime_extern_delete(&item);
    const mem_data = c.wasmtime_memory_data(sb.context, &item.of.memory);
    @memcpy(&keccak_buf, mem_data[2048..2080]);
    @memcpy(&sha_buf, mem_data[2080..2112]);

    // Verify expected hashes
    const expected_keccak = "1c8aff950685c2ed4bc3174f3472287b56d9517b9c948127319a09a7a36deac8";
    const expected_sha256 = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824";
    const actual_keccak = std.fmt.bytesToHex(keccak_buf, .lower);
    const actual_sha256 = std.fmt.bytesToHex(sha_buf, .lower);
    try std.testing.expectEqualStrings(expected_keccak, &actual_keccak);
    try std.testing.expectEqualStrings(expected_sha256, &actual_sha256);
}
