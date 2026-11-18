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

const testing = std.testing;

const UnshownWindow = struct {
    window_host: Host = undefined,

    /// With `forced_scale` set, a surface coordinate is that many layout
    /// units at a zoom of 1 and a buffer scale of 1.
    fn open(self: *UnshownWindow, forced_scale: ?f32) !void {
        self.window_host.forced_scale = forced_scale;
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
