const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const windows = target.result.os.tag == .windows;

    const zui_dependency = b.dependency("zui", .{ .target = target, .optimize = optimize });
    const zui_module = zui_dependency.module("zui");

    const host_module = b.addModule("zui_host", .{
        .root_source_file = b.path("zui_host.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zui", .module = zui_module }},
    });
    if (windows) {
        for ([_][]const u8{ "user32", "shell32", "imm32", "dwmapi", "advapi32" }) |library| host_module.linkSystemLibrary(library, .{});
    }

    const unit_tests = b.addTest(.{ .root_module = host_module });
    const test_step = b.step("test", "Run the host's unit tests, and on Windows zui's host suite against a hidden window");
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);

    const conformance_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("windows/conformance.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zui_host", .module = host_module },
            .{ .name = "zui_testing", .module = zui_dependency.module("zui_testing") },
        },
    }) });
    const conformance_step = b.step("conformance", "Run zui's host suite and the host's own tests against a hidden window");
    conformance_step.dependOn(&b.addRunArtifact(conformance_tests).step);
    if (windows) test_step.dependOn(conformance_step);

    const check_step = b.step("check", "Compile the host and its tests without producing output");
    check_step.dependOn(&unit_tests.step);
    if (windows) check_step.dependOn(&conformance_tests.step);

    if (windows) addTour(b, target, optimize, host_module, check_step);

    const formatted_paths: []const []const u8 = &.{ "build.zig", "build.zig.zon", "zui_host.zig", "windows", "examples" };
    b.step("fmt", "Format all Zig sources").dependOn(&b.addFmt(.{ .paths = formatted_paths }).step);
    b.step("fmt-check", "Fail if any Zig source is not formatted").dependOn(&b.addFmt(.{ .paths = formatted_paths, .check = true }).step);
}

/// zui-sokol's tour on this host, drawn by zui-sokol's renderer with
/// OpenGL, which is how it draws into a `win32` surface.
fn addTour(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, host_module: *std.Build.Module, check_step: *std.Build.Step) void {
    const zui_sokol_dependency = b.lazyDependency("zui_sokol", .{ .target = target, .optimize = optimize, .gl = true }) orelse return;
    const tour = b.addExecutable(.{
        .name = "zui-host-tour",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/tour.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zui_host", .module = host_module },
                .{ .name = "zui_sokol", .module = zui_sokol_dependency.module("zui_sokol") },
                .{ .name = "zui_sokol_tour", .module = zui_sokol_dependency.module("zui_sokol_tour") },
            },
        }),
    });
    b.installArtifact(tour);
    const run_tour = b.addRunArtifact(tour);
    if (b.args) |arguments| run_tour.addArgs(arguments);
    b.step("tour", "Run zui-sokol's tour on the Windows host (`-- --measure-idle` reports its idle CPU time)").dependOn(&run_tour.step);
    check_step.dependOn(&tour.step);
}
