// build.zig — NtripCaster Zig rewrite
// Zig 0.15.x  |  zero external dependencies
//
// Build commands:
//   zig build                                        # host target
//   zig build -Dtarget=aarch64-linux-musl            # RPi (static musl)
//   zig build -Dtarget=aarch64-macos                 # Apple Silicon
//   zig build -Doptimize=ReleaseSafe                 # optimised release
//   zig build test                                   # run all unit tests

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── "ntripcaster" library module (src/ tree exposed for tests) ──────────
    const ntripcaster_mod = b.addModule("ntripcaster", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
    });

    // ── Main executable ────────────────────────────────────────────────────
    const exe = b.addExecutable(.{
        .name = "ntripcaster",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ntripcaster", .module = ntripcaster_mod },
            },
        }),
    });
    b.installArtifact(exe);

    // zig build run [-- args...]
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run ntripcaster").dependOn(&run_cmd.step);

    // ── Unit tests ─────────────────────────────────────────────────────────
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/test_all.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ntripcaster", .module = ntripcaster_mod },
            },
        }),
    });

    b.step("test", "Run all unit tests").dependOn(
        &b.addRunArtifact(unit_tests).step,
    );

    // ── FKP Demo (rtk2go実証クライアント) ─────────────────────────────
    const fkp_demo = b.addExecutable(.{
        .name = "fkp-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/fkp_demo.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ntripcaster", .module = ntripcaster_mod },
            },
        }),
    });
    b.installArtifact(fkp_demo);
    b.step("fkp-demo", "Build FKP demo client").dependOn(&b.addRunArtifact(fkp_demo).step);

    // ── Integration tests (TCP接続テスト) ──────────────────────────────────
    const int_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/test_server.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ntripcaster", .module = ntripcaster_mod },
            },
        }),
    });

    b.step("test-integration", "Run integration tests (TCP)").dependOn(
        &b.addRunArtifact(int_tests).step,
    );
}
