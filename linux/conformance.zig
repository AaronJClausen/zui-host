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

test "a fractional scale of 1.25 or 1.5 is the record's scale, and the viewport keeps the surface's size while the buffer takes its pixels" {
    for ([_]struct { u32, f32 }{ .{ 150, 1.25 }, .{ 180, 1.5 } }) |step| {
        var window: UnshownWindow = .{};
        try window.open(null);
        defer window.close();
        const window_host = window.host();
        var polled: Polled = .{};
        polled.init();
        _ = polled.poll(window_host);

        window_host.onPreferredFractionalScale(step[0]);
        window_host.onPreferredBufferScale(2);
        _ = polled.poll(window_host);
        const params = polled.builder.params;
        try testing.expectEqual(step[1], params.scale);
        try testing.expectEqual([2]f32{ 320, 240 }, params.viewport);
        try testing.expectEqual(@as(i32, 1), window_host.buffer_scale);
        const buffer_width = @round(params.viewport[0] * params.scale * params.zoom);
        try testing.expectEqual(@round(320 * step[1]), buffer_width);

        polled.builder.params.zoom = 2;
        window_host.onPointerMotion(.{ 100, 50 });
        _ = polled.poll(window_host);
        try testing.expectEqual([2]f32{ 160, 120 }, polled.builder.params.viewport);
        try testing.expectEqual([2]f32{ 50, 25 }, polled.find(.pointer_move).?.pointer.position);
    }
}

test "a forced scale still wins over a fractional one, and the buffer still takes the surface's pixels" {
    var window: UnshownWindow = .{};
    try window.open(1);
    defer window.close();
    var polled: Polled = .{};
    polled.init();
    window.host().onPreferredFractionalScale(150);
    _ = polled.poll(window.host());
    try testing.expectEqual(@as(f32, 1), polled.builder.params.scale);
    try testing.expectApproxEqAbs(@as(f32, 400), polled.builder.params.viewport[0], 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 300), polled.builder.params.viewport[1], 1e-3);
}

const ClipboardReplies = struct {
    replies: [2]zui.ServiceReply(128 * 1024) = undefined,
    count: usize = 0,

    pub fn publish(self: *ClipboardReplies, reply: zui.ServiceReply(128 * 1024)) error{Full}!zui.Wake {
        if (self.count == self.replies.len) return error.Full;
        self.replies[self.count] = reply;
        self.count += 1;
        return .needed;
    }
};

const transfer_bound_ns = 2 * std.time.ns_per_s;

/// Waits, as the loop would, until `done`, first taking what is already
/// pending, which would end every wait at once.
fn waitUntil(window_host: *Host, comptime done: fn (*Host, *const anyopaque) bool, context: *const anyopaque) !void {
    var pending: Polled = .{};
    pending.init();
    _ = pending.poll(window_host);
    const deadline = window_host.now().addNanoseconds(transfer_bound_ns);
    while (!done(window_host, context)) {
        if (!window_host.now().isBefore(deadline)) return error.Timeout;
        window_host.zuiWait(.{ .at = window_host.now().addSeconds(0.05) });
    }
}

fn answered(_: *Host, context: *const anyopaque) bool {
    const replies: *const ClipboardReplies = @ptrCast(@alignCast(context));
    return replies.count > 0;
}

fn pipe() ![2]i32 {
    var ends: [2]i32 = undefined;
    if (std.os.linux.errno(std.os.linux.pipe2(&ends, .{ .CLOEXEC = true })) != .SUCCESS) return error.NoPipe;
    _ = std.os.linux.fcntl(ends[0], std.os.linux.F.SETFL, 1 << @bitOffsetOf(std.os.linux.O, "NONBLOCK"));
    return ends;
}

test "text the clipboard is given is written to a reader through a pipe, and read back from one, by the host's own wait" {
    var window: UnshownWindow = .{};
    try window.open(1);
    defer window.close();
    const window_host = window.host();
    if (window_host.data_device.device == null) {
        std.debug.print("skipped: the compositor offers no wl_data_device_manager\n", .{});
        return error.SkipZigTest;
    }
    var text: [zui_host.linux.data_device.DataDevice.clipboard_text_capacity]u8 = undefined;
    for (&text, 0..) |*byte, index| byte.* = 'a' + @as(u8, @intCast(index % 26));
    try Host.zuiClipboard.write(window_host, &text);

    const ends = try pipe();
    // A pipe smaller than the text, so the write goes in pieces as the
    // reader drains it.
    _ = std.os.linux.fcntl(ends[1], std.os.linux.F.SETPIPE_SZ, 4096);
    window_host.data_device.sendSelectionTo(ends[1]);
    var replies: ClipboardReplies = .{};
    window_host.data_device.receiveClipboardFrom(.of("paste"), .of(&replies), window_host.zuiWaker(), ends[0]);
    try waitUntil(window_host, answered, &replies);
    const reply = &replies.replies[0];
    try testing.expectEqual(zui.ServiceRequest.of("paste"), reply.request);
    try testing.expectEqual(@as(usize, text.len), reply.text().len);
    try testing.expectEqualStrings(&text, reply.text());
    try testing.expectEqual(@as(u32, 0), reply.left_out_bytes);

    try testing.expectError(error.InvalidUtf8, Host.zuiClipboard.write(window_host, "\xff"));
    var too_large: [text.len + 1]u8 = @splat('z');
    try testing.expectError(error.TooLarge, Host.zuiClipboard.write(window_host, &too_large));
}

/// With SIGPIPE blocked on its thread, so a reader that gave up fails the
/// write rather than ending the process, and giving up itself once the
/// reader has not drained the pipe for twice a transfer's bound.
fn writeAndClose(fd: i32, bytes: []const u8) void {
    var pipe_signal = std.posix.sigemptyset();
    std.posix.sigaddset(&pipe_signal, .PIPE);
    std.posix.sigprocmask(std.posix.SIG.BLOCK, &pipe_signal, null);
    var written: usize = 0;
    while (written < bytes.len) {
        var writable = [_]std.os.linux.pollfd{.{ .fd = fd, .events = std.os.linux.POLL.OUT, .revents = 0 }};
        var bound: std.os.linux.timespec = .{ .sec = 2 * transfer_bound_ns / std.time.ns_per_s, .nsec = 0 };
        if (std.os.linux.ppoll(&writable, 1, &bound, null) != 1) break;
        const result = std.os.linux.write(fd, bytes[written..].ptr, bytes.len - written);
        if (std.os.linux.errno(result) != .SUCCESS) break;
        written += result;
    }
    _ = std.os.linux.close(fd);
}

test "a clipboard's text past what a read holds is cut at a character, and the rest counted as left out" {
    var window: UnshownWindow = .{};
    try window.open(1);
    defer window.close();
    const window_host = window.host();
    const capacity = zui_host.linux.data_device.DataDevice.clipboard_text_capacity;
    const check_mark = "\u{2713}";
    var text: [capacity + 100]u8 = @splat('x');
    @memcpy(text[capacity - 1 ..][0..check_mark.len], check_mark);

    const ends = try pipe();
    var replies: ClipboardReplies = .{};
    window_host.data_device.receiveClipboardFrom(.of("paste"), .of(&replies), window_host.zuiWaker(), ends[0]);
    const writer = try std.Thread.spawn(.{}, writeAndClose, .{ ends[1], @as([]const u8, &text) });
    defer writer.join();
    try waitUntil(window_host, answered, &replies);
    const reply = &replies.replies[0];
    try testing.expectEqual(@as(usize, capacity - 1), reply.text().len);
    try testing.expectEqual(@as(u32, text.len - (capacity - 1)), reply.left_out_bytes);
}

test "a clipboard holding no text is read as empty, and a second read while one is in flight is busy" {
    var window: UnshownWindow = .{};
    try window.open(1);
    defer window.close();
    const window_host = window.host();
    window_host.data_device.onSelection(null);
    var replies: ClipboardReplies = .{};
    try Host.zuiClipboard.read(window_host, .of("empty"), .of(&replies));
    try testing.expectEqual(@as(usize, 1), replies.count);
    try testing.expectEqual(zui.ServiceReply(128 * 1024).Kind.clipboard_text, replies.replies[0].kind);
    try testing.expectEqualStrings("", replies.replies[0].text());

    const ends = try pipe();
    defer _ = std.os.linux.close(ends[1]);
    window_host.data_device.receiveClipboardFrom(.of("slow"), .of(&replies), window_host.zuiWaker(), ends[0]);
    try testing.expectError(error.Busy, Host.zuiClipboard.read(window_host, .of("second"), .of(&replies)));
}

test "a drop's URI list, read from the wait, arrives as files_dropped at the drag's position in layout units" {
    var window: UnshownWindow = .{};
    try window.open(2);
    defer window.close();
    const window_host = window.host();
    var polled: Polled = .{};
    polled.init();
    _ = polled.poll(window_host);

    window_host.onDragMotion(.{ 120, 80 });
    const ends = try pipe();
    window_host.receiveDropFrom(ends[0]);
    writeAndClose(ends[1], "file:///home/user/My%20Theme.zon\r\nhttps://ziglang.org/\r\nfile:///tmp/notes.txt\r\n");
    const deadline = window_host.now().addNanoseconds(transfer_bound_ns);
    const drop = while (true) {
        _ = polled.poll(window_host);
        if (polled.find(.files_dropped)) |drop| break drop;
        if (!window_host.now().isBefore(deadline)) return error.Timeout;
        window_host.zuiWait(.{ .at = window_host.now().addSeconds(0.05) });
    };
    try testing.expectEqual([2]f32{ 60, 40 }, drop.position);
    var paths = drop.paths();
    try testing.expectEqualStrings("/home/user/My Theme.zon", paths.next().?);
    try testing.expectEqualStrings("/tmp/notes.txt", paths.next().?);
    try testing.expectEqual(@as(?[]const u8, null), paths.next());
}

const FileChanges = struct {
    changes: [64]zui.FileChange = undefined,
    count: usize = 0,

    pub fn publish(self: *FileChanges, change: zui.FileChange) zui.Wake {
        if (self.count == self.changes.len) return .already_pending;
        self.changes[self.count] = change;
        self.count += 1;
        return .needed;
    }

    fn has(self: *const FileChanges, kind: zui.FileChange.Kind, path: []const u8) bool {
        for (self.changes[0..self.count]) |change| if (change.kind == kind and std.mem.eql(u8, change.pathBytes(), path)) return true;
        return false;
    }
};

const ExpectedChange = struct { changes: *const FileChanges, kind: zui.FileChange.Kind, path: []const u8 };

fn changeSeen(_: *Host, context: *const anyopaque) bool {
    const expected: *const ExpectedChange = @ptrCast(@alignCast(context));
    return expected.changes.has(expected.kind, expected.path);
}

fn expectChange(window_host: *Host, changes: *const FileChanges, kind: zui.FileChange.Kind, path: []const u8) !void {
    const expected: ExpectedChange = .{ .changes = changes, .kind = kind, .path = path };
    waitUntil(window_host, changeSeen, &expected) catch |err| {
        std.debug.print("no .{t} of \"{s}\" within {d} s\n", .{ kind, path, transfer_bound_ns / std.time.ns_per_s });
        return err;
    };
}

test "a watched directory reports a file added, modified and removed, in it and in a subdirectory made after the watch" {
    var window: UnshownWindow = .{};
    try window.open(1);
    defer window.close();
    const window_host = window.host();
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    const io = testing.io;
    try temporary.dir.createDir(io, "existing", .default_dir);
    var path_buffer: [256]u8 = undefined;
    const directory = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}", .{&temporary.sub_path});

    var changes: FileChanges = .{};
    try Host.zuiFileWatch.watch(window_host, directory, .of(&changes));
    try testing.expectEqual(@as(usize, 0), changes.count);

    try temporary.dir.writeFile(io, .{ .sub_path = "theme.zon", .data = ".{}" });
    try expectChange(window_host, &changes, .added, "theme.zon");
    try temporary.dir.writeFile(io, .{ .sub_path = "theme.zon", .data = ".{ .changed = true }" });
    try expectChange(window_host, &changes, .modified, "theme.zon");
    try temporary.dir.deleteFile(io, "theme.zon");
    try expectChange(window_host, &changes, .removed, "theme.zon");

    try temporary.dir.writeFile(io, .{ .sub_path = "existing/old.zon", .data = ".{}" });
    try expectChange(window_host, &changes, .added, "existing/old.zon");

    try temporary.dir.createDir(io, "made_after", .default_dir);
    try expectChange(window_host, &changes, .added, "made_after");
    try temporary.dir.writeFile(io, .{ .sub_path = "made_after/new.zon", .data = ".{}" });
    try expectChange(window_host, &changes, .added, "made_after/new.zon");
    try temporary.dir.writeFile(io, .{ .sub_path = "made_after/new.zon", .data = ".{ .changed = true }" });
    try expectChange(window_host, &changes, .modified, "made_after/new.zon");
    try temporary.dir.deleteFile(io, "made_after/new.zon");
    try expectChange(window_host, &changes, .removed, "made_after/new.zon");
}

test "a directory that cannot be opened is unavailable, and one past the host's watches is too many" {
    var window: UnshownWindow = .{};
    try window.open(1);
    defer window.close();
    const window_host = window.host();
    var temporary = testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [256]u8 = undefined;
    const directory = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}", .{&temporary.sub_path});
    var changes: FileChanges = .{};
    try testing.expectError(error.DirectoryUnavailable, Host.zuiFileWatch.watch(window_host, "/nonexistent/zui-host-watch", .of(&changes)));
    for (0..zui_host.linux.file_watch.Watches.capacity) |_| try Host.zuiFileWatch.watch(window_host, directory, .of(&changes));
    try testing.expectError(error.TooManyWatches, Host.zuiFileWatch.watch(window_host, directory, .of(&changes)));
}

const wayland = zui_host.linux.wayland;
extern "wayland-client" const wl_shm_interface: wayland.Interface;
extern "wayland-client" const wl_shm_pool_interface: wayland.Interface;
extern "wayland-client" const wl_buffer_interface: wayland.Interface;

/// Gives a shown window a buffer of one color, so the compositor maps it
/// and gives it focus; the clipboard's selection reaches only the window
/// with focus.
const PlainBuffer = struct {
    shm: ?*wayland.Proxy = null,
    buffer: ?*wayland.Proxy = null,

    const shm_create_pool = 0;
    const shm_pool_create_buffer = 0;
    const shm_pool_destroy = 1;
    const buffer_destroy = 0;
    const surface_attach = 1;
    const format_xrgb8888 = 1;

    const registry_listener: wayland.RegistryListener = .{
        .global = struct {
            fn global(data: ?*anyopaque, registry: ?*wayland.Proxy, name: u32, interface_name: [*:0]const u8, _: u32) callconv(.c) void {
                const self: *PlainBuffer = @ptrCast(@alignCast(data.?));
                if (std.mem.eql(u8, std.mem.span(interface_name), "wl_shm")) self.shm = wayland.bind(registry.?, name, &wl_shm_interface, 1);
            }
        }.global,
        .global_remove = struct {
            fn globalRemove(_: ?*anyopaque, _: ?*wayland.Proxy, _: u32) callconv(.c) void {}
        }.globalRemove,
    };

    fn attach(self: *PlainBuffer, window_host: *Host) !void {
        const linux = std.os.linux;
        const registry = wayland.create(wayland.displayProxy(window_host.display), wayland.display_get_registry, &wayland.wl_registry_interface, 1, .{wayland.no_id}) orelse return error.NoRegistry;
        defer wayland.wl_proxy_destroy(registry);
        wayland.addListener(registry, &registry_listener, self);
        if (wayland.wl_display_roundtrip(window_host.display) < 0) return error.CompositorUnreachable;
        const shm = self.shm orelse return error.NoShm;
        const size = window_host.surface_size;
        const stride: i32 = @intCast(size[0] * 4);
        const bytes: i32 = stride * @as(i32, @intCast(size[1]));
        const memory = linux.memfd_create("zui-host-test", linux.MFD.CLOEXEC);
        if (linux.errno(memory) != .SUCCESS) return error.NoSharedMemory;
        const memory_fd: i32 = @intCast(memory);
        defer _ = linux.close(memory_fd);
        if (linux.errno(linux.ftruncate(memory_fd, bytes)) != .SUCCESS) return error.NoSharedMemory;
        const pool = wayland.create(shm, shm_create_pool, &wl_shm_pool_interface, 1, .{ wayland.no_id, memory_fd, bytes }) orelse return error.NoSharedMemory;
        defer wayland.destroy(pool, shm_pool_destroy);
        self.buffer = wayland.create(pool, shm_pool_create_buffer, &wl_buffer_interface, 1, .{ wayland.no_id, @as(i32, 0), @as(i32, @intCast(size[0])), @as(i32, @intCast(size[1])), stride, @as(u32, format_xrgb8888) }) orelse return error.NoBuffer;
        wayland.send(window_host.surface, surface_attach, .{ self.buffer.?, @as(i32, 0), @as(i32, 0) });
        wayland.send(window_host.surface, wayland.surface_commit, .{});
        _ = wayland.wl_display_flush(window_host.display);
    }

    fn release(self: *PlainBuffer) void {
        if (self.buffer) |buffer| wayland.destroy(buffer, buffer_destroy);
        if (self.shm) |shm| wayland.wl_proxy_destroy(shm);
    }
};

test "with ZUI_HOST_TEST_SHOWN_WINDOW set, text written to the clipboard comes back through the compositor's own selection" {
    _ = std.c.getenv("ZUI_HOST_TEST_SHOWN_WINDOW") orelse return error.SkipZigTest;
    var window_host: Host = undefined;
    window_host.forced_scale = 1;
    window_host.bus_addresses = .{ .session = null, .system = null };
    try window_host.init(testing.io, .{ .title = "zui host suite: clipboard", .size = .{ 320, 240 } });
    defer window_host.deinit();
    var plain: PlainBuffer = .{};
    defer plain.release();
    try plain.attach(&window_host);

    var polled: Polled = .{};
    polled.init();
    const deadline = window_host.now().addNanoseconds(transfer_bound_ns);
    while (true) {
        _ = polled.poll(&window_host);
        if (polled.find(.environment)) |change| if (change == .window_focused and change.window_focused) break;
        if (!window_host.now().isBefore(deadline)) return error.WindowNotFocused;
        window_host.zuiWait(.{ .at = window_host.now().addSeconds(0.05) });
    }

    const copied = "zui \u{2713} through the compositor";
    try Host.zuiClipboard.write(&window_host, copied);
    while (window_host.data_device.source_is_newest_selection) {
        _ = polled.poll(&window_host);
        if (polled.find(.environment)) |change| if (change == .window_focused and !change.window_focused) {
            std.debug.print("skipped: the window lost focus before the compositor named its selection\n", .{});
            return error.SkipZigTest;
        };
        if (!window_host.now().isBefore(deadline.addNanoseconds(transfer_bound_ns))) return error.SelectionNotNamed;
        window_host.zuiWait(.{ .at = window_host.now().addSeconds(0.05) });
    }
    var replies: ClipboardReplies = .{};
    try Host.zuiClipboard.read(&window_host, .of("paste"), .of(&replies));
    try waitUntil(&window_host, answered, &replies);
    try testing.expectEqualStrings(copied, replies.replies[0].text());
}
