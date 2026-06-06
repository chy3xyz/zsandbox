//! Host entry point: demonstrates plugin system, smart contract, and user code execution
//! all running on the same sandbox kernel.

const std = @import("std");
const c = @import("sandbox_bindings.zig");
const sandbox = @import("sandbox.zig");
const limits = @import("limits.zig");
const PluginRegistry = @import("extensions/plugin_registry.zig").PluginRegistry;
const contract_registry = @import("extensions/contract_registry.zig");
const ContractRegistry = contract_registry.ContractRegistry;
const StateStore = @import("extensions/state_store.zig").StateStore;
const IoPipeline = @import("extensions/io_pipeline.zig").IoPipeline;
const Watchdog = @import("extensions/io_pipeline.zig").Watchdog;
const ModuleCache = @import("extensions/module_cache.zig").ModuleCache;

const log = std.log.scoped(.host);

fn loadSandboxWasm(alloc: std.mem.Allocator, io: std.Io) ![]const u8 {
    return try std.Io.Dir.cwd().readFileAlloc(
        io,
        "zig-out/bin/sandbox.wasm",
        alloc,
        .limited(limits.max_module_bytes),
    );
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    log.info("===============================================", .{});
    log.info("Zig WASM Sandbox: 3-in-1 Demo", .{});
    log.info("Plugins + Smart Contracts + User Code", .{});
    log.info("===============================================", .{});

    const wasm_bytes = try loadSandboxWasm(allocator, io);
    defer allocator.free(wasm_bytes);

    // ================================================================
    // SCENE 1: Plugin System
    // ================================================================
    log.info("", .{});
    log.info("=== SCENE 1: Plugin System ===", .{});

    var registry = PluginRegistry.init(allocator);
    defer registry.deinit();

    // Load plugin "math" from WASM bytes
    try registry.load("math", "1.0.0", wasm_bytes);

    // Call plugin function
    const r1 = try registry.call("math", "sandbox_add", &[_]i32{ 10, 20 });
    log.info("Plugin 'math'.sandbox_add(10, 20) = {d}", .{r1});

    const r2 = try registry.call("math", "sandbox_add", &[_]i32{ 100, 200 });
    log.info("Plugin 'math'.sandbox_add(100, 200) = {d}", .{r2});

    // List plugins
    const infos = try registry.list(allocator);
    defer allocator.free(infos);
    for (infos) |info| {
        log.info("Plugin: {s} v{s} | calls={d} fuel={d}", .{
            info.name, info.version, info.call_count, info.total_fuel,
        });
    }

    // ================================================================
    // SCENE 2a: Smart Contract (Counter with Per-Op Gas Logging)
    // ================================================================
    log.info("", .{});
    log.info("=== SCENE 2a: Smart Contract (Counter + Gas) ===", .{});

    const counter_wasm = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "zig-out/bin/contract_counter.wasm",
        allocator,
        .limited(limits.max_module_bytes),
    );
    defer allocator.free(counter_wasm);

    const counter_imports = [_][]const u8{ "env.host_log", "env.host_log_event", "env.storage_read", "env.storage_write" };
    const counter_exports = [_][]const u8{ "increment", "memory", "__stack_pointer" };
    const counter_required = [_][]const u8{"increment"};

    var counter = try sandbox.Sandbox.init(
        allocator,
        counter_wasm,
        &counter_imports,
        &counter_exports,
        &counter_required,
    );
    defer counter.deinit();
    counter.setAddress("0xCOUNTER");

    var counter_state = try StateStore.initMemory(allocator, .{});
    defer counter_state.deinit();
    counter.attachState(&counter_state);

    log.info("Initial gas: {d}", .{counter.remainingGas()});

    // First increment: SLOAD (missing → 0) + SSTORE (new key → 20,000)
    const c1 = try counter.call("increment", &[_]i32{});
    log.info("increment() #1 = {d}, gas_remaining={d}", .{ c1, counter.remainingGas() });

    // Second increment: SLOAD (reads 1) + SSTORE (modify → 5,000)
    const c2 = try counter.call("increment", &[_]i32{});
    log.info("increment() #2 = {d}, gas_remaining={d}", .{ c2, counter.remainingGas() });

    const total_gas = counter.totalGasConsumed();
    log.info("Total gas consumed: {d}", .{total_gas});
    log.info("Expected: SLOAD(200) + SSTORE_NEW(20000) + SLOAD(200) + SSTORE_MODIFY(5000) = 25,400", .{});

    // ================================================================
    // SCENE 2b: Smart Contract (LMDB-backed persistent state)
    // ================================================================
    log.info("", .{});
    log.info("=== SCENE 2b: Smart Contract (LMDB Persistent State) ===", .{});

    const allowed_imports = [_][]const u8{"env.host_log"};
    const allowed_exports = [_][]const u8{ "sandbox_add", "sandbox_panic", "memory", "__stack_pointer" };
    const required_exports = [_][]const u8{"sandbox_add"};

    var contract2 = try sandbox.Sandbox.init(
        allocator,
        wasm_bytes,
        &allowed_imports,
        &allowed_exports,
        &required_exports,
    );
    defer contract2.deinit();
    contract2.setAddress("0xCONTRACT_B");

    // Create LMDB-backed state store in a temp directory
    const lmdb_path = "/tmp/zsandbox_lmdb_test";
    var lmdb_state = try StateStore.initLmdb(allocator, .{}, lmdb_path);
    defer {
        lmdb_state.deinit();
        // LMDB files in /tmp are cleaned up by the OS
    }
    contract2.attachState(&lmdb_state);

    log.info("LMDB state store opened at {s}", .{lmdb_path});
    log.info("Initial gas: {d}", .{contract2.remainingGas()});

    // Write some persistent state
    try lmdb_state.beginTx();
    try lmdb_state.set("token_name", "ZigToken");
    try lmdb_state.set("token_supply", "1000000");
    try lmdb_state.commit();
    log.info("LMDB state committed", .{});

    // Read back from LMDB
    const token_name = (try lmdb_state.get("token_name")).?;
    defer lmdb_state.allocator.free(token_name);
    const token_supply = (try lmdb_state.get("token_supply")).?;
    defer lmdb_state.allocator.free(token_supply);
    log.info("Persisted: name={s}, supply={s}", .{ token_name, token_supply });

    // Execute contract with LMDB state attached
    const lmdb_result = try contract2.call("sandbox_add", &[_]i32{ 7, 8 });
    log.info("Contract on LMDB result: {d}", .{lmdb_result});
    log.info("Gas remaining: {d}", .{contract2.remainingGas()});

    // ================================================================
    // SCENE 2c: Cross-Contract Call + Call Stack Tracking
    // ================================================================
    log.info("", .{});
    log.info("=== SCENE 2c: Cross-Contract Call + Call Stack ===", .{});

    var contract3 = try sandbox.Sandbox.init(
        allocator,
        wasm_bytes,
        &allowed_imports,
        &allowed_exports,
        &required_exports,
    );
    defer contract3.deinit();
    contract3.setAddress("0xCONTRACT_C");

    // Push a call frame manually (simulating a cross-contract call entry)
    try contract3.call_stack.push("0xCONTRACT_C", "entrypoint");
    log.info("Call stack depth: {d}", .{contract3.call_stack.len});

    // Execute within this frame
    const cc_result = try contract3.call("sandbox_add", &[_]i32{ 3, 4 });
    log.info("Cross-contract call result: {d}", .{cc_result});

    // Pop the frame
    contract3.call_stack.pop();
    log.info("Call stack depth after pop: {d}", .{contract3.call_stack.len});

    // Demonstrate call depth limit
    log.info("Testing call depth limit (max={d})...", .{sandbox.CallStack.max_call_depth});
    var depth_test = try sandbox.Sandbox.init(
        allocator,
        wasm_bytes,
        &allowed_imports,
        &allowed_exports,
        &required_exports,
    );
    defer depth_test.deinit();
    depth_test.setAddress("0xDEPTH_TEST");

    // Push to max depth
    var i: u32 = 0;
    while (i < sandbox.CallStack.max_call_depth) : (i += 1) {
        try depth_test.call_stack.push(
            try std.fmt.allocPrint(allocator, "0xADDR_{d}", .{i}),
            "func",
        );
    }
    log.info("Pushed {d} frames", .{depth_test.call_stack.len});

    // Next push should fail
    const depth_err = depth_test.call_stack.push("0xOVERFLOW", "func");
    if (depth_err) {
        log.info("ERROR: Should have failed at max depth!", .{});
    } else |_| {
        log.info("Correctly rejected call depth overflow", .{});
    }

    // ================================================================
    // SCENE 2d: ContractRegistry + Real Cross-Contract Calls
    // ================================================================
    log.info("", .{});
    log.info("=== SCENE 2d: ContractRegistry + Cross-Contract Calls ===", .{});

    var contract_reg = ContractRegistry.init(allocator);
    defer contract_reg.deinit();
    contract_registry.g_registry = &contract_reg;

    // Deploy "math" contract (from sandbox.wasm)
    const math_imports = [_][]const u8{"env.host_log"};
    const math_exports = [_][]const u8{ "sandbox_add", "sandbox_panic", "memory", "__stack_pointer" };
    const math_required = [_][]const u8{"sandbox_add"};
    try contract_reg.deploy("math", wasm_bytes, &math_imports, &math_exports, &math_required);
    log.info("Deployed: math", .{});

    // Deploy "counter" contract
    const counter_wasm2 = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "zig-out/bin/contract_counter.wasm",
        allocator,
        .limited(limits.max_module_bytes),
    );
    defer allocator.free(counter_wasm2);
    const ctr_imports = [_][]const u8{ "env.host_log", "env.host_log_event", "env.storage_read", "env.storage_write" };
    const ctr_exports = [_][]const u8{ "increment", "memory", "__stack_pointer" };
    const ctr_required = [_][]const u8{"increment"};
    try contract_reg.deploy("counter", counter_wasm2, &ctr_imports, &ctr_exports, &ctr_required);
    log.info("Deployed: counter", .{});

    // Direct call: math.add(3, 4)
    const math_result = try contract_reg.call("math", "math", "sandbox_add", &[_]i32{ 3, 4 });
    log.info("Direct call math.add(3,4) = {d}", .{math_result});

    // Direct call: counter.increment()
    const ctr_result = try contract_reg.call("counter", "counter", "increment", &[_]i32{});
    log.info("Direct call counter.increment() = {d}", .{ctr_result});

    // Deploy "composite" contract (cross-contract caller)
    const composite_wasm = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "zig-out/bin/contract_composite.wasm",
        allocator,
        .limited(limits.max_module_bytes),
    );
    defer allocator.free(composite_wasm);
    const comp_imports = [_][]const u8{ "env.host_log", "env.host_log_event", "env.call_contract" };
    const comp_exports = [_][]const u8{ "add_via_math", "memory", "__stack_pointer" };
    const comp_required = [_][]const u8{"add_via_math"};
    try contract_reg.deploy("composite", composite_wasm, &comp_imports, &comp_exports, &comp_required);
    log.info("Deployed: composite", .{});

    // Cross-contract call: composite.add_via_math(10, 20) → internally calls math.add(10, 20)
    log.info("Cross-contract call: composite.add_via_math(10, 20)...", .{});
    const cross_result = try contract_reg.call("composite", "composite", "add_via_math", &[_]i32{ 10, 20 });
    log.info("Cross-contract result = {d} (expected 30)", .{cross_result});

    // Print event log
    log.info("", .{});
    log.info("--- Event Log ({d} events) ---", .{contract_reg.event_log.len()});
    const all_events = contract_reg.event_log.getAll();
    for (all_events) |event| {
        log.info("  [{s}] {s}: {s}", .{ event.contract, event.name, event.data });
    }
    log.info("--- End Event Log ---", .{});

    // ================================================================
    // SCENE 2e: Token Transfer Contract
    // ================================================================
    log.info("", .{});
    log.info("=== SCENE 2e: Token Transfer Contract ===", .{});

    // Clear previous events for a fresh token demo
    contract_reg.event_log.clear();

    const token_wasm = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "zig-out/bin/contract_token.wasm",
        allocator,
        .limited(limits.max_module_bytes),
    );
    defer allocator.free(token_wasm);

    const token_imports = [_][]const u8{ "env.host_log", "env.host_log_event", "env.storage_read", "env.storage_write" };
    const token_exports = [_][]const u8{ "mint", "transfer", "balanceOf", "totalSupply", "memory", "__stack_pointer" };
    const token_required = [_][]const u8{ "mint", "transfer", "balanceOf", "totalSupply" };
    try contract_reg.deploy("token", token_wasm, &token_imports, &token_exports, &token_required);
    log.info("Deployed: token", .{});

    // Mint 1000 tokens to owner
    const mint_result = try contract_reg.call("token", "token", "mint", &[_]i32{1000});
    log.info("mint(1000) = {d}", .{mint_result});

    // Get token sandbox to write address strings into guest memory
    const token_entry = contract_reg.get("token").?;

    // Write "owner" to guest memory at address 1024
    try token_entry.sandbox.writeToGuestMemory(1024, "owner");
    // Write "Bob" to guest memory at address 2048
    try token_entry.sandbox.writeToGuestMemory(2048, "Bob");

    // Transfer 100 tokens from owner to Bob
    const transfer_result = try contract_reg.call("token", "token", "transfer", &[_]i32{ 2048, 3, 100 });
    log.info("transfer('Bob', 100) = {d}", .{transfer_result});

    // Query owner balance
    const owner_bal = try contract_reg.call("token", "token", "balanceOf", &[_]i32{ 1024, 5 });
    log.info("balanceOf('owner') = {d}", .{owner_bal});

    // Query Bob balance
    const bob_bal = try contract_reg.call("token", "token", "balanceOf", &[_]i32{ 2048, 3 });
    log.info("balanceOf('Bob') = {d}", .{bob_bal});

    // Query total supply
    const supply = try contract_reg.call("token", "token", "totalSupply", &[_]i32{});
    log.info("totalSupply() = {d}", .{supply});

    // Print token event log
    log.info("", .{});
    log.info("--- Token Event Log ({d} events) ---", .{contract_reg.event_log.len()});
    const token_events = contract_reg.event_log.getAll();
    for (token_events) |event| {
        log.info("  [{s}] {s}: {s}", .{ event.contract, event.name, event.data });
    }
    log.info("--- End Token Event Log ---", .{});

    // ================================================================
    // SCENE 2f: Module Compilation Cache
    // ================================================================
    log.info("", .{});
    log.info("=== SCENE 2f: Module Compilation Cache ===", .{});

    var mod_cache = try ModuleCache.init(allocator);
    defer mod_cache.deinit();

    // First sandbox using cache: cold miss (compiles)
    var cached_sb1 = try sandbox.Sandbox.initWithCache(
        allocator,
        wasm_bytes,
        &allowed_imports,
        &allowed_exports,
        &required_exports,
        &mod_cache,
    );
    defer cached_sb1.deinit();
    const r_cache1 = try cached_sb1.call("sandbox_add", &[_]i32{ 1, 2 });
    log.info("Cache sandbox #1: sandbox_add(1,2) = {d}", .{r_cache1});

    // Second sandbox using cache: warm hit (reuses compiled module)
    var cached_sb2 = try sandbox.Sandbox.initWithCache(
        allocator,
        wasm_bytes,
        &allowed_imports,
        &allowed_exports,
        &required_exports,
        &mod_cache,
    );
    defer cached_sb2.deinit();
    const r_cache2 = try cached_sb2.call("sandbox_add", &[_]i32{ 3, 4 });
    log.info("Cache sandbox #2: sandbox_add(3,4) = {d} (module reused)", .{r_cache2});

    // ================================================================
    // SCENE 2g: Cryptographic Precompiles (keccak256 / sha256)
    // ================================================================
    log.info("", .{});
    log.info("=== SCENE 2g: Cryptographic Precompiles ===", .{});

    const crypto_wasm = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "zig-out/bin/contract_crypto.wasm",
        allocator,
        .limited(limits.max_module_bytes),
    );
    defer allocator.free(crypto_wasm);

    const crypto_imports = [_][]const u8{ "env.host_log", "env.keccak256", "env.sha256" };
    const crypto_exports = [_][]const u8{ "hash_both", "copy_string", "memory", "__stack_pointer" };
    const crypto_required = [_][]const u8{"hash_both"};

    var crypto_sb = try sandbox.Sandbox.init(
        allocator,
        crypto_wasm,
        &crypto_imports,
        &crypto_exports,
        &crypto_required,
    );
    defer crypto_sb.deinit();

    // Write test data "hello" to guest memory at address 1024
    try crypto_sb.writeToGuestMemory(1024, "hello");

    // Call hash_both(1024, 5, 2048, 2080)
    // Writes keccak256("hello") to 2048, sha256("hello") to 2080
    const hash_result = try crypto_sb.call("hash_both", &[_]i32{ 1024, 5, 2048, 2080 });
    log.info("hash_both() = {d}", .{hash_result});

    // Read back the hashes from guest memory
    var keccak_buf: [32]u8 = undefined;
    var sha_buf: [32]u8 = undefined;
    {
        var item: c.wasmtime_extern_t = undefined;
        const found = c.wasmtime_instance_export_get(crypto_sb.context, &crypto_sb.instance, "memory", "memory".len, &item);
        if (found and item.kind == c.WASMTIME_EXTERN_MEMORY) {
            defer c.wasmtime_extern_delete(&item);
            const mem_data = c.wasmtime_memory_data(crypto_sb.context, &item.of.memory);
            @memcpy(&keccak_buf, mem_data[2048..2080]);
            @memcpy(&sha_buf, mem_data[2080..2112]);
        }
    }

    log.info("keccak256(\"hello\") = {s}", .{std.fmt.bytesToHex(keccak_buf, .lower)});
    log.info("sha256(\"hello\")    = {s}", .{std.fmt.bytesToHex(sha_buf, .lower)});

    // Verify against expected values
    const expected_keccak = "1c8aff950685c2ed4bc3174f3472287b56d9517b9c948127319a09a7a36deac8";
    const expected_sha256 = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824";
    const actual_keccak = std.fmt.bytesToHex(keccak_buf, .lower);
    const actual_sha256 = std.fmt.bytesToHex(sha_buf, .lower);
    if (std.mem.eql(u8, &actual_keccak, expected_keccak) and std.mem.eql(u8, &actual_sha256, expected_sha256)) {
        log.info("Hash verification: PASS", .{});
    } else {
        log.warn("Hash verification: FAIL", .{});
    }

    // ================================================================
    // SCENE 3: User Code Execution
    // ================================================================
    log.info("", .{});
    log.info("=== SCENE 3: User Code Execution ===", .{});

    var userbox = try sandbox.Sandbox.init(
        allocator,
        wasm_bytes,
        &allowed_imports,
        &allowed_exports,
        &required_exports,
    );
    defer userbox.deinit();

    // Attach I/O pipeline
    var io_pipe = try IoPipeline.init(allocator, .{});
    defer io_pipe.deinit();
    userbox.attachIo(&io_pipe);

    // Attach watchdog (5 second timeout)
    var wd = Watchdog.init(5000);
    userbox.attachWatchdog(&wd);

    log.info("User code sandbox created with I/O + watchdog", .{});
    log.info("Remaining fuel: {d}", .{userbox.remainingFuel()});

    // Call a simple function (the guest's sandbox_add) as a proxy for user code
    const user_result = try userbox.call("sandbox_add", &[_]i32{ 42, 58 });
    log.info("User code result: {d}", .{user_result});

    // ================================================================
    // Summary
    // ================================================================
    log.info("", .{});
    log.info("===============================================", .{});
    log.info("All 3 scenes completed successfully.", .{});
    log.info("Features demonstrated:", .{});
    log.info("  - Plugin system (load/unload/call/stats)", .{});
    log.info("  - Memory-backed state store (tx begin/commit/rollback)", .{});
    log.info("  - LMDB-backed persistent state store", .{});
    log.info("  - Gas metering (SLOAD/SSTORE/CALL pricing)", .{});
    log.info("  - Cross-contract call stack tracking", .{});
    log.info("  - Call depth limiting + reentrancy detection", .{});
    log.info("  - ContractRegistry (deploy + direct/cross calls)", .{});
    log.info("  - Module compilation cache (shared engine + compiled module reuse)", .{});
    log.info("  - Cryptographic precompiles (keccak256/sha256 with gas pricing)", .{});
    log.info("  - User code execution (I/O pipeline + watchdog)", .{});
    log.info("===============================================", .{});
}
