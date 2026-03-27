// build.zig — NtripCaster Zig rewrite
// Zig 0.14.0+  |  zero external dependencies
//
// Build commands:
//   zig build                                        # host target
//   zig build -Dtarget=aarch64-linux-musl            # RPi (static musl)
//   zig build -Dtarget=aarch64-macos                 # Apple Silicon
//   zig build -Doptimize=ReleaseSafe                 # optimised release
//   zig build test                                   # run all unit tests

const std = @import("std");

pub fn build(b: *std.Build) void {
    // zig build -Dtarget=<triple>  for cross-compilation
    // Supported: x86_64-linux[-musl], aarch64-linux[-musl], aarch64-macos
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Main executable ──────────────────────────────────────────────────────
    const exe = b.addExecutable(.{
        .name = "ntripcaster",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        // No libc linkage — Zig stdlib only, static by default
    });
    b.installArtifact(exe);

    // zig build run [-- args...]
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run ntripcaster").dependOn(&run_cmd.step);

    // ── "ntripcaster" module (src/ tree exposed for tests) ───────────────────
    // src/lib.zig re-exports config and auth submodules.
    // Relative imports within src/ work because lib.zig is the module root.
    const ntripcaster_mod = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
    });

    // ── Unit tests ───────────────────────────────────────────────────────────
    const unit_tests = b.addTest(.{
        .root_source_file = b.path("tests/test_all.zig"),
        .target = target,
        .optimize = optimize,
    });
    // Make the "ntripcaster" module available to test files
    unit_tests.root_module.addImport("ntripcaster", ntripcaster_mod);

    b.step("test", "Run all unit tests").dependOn(
        &b.addRunArtifact(unit_tests).step,
    );
}
