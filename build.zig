const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Create shared module for common code
    const common_mod = b.createModule(.{
        .root_source_file = b.path("src/common/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const api_mod = b.createModule(.{
        .root_source_file = b.path("src/api/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "common", .module = common_mod },
        },
    });

    // Storage module: SQLite-backed persistence
    const storage_mod = b.createModule(.{
        .root_source_file = b.path("src/storage/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "common", .module = common_mod },
            .{ .name = "api", .module = api_mod },
        },
        .link_libc = true,
    });
    storage_mod.linkSystemLibrary("sqlite3", .{});

    const tools_mod = b.createModule(.{
        .root_source_file = b.path("src/tools/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "common", .module = common_mod },
            .{ .name = "api", .module = api_mod },
            .{ .name = "storage", .module = storage_mod },
        },
    });

    // Shared provider-neutral inference contracts. Chat and Narrative both
    // depend on this module; Narrative deliberately does not import core.Engine.
    const inference_mod = b.createModule(.{
        .root_source_file = b.path("src/inference/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "common", .module = common_mod },
            .{ .name = "api", .module = api_mod },
        },
    });

    // Workers module: background processing (summarizer, extractor)
    const workers_mod = b.createModule(.{
        .root_source_file = b.path("src/workers/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "common", .module = common_mod },
            .{ .name = "api", .module = api_mod },
            .{ .name = "storage", .module = storage_mod },
        },
    });

    // Core module: business logic (engine, router)
    const core_mod = b.createModule(.{
        .root_source_file = b.path("src/core/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "common", .module = common_mod },
            .{ .name = "api", .module = api_mod },
            .{ .name = "tools", .module = tools_mod },
            .{ .name = "storage", .module = storage_mod },
            .{ .name = "workers", .module = workers_mod },
            .{ .name = "inference", .module = inference_mod },
        },
    });

    // Narrative Studio is a standalone application subsystem. It shares
    // inference and storage primitives but never imports the chat Engine.
    const narrative_mod = b.createModule(.{
        .root_source_file = b.path("src/narrative/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "common", .module = common_mod },
            .{ .name = "storage", .module = storage_mod },
            .{ .name = "inference", .module = inference_mod },
        },
    });

    // Adapters module: formal adapter system (CLI socket, Web HTTP, future Discord/etc)
    const adapters_mod = b.createModule(.{
        .root_source_file = b.path("src/adapters/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "common", .module = common_mod },
            .{ .name = "core", .module = core_mod },
            .{ .name = "storage", .module = storage_mod },
            .{ .name = "narrative", .module = narrative_mod },
        },
    });

    // Daemon module: legacy transport wrappers (kept for compatibility during transition)
    const daemon_mod = b.createModule(.{
        .root_source_file = b.path("src/daemon/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "common", .module = common_mod },
            .{ .name = "core", .module = core_mod },
        },
    });

    const client_mod = b.createModule(.{
        .root_source_file = b.path("src/client/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "common", .module = common_mod },
        },
    });

    // Daemon executable
    const daemon_main_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "common", .module = common_mod },
            .{ .name = "api", .module = api_mod },
            .{ .name = "tools", .module = tools_mod },
            .{ .name = "storage", .module = storage_mod },
            .{ .name = "core", .module = core_mod },
            .{ .name = "daemon", .module = daemon_mod },
            .{ .name = "adapters", .module = adapters_mod },
            .{ .name = "workers", .module = workers_mod },
            .{ .name = "inference", .module = inference_mod },
            .{ .name = "narrative", .module = narrative_mod },
        },
    });

    const daemon = b.addExecutable(.{
        .name = "clawforged",
        .root_module = daemon_main_mod,
    });
    b.installArtifact(daemon);

    // CLI client executable
    const cli_main_mod = b.createModule(.{
        .root_source_file = b.path("src/cli.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "common", .module = common_mod },
            .{ .name = "client", .module = client_mod },
        },
    });

    const cli = b.addExecutable(.{
        .name = "clawforge",
        .root_module = cli_main_mod,
    });
    b.installArtifact(cli);

    // Run steps
    const run_daemon = b.addRunArtifact(daemon);
    run_daemon.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_daemon.addArgs(args);
    }

    const run_cli = b.addRunArtifact(cli);
    run_cli.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cli.addArgs(args);
    }

    const daemon_step = b.step("daemon", "Run the daemon");
    daemon_step.dependOn(&run_daemon.step);

    const cli_step = b.step("cli", "Run the CLI client");
    cli_step.dependOn(&run_cli.step);

    // Tests
    const common_test_mod = b.createModule(.{
        .root_source_file = b.path("src/common/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const common_tests = b.addTest(.{
        .root_module = common_test_mod,
    });

    const api_test_mod = b.createModule(.{
        .root_source_file = b.path("src/api/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "common", .module = common_mod },
        },
    });

    const api_tests = b.addTest(.{
        .root_module = api_test_mod,
    });

    const router_test_mod = b.createModule(.{
        .root_source_file = b.path("src/core/router.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "common", .module = common_mod },
        },
    });

    const router_tests = b.addTest(.{
        .root_module = router_test_mod,
    });

    // Storage tests
    const storage_test_mod = b.createModule(.{
        .root_source_file = b.path("src/storage/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "common", .module = common_mod },
            .{ .name = "api", .module = api_mod },
        },
        .link_libc = true,
    });
    storage_test_mod.linkSystemLibrary("sqlite3", .{});

    const storage_tests = b.addTest(.{
        .root_module = storage_test_mod,
    });

    const workers_test_mod = b.createModule(.{
        .root_source_file = b.path("src/workers/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "common", .module = common_mod },
            .{ .name = "api", .module = api_mod },
            .{ .name = "storage", .module = storage_mod },
        },
    });

    const workers_tests = b.addTest(.{
        .root_module = workers_test_mod,
    });

    const inference_tests = b.addTest(.{
        .root_module = inference_mod,
    });

    const narrative_tests = b.addTest(.{
        .root_module = narrative_mod,
    });

    const tools_test_mod = b.createModule(.{
        .root_source_file = b.path("src/tools/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "common", .module = common_mod },
            .{ .name = "api", .module = api_mod },
            .{ .name = "storage", .module = storage_mod },
        },
    });

    const tools_tests = b.addTest(.{
        .root_module = tools_test_mod,
    });

    // SIMD tests
    const simd_test_mod = b.createModule(.{
        .root_source_file = b.path("src/common/simd.zig"),
        .target = target,
        .optimize = optimize,
    });

    const simd_tests = b.addTest(.{
        .root_module = simd_test_mod,
    });

    const run_common_tests = b.addRunArtifact(common_tests);
    const run_api_tests = b.addRunArtifact(api_tests);
    const run_router_tests = b.addRunArtifact(router_tests);
    const run_storage_tests = b.addRunArtifact(storage_tests);
    const run_workers_tests = b.addRunArtifact(workers_tests);
    const run_inference_tests = b.addRunArtifact(inference_tests);
    const run_narrative_tests = b.addRunArtifact(narrative_tests);
    const run_tools_tests = b.addRunArtifact(tools_tests);
    const run_simd_tests = b.addRunArtifact(simd_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_common_tests.step);
    test_step.dependOn(&run_api_tests.step);
    test_step.dependOn(&run_router_tests.step);
    test_step.dependOn(&run_storage_tests.step);
    test_step.dependOn(&run_workers_tests.step);
    test_step.dependOn(&run_inference_tests.step);
    test_step.dependOn(&run_narrative_tests.step);
    test_step.dependOn(&run_tools_tests.step);
    test_step.dependOn(&run_simd_tests.step);
}
