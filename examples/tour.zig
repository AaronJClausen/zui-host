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
const zui_app = @import("zui_app");
const tour = @import("zui_sokol_tour");
const capture = @import("capture.zig");
const zui = zui_host.zui;
const win32 = zui_host.windows.win32;
const Ui = tour.kit.Ui;

pub fn main(init: std.process.Init) !void {
    try zui_app.run(TourOnHost, init, .{ .title = "zui tour (zui-host, sokol)", .size = .{ 1440, 900 } });
}

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

/// zui-sokol's tour application, unchanged, as `zui_app` runs one: this
/// names the host, the renderer and the tour's text contract, and passes
/// each step on.
const TourOnHost = struct {
    pub const Host = zui_host.Host;
    pub const Renderer = SokolRenderer;
    pub const Text = zui_sokol.Text;

    tour: tour.App,
    sources: *tour.kit.Sources,
    host: *Host,
    renderer: *SokolRenderer,
    gpa: std.mem.Allocator,
    options: Options,
    launched_at: zui.Instant,
    frames: u64 = 0,
    next: ?zui.NextFrame = null,
    reason: tour.FrameReason = .first,
    polled_at: zui.Instant = .zero,
    declare_started_at: zui.Instant = .zero,
    declared_at: zui.Instant = .zero,
    measurement: ?IdleMeasurement = null,

    pub fn init(app: *TourOnHost, start: zui_app.Start(TourOnHost)) !void {
        const options: Options = if (start.process) |process| try parseOptions(try process.minimal.args.toSlice(process.arena.allocator())) else .{};
        app.* = .{
            .tour = undefined,
            .sources = &app.tour.sources,
            .host = start.host,
            .renderer = start.renderer,
            .gpa = start.gpa,
            .options = options,
            .launched_at = start.host.now(),
        };
        app.tour.init(start.io, start.host.now());
        app.tour.host_waker = start.waker;
        if (options.screen) |screen| app.tour.current = screen;
        app.tour.cycle_every = options.cycle_every;
        if (options.measure_idle) app.tour.heartbeat = false;
        if (options.screenshot_path != null) app.tour.live = true;
        start.renderer.io = start.io;
    }

    pub fn deinit(app: *TourOnHost) void {
        app.tour.deinit();
        if (app.options.frame_limit != null) {
            std.debug.print("drew {d} frames, {d} layer overflows, diagnostics ok: {}\n", .{ app.frames, app.renderer.sokol.layer_overflows, app.tour.perf.diagnostics.ok() });
        }
    }

    pub fn zuiRecord(app: *TourOnHost, record: *zui.RecordBuilder) void {
        record.params.zoom = app.tour.zoom;
        for (app.tour.environment_changes.drain()) |change| record.append(.{ .environment = change });
        app.reason = frameReason(app.next, record.events().len != 0);
        app.polled_at = app.host.now();
    }

    pub fn zuiDeclare(app: *TourOnHost, ui: *Ui) void {
        if (app.options.measure_idle) app.measurement = app.measureIdle(ui) catch |err| switch (err) {
            error.MeasurementDone => finished: {
                app.host.close();
                break :finished null;
            },
        };
        app.declare_started_at = app.host.now();
        app.tour.declare(ui);
        app.declared_at = app.host.now();
        app.renderer.sokol.clear_color = tour.kit.Palette.forEnvironment(ui.environment()).background;
    }

    pub fn zuiLoader(app: *TourOnHost, ui: *const Ui, io: std.Io) void {
        app.recordPerf();
        // The tour's loaders only read `ui`; they take it as zui-sokol's own loop gives it.
        app.tour.afterFrame(@constCast(ui));

        app.frames += 1;
        if (app.options.screenshot_path) |path| if (app.frames == screenshot_after_frames) {
            capture.saveClientArea(app.gpa, io, app.host.hwnd, path) catch |err| std.log.err("could not save {s}: {t}", .{ path, err });
            app.host.close();
        };
        if (app.options.frame_limit) |limit| if (app.frames == limit) app.host.close();
        app.next = ui.nextFrame(app.sources);
        app.tour.perf.next_frame = app.next.?;
    }

    /// Settles for a second, then measures from one requested frame to
    /// another 10 s later: whatever ran in between was the idle tour.
    fn measureIdle(app: *TourOnHost, ui: *Ui) error{MeasurementDone}!?IdleMeasurement {
        const now = ui.now();
        const started = app.measurement orelse {
            const settle_until = app.launched_at.addSeconds(idle_settle_seconds);
            if (now.isBefore(settle_until)) {
                ui.requestFrameAt(settle_until);
                return null;
            }
            const ends_at = now.addSeconds(idle_seconds);
            ui.requestFrameAt(ends_at);
            return .{ .ends_at = ends_at, .cpu_100ns = IdleMeasurement.processCpu100ns(), .frames = app.frames, .wakes = app.tour.wakes.load(.monotonic) };
        };
        if (now.isBefore(started.ends_at)) {
            ui.requestFrameAt(started.ends_at);
            return started;
        }
        const cpu_ms = @as(f64, @floatFromInt(IdleMeasurement.processCpu100ns() - started.cpu_100ns)) / 10_000;
        // Less the measurement's own frame.
        const frames_between = app.frames - started.frames - 1;
        std.debug.print("idle: {d:.1} ms of CPU over {d} s, {d} frames, {d} wakes\n", .{ cpu_ms, idle_seconds, frames_between, app.tour.wakes.load(.monotonic) - started.wakes });
        return error.MeasurementDone;
    }

    fn recordPerf(app: *TourOnHost) void {
        const submitted = app.renderer.last_submit;
        const perf = &app.tour.perf;
        perf.record(.{
            .begin_frame_us = microsecondsBetween(app.polled_at, app.declare_started_at),
            .declare_us = microsecondsBetween(app.declare_started_at, app.declared_at),
            .end_frame_us = microsecondsBetween(app.declared_at, submitted.started_at),
            .elements = submitted.elements,
            .commands = submitted.commands,
            .measure_calls = 0,
            .reason = app.reason,
        });
        perf.zui_frames += 1;
        perf.display_frames += 1;
        perf.submit_us = microsecondsBetween(submitted.started_at, submitted.ended_at);
        perf.diagnostics = submitted.diagnostics;
        perf.wakes = app.tour.wakes.load(.monotonic);
    }
};

/// zui-sokol's renderer as `zui_app` opens one: drawing into the host's
/// window with the tour's text, and timing each submit for the tour's
/// performance strip.
const SokolRenderer = struct {
    pub const zui_surfaces: zui.SurfaceKinds = .initOne(.win32);
    pub const ImageHandle = zui_sokol.Renderer.ImageHandle;

    sokol: zui_sokol.Renderer,
    /// Set by the application, which has the `Io`; until then submits are not timed.
    io: ?std.Io = null,
    last_submit: Submitted = .{},

    const Submitted = struct {
        started_at: zui.Instant = .zero,
        ended_at: zui.Instant = .zero,
        elements: u32 = 0,
        commands: u32 = 0,
        diagnostics: zui.Diagnostics = .{},
    };

    pub fn init(self: *SokolRenderer, surface: zui.Surface, text: *const zui_sokol.Text) !void {
        self.sokol = try .initForSurface(text, surface);
    }

    pub fn deinit(self: *SokolRenderer) void {
        self.sokol.deinit();
    }

    pub fn zuiSubmit(self: *SokolRenderer, surface: zui.Surface, frame: anytype) !void {
        const io = self.io orelse return self.sokol.zuiSubmit(surface, frame);
        const started_at: zui.Instant = .fromTimestamp(std.Io.Timestamp.now(io, .awake));
        try self.sokol.zuiSubmit(surface, frame);
        self.last_submit = .{
            .started_at = started_at,
            .ended_at = .fromTimestamp(std.Io.Timestamp.now(io, .awake)),
            .elements = frame.elementCount(),
            .commands = @intCast(frame.commands().len),
            .diagnostics = frame.diagnostics,
        };
    }
};

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

fn frameReason(previous: ?zui.NextFrame, has_events: bool) tour.FrameReason {
    const next = previous orelse return .first;
    if (has_events) return .input;
    return switch (next) {
        .immediately => .requested,
        .at => .timer,
        .on_event => .source,
    };
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
