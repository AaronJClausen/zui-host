//! One application with many windows: each declares its own UI in a
//! context of its own, counts its own clicks, and shows a count shared by
//! every window, which the application publishes into each window's
//! sources. Any window can open another or close itself; the run ends when
//! the last one closes.
//!
//! ```sh
//! zig build many-windows                         # interactive windows
//! zig build many-windows -- --check              # open, click and close hidden windows, then quit
//! zig build many-windows -- --measure-idle       # CPU time of two idle windows over 10 s
//! zig build many-windows -- --measure-animation  # frame rates of one, then two, windows animating
//! ```

const std = @import("std");
const builtin = @import("builtin");
const zui_host = @import("zui_host");
const zui_sokol = @import("zui_sokol");
const zui_app = @import("zui_app");
const zui_async = @import("zui_async");
const zui_widgets = @import("zui_widgets");
const zui = zui_host.zui;
const win32 = zui_host.windows.win32;

const WindowSources = struct { shared_count: zui_async.Latest(u32) = .{} };
const Ui = zui.Context(zui_sokol.config(.{ .Sources = WindowSources }));
const Widgets = zui_widgets.Widgets(Ui);
const ids = zui.ids(.{ "root", "add_here", "add_everywhere", "open", "close" });

pub fn main(init: std.process.Init) !void {
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    var mode: Mode = .interactive;
    for (arguments[1..]) |argument| {
        mode = std.meta.stringToEnum(Mode, argument) orelse {
            std.debug.print("unknown argument \"{s}\"; expected --check, --measure-idle or --measure-animation\n", .{argument});
            return error.UnknownArgument;
        };
    }

    const runner = try init.gpa.create(zui_app.Runner(ManyWindowsApp));
    defer init.gpa.destroy(runner);
    try runner.start(.{ .gpa = init.gpa, .io = init.io, .process = init }, .{
        .title = "zui: window 0",
        .size = .{ 480, 320 },
        .visible = mode != .@"--check",
    });
    defer runner.stop();
    try runner.app.begin(mode);
    while (try runner.frame()) {}
    if (runner.app.failure) |failure| {
        std.debug.print("many-windows check: {s}\n", .{failure});
        return error.CheckFailed;
    }
    if (mode == .@"--check") std.debug.print("many-windows check: two windows opened, each took only its own clicks, the shared count reached both, and the first drew on after the second closed\n", .{});
}

const Mode = enum { interactive, @"--check", @"--measure-idle", @"--measure-animation" };

/// What each open window has: its id, its sources and its own count.
const Slot = struct {
    id: ?zui.WindowId = null,
    sources: WindowSources = .{},
    clicks_here: u32 = 0,
    shared_shown: u32 = 0,
    frames: u32 = 0,
};

const ManyWindowsApp = struct {
    pub const Host = zui_host.Host;
    pub const Renderer = SokolRenderer;
    pub const Text = zui_sokol.Text;

    host: *Host = undefined,
    windows: zui_app.Windows(ManyWindowsApp) = undefined,
    waker: zui.Waker = undefined,
    widgets: Widgets = .{},
    slots: [Host.max_windows]Slot = @splat(.{}),
    shared_count: u32 = 0,
    publish_shared: bool = false,
    open_requested: bool = false,
    mode: Mode = .interactive,
    check: Check = .{},
    idle: ?IdleMeasurement = null,
    idle_settle_until: ?zui.Instant = null,
    animation: Animation = .{},
    failure: ?[]const u8 = null,

    pub fn init(app: *ManyWindowsApp, start: zui_app.Start(ManyWindowsApp)) !void {
        app.* = .{ .host = start.host, .windows = start.windows, .waker = start.waker };
        app.slots[0].id = .main;
    }

    /// After `start`, which opens the first window, so the mode is known
    /// before the second opens.
    fn begin(app: *ManyWindowsApp, mode: Mode) !void {
        app.mode = mode;
        switch (mode) {
            .interactive, .@"--measure-idle", .@"--measure-animation" => try app.openWindow(mode != .@"--check"),
            .@"--check" => {},
        }
    }

    fn openWindow(app: *ManyWindowsApp, visible: bool) !void {
        const slot = for (&app.slots) |*slot| {
            if (slot.id == null) break slot;
        } else return error.TooManyWindows;
        var title_bytes: [32:0]u8 = undefined;
        const index = (@intFromPtr(slot) - @intFromPtr(&app.slots)) / @sizeOf(Slot);
        const title = std.fmt.bufPrintZ(&title_bytes, "zui: window {d}", .{index}) catch unreachable;
        const id = try app.windows.open(.{ .title = title, .size = .{ 480, 320 }, .visible = visible });
        slot.* = .{ .id = id };
        app.publish_shared = true;
    }

    fn slotOf(app: *ManyWindowsApp, window: zui.WindowId) *Slot {
        for (&app.slots) |*slot| if (slot.id == window) return slot;
        unreachable;
    }

    pub fn zuiSources(app: *ManyWindowsApp, window: zui.WindowId) *WindowSources {
        return &app.slotOf(window).sources;
    }

    pub fn zuiDeclare(app: *ManyWindowsApp, ui: *Ui, window: zui.WindowId) void {
        const slot = app.slotOf(window);
        slot.frames += 1;
        if (ui.source(.shared_count).get()) |count| slot.shared_shown = count;
        if (app.mode == .@"--check" or (app.mode == .@"--measure-animation" and app.animation.animates(window))) ui.requestFrame();
        if (app.mode == .@"--measure-idle" and window == .main) app.measureIdle(ui);

        ui.open(.{
            .id = ids.root,
            .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both, .padding = .all(24), .child_gap = 12 },
            .decoration = .{ .background = if (window == .main) .rgb(0x1c1c26) else .rgb(0x1c2620) },
        });
        defer ui.close();
        var line_bytes: [64]u8 = undefined;
        app.widgets.label(ui, std.fmt.bufPrint(&line_bytes, "Window {d}", .{@intFromEnum(window)}) catch unreachable);
        app.widgets.label(ui, std.fmt.bufPrint(&line_bytes, "Clicked here {d} times", .{slot.clicks_here}) catch unreachable);
        app.widgets.label(ui, std.fmt.bufPrint(&line_bytes, "Clicked everywhere {d} times", .{slot.shared_shown}) catch unreachable);
        if (app.widgets.button(ui, ids.add_here, "Add one here", .{})) slot.clicks_here += 1;
        if (app.widgets.button(ui, ids.add_everywhere, "Add one everywhere", .{})) {
            app.shared_count += 1;
            app.publish_shared = true;
        }
        if (app.widgets.button(ui, ids.open, "Open a window", .{})) app.open_requested = true;
        if (app.widgets.button(ui, ids.close, "Close this window", .{})) app.windows.close(window);
    }

    pub fn zuiLoader(app: *ManyWindowsApp, ui: *const Ui, window: zui.WindowId, _: std.Io) void {
        if (app.open_requested) {
            app.open_requested = false;
            app.openWindow(true) catch |err| std.debug.print("could not open a window: {t}\n", .{err});
        }
        if (app.publish_shared) {
            app.publish_shared = false;
            for (&app.slots) |*slot| if (slot.id != null) app.waker.wakeIf(slot.sources.shared_count.publish(app.shared_count));
        }
        switch (app.mode) {
            .@"--check" => app.stepCheck(ui, window),
            .@"--measure-animation" => app.animation.step(app, ui, window),
            else => {},
        }
    }

    pub fn zuiWindowClosed(app: *ManyWindowsApp, window: zui.WindowId) void {
        app.slotOf(window).* = .{};
        if (app.mode == .@"--check") app.check.closed = window;
    }

    /// Opens a hidden second window, clicks its buttons through the host,
    /// expects only it to count its own click and both to show the shared
    /// count, then closes it and expects the first to draw on.
    fn stepCheck(app: *ManyWindowsApp, ui: *const Ui, window: zui.WindowId) void {
        const check = &app.check;
        check.turns += 1;
        if (check.turns > 2000) return app.fail("the check did not finish within 2000 frames");
        switch (check.step) {
            .open_second => if (window == .main) {
                app.openWindow(false) catch return app.fail("could not open the second window");
                check.second = app.slots[1].id;
                check.step = .click_second;
            },
            .click_second => if (window == check.second and app.slotOf(window).frames >= 3) {
                app.clickAt(window, ui.rectOf(ids.add_here) orelse return) catch return app.fail("could not click the second window");
                app.clickAt(window, ui.rectOf(ids.add_everywhere) orelse return) catch return app.fail("could not click the second window");
                check.step = .expect_counts;
            },
            .expect_counts => if (window == .main) {
                const second = app.slotOf(check.second.?);
                const first = app.slotOf(.main);
                if (second.clicks_here != 1 or second.shared_shown != 1 or first.shared_shown != 1) return;
                if (first.clicks_here != 0) return app.fail("the first window counted a click made in the second");
                app.windows.close(check.second.?);
                check.step = .expect_closed;
            },
            .expect_closed => if (window == .main and check.closed == check.second) {
                check.frames_after_close = 0;
                check.step = .draw_on;
            },
            .draw_on => if (window == .main) {
                check.frames_after_close += 1;
                if (check.frames_after_close == 3) app.windows.close(.main);
            },
        }
    }

    /// A press and release at the centre of `rect`, sent to the window as
    /// Windows would.
    fn clickAt(app: *ManyWindowsApp, window: zui.WindowId, rect: zui.Rect) !void {
        const target = app.host.windowById(window) orelse return error.WindowNotOpen;
        const pixels_per_unit = app.host.pixelsPerUnit(window);
        const point = win32.lparamFromPoint(@intFromFloat((rect.x + rect.width / 2) * pixels_per_unit), @intFromFloat((rect.y + rect.height / 2) * pixels_per_unit));
        for ([_]win32.UINT{ win32.WM_MOUSEMOVE, win32.WM_LBUTTONDOWN, win32.WM_LBUTTONUP }) |message| {
            _ = win32.SendMessageW(target.hwnd, message, if (message == win32.WM_LBUTTONDOWN) win32.MK_LBUTTON else 0, point);
        }
    }

    fn fail(app: *ManyWindowsApp, failure: []const u8) void {
        if (app.failure == null) app.failure = failure;
        for (app.slots) |slot| if (slot.id) |id| app.windows.close(id);
    }

    /// Settles for a second, then measures from one requested frame to
    /// another 10 s later, with both windows open.
    fn measureIdle(app: *ManyWindowsApp, ui: *Ui) void {
        const now = ui.now();
        const started = app.idle orelse {
            const settle_until = (app.idle_settle_until orelse blk: {
                app.idle_settle_until = now.addSeconds(1);
                break :blk app.idle_settle_until.?;
            });
            if (now.isBefore(settle_until)) return ui.requestFrameAt(settle_until);
            app.idle = .{ .ends_at = now.addSeconds(10), .cpu_ns = processCpuNanoseconds(), .frames = app.totalFrames() };
            return ui.requestFrameAt(app.idle.?.ends_at);
        };
        if (now.isBefore(started.ends_at)) return ui.requestFrameAt(started.ends_at);
        const cpu_ms = @as(f64, @floatFromInt(processCpuNanoseconds() - started.cpu_ns)) / std.time.ns_per_ms;
        // Less the measurement's own frame.
        std.debug.print("idle: {d:.1} ms of CPU over 10 s with two windows open, {d} frames\n", .{ cpu_ms, app.totalFrames() - started.frames - 1 });
        for (app.slots) |slot| if (slot.id) |id| app.windows.close(id);
    }

    fn totalFrames(app: *const ManyWindowsApp) u32 {
        var frames: u32 = 0;
        for (app.slots) |slot| frames += slot.frames;
        return frames;
    }
};

const Check = struct {
    step: enum { open_second, click_second, expect_counts, expect_closed, draw_on } = .open_second,
    second: ?zui.WindowId = null,
    closed: ?zui.WindowId = null,
    turns: u32 = 0,
    frames_after_close: u32 = 0,
};

const IdleMeasurement = struct {
    ends_at: zui.Instant,
    cpu_ns: u64,
    frames: u32,
};

/// Counts frames while the first window animates alone for three seconds,
/// then while both do, and reports each window's rate.
const Animation = struct {
    phase: enum { settling, one_window, two_windows, done } = .settling,
    phase_started: zui.Instant = .zero,
    frames: [2]u32 = .{ 0, 0 },
    one_window_rate: f32 = 0,

    const settle_seconds = 1;
    const phase_seconds = 3;

    fn animates(self: *const Animation, window: zui.WindowId) bool {
        return switch (self.phase) {
            .settling, .one_window => window == .main,
            .two_windows => true,
            .done => false,
        };
    }

    fn step(self: *Animation, app: *ManyWindowsApp, ui: *const Ui, window: zui.WindowId) void {
        const now = ui.now();
        if (self.phase_started.nanoseconds == 0) self.phase_started = now;
        const index: usize = if (window == .main) 0 else 1;
        self.frames[index] += 1;
        if (window != .main) return;
        const elapsed = now.secondsSince(self.phase_started);
        switch (self.phase) {
            .settling => if (elapsed >= settle_seconds) self.startPhase(.one_window, now),
            .one_window => if (elapsed >= phase_seconds) {
                self.one_window_rate = @as(f32, @floatFromInt(self.frames[0])) / elapsed;
                self.startPhase(.two_windows, now);
                // A publish makes the idle second window due, and its frame
                // then asks for the next.
                app.publish_shared = true;
            },
            .two_windows => if (elapsed >= phase_seconds) {
                std.debug.print("animation: one window alone at {d:.1} frames a second; both at once at {d:.1} and {d:.1}\n", .{
                    self.one_window_rate,
                    @as(f32, @floatFromInt(self.frames[0])) / elapsed,
                    @as(f32, @floatFromInt(self.frames[1])) / elapsed,
                });
                self.phase = .done;
                for (app.slots) |slot| if (slot.id) |id| app.windows.close(id);
            },
            .done => {},
        }
    }

    fn startPhase(self: *Animation, phase: @TypeOf(self.phase), now: zui.Instant) void {
        self.phase = phase;
        self.phase_started = now;
        self.frames = .{ 0, 0 };
    }
};

fn processCpuNanoseconds() u64 {
    if (comptime builtin.os.tag != .windows) return 0;
    var creation: u64 = 0;
    var exit: u64 = 0;
    var kernel: u64 = 0;
    var user: u64 = 0;
    _ = win32.GetProcessTimes(win32.GetCurrentProcess(), &creation, &exit, &kernel, &user);
    return (kernel + user) * 100;
}

/// zui-sokol's renderer as `zui_app` opens one, with each window after the
/// first attached to it.
const SokolRenderer = struct {
    pub const zui_surfaces: zui.SurfaceKinds = zui_host.Host.zui_surfaces;
    pub const ImageHandle = zui_sokol.Renderer.ImageHandle;

    sokol: zui_sokol.Renderer,

    pub fn init(self: *SokolRenderer, surface: zui.Surface, text: *const zui_sokol.Text) !void {
        self.sokol = try .initForSurface(text, surface);
    }

    pub fn deinit(self: *SokolRenderer) void {
        self.sokol.deinit();
    }

    pub fn zuiSubmit(self: *SokolRenderer, surface: zui.Surface, frame: anytype) !void {
        try self.sokol.zuiSubmit(surface, frame);
    }

    pub fn zuiAttachSurface(self: *SokolRenderer, surface: zui.Surface) !void {
        try self.sokol.zuiAttachSurface(surface);
    }

    pub fn zuiDetachSurface(self: *SokolRenderer, surface: zui.Surface) void {
        self.sokol.zuiDetachSurface(surface);
    }
};
