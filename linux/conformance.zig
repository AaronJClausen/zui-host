//! zui's host suite and the Linux host's own tests, each against a window
//! the compositor never shows: a surface without a role. Events are
//! delivered to the host's handlers as the compositor's would be, so each
//! one has reached the host before the test polls. Without a Wayland
//! compositor to connect to, every test is skipped.

const std = @import("std");
const zui_host = @import("zui_host");
const zui = zui_host.zui;
const zui_testing = @import("zui_testing");
const Host = zui_host.Host;
const keys = zui_host.linux.keys;
const desktop_bus = zui_host.linux.desktop_bus;

const testing = std.testing;

const UnshownWindow = struct {
    window_host: Host = undefined,

    /// With `forced_scale` set, a surface coordinate is that many layout
    /// units at a zoom of 1 and a buffer scale of 1. The window reads no
    /// bus, so its environment starts at zui's defaults.
    fn open(self: *UnshownWindow, forced_scale: ?f32) !void {
        return self.openReading(forced_scale, .{ .session = null, .system = null });
    }

    /// Null reads the session's and the system's buses.
    fn openReading(self: *UnshownWindow, forced_scale: ?f32, bus_addresses: ?desktop_bus.Addresses) !void {
        self.window_host.forced_scale = forced_scale;
        self.window_host.bus_addresses = bus_addresses;
        self.window_host.init(testing.io, .{ .title = "zui host suite", .size = .{ 320, 240 }, .visible = false }) catch |err| switch (err) {
            error.NoWaylandDisplay => {
                std.debug.print("skipped: no Wayland compositor to connect to (WAYLAND_DISPLAY and XDG_RUNTIME_DIR)\n", .{});
                return error.SkipZigTest;
            },
            else => return err,
        };
        if (self.window_host.keymap == null) try self.window_host.useKeymap(null);
    }

    fn close(self: *UnshownWindow) void {
        self.window_host.deinit();
    }

    fn host(self: *UnshownWindow) *Host {
        return &self.window_host;
    }
};

/// Delivers each event the suite posts as the compositor would, at the
/// surface coordinates the last poll's scale and zoom put it at.
const CompositorHarness = struct {
    window: UnshownWindow = .{},

    pub fn host(self: *CompositorHarness) *Host {
        return self.window.host();
    }

    pub fn post(self: *CompositorHarness, event: zui.Event) bool {
        const window_host = self.host();
        switch (event) {
            .pointer_move => |move| window_host.onPointerMotion(surfaceCoordinates(window_host, move.pointer.position)),
            .pointer_down => window_host.onPointerButton(keys.evdev_button_left, true),
            .pointer_up => window_host.onPointerButton(keys.evdev_button_left, false),
            .key_down => |key| window_host.onKey(evdevCodeOf(window_host, key.key) orelse return false, true),
            .key_up => |key| window_host.onKey(evdevCodeOf(window_host, key.key) orelse return false, false),
            else => return false,
        }
        return true;
    }

    pub fn close(self: *CompositorHarness) void {
        self.host().close();
    }
};

fn surfaceCoordinates(window_host: *const Host, position: [2]f32) [2]f32 {
    const per_unit = window_host.surface_coordinates_per_unit;
    return .{ position[0] * per_unit, position[1] * per_unit };
}

fn evdevCodeOf(window_host: *const Host, key: zui.Key) ?u32 {
    for (1..256) |code| {
        if (window_host.keyOf(@intCast(code)) == key) return @intCast(code);
    }
    return null;
}

test "the host passes zui's host suite" {
    var harness: CompositorHarness = .{};
    try harness.window.open(1);
    defer harness.window.close();
    try zui_testing.expectHostConforms(Host, &harness, .{ .io = testing.io });
}

const Polled = struct {
    events: [64]zui.Event = undefined,
    text: [8192]u8 = undefined,
    builder: zui.RecordBuilder = undefined,

    fn init(self: *Polled) void {
        self.builder = .init(&self.events, &self.text);
    }

    fn poll(self: *Polled, window_host: *Host) bool {
        return window_host.zuiPoll(.main, &self.builder);
    }

    fn find(self: *const Polled, comptime tag: std.meta.Tag(zui.Event)) ?@FieldType(zui.Event, @tagName(tag)) {
        for (self.builder.events()) |event| if (event == tag) return @field(event, @tagName(tag));
        return null;
    }

    fn typed(self: *const Polled, buffer: []u8) []const u8 {
        var len: usize = 0;
        for (self.builder.events()) |event| if (event == .text) {
            @memcpy(buffer[len..][0..event.text.len], event.text);
            len += event.text.len;
        };
        return buffer[0..len];
    }
};

test "the first poll reports focus, and a viewport in layout units" {
    var window: UnshownWindow = .{};
    try window.open(2);
    defer window.close();
    var polled: Polled = .{};
    polled.init();
    polled.builder.params.zoom = 1.25;
    try testing.expect(polled.poll(window.host()));
    try testing.expectEqual(@as(f32, 2), polled.builder.params.scale);
    try testing.expectEqual([2]f32{ 320 / 2.5, 240 / 2.5 }, polled.builder.params.viewport);
    try testing.expectEqual(false, polled.find(.environment).?.window_focused);
}

test "a new buffer scale moves the scale, and the window keeps its size in layout units" {
    var window: UnshownWindow = .{};
    try window.open(null);
    defer window.close();
    var polled: Polled = .{};
    polled.init();
    _ = polled.poll(window.host());
    const viewport = polled.builder.params.viewport;

    window.host().onPreferredBufferScale(2);
    _ = polled.poll(window.host());
    try testing.expectEqual(@as(f32, 2), polled.builder.params.scale);
    try testing.expectEqual(viewport, polled.builder.params.viewport);
}

test "a configured size is the window's size once the configure is done" {
    var window: UnshownWindow = .{};
    try window.open(1);
    defer window.close();
    var polled: Polled = .{};
    polled.init();
    window.host().onToplevelConfigure(500, 400);
    _ = polled.poll(window.host());
    try testing.expectEqual([2]f32{ 320, 240 }, polled.builder.params.viewport);
    window.host().onConfigure(1);
    _ = polled.poll(window.host());
    try testing.expectEqual([2]f32{ 500, 400 }, polled.builder.params.viewport);
}

test "a wheel's notch scrolls a step toward the end, and a touchpad its distance" {
    var window: UnshownWindow = .{};
    try window.open(1);
    defer window.close();
    var polled: Polled = .{};
    polled.init();
    _ = polled.poll(window.host());

    window.host().onPointerAxisNotches(0, 1);
    window.host().onPointerAxis(0, 15);
    _ = polled.poll(window.host());
    try testing.expectEqual([2]f32{ 0, Host.wheel_step }, polled.find(.wheel).?.delta);

    window.host().onPointerAxis(1, -7.5);
    _ = polled.poll(window.host());
    try testing.expectEqual([2]f32{ -7.5, 0 }, polled.find(.wheel).?.delta);
}

test "keys type their text, but not with Control held, and Enter types nothing" {
    var window: UnshownWindow = .{};
    try window.open(1);
    defer window.close();
    const window_host = window.host();
    var polled: Polled = .{};
    polled.init();
    _ = polled.poll(window_host);

    for ([_]zui.Key{ .h, .i, .enter }) |key| {
        window_host.onKey(evdevCodeOf(window_host, key).?, true);
        window_host.onKey(evdevCodeOf(window_host, key).?, false);
    }
    _ = polled.poll(window_host);
    var buffer: [32]u8 = undefined;
    try testing.expectEqualStrings("hi", polled.typed(&buffer));
    const pressed = polled.find(.key_down).?;
    try testing.expectEqual(zui.Key.h, pressed.key);
    try testing.expectEqual(evdevCodeOf(window_host, .h).?, pressed.scancode);

    window_host.modifiers.control = true;
    window_host.onKey(evdevCodeOf(window_host, .s).?, true);
    _ = polled.poll(window_host);
    try testing.expectEqualStrings("", polled.typed(&buffer));
    try testing.expect(polled.find(.key_down).?.modifiers.control);
}

test "the close button closes the window at the next poll" {
    var window: UnshownWindow = .{};
    try window.open(1);
    defer window.close();
    var polled: Polled = .{};
    polled.init();
    try testing.expect(polled.poll(window.host()));
    window.host().onClose();
    try testing.expect(!polled.poll(window.host()));
}

fn environmentOf(polled: *const Polled) struct { environment: zui.Environment, changes: usize } {
    var environment: zui.Environment = .{};
    var changes: usize = 0;
    for (polled.builder.events()) |event| if (event == .environment and event.environment != .window_focused) {
        environment.apply(event.environment);
        changes += 1;
    };
    return .{ .environment = environment, .changes = changes };
}

test "without a bus to read, the first poll reports the environment at zui's defaults" {
    var window: UnshownWindow = .{};
    try window.openReading(1, .{ .session = "unix:path=/nonexistent/zui-host-session-bus", .system = "unix:path=/nonexistent/zui-host-system-bus" });
    defer window.close();
    var polled: Polled = .{};
    polled.init();
    _ = polled.poll(window.host());
    const reported = environmentOf(&polled);
    try testing.expectEqual(@as(usize, 4), reported.changes);
    try testing.expectEqual(zui.Environment{ .window_focused = true }, reported.environment);
    try testing.expectEqual(desktop_bus.Sources{}, window.host().environmentSources());
}

test "the desktop's own buses, where they run, report the whole environment within init's bound" {
    var window: UnshownWindow = .{};
    const started = std.Io.Timestamp.now(testing.io, .awake);
    try window.openReading(1, null);
    defer window.close();
    const init_ns = started.durationTo(std.Io.Timestamp.now(testing.io, .awake)).nanoseconds;
    try testing.expect(init_ns < std.time.ns_per_s);
    var polled: Polled = .{};
    polled.init();
    _ = polled.poll(window.host());
    try testing.expectEqual(@as(usize, 4), environmentOf(&polled).changes);
}

test "a setting the desktop changes is reported, and only what changed" {
    var window: UnshownWindow = .{};
    try window.open(1);
    defer window.close();
    const window_host = window.host();
    var polled: Polled = .{};
    polled.init();
    _ = polled.poll(window_host);

    window_host.onDesktopReport(.{ .theme = .dark });
    window_host.onDesktopReport(.{ .contrast = .normal });
    _ = polled.poll(window_host);
    try testing.expectEqual(@as(usize, 1), environmentOf(&polled).changes);
    try testing.expectEqual(zui.Environment.Theme.dark, polled.find(.environment).?.theme);

    const expected_power = [_]struct { desktop_bus.Report, zui.Environment.Power }{
        .{ .{ .on_battery = true }, .battery },
        .{ .{ .power_saver = true }, .saver },
        .{ .{ .power_saver = false }, .battery },
        .{ .{ .on_battery = false }, .plugged },
    };
    for (expected_power) |step| {
        window_host.onDesktopReport(step[0]);
        _ = polled.poll(window_host);
        try testing.expectEqual(step[1], polled.find(.environment).?.power);
    }
}

test "the system preparing to sleep is a suspend, and waking a resume" {
    var window: UnshownWindow = .{};
    try window.open(1);
    defer window.close();
    var polled: Polled = .{};
    polled.init();
    window.host().onDesktopReport(.{ .preparing_for_sleep = true });
    window.host().onDesktopReport(.{ .preparing_for_sleep = false });
    _ = polled.poll(window.host());
    var lifecycle: [2]zui.Lifecycle = undefined;
    var count: usize = 0;
    for (polled.builder.events()) |event| if (event == .lifecycle) {
        lifecycle[count] = event.lifecycle;
        count += 1;
    };
    try testing.expectEqualSlices(zui.Lifecycle, &.{ .@"suspend", .@"resume" }, lifecycle[0..count]);
}

test "SIGINT, SIGTERM and SIGHUP each wake the wait as a terminate request, after which the window reports closed" {
    for ([_]std.posix.SIG{ .INT, .TERM, .HUP }) |signal| {
        var window: UnshownWindow = .{};
        try window.open(1);
        defer window.close();
        const window_host = window.host();
        if (!window_host.handlesSignal(signal)) {
            std.debug.print("skipped: SIG{t} already has a handler in this process\n", .{signal});
            return error.SkipZigTest;
        }
        var polled: Polled = .{};
        polled.init();
        _ = polled.poll(window_host);
        try std.posix.raise(signal);
        window_host.zuiWait(.{ .at = window_host.now().addSeconds(2) });
        try testing.expect(polled.poll(window_host));
        try testing.expectEqual(zui.Lifecycle.terminate_requested, polled.find(.lifecycle).?);
        try testing.expect(!polled.poll(window_host));
    }
}

fn findRepeat(polled: *const Polled) ?zui.KeyEvent {
    for (polled.builder.events()) |event| if (event == .key_down and event.key_down.repeat) return event.key_down;
    return null;
}

test "a held key repeats after the delay at the compositor's rate, typing each time, until it is released" {
    var window: UnshownWindow = .{};
    try window.open(1);
    defer window.close();
    const window_host = window.host();
    var polled: Polled = .{};
    polled.init();
    _ = polled.poll(window_host);
    const a = evdevCodeOf(window_host, .a).?;

    window_host.onRepeatInfo(100, 30);
    window_host.onKey(a, true);
    _ = polled.poll(window_host);
    const press = polled.find(.key_down).?;
    try testing.expect(!press.repeat);

    const pressed_at = press.at;
    window_host.zuiWait(.{ .at = pressed_at.addSeconds(2) });
    try testing.expect(window_host.now().secondsSince(pressed_at) < 1);
    _ = polled.poll(window_host);
    const repeat = findRepeat(&polled).?;
    try testing.expectEqual(zui.Key.a, repeat.key);
    try testing.expect(repeat.at.secondsSince(pressed_at) >= 0.03);
    var buffer: [32]u8 = undefined;
    try testing.expect(std.mem.startsWith(u8, polled.typed(&buffer), "a"));

    window_host.onKey(a, false);
    try testing.expectEqual(@as(?zui.Instant, null), window_host.nextRepeatAt());
    window_host.zuiWait(.{ .at = window_host.now().addSeconds(0.1) });
    _ = polled.poll(window_host);
    try testing.expectEqual(@as(?zui.KeyEvent, null), findRepeat(&polled));
}

test "a modifier pressed while a key is held leaves it repeating; losing focus, or a rate of 0, stops it" {
    var window: UnshownWindow = .{};
    try window.open(1);
    defer window.close();
    const window_host = window.host();
    const a = evdevCodeOf(window_host, .a).?;

    window_host.onKey(a, true);
    const repeat_at = window_host.nextRepeatAt().?;
    window_host.onKey(evdevCodeOf(window_host, .shift).?, true);
    try testing.expectEqual(repeat_at, window_host.nextRepeatAt().?);
    window_host.onKeyboardFocus(false);
    try testing.expectEqual(@as(?zui.Instant, null), window_host.nextRepeatAt());

    window_host.onRepeatInfo(0, 600);
    window_host.onKey(a, true);
    try testing.expectEqual(@as(?zui.Instant, null), window_host.nextRepeatAt());
}
