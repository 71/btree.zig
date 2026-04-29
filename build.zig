const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Library.
    const mod = b.addModule("btree", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name = "btree",
        .root_module = mod,
    });
    b.installArtifact(lib);

    // Tests.
    const test_filter = b.option([]const u8, "test-filter", "") orelse "";
    const test_filters = [_][]const u8{test_filter};
    const tests = b.addTest(.{
        .root_module = mod,
        .filters = if (test_filter.len == 0) &.{} else &test_filters,
    });

    const run_tests = b.addRunArtifact(tests);
    const run_tests_step = b.step("test", "Run tests");
    run_tests_step.dependOn(&run_tests.step);

    const build_tests = b.addInstallArtifact(tests, .{
        .dest_sub_path = "debug-unit-tests",
    });
    const build_tests_step = b.step("build-tests", "Build tests");
    build_tests_step.dependOn(&build_tests.step);

    // Benchmarks.
    const benchmarks = b.addExecutable(.{
        .name = "benchmarks",
        .root_module = b.addModule("benchmarks", .{
            .root_source_file = b.path("src/bench.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    benchmarks.root_module.addImport("btree", mod);

    const run_benchmarks = b.addRunArtifact(benchmarks);
    const run_benchmarks_step = b.step("benchmark", "Run benchmarks");
    run_benchmarks_step.dependOn(&run_benchmarks.step);
}
