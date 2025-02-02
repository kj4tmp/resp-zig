const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const resp = b.addModule("resp", .{
        .root_source_file = b.path("src/root.zig"),
    });
    const lib_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
    b.default_step.dependOn(&run_lib_unit_tests.step);

    const valkey_client_tests = b.addTest(.{
        .root_source_file = b.path("test/valkey_client.zig"),
        .target = target,
        .optimize = optimize,
    });
    valkey_client_tests.root_module.addImport("resp", resp);
    const run_valkey_client_tests = b.addRunArtifact(valkey_client_tests);
    b.default_step.dependOn(&run_valkey_client_tests.step);
}
