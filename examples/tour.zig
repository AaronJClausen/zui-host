//! zui-sokol's tour on the Windows host, drawn by zui-sokol's renderer into
//! the host's window. The tour's application is zui-sokol's own, unchanged:
//! this file is only the loop of SPEC.md §6.1 around it.
//!
//! ```sh
//! zig build tour                               # interactive window
//! zig build tour -- --screen box_storm         # start on one screen
//! zig build tour -- --frames 300 --cycle 30    # visit every screen, 30 frames each, then quit
//! zig build tour -- --measure-idle             # report the CPU time used over 10 idle seconds
//! zig build tour -- --screenshot tour.bmp      # save the window after a few frames, then quit
//! ```

const std = @import("std");
const zui_host = @import("zui_host");
const zui_sokol = @import("zui_sokol");
const tour = @import("zui_sokol_tour");
const capture = @import("capture.zig");
const zui = zui_host.zui;
const win32 = zui_host.windows.win32;
const Host = zui_host.Host;
const Renderer = zui_sokol.Renderer;
const App = tour.App;
const Ui = tour.kit.Ui;

const Options = struct {
    screen: ?tour.kit.Screen = null,
    frame_limit: ?u64 = null,
    cycle_every: ?u32 = null,
    measure_idle: bool = false,
    screenshot_path: ?[]const u8 = null,
};

/// Frames drawn before a screenshot, so it shows a settled layout.
const screenshot_after_frames = 5;

const idle_settle_seconds = 1;
const idle_seconds = 10;

/// The process's CPU time and the loop's counts at the start of the idle
/// window, read again at its end.
const IdleMeasurement = struct {
    ends_at: zui.Instant,
    cpu_100ns: u64,
    frames: u64,
    wakes: u32,

    fn processCpu100ns() u64 {
        var creation: u64 = 0;
        var exit: u64 = 0;
        var kernel: u64 = 0;
        var user: u64 = 0;
        _ = win32.GetProcessTimes(win32.GetCurrentProcess(), &creation, &exit, &kernel, &user);
        return kernel + user;
    }
};

pub fn main(init: std.process.Init) !void {
    comptime zui.checkHostAndRenderer(Host, Renderer);
    const options = try parseOptions(try init.minimal.args.toSlice(init.arena.allocator()));
    const gpa = init.gpa;
    const io = init.io;

    const host = try gpa.create(Host);
    defer gpa.destroy(host);
    host.forced_scale = null;
    try host.init(io, .{ .title = "zui tour (zui-host, sokol)", .size = .{ 1440, 900 } });
    defer host.deinit();

    var text: zui_sokol.Text = .{};
    var renderer: Renderer = try .initForSurface(&text, host.zuiSurface(.main));
    defer renderer.deinit();

    const app = try gpa.create(App);
    defer gpa.destroy(app);
    app.init(io, host.now());
    defer app.deinit();
    app.host_waker = host.zuiWaker();
    if (options.screen) |screen| app.current = screen;
    app.cycle_every = options.cycle_every;
    if (options.measure_idle) app.heartbeat = false;
    if (options.screenshot_path != null) app.live = true;

    var ui: Ui = try .init(gpa, io, &text);
    defer ui.deinit(gpa);

    var events: [Ui.limits.max_events_per_frame]zui.Event = undefined;
    var text_buffer: [Ui.limits.max_text_input_bytes + Ui.limits.max_dropped_path_bytes]u8 = undefined;
    var builder: zui.RecordBuilder = .init(&events, &text_buffer);
    var next: ?zui.NextFrame = null;
    var frames: u64 = 0;
    var measurement: ?IdleMeasurement = null;
    const launched_at = host.now();

    while (true) {
        builder.params.zoom = app.zoom;
        if (!host.zuiPoll(.main, &builder)) break;
        for (app.environment_changes.drain()) |change| builder.append(.{ .environment = change });
        const reason = frameReason(next, builder.events().len != 0);

        const started = host.now();
        ui.beginFrame(&builder.recordWith(Ui.Deliveries), &app.sources);
        if (options.measure_idle) measurement = measureIdle(&ui, app, measurement, launched_at, frames) catch |err| switch (err) {
            error.MeasurementDone => break,
        };
        const began = host.now();
        app.declare(&ui);
        const declared = host.now();
        const frame = ui.endFrame();
        const ended = host.now();

        renderer.clear_color = tour.kit.Palette.forEnvironment(ui.environment()).background;
        try renderer.zuiSubmit(host.zuiSurface(.main), frame);
        const submitted = host.now();
        host.zuiApply(.main, frame.requests());
        recordPerf(app, &ui, frame, reason, .{ started, began, declared, ended, submitted });
        ui.release(frame);
        app.afterFrame(&ui);

        frames += 1;
        if (options.screenshot_path) |path| if (frames == screenshot_after_frames) {
            try capture.saveClientArea(gpa, io, host.hwnd, path);
            break;
        };
        if (options.frame_limit) |limit| if (frames >= limit) break;
        next = ui.nextFrame(&app.sources);
        app.perf.next_frame = next.?;
        host.zuiWait(next.?);
    }
    if (options.frame_limit != null) {
        std.debug.print("drew {d} frames, {d} layer overflows, diagnostics ok: {}\n", .{ frames, renderer.layer_overflows, app.perf.diagnostics.ok() });
    }
}

/// Settles for a second, then measures from one requested frame to
/// another 10 s later: whatever ran in between was the idle tour.
fn measureIdle(ui: *Ui, app: *App, measurement: ?IdleMeasurement, launched_at: zui.Instant, frames: u64) error{MeasurementDone}!?IdleMeasurement {
    const now = ui.now();
    const started = measurement orelse {
        const settle_until = launched_at.addSeconds(idle_settle_seconds);
        if (now.isBefore(settle_until)) {
            ui.requestFrameAt(settle_until);
            return null;
        }
        const ends_at = now.addSeconds(idle_seconds);
        ui.requestFrameAt(ends_at);
        return .{ .ends_at = ends_at, .cpu_100ns = IdleMeasurement.processCpu100ns(), .frames = frames, .wakes = app.wakes.load(.monotonic) };
    };
    if (now.isBefore(started.ends_at)) {
        ui.requestFrameAt(started.ends_at);
        return started;
    }
    const cpu_ms = @as(f64, @floatFromInt(IdleMeasurement.processCpu100ns() - started.cpu_100ns)) / 10_000;
    // Less the measurement's own frame.
    const frames_between = frames - started.frames - 1;
    std.debug.print("idle: {d:.1} ms of CPU over {d} s, {d} frames, {d} wakes\n", .{ cpu_ms, idle_seconds, frames_between, app.wakes.load(.monotonic) - started.wakes });
    return error.MeasurementDone;
}

fn frameReason(previous: ?zui.NextFrame, has_events: bool) tour.FrameReason {
    const next = previous orelse return .first;
    if (has_events) return .input;
    return switch (next) {
        .immediately => .requested,
        .at => .timer,
        .on_event => .source,
    };
}

fn recordPerf(app: *App, ui: *const Ui, frame: *const Ui.Frame, reason: tour.FrameReason, at: [5]zui.Instant) void {
    const perf = &app.perf;
    perf.record(.{
        .begin_frame_us = microsecondsBetween(at[0], at[1]),
        .declare_us = microsecondsBetween(at[1], at[2]),
        .end_frame_us = microsecondsBetween(at[2], at[3]),
        .elements = frame.elementCount(),
        .commands = @intCast(frame.commands().len),
        .measure_calls = 0,
        .reason = reason,
    });
    perf.zui_frames += 1;
    perf.display_frames += 1;
    perf.submit_us = microsecondsBetween(at[3], at[4]);
    perf.diagnostics = frame.diagnostics;
    perf.wakes = app.wakes.load(.monotonic);
    _ = ui;
}

fn microsecondsBetween(earlier: zui.Instant, later: zui.Instant) f32 {
    return later.secondsSince(earlier) * std.time.us_per_s;
}

fn parseOptions(arguments: []const [:0]const u8) !Options {
    var options: Options = .{};
    var index: usize = 1;
    while (index < arguments.len) : (index += 1) {
        const argument = arguments[index];
        const has_value = index + 1 < arguments.len;
        if (std.mem.eql(u8, argument, "--screen") and has_value) {
            index += 1;
            options.screen = std.meta.stringToEnum(tour.kit.Screen, arguments[index]) orelse return error.UnknownScreen;
        } else if (std.mem.eql(u8, argument, "--frames") and has_value) {
            index += 1;
            options.frame_limit = try std.fmt.parseInt(u64, arguments[index], 10);
        } else if (std.mem.eql(u8, argument, "--cycle") and has_value) {
            index += 1;
            options.cycle_every = try std.fmt.parseInt(u32, arguments[index], 10);
        } else if (std.mem.eql(u8, argument, "--screenshot") and has_value) {
            index += 1;
            options.screenshot_path = arguments[index];
        } else if (std.mem.eql(u8, argument, "--measure-idle")) {
            options.measure_idle = true;
        } else {
            std.debug.print("unknown argument \"{s}\"; expected --screen <name>, --frames <count>, --cycle <frames>, --measure-idle or --screenshot <path>\n", .{argument});
            return error.UnknownArgument;
        }
    }
    return options;
}
