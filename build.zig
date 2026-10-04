const std = @import("std");

pub fn build(b: *std.Build) void {
    // ================================================================
    // 1. WASM Sandbox (guest)
    // ================================================================
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
        .abi = .none,
    });

    const wasm_mod = b.createModule(.{
        .root_source_file = b.path("sandbox.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });

    const wasm_lib = b.addExecutable(.{
        .name = "sandbox",
        .root_module = wasm_mod,
    });
    wasm_lib.entry = .disabled;
    wasm_lib.rdynamic = true;
    wasm_lib.initial_memory = limits.max_memory_bytes;
    wasm_lib.max_memory = limits.max_memory_bytes;
    b.installArtifact(wasm_lib);

    // ================================================================
    // 1b. Counter Contract (guest)
    // ================================================================
    const counter_mod = b.createModule(.{
        .root_source_file = b.path("contract_counter.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });

    const counter_lib = b.addExecutable(.{
        .name = "contract_counter",
        .root_module = counter_mod,
    });
    counter_lib.entry = .disabled;
    counter_lib.rdynamic = true;
    counter_lib.initial_memory = limits.max_memory_bytes;
    counter_lib.max_memory = limits.max_memory_bytes;
    b.installArtifact(counter_lib);

    // ================================================================
    // 1c. Composite Contract (guest, demonstrates cross-contract calls)
    // ================================================================
    const composite_mod = b.createModule(.{
        .root_source_file = b.path("contract_composite.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });

    const composite_lib = b.addExecutable(.{
        .name = "contract_composite",
        .root_module = composite_mod,
    });
    composite_lib.entry = .disabled;
    composite_lib.rdynamic = true;
    composite_lib.initial_memory = limits.max_memory_bytes;
    composite_lib.max_memory = limits.max_memory_bytes;
    b.installArtifact(composite_lib);

    // ================================================================
    // 1d. Crypto Contract (guest, demonstrates keccak256/sha256 precompiles)
    // ================================================================
    const crypto_mod = b.createModule(.{
        .root_source_file = b.path("contract_crypto.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });

    const crypto_lib = b.addExecutable(.{
        .name = "contract_crypto",
        .root_module = crypto_mod,
    });
    crypto_lib.entry = .disabled;
    crypto_lib.rdynamic = true;
    crypto_lib.initial_memory = limits.max_memory_bytes;
    crypto_lib.max_memory = limits.max_memory_bytes;
    b.installArtifact(crypto_lib);

    // ================================================================
    // 1e. Token Contract (guest, ERC-20 style)
    // ================================================================
    const token_mod = b.createModule(.{
        .root_source_file = b.path("contract_token.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });

    const token_lib = b.addExecutable(.{
        .name = "contract_token",
        .root_module = token_mod,
    });
    token_lib.entry = .disabled;
    token_lib.rdynamic = true;
    token_lib.initial_memory = limits.max_memory_bytes;
    token_lib.max_memory = limits.max_memory_bytes;
    b.installArtifact(token_lib);

    // ================================================================
    // 2. Host executable (loader + runtime)
    // ================================================================
    const host_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
        .link_libc = true,
    });
    host_mod.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
    host_mod.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
    host_mod.linkSystemLibrary("wasmtime", .{});
    host_mod.linkSystemLibrary("lmdb", .{});

    const host_exe = b.addExecutable(.{
        .name = "host",
        .root_module = host_mod,
    });
    b.installArtifact(host_exe);

    const run_host = b.addRunArtifact(host_exe);
    run_host.step.dependOn(b.getInstallStep());
    b.step("run", "Run host loader").dependOn(&run_host.step);

    // ================================================================
    // 3. Tests
    // ================================================================
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
        .link_libc = true,
    });
    test_mod.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
    test_mod.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
    test_mod.linkSystemLibrary("wasmtime", .{});
    test_mod.linkSystemLibrary("lmdb", .{});

    const test_exe = b.addTest(.{
        .name = "sandbox_test",
        .root_module = test_mod,
    });
    const run_tests = b.addRunArtifact(test_exe);
    // Tests load compiled guest WASM from zig-out/bin, so they need
    // the install step (all guest artifacts) to complete first.
    run_tests.step.dependOn(b.getInstallStep());
    b.step("test", "Run sandbox tests").dependOn(&run_tests.step);
}

const limits = struct {
    pub const max_memory_pages = 17;
    pub const max_memory_bytes = max_memory_pages * 64 * 1024;
};
