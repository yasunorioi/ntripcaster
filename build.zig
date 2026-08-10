// build.zig — NtripCaster Zig rewrite
// Zig 0.15.x ONLY  |  zero external dependencies
//
// 0.16+ requires migrating Mutex / net to the new std.Io interface
// (entire codebase needs an *Io runtime threaded through Server / Source
// / Relay / FKP). Not yet done. Pin to 0.15.x for now.
//
// Build commands:
//   zig build                                        # host target
//   zig build -Dtarget=aarch64-linux-musl            # RPi (static musl)
//   zig build -Dtarget=aarch64-macos                 # Apple Silicon
//   zig build -Doptimize=ReleaseSafe                 # optimised release
//   zig build test                                   # run all unit tests

const std = @import("std");
const builtin = @import("builtin");

// Hard-fail on 0.16+ rather than producing 200 lines of API errors.
comptime {
    const v = builtin.zig_version;
    if (v.major != 0 or v.minor != 15) {
        @compileError(std.fmt.comptimePrint(
            "ntripcaster currently requires Zig 0.15.x (found {d}.{d}.{d}). " ++
                "0.16+ port is blocked on the std.Io interface migration " ++
                "(std.Thread.Mutex → std.Io.Mutex, std.net → std.Io.net). " ++
                "Install Zig 0.15.2 from https://ziglang.org/download/0.15.2/",
            .{ v.major, v.minor, v.patch },
        ));
    }
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── build options (comptime-baked flags) ───────────────────────────────
    const options_step = b.addOptions();
    options_step.addOption(
        bool,
        "vrs_inject_antenna",
        b.option(bool, "vrs-inject-antenna", "Inject RTCM3 Type 1008 antenna descriptor for VRS rovers") orelse false,
    );
    // I/O backend 選択 (src/io.zig)。posix=host/Linux/クラウド、lwip=ESP-IDF(Tab5)。
    // lwip backend は未実装 (io_lwip.zig TODO)。host ビルドは posix のまま。
    const IoBackend = enum { posix, lwip };
    options_step.addOption(
        IoBackend,
        "io_backend",
        b.option(IoBackend, "io-backend", "I/O backend: posix (host/cloud) or lwip (ESP-IDF/Tab5)") orelse .posix,
    );
    const options_mod = options_step.createModule();

    // ── "ntripcaster" library module (src/ tree exposed for tests) ──────────
    const ntripcaster_mod = b.addModule("ntripcaster", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "build_options", .module = options_mod },
        },
    });

    // ── Main executable ────────────────────────────────────────────────────
    // build_options を直接 imports に入れているのは、vrs.zig が
    // `@import("build_options")` を持つため。lib.zig 経由 (ntripcaster_mod) の
    // `.imports` だけだと Zig 0.15.2 ではトランジティブに解決されず
    // 「no module named 'build_options' available within module 'root'」になる。
    const exe = b.addExecutable(.{
        .name = "ntripcaster",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ntripcaster", .module = ntripcaster_mod },
                .{ .name = "build_options", .module = options_mod },
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
                .{ .name = "build_options", .module = options_mod },
            },
        }),
    });

    // src/ ツリー内の `test {}` ブロックを拾うため、lib.zig をテストルート
    // にした step を併走させる (tests/test_all.zig のモジュール境界では
    // src/ 配下の test ブロックが集約されない)。
    const src_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "build_options", .module = options_mod },
            },
        }),
    });

    const test_step = b.step("test", "Run all unit tests");
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);
    test_step.dependOn(&b.addRunArtifact(src_tests).step);

    // ── FKP Demo (実証クライアント) ────────────────────────────────────
    const fkp_demo = b.addExecutable(.{
        .name = "fkp-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/fkp_demo.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ntripcaster", .module = ntripcaster_mod },
                .{ .name = "build_options", .module = options_mod },
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
                .{ .name = "build_options", .module = options_mod },
            },
        }),
    });

    b.step("test-integration", "Run integration tests (TCP)").dependOn(
        &b.addRunArtifact(int_tests).step,
    );

    // ── Embedded static library (M2: ESP-IDF/Tab5 link target) ─────────────
    // ESP-IDF の CMake component がこの成果物 (libntripcaster.a) を firmware に
    // リンクする。cross-compile の健全性検証用にも使う:
    //   zig build caster-lib -Dio-backend=lwip \
    //     -Dtarget=riscv32-freestanding -Dcpu=generic_rv32+m+a+f+c
    const caster_mod = b.createModule(.{
        .root_source_file = b.path("src/embedded.zig"),
        .target = target,
        .optimize = optimize,
        // ESP-IDF provides newlib (malloc/free → PSRAM) and pthread. Zig
        // needs libc "declared" to permit the extern "c" allocator decls;
        // the actual symbols are resolved by the IDF final link. On the host
        // this links the system libc for real (so the lib is host-buildable).
        .link_libc = true,
        .imports = &.{
            .{ .name = "build_options", .module = options_mod },
        },
    });
    // ESP-IDF component ビルドが FreeRTOS/lwip の include dir 群を
    // `NTRIPCASTER_IDF_INCLUDES` (`;` 区切り) で渡してくる。io_lwip.zig /
    // os_lwip.zig の @cImport がこれらを解決する。host ビルド (env 未設定)
    // では素通り。
    if (std.process.getEnvVarOwned(b.allocator, "NTRIPCASTER_IDF_INCLUDES")) |inc| {
        var it = std.mem.tokenizeScalar(u8, inc, ';');
        while (it.next()) |dir| {
            if (dir.len == 0) continue;
            caster_mod.addSystemIncludePath(.{ .cwd_relative = dir });
        }
    } else |_| {}

    const caster_lib = b.addLibrary(.{
        .name = "ntripcaster",
        .linkage = .static,
        .root_module = caster_mod,
    });
    // Bundle compiler-rt into the archive: std.fmt's float formatter pulls in
    // 128-bit division (__udivti3) which the riscv32 libgcc esp-idf links does
    // not provide. Zig's compiler-rt has it.
    caster_lib.bundle_compiler_rt = true;
    b.step("caster-lib", "Build embedded static library (ESP-IDF link target)").dependOn(
        &b.addInstallArtifact(caster_lib, .{}).step,
    );
}
