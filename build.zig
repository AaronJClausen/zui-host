const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const windows = target.result.os.tag == .windows;
    const linux = target.result.os.tag == .linux;
    const has_host = windows or linux;

    const zui_dependency = b.dependency("zui", .{ .target = target, .optimize = optimize });
    const zui_module = zui_dependency.module("zui");

    const host_module = b.addModule("zui_host", .{
        .root_source_file = b.path("zui_host.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zui", .module = zui_module }},
    });
    if (windows) {
        for ([_][]const u8{ "user32", "gdi32", "shell32", "imm32", "dwmapi", "advapi32", "dxgi", "ole32", "oleaut32", "uiautomationcore" }) |library| host_module.linkSystemLibrary(library, .{});
    }
    if (linux) {
        host_module.link_libc = true;
        for ([_][]const u8{ "wayland-client", "xkbcommon" }) |library| host_module.linkSystemLibrary(library, .{});
    }

    const unit_tests = b.addTest(.{ .root_module = host_module });
    linkThroughLlvmOnLinux(unit_tests);
    const test_step = b.step("test", "Run the host's unit tests, and zui's host suite against a window the user never sees");
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);

    const conformance_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path(if (linux) "linux/conformance.zig" else "windows/conformance.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zui_host", .module = host_module },
            .{ .name = "zui_testing", .module = zui_dependency.module("zui_testing") },
            .{ .name = "zui_async", .module = zui_dependency.module("zui_async") },
            .{ .name = "zui_widgets", .module = zui_dependency.module("zui_widgets") },
        },
    }) });
    linkThroughLlvmOnLinux(conformance_tests);
    const conformance_step = b.step("conformance", "Run zui's host suite and the host's own tests against a window the user never sees (Linux: skipped without a Wayland compositor)");
    conformance_step.dependOn(&b.addRunArtifact(conformance_tests).step);
    if (has_host) test_step.dependOn(conformance_step);

    const check_step = b.step("check", "Compile the host and its tests without producing output");
    check_step.dependOn(&unit_tests.step);
    if (has_host) check_step.dependOn(&conformance_tests.step);

    if (has_host) addTour(b, target, optimize, host_module, zui_dependency, check_step);
    if (windows) addWindowsExamples(b, target, optimize, host_module, zui_dependency, check_step);

    const formatted_paths: []const []const u8 = &.{ "build.zig", "build.zig.zon", "zui_host.zig", "windows", "linux", "examples" };
    b.step("fmt", "Format all Zig sources").dependOn(&b.addFmt(.{ .paths = formatted_paths }).step);
    b.step("fmt-check", "Fail if any Zig source is not formatted").dependOn(&b.addFmt(.{ .paths = formatted_paths, .check = true }).step);
}

/// Zig 0.16's own ELF linker rejects the R_X86_64_PC64 relocations in the
/// `.sframe` section that GCC 16's crt1.o carries, and LLD crashes the
/// compiler unless the LLVM backend produced the objects.
fn linkThroughLlvmOnLinux(compile: *std.Build.Step.Compile) void {
    if (compile.rootModuleTarget().os.tag == .linux) {
        compile.use_llvm = true;
        compile.use_lld = true;
    }
}

/// zui-sokol's tour on this host, drawn by zui-sokol's renderer: on
/// Windows through a Direct3D 11 swapchain that DirectComposition composes
/// over the window's backdrop, on Linux with OpenGL through EGL.
fn addTour(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, host_module: *std.Build.Module, zui_dependency: *std.Build.Dependency, check_step: *std.Build.Step) void {
    const zui_sokol_dependency = b.lazyDependency("zui_sokol", .{ .target = target, .optimize = optimize }) orelse return;
    const tour = b.addExecutable(.{
        .name = "zui-host-tour",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/tour.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zui_host", .module = host_module },
                .{ .name = "zui_app", .module = zui_dependency.module("zui_app") },
                .{ .name = "zui_sokol", .module = zui_sokol_dependency.module("zui_sokol") },
                .{ .name = "zui_sokol_tour", .module = zui_sokol_dependency.module("zui_sokol_tour") },
            },
        }),
    });
    linkThroughLlvmOnLinux(tour);
    b.installArtifact(tour);
    const run_tour = b.addRunArtifact(tour);
    if (b.args) |arguments| run_tour.addArgs(arguments);
    b.step("tour", "Run zui-sokol's tour on this host (`-- --measure-idle` reports its idle CPU time)").dependOn(&run_tour.step);
    check_step.dependOn(&tour.step);
}

/// The remote, material, HDR, theme, accessibility, services and title bar examples, which run
/// only on the Windows host so far.
fn addWindowsExamples(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, host_module: *std.Build.Module, zui_dependency: *std.Build.Dependency, check_step: *std.Build.Step) void {
    const app_module = zui_dependency.module("zui_app");
    const zui_sokol_dependency = b.lazyDependency("zui_sokol", .{ .target = target, .optimize = optimize }) orelse return;

    const remote = b.addExecutable(.{
        .name = "zui-host-remote",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/remote.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zui_host", .module = host_module },
                .{ .name = "zui_app", .module = app_module },
                .{ .name = "zui_wire", .module = zui_dependency.module("zui_wire") },
                .{ .name = "zui_sokol", .module = zui_sokol_dependency.module("zui_sokol") },
                .{ .name = "zui_sokol_tour", .module = zui_sokol_dependency.module("zui_sokol_tour") },
            },
        }),
    });
    b.installArtifact(remote);
    const run_remote = b.addRunArtifact(remote);
    if (b.args) |arguments| run_remote.addArgs(arguments);
    b.step("remote", "Run the tour in one process and draw it in this one, over zui_wire (`-- --check tour.bmp` scripts it)").dependOn(&run_remote.step);
    check_step.dependOn(&remote.step);

    const material = b.addExecutable(.{
        .name = "zui-host-material",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/material.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zui_host", .module = host_module },
                .{ .name = "zui_sokol", .module = zui_sokol_dependency.module("zui_sokol") },
            },
        }),
    });
    b.installArtifact(material);
    const run_material = b.addRunArtifact(material);
    if (b.args) |arguments| run_material.addArgs(arguments);
    b.step("material", "Show the desktop through a window, or the solid fallback (`-- --no-system-material`)").dependOn(&run_material.step);
    check_step.dependOn(&material.step);

    const hdr = b.addExecutable(.{
        .name = "zui-host-hdr",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/hdr.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zui_host", .module = host_module },
                .{ .name = "zui_sokol", .module = zui_sokol_dependency.module("zui_sokol") },
            },
        }),
    });
    b.installArtifact(hdr);
    const run_hdr = b.addRunArtifact(hdr);
    if (b.args) |arguments| run_hdr.addArgs(arguments);
    b.step("hdr", "Show HDR white beside SDR white (`-- --measure` reads them back off the desktop in scRGB)").dependOn(&run_hdr.step);
    check_step.dependOn(&hdr.step);

    const theme = b.addExecutable(.{
        .name = "zui-host-theme",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/theme.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zui_host", .module = host_module },
                .{ .name = "zui_async", .module = zui_dependency.module("zui_async") },
                .{ .name = "zui_sokol", .module = zui_sokol_dependency.module("zui_sokol") },
            },
        }),
    });
    b.installArtifact(theme);
    const run_theme = b.addRunArtifact(theme);
    if (b.args) |arguments| run_theme.addArgs(arguments);
    b.step("theme", "Show a window styled by examples/theme.zon, restyled when the file changes (`-- --check` scripts it)").dependOn(&run_theme.step);
    check_step.dependOn(&theme.step);

    const accessible = b.addExecutable(.{
        .name = "zui-host-accessible",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/accessible.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zui_host", .module = host_module },
                .{ .name = "zui_app", .module = app_module },
                .{ .name = "zui_widgets", .module = zui_dependency.module("zui_widgets") },
                .{ .name = "zui_sokol", .module = zui_sokol_dependency.module("zui_sokol") },
            },
        }),
    });
    b.installArtifact(accessible);
    const run_accessible = b.addRunArtifact(accessible);
    if (b.args) |arguments| run_accessible.addArgs(arguments);
    b.step("accessible", "Show zui_widgets controls to UI Automation, for Narrator and Accessibility Insights (`-- --frames 30` quits)").dependOn(&run_accessible.step);
    check_step.dependOn(&accessible.step);

    const services = b.addExecutable(.{
        .name = "zui-host-services",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/services.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zui_host", .module = host_module },
                .{ .name = "zui_app", .module = app_module },
                .{ .name = "zui_async", .module = zui_dependency.module("zui_async") },
                .{ .name = "zui_widgets", .module = zui_dependency.module("zui_widgets") },
                .{ .name = "zui_sokol", .module = zui_sokol_dependency.module("zui_sokol") },
            },
        }),
    });
    b.installArtifact(services);
    const run_services = b.addRunArtifact(services);
    if (b.args) |arguments| run_services.addArgs(arguments);
    b.step("services", "Call every host service from buttons, each answer shown (`-- --check` answers them through the host's fake and quits)").dependOn(&run_services.step);
    check_step.dependOn(&services.step);

    const title_bar = b.addExecutable(.{
        .name = "zui-host-title-bar",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/title_bar.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zui_host", .module = host_module },
                .{ .name = "zui_app", .module = app_module },
                .{ .name = "zui_widgets", .module = zui_dependency.module("zui_widgets") },
                .{ .name = "zui_sokol", .module = zui_sokol_dependency.module("zui_sokol") },
            },
        }),
    });
    b.installArtifact(title_bar);
    const run_title_bar = b.addRunArtifact(title_bar);
    if (b.args) |arguments| run_title_bar.addArgs(arguments);
    b.step("title-bar", "Draw the title bar in the window, which Windows still drags, snaps and resizes (`-- --check` hit-tests it hidden and quits)").dependOn(&run_title_bar.step);
    check_step.dependOn(&title_bar.step);
}
