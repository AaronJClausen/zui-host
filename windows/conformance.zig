//! zui's host suite and the Windows host's own tests, each against a
//! hidden window. Messages are sent, not posted, so each one has reached
//! the window before the test polls.

const std = @import("std");
const zui_host = @import("zui_host");
const zui = zui_host.zui;
const zui_testing = @import("zui_testing");
const Host = zui_host.Host;
const win32 = zui_host.windows.win32;
const keys = zui_host.windows.keys;

const testing = std.testing;

const HiddenWindow = struct {
    window_host: Host = undefined,

    /// With `forced_scale` set, a pixel is that many layout units at a zoom of 1.
    fn open(self: *HiddenWindow, forced_scale: ?f32) !void {
        self.window_host.forced_scale = forced_scale;
        try self.window_host.init(testing.io, .{ .title = "zui host suite", .size = .{ 320, 240 }, .visible = false });
    }

    fn close(self: *HiddenWindow) void {
        self.window_host.deinit();
    }

    fn send(self: *HiddenWindow, message: win32.UINT, wparam: win32.WPARAM, lparam: win32.LPARAM) void {
        _ = win32.SendMessageW(self.window_host.hwnd, message, wparam, lparam);
    }
};

/// Turns each event the suite posts into the messages Windows would send
/// for it, at the pixels the last poll's scale and zoom put it at.
const MessageHarness = struct {
    window: HiddenWindow = .{},

    pub fn host(self: *MessageHarness) *Host {
        return &self.window.window_host;
    }

    pub fn post(self: *MessageHarness, event: zui.Event) bool {
        const pixels_per_unit = self.window.window_host.pixels_per_unit;
        switch (event) {
            .pointer_move => |move| self.window.send(win32.WM_MOUSEMOVE, 0, pixels(move.pointer.position, pixels_per_unit)),
            .pointer_down => |press| self.window.send(win32.WM_LBUTTONDOWN, win32.MK_LBUTTON, pixels(press.pointer.position, pixels_per_unit)),
            .pointer_up => |release| self.window.send(win32.WM_LBUTTONUP, 0, pixels(release.pointer.position, pixels_per_unit)),
            .key_down => |key| self.window.send(win32.WM_KEYDOWN, keys.virtualKeyFromKey(key.key).?, 1),
            .key_up => |key| self.window.send(win32.WM_KEYUP, keys.virtualKeyFromKey(key.key).?, @bitCast(@as(usize, 0xC0000001))),
            .text => |text| for (text) |byte| self.window.send(win32.WM_CHAR, byte, 1),
            else => return false,
        }
        return true;
    }

    pub fn close(self: *MessageHarness) void {
        self.window.window_host.close();
    }

    fn pixels(position: [2]f32, pixels_per_unit: f32) win32.LPARAM {
        return win32.lparamFromPoint(@intFromFloat(position[0] * pixels_per_unit), @intFromFloat(position[1] * pixels_per_unit));
    }
};

test "the host passes zui's host suite" {
    var harness: MessageHarness = .{};
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

    fn poll(self: *Polled, host: *Host) bool {
        return host.zuiPoll(.main, &self.builder);
    }

    fn find(self: *const Polled, comptime tag: std.meta.Tag(zui.Event)) ?@FieldType(zui.Event, @tagName(tag)) {
        for (self.builder.events()) |event| if (event == tag) return @field(event, @tagName(tag));
        return null;
    }
};

test "the first poll reports the environment, and a viewport in layout units" {
    var window: HiddenWindow = .{};
    try window.open(2);
    defer window.close();
    var polled: Polled = .{};
    polled.init();
    polled.builder.params.zoom = 1.25;
    try testing.expect(polled.poll(&window.window_host));
    try testing.expectEqual(@as(f32, 2), polled.builder.params.scale);
    var client: win32.RECT = .{};
    _ = win32.GetClientRect(window.window_host.hwnd, &client);
    try testing.expectEqual([2]f32{ @as(f32, @floatFromInt(client.right)) / 2.5, @as(f32, @floatFromInt(client.bottom)) / 2.5 }, polled.builder.params.viewport);
    try testing.expect(polled.find(.environment) != null);
}

test "a DPI change moves the scale, and the window keeps its size in layout units" {
    var window: HiddenWindow = .{};
    try window.open(null);
    defer window.close();
    var polled: Polled = .{};
    polled.init();
    _ = polled.poll(&window.window_host);
    const viewport = polled.builder.params.viewport;

    var client: win32.RECT = .{};
    _ = win32.GetClientRect(window.window_host.hwnd, &client);
    const dpi = win32.GetDpiForWindow(window.window_host.hwnd);
    var suggested: win32.RECT = .{ .right = @intCast(@divTrunc(client.right * 2 * win32.USER_DEFAULT_SCREEN_DPI, @as(i32, @intCast(dpi)))), .bottom = @intCast(@divTrunc(client.bottom * 2 * win32.USER_DEFAULT_SCREEN_DPI, @as(i32, @intCast(dpi)))) };
    // The frame stays the size of the monitor's real DPI, since only the
    // message is made up.
    _ = win32.AdjustWindowRectExForDpi(&suggested, win32.WS_OVERLAPPEDWINDOW, 0, 0, dpi);
    window.send(win32.WM_DPICHANGED, 2 * win32.USER_DEFAULT_SCREEN_DPI * 0x10001, @bitCast(@intFromPtr(&suggested)));

    _ = polled.poll(&window.window_host);
    try testing.expectEqual(@as(f32, 2), polled.builder.params.scale);
    try testing.expectApproxEqAbs(viewport[0], polled.builder.params.viewport[0], 1);
    try testing.expectApproxEqAbs(viewport[1], polled.builder.params.viewport[1], 1);
}

test "typed text arrives as UTF-8, with surrogate pairs joined and control characters left to keys" {
    var window: HiddenWindow = .{};
    try window.open(1);
    defer window.close();
    var polled: Polled = .{};
    polled.init();
    _ = polled.poll(&window.window_host);

    for ([_]u16{ 'h', 0xE9, 0x08, 0xD83D, 0xDE00 }) |unit| window.send(win32.WM_CHAR, unit, 1);
    _ = polled.poll(&window.window_host);
    var typed: [32]u8 = undefined;
    var typed_len: usize = 0;
    for (polled.builder.events()) |event| if (event == .text) {
        @memcpy(typed[typed_len..][0..event.text.len], event.text);
        typed_len += event.text.len;
    };
    try testing.expectEqualStrings("hé😀", typed[0..typed_len]);
}

test "the wheel scrolls toward the end when turned toward the user" {
    var window: HiddenWindow = .{};
    try window.open(1);
    defer window.close();
    var polled: Polled = .{};
    polled.init();
    _ = polled.poll(&window.window_host);

    const toward_user: i16 = -120;
    window.send(win32.WM_MOUSEWHEEL, @as(usize, @as(u16, @bitCast(toward_user))) << 16, 0);
    _ = polled.poll(&window.window_host);
    try testing.expectEqual([2]f32{ 0, Host.wheel_step }, polled.find(.wheel).?.delta);
}

test "dropped files arrive with their paths and where they were dropped" {
    var window: HiddenWindow = .{};
    try window.open(1);
    defer window.close();
    var polled: Polled = .{};
    polled.init();
    _ = polled.poll(&window.window_host);

    const paths = std.unicode.utf8ToUtf16LeStringLiteral("C:\\one.txt\x00C:\\twó.png\x00\x00");
    const DropFiles = extern struct { files_offset: u32, point: win32.POINT, non_client: win32.BOOL, wide: win32.BOOL };
    const memory = win32.GlobalAlloc(win32.GMEM_MOVEABLE, @sizeOf(DropFiles) + paths.len * 2).?;
    {
        const locked: [*]u8 = @ptrCast(win32.GlobalLock(memory).?);
        defer _ = win32.GlobalUnlock(memory);
        const header: DropFiles = .{ .files_offset = @sizeOf(DropFiles), .point = .{ .x = 12, .y = 34 }, .non_client = 0, .wide = 1 };
        @memcpy(locked[0..@sizeOf(DropFiles)], std.mem.asBytes(&header));
        @memcpy(locked[@sizeOf(DropFiles)..][0 .. paths.len * 2], std.mem.sliceAsBytes(paths[0..paths.len]));
    }
    window.send(win32.WM_DROPFILES, @intFromPtr(memory), 0);

    _ = polled.poll(&window.window_host);
    const drop = polled.find(.files_dropped).?;
    try testing.expectEqual([2]f32{ 12, 34 }, drop.position);
    var dropped = drop.paths();
    try testing.expectEqualStrings("C:\\one.txt", dropped.next().?);
    try testing.expectEqualStrings("C:\\twó.png", dropped.next().?);
    try testing.expectEqual(@as(?[]const u8, null), dropped.next());
}

test "the session ending is a terminate request, after which the window reports closed" {
    var window: HiddenWindow = .{};
    try window.open(1);
    defer window.close();
    var polled: Polled = .{};
    polled.init();
    _ = polled.poll(&window.window_host);

    window.send(win32.WM_POWERBROADCAST, win32.PBT_APMSUSPEND, 0);
    window.send(win32.WM_QUERYENDSESSION, 0, 0);
    try testing.expect(polled.poll(&window.window_host));
    try testing.expectEqual(zui.Lifecycle.@"suspend", polled.builder.events()[0].lifecycle);
    try testing.expectEqual(zui.Lifecycle.terminate_requested, polled.builder.events()[1].lifecycle);
    try testing.expect(!polled.poll(&window.window_host));
}

test "the clipboard round-trips text" {
    var window: HiddenWindow = .{};
    try window.open(1);
    defer window.close();
    const host = &window.window_host;
    try Host.zuiClipboard.write(host, "zui → clipboard ✓");
    var buffer: [64]u8 = undefined;
    try testing.expectEqualStrings("zui → clipboard ✓", Host.zuiClipboard.read(host, &buffer).?);
    try testing.expectEqual(@as(?[]u8, null), Host.zuiClipboard.read(host, buffer[0..4]));
}

test "requests reach the window: the cursor it shows, and an IME only while text input is asked for" {
    var window: HiddenWindow = .{};
    try window.open(1);
    defer window.close();
    const host = &window.window_host;
    var polled: Polled = .{};
    polled.init();
    _ = polled.poll(host);

    const requests: zui.HostRequests = .{ .cursor = .text, .text_input = .{ .caret = .{ .x = 10, .y = 10, .width = 2, .height = 16 } } };
    host.zuiApply(.main, requests);
    try expectAppliedWithin(host, requests);
    try testing.expect(host.window.ime_enabled);
    host.zuiApply(.main, .{});
    try expectAppliedWithin(host, .{});
    try testing.expect(!host.window.ime_enabled);
}

fn expectAppliedWithin(host: *Host, requests: zui.HostRequests) !void {
    for (0..200) |_| {
        if (std.meta.eql(host.window.applied, requests)) return;
        try testing.io.sleep(.fromMilliseconds(5), .awake);
    }
    return error.RequestsNotApplied;
}

test "Ctrl+C is a terminate request, as the console's handler reports it" {
    var window: HiddenWindow = .{};
    try window.open(1);
    defer window.close();
    var polled: Polled = .{};
    polled.init();
    _ = polled.poll(&window.window_host);

    try testing.expectEqual(@as(win32.BOOL, 1), zui_host.windows.onConsoleControl(win32.CTRL_C_EVENT));
    try testing.expect(polled.poll(&window.window_host));
    try testing.expectEqual(zui.Lifecycle.terminate_requested, polled.find(.lifecycle).?);
    try testing.expect(!polled.poll(&window.window_host));
}
