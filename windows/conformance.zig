//! zui's host suite and the Windows host's own tests, each against a
//! hidden window. Messages are sent, not posted, so each one has reached
//! the window before the test polls.

const std = @import("std");
const zui_host = @import("zui_host");
const zui = zui_host.zui;
const zui_testing = @import("zui_testing");
const zui_async = @import("zui_async");
const zui_widgets = @import("zui_widgets");
const Host = zui_host.Host;
const win32 = zui_host.windows.win32;
const keys = zui_host.windows.keys;
const uia = zui_host.windows.uia;
const uia_client = @import("uia_client.zig");

const testing = std.testing;

const HiddenWindow = struct {
    window_host: Host = undefined,
    service_fake: zui_host.windows.services.ServiceFake = .{},

    /// With `forced_scale` set, a pixel is that many layout units at a zoom of 1.
    fn open(self: *HiddenWindow, forced_scale: ?f32) !void {
        try self.openWithSemantics(forced_scale, .{});
    }

    fn openWithSemantics(self: *HiddenWindow, forced_scale: ?f32, semantics: zui.SemanticsCapacity) !void {
        self.window_host.forced_scale = forced_scale;
        self.window_host.service_fake = &self.service_fake;
        try self.window_host.init(testing.io, .{ .title = "zui host suite", .size = .{ 320, 240 }, .visible = false, .semantics = semantics });
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

    /// Through UI Automation, from this thread, which owns no window.
    pub fn invoke(self: *MessageHarness, label: []const u8) bool {
        invokeByName(self.window.window_host.hwnd, label) catch |err| std.debug.print("invoking \"{s}\" through UI Automation failed: {t}\n", .{ label, err });
        return true;
    }

    fn invokeByName(hwnd: win32.HWND, label: []const u8) !void {
        var client: uia_client.Client = try .init();
        defer client.deinit();
        const window = try client.elementFromHandle(hwnd);
        defer window.release();
        const element = try client.findByName(window, label) orelse return error.ElementNotFound;
        defer element.release();
        if (!try element.invoke()) return error.NotInvokable;
    }

    pub fn openedUrl(self: *MessageHarness) ?[]const u8 {
        return self.window.service_fake.openedUrl();
    }

    pub fn scriptServices(self: *MessageHarness, script: zui_testing.ServiceScript) void {
        self.window.service_fake.scriptFileDialog(script.chosen_paths);
        self.window.service_fake.scriptPopupMenu(script.chosen_menu_item);
        self.window.service_fake.scriptNotification(switch (script.notification) {
            .activated => .activated,
            .dismissed => .dismissed,
        });
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
    try harness.window.openWithSemantics(1, .{ .nodes = 8, .text_bytes = 64 });
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

const Replies = zui_async.Stream(zui.ServiceReply(64), .{ .capacity = 4 });

/// Waits, a wake at a time and for at most two seconds, for the host's
/// next answer.
fn awaitReply(host: *Host, replies: *Replies) !zui.ServiceReply(64) {
    const deadline = host.now().addNanoseconds(2 * std.time.ns_per_s);
    while (host.now().isBefore(deadline)) {
        host.zuiWait(.{ .at = deadline });
        replies.zuiSwap();
        var items = replies.zuiView().items();
        if (items.next()) |reply| return reply.*;
    }
    return error.NotAnswered;
}

test "the clipboard round-trips text, answered from the window thread for its request" {
    var window: HiddenWindow = .{};
    try window.open(1);
    defer window.close();
    const host = &window.window_host;
    try Host.zuiClipboard.write(host, "zui → clipboard ✓");
    var replies: Replies = .{};
    const paste: zui.ServiceRequest = .of("paste");
    try Host.zuiClipboard.read(host, paste, .of(&replies));
    const reply = try awaitReply(host, &replies);
    try testing.expectEqual(paste, reply.request);
    try testing.expectEqual(.clipboard_text, reply.kind);
    try testing.expectEqualStrings("zui → clipboard ✓", reply.text());
    try testing.expectError(error.InvalidUtf8, Host.zuiClipboard.write(host, "\xff"));
}

test "a URL reaches the system from the window thread, and what is not one never does" {
    var window: HiddenWindow = .{};
    try window.open(1);
    defer window.close();
    const host = &window.window_host;
    for ([_][]const u8{ "C:\\Windows\\System32\\calc.exe", "file:///C:/Windows/System32/calc.exe", "\\\\server\\share\\run.bat", "calc" }) |not_a_url| {
        try testing.expectError(error.InvalidUrl, Host.zuiOpenUrl.open(host, not_a_url));
    }
    try testing.expectError(error.TooLarge, Host.zuiOpenUrl.open(host, "https://example.com/" ++ "a" ** zui_host.windows.services.Services.url_capacity));
    try testing.expectError(error.InvalidUtf8, Host.zuiOpenUrl.open(host, "https://example.com/\xff"));
    try testing.expectEqual(@as(?[]const u8, null), window.service_fake.openedUrl());

    const url = "https://ziglang.org/documentation/0.16.0/#✓";
    try Host.zuiOpenUrl.open(host, url);
    const deadline = host.now().addNanoseconds(2 * std.time.ns_per_s);
    while (window.service_fake.openedUrl() == null and host.now().isBefore(deadline)) try testing.io.sleep(.fromMilliseconds(5), .awake);
    try testing.expectEqualStrings(url, window.service_fake.openedUrl() orelse "");
}

/// Waits for at most two seconds until the window thread has made `count`
/// `Shell_NotifyIconW` calls with `message`.
fn awaitNotifyIconCalls(window: *HiddenWindow, message: win32.DWORD, count: u32) !void {
    const deadline = window.window_host.now().addNanoseconds(2 * std.time.ns_per_s);
    while (window.service_fake.notifyIconCalls(message) < count) {
        if (!window.window_host.now().isBefore(deadline)) return error.NotShown;
        try testing.io.sleep(.fromMilliseconds(5), .awake);
    }
}

fn sendNotifyIconEvent(window: *HiddenWindow, event: win32.UINT) void {
    window.send(Host.wm_notify_icon, 0, zui_host.windows.services.notifyIconEventLparam(event));
}

test "a notification shows as a balloon of the window's icon, its title cut at a character, and answers activated when clicked" {
    var window: HiddenWindow = .{};
    try window.open(1);
    defer window.close();
    const host = &window.window_host;
    var replies: Replies = .{};
    const saved: zui.ServiceRequest = .of("saved");
    try Host.zuiNotifications.show(host, saved, .{ .title = "Saved " ++ "é" ** 60, .body = "zui → notification ✓" }, .of(&replies));
    try awaitNotifyIconCalls(&window, win32.NIM_MODIFY, 1);
    try testing.expectEqual(@as(u32, 1), window.service_fake.notifyIconCalls(win32.NIM_ADD));
    try testing.expectEqual(@as(u32, 1), window.service_fake.notifyIconCalls(win32.NIM_SETVERSION));
    const title = std.mem.sliceTo(&window.service_fake.balloon_title, 0);
    try testing.expectEqual(@as(usize, 63), title.len);
    try testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("Saved " ++ "é" ** 57), title);
    try testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("zui → notification ✓"), std.mem.sliceTo(&window.service_fake.balloon_body, 0));

    sendNotifyIconEvent(&window, win32.NIN_BALLOONSHOW);
    sendNotifyIconEvent(&window, win32.NIN_BALLOONUSERCLICK);
    const reply = try awaitReply(host, &replies);
    try testing.expectEqual(saved, reply.request);
    try testing.expectEqual(.notification_activated, reply.kind);
    try testing.expectEqual(@as(u32, 1), window.service_fake.notifyIconCalls(win32.NIM_DELETE));
}

test "a notification replaced by the next is dismissed, so is one that times out, and the icon goes with the last" {
    var window: HiddenWindow = .{};
    try window.open(1);
    defer window.close();
    const host = &window.window_host;
    var replies: Replies = .{};
    const first: zui.ServiceRequest = .of("first");
    const second: zui.ServiceRequest = .of("second");
    try Host.zuiNotifications.show(host, first, .{ .title = "First" }, .of(&replies));
    try awaitNotifyIconCalls(&window, win32.NIM_MODIFY, 1);
    try Host.zuiNotifications.show(host, second, .{ .title = "Second" }, .of(&replies));
    try awaitNotifyIconCalls(&window, win32.NIM_MODIFY, 2);
    const replaced = try awaitReply(host, &replies);
    try testing.expectEqual(first, replaced.request);
    try testing.expectEqual(.notification_dismissed, replaced.kind);
    try testing.expectEqual(@as(u32, 1), window.service_fake.notifyIconCalls(win32.NIM_ADD));
    try testing.expectEqual(@as(u32, 0), window.service_fake.notifyIconCalls(win32.NIM_DELETE));

    sendNotifyIconEvent(&window, win32.NIN_BALLOONTIMEOUT);
    const timed_out = try awaitReply(host, &replies);
    try testing.expectEqual(second, timed_out.request);
    try testing.expectEqual(.notification_dismissed, timed_out.kind);
    try testing.expectEqual(@as(u32, 1), window.service_fake.notifyIconCalls(win32.NIM_DELETE));

    sendNotifyIconEvent(&window, win32.NIN_BALLOONHIDE);
    replies.zuiSwap();
    var unanswered = replies.zuiView().items();
    try testing.expectEqual(null, unanswered.next());
}

const file_dialog = zui_host.windows.file_dialog;
const W = std.unicode.utf8ToUtf16LeStringLiteral;

/// Waits for at most two seconds until the window thread has made the
/// shell's dialog for the `count`th time.
fn awaitFileDialogs(window: *HiddenWindow, count: u32) !void {
    const deadline = window.window_host.now().addNanoseconds(2 * std.time.ns_per_s);
    while (window.service_fake.fileDialogsShown() < count) {
        if (!window.window_host.now().isBefore(deadline)) return error.NotShown;
        try testing.io.sleep(.fromMilliseconds(5), .awake);
    }
}

test "an open dialog is made as asked, read back from the shell's dialog, and answers the paths chosen" {
    var window: HiddenWindow = .{};
    try window.open(1);
    defer window.close();
    const host = &window.window_host;
    var replies: Replies = .{};
    const open: zui.ServiceRequest = .of("open themes");
    window.service_fake.scriptFileDialog("C:\\a.zon\x00C:\\b.zon\x00");
    try Host.zuiFileDialogs.show(host, .main, open, .{
        .kind = .open_files,
        .title = "Open themes",
        .directory = "C:\\Windows",
        .filters = &.{ .{ .name = "Themes", .extensions = &.{ "zon", "json" } }, .{ .name = "All files", .extensions = &.{} } },
    }, .of(&replies));
    const reply = try awaitReply(host, &replies);
    try testing.expectEqual(open, reply.request);
    try testing.expectEqual(zui.WindowId.main, reply.window);
    try testing.expectEqual(.files_chosen, reply.kind);
    var chosen = reply.paths();
    try testing.expectEqualStrings("C:\\a.zon", chosen.next().?);
    try testing.expectEqualStrings("C:\\b.zon", chosen.next().?);
    try testing.expectEqual(null, chosen.next());

    const seen = &window.service_fake.seen_dialog;
    const asked = file_dialog.FOS_ALLOWMULTISELECT | file_dialog.FOS_FILEMUSTEXIST | file_dialog.FOS_FORCEFILESYSTEM | file_dialog.FOS_NOCHANGEDIR;
    try testing.expectEqual(asked, seen.options & asked);
    try testing.expectEqual(@as(u32, 0), seen.options & file_dialog.FOS_PICKFOLDERS);
    try testing.expectEqualSlices(u16, W("C:\\Windows"), seen.folderPath());
    try testing.expectEqual(@as(usize, 2), seen.filter_count);
    try testing.expectEqualSlices(u16, W("Themes"), seen.firstFilterName());
    try testing.expectEqualSlices(u16, W("*.zon;*.json"), seen.firstFilterPattern());
}

test "a save dialog suggests its name and asks before overwriting, a folder dialog picks folders, and either canceled answers canceled" {
    var window: HiddenWindow = .{};
    try window.open(1);
    defer window.close();
    const host = &window.window_host;
    var replies: Replies = .{};
    const save: zui.ServiceRequest = .of("save theme");
    window.service_fake.scriptFileDialog("");
    try Host.zuiFileDialogs.show(host, .main, save, .{ .kind = .save_file, .file_name = "dark.zon", .filters = &.{.{ .name = "Themes", .extensions = &.{"zon"} }} }, .of(&replies));
    const canceled = try awaitReply(host, &replies);
    try testing.expectEqual(save, canceled.request);
    try testing.expectEqual(.canceled, canceled.kind);
    const seen = &window.service_fake.seen_dialog;
    try testing.expect(seen.options & file_dialog.FOS_OVERWRITEPROMPT != 0);
    try testing.expectEqual(@as(u32, 0), seen.options & file_dialog.FOS_ALLOWMULTISELECT);
    try testing.expectEqualSlices(u16, W("dark.zon"), seen.fileName());

    const folder: zui.ServiceRequest = .of("choose folder");
    window.service_fake.scriptFileDialog("C:\\themes\x00");
    try Host.zuiFileDialogs.show(host, .main, folder, .{ .kind = .choose_folder }, .of(&replies));
    const chosen = try awaitReply(host, &replies);
    try testing.expectEqual(folder, chosen.request);
    var chosen_folders = chosen.paths();
    try testing.expectEqualStrings("C:\\themes", chosen_folders.next().?);
    try testing.expect(seen.options & file_dialog.FOS_PICKFOLDERS != 0);
}

test "a second file dialog while one is open is busy, and paths past the reply's room are counted" {
    var window: HiddenWindow = .{};
    try window.open(1);
    defer window.close();
    const host = &window.window_host;
    var replies: Replies = .{};
    const first: zui.ServiceRequest = .of("first");
    window.service_fake.hold_file_dialog_open.store(true, .release);
    window.service_fake.scriptFileDialog("C:\\" ++ "a" ** 40 ++ ".zon\x00C:\\" ++ "b" ** 40 ++ ".zon\x00");
    try Host.zuiFileDialogs.show(host, .main, first, .{}, .of(&replies));
    try awaitFileDialogs(&window, 1);
    try testing.expectError(error.Busy, Host.zuiFileDialogs.show(host, .main, .of("second"), .{}, .of(&replies)));

    window.service_fake.releaseHeldFileDialog(host.hwnd);
    const reply = try awaitReply(host, &replies);
    try testing.expectEqual(first, reply.request);
    var chosen = reply.paths();
    try testing.expectEqualStrings("C:\\" ++ "a" ** 40 ++ ".zon", chosen.next().?);
    try testing.expectEqual(null, chosen.next());
    try testing.expectEqual(@as(u32, 3 + 40 + 4 + 1), reply.left_out_bytes);
    try Host.zuiFileDialogs.show(host, .main, .of("second"), .{}, .of(&replies));
}

test "a file dialog the host cannot hold, or whose text is not UTF-8, is refused and shown neither" {
    var window: HiddenWindow = .{};
    try window.open(1);
    defer window.close();
    const host = &window.window_host;
    var replies: Replies = .{};
    const filter: zui.FileFilter = .{ .name = "Themes", .extensions = &.{"zon"} };
    try testing.expectError(error.TooLarge, Host.zuiFileDialogs.show(host, .main, .of("open"), .{ .filters = &([_]zui.FileFilter{filter} ** (file_dialog.CopiedDialog.filter_capacity + 1)) }, .of(&replies)));
    try testing.expectError(error.TooLarge, Host.zuiFileDialogs.show(host, .main, .of("open"), .{ .title = "t" ** file_dialog.CopiedDialog.unit_capacity }, .of(&replies)));
    try testing.expectError(error.InvalidUtf8, Host.zuiFileDialogs.show(host, .main, .of("open"), .{ .file_name = "\xff.zon" }, .of(&replies)));
    try testing.io.sleep(.fromMilliseconds(50), .awake);
    try testing.expectEqual(@as(u32, 0), window.service_fake.fileDialogsShown());
}

test "a file dialog still open when the host closes is closed first, and not answered" {
    var window: HiddenWindow = .{};
    try window.open(1);
    var replies: Replies = .{};
    window.service_fake.hold_file_dialog_open.store(true, .release);
    window.service_fake.scriptFileDialog("C:\\a.zon\x00");
    try Host.zuiFileDialogs.show(&window.window_host, .main, .of("open"), .{}, .of(&replies));
    try awaitFileDialogs(&window, 1);
    window.close();
    replies.zuiSwap();
    var unanswered = replies.zuiView().items();
    try testing.expectEqual(null, unanswered.next());
}

const SeenMenu = zui_host.windows.services.ServiceFake.SeenMenu;
const CopiedMenu = zui_host.windows.menu.CopiedMenu;

/// Waits for at most two seconds until the window thread has shown a
/// popup menu for the `count`th time.
fn awaitPopupMenus(window: *HiddenWindow, count: u32) !void {
    const deadline = window.window_host.now().addNanoseconds(2 * std.time.ns_per_s);
    while (window.service_fake.popupMenusShown() < count) {
        if (!window.window_host.now().isBefore(deadline)) return error.NotShown;
        try testing.io.sleep(.fromMilliseconds(5), .awake);
    }
}

/// Waits for at most two seconds until the window's menu bar is no longer
/// `replaced`, and returns it.
fn awaitMenuBarReplacing(window: *HiddenWindow, replaced: ?win32.HMENU) !?win32.HMENU {
    const deadline = window.window_host.now().addNanoseconds(2 * std.time.ns_per_s);
    while (win32.GetMenu(window.window_host.hwnd) == replaced) {
        if (!window.window_host.now().isBefore(deadline)) return error.MenuBarNotSet;
        try testing.io.sleep(.fromMilliseconds(5), .awake);
    }
    return win32.GetMenu(window.window_host.hwnd);
}

fn expectNoReply(replies: *Replies) !void {
    replies.zuiSwap();
    var unanswered = replies.zuiView().items();
    try testing.expectEqual(null, unanswered.next());
}

fn chooseFromMenuBar(window: *HiddenWindow, command: u32) void {
    window.send(win32.WM_COMMAND, command, 0);
}

test "a popup menu is built as asked, read back from Windows' menu, shown in screen pixels where it was asked, and answers the item chosen" {
    var window: HiddenWindow = .{};
    try window.open(2);
    defer window.close();
    const host = &window.window_host;
    var polled: Polled = .{};
    polled.init();
    _ = polled.poll(host);

    var replies: Replies = .{};
    const edit: zui.ServiceRequest = .of("edit menu");
    const dark: zui.MenuItemId = @enumFromInt(20);
    window.service_fake.scriptPopupMenu(dark);
    try Host.zuiMenus.popup(host, .main, edit, &.{
        .{ .id = @enumFromInt(10), .label = "Cut", .shortcut = .{ .key = .x, .modifiers = .{ .control = true } } },
        .separator,
        .{ .label = "Recent", .submenu = &.{ .{ .id = dark, .label = "dark.zon" }, .{ .id = @enumFromInt(21), .label = "light.zon", .enabled = false, .checked = true } } },
        .{ .id = @enumFromInt(30), .label = "Paste & go" },
    }, .{ 10, 20 }, .of(&replies));
    const reply = try awaitReply(host, &replies);
    try testing.expectEqual(edit, reply.request);
    try testing.expectEqual(zui.WindowId.main, reply.window);
    try testing.expectEqual(.menu_item_chosen, reply.kind);
    try testing.expectEqual(dark, reply.menu_item);

    const seen = &window.service_fake.seen_popup_menu;
    var expected_position: win32.POINT = .{ .x = 20, .y = 40 };
    _ = win32.ClientToScreen(host.hwnd, &expected_position);
    try testing.expectEqual(expected_position, seen.position);
    try testing.expectEqual(@as(usize, 6), seen.item_count);
    try testing.expectEqualSlices(u16, W("Cut\tCtrl+X"), seen.items[0].labelUnits());
    try testing.expect(seen.items[1].state & win32.MF_SEPARATOR != 0);
    try testing.expectEqualSlices(u16, W("Recent"), seen.items[2].labelUnits());
    try testing.expect(seen.items[2].state & win32.MF_POPUP != 0);
    try testing.expectEqual(@as(usize, 1), seen.items[3].depth);
    try testing.expectEqualSlices(u16, W("light.zon"), seen.items[4].labelUnits());
    try testing.expectEqual(@as(u32, win32.MF_GRAYED | win32.MF_CHECKED), seen.items[4].state & (win32.MF_GRAYED | win32.MF_CHECKED));
    try testing.expectEqual(@as(u32, 0), seen.items[3].state & (win32.MF_GRAYED | win32.MF_CHECKED));
    try testing.expectEqualSlices(u16, W("Paste && go"), seen.items[5].labelUnits());
}

test "one dialog or menu shows at a time: a popup menu or a file dialog while a popup menu is open is busy, and a menu closed answers canceled" {
    var window: HiddenWindow = .{};
    try window.open(1);
    defer window.close();
    const host = &window.window_host;
    var replies: Replies = .{};
    const items = [_]zui.MenuItem{.{ .id = @enumFromInt(1), .label = "Copy" }};
    const first: zui.ServiceRequest = .of("first");
    window.service_fake.scriptPopupMenu(null);
    window.service_fake.hold_popup_menu_open.store(true, .release);
    try Host.zuiMenus.popup(host, .main, first, &items, .{ 0, 0 }, .of(&replies));
    try awaitPopupMenus(&window, 1);
    try testing.expectError(error.Busy, Host.zuiMenus.popup(host, .main, .of("second"), &items, .{ 0, 0 }, .of(&replies)));
    try testing.expectError(error.Busy, Host.zuiFileDialogs.show(host, .main, .of("open"), .{}, .of(&replies)));

    window.service_fake.releaseHeldPopupMenu(host.hwnd);
    const closed = try awaitReply(host, &replies);
    try testing.expectEqual(first, closed.request);
    try testing.expectEqual(.canceled, closed.kind);

    window.service_fake.hold_file_dialog_open.store(true, .release);
    window.service_fake.scriptFileDialog("");
    try Host.zuiFileDialogs.show(host, .main, .of("open"), .{}, .of(&replies));
    try awaitFileDialogs(&window, 1);
    try testing.expectError(error.Busy, Host.zuiMenus.popup(host, .main, .of("second"), &items, .{ 0, 0 }, .of(&replies)));
    window.service_fake.releaseHeldFileDialog(host.hwnd);
    _ = try awaitReply(host, &replies);
    try Host.zuiMenus.popup(host, .main, .of("second"), &items, .{ 0, 0 }, .of(&replies));
    _ = try awaitReply(host, &replies);
}

test "a menu the host cannot hold, or whose labels are not UTF-8, is refused and shown neither as a popup nor as a bar" {
    var window: HiddenWindow = .{};
    try window.open(1);
    defer window.close();
    const host = &window.window_host;
    var replies: Replies = .{};
    const item: zui.MenuItem = .{ .id = @enumFromInt(1), .label = "Item" };
    const too_many = [_]zui.MenuItem{item} ** (CopiedMenu.entry_capacity + 1);
    try testing.expectError(error.TooLarge, Host.zuiMenus.popup(host, .main, .of("menu"), &too_many, .{ 0, 0 }, .of(&replies)));
    try testing.expectError(error.TooLarge, Host.zuiMenus.setBar(host, .main, .of("bar"), &too_many, .of(&replies)));
    try testing.expectError(error.InvalidUtf8, Host.zuiMenus.popup(host, .main, .of("menu"), &.{.{ .label = "\xff" }}, .{ 0, 0 }, .of(&replies)));
    try testing.expectError(error.InvalidUtf8, Host.zuiMenus.setBar(host, .main, .of("bar"), &.{.{ .label = "File", .submenu = &.{.{ .label = "\xc3" }} }}, .of(&replies)));
    try testing.io.sleep(.fromMilliseconds(50), .awake);
    try testing.expectEqual(@as(u32, 0), window.service_fake.popupMenusShown());
    try testing.expectEqual(@as(?win32.HMENU, null), win32.GetMenu(host.hwnd));
    try expectNoReply(&replies);
}

test "a popup menu still open when the host closes is closed first, and not answered" {
    var window: HiddenWindow = .{};
    try window.open(1);
    var replies: Replies = .{};
    window.service_fake.hold_popup_menu_open.store(true, .release);
    window.service_fake.scriptPopupMenu(@enumFromInt(1));
    try Host.zuiMenus.popup(&window.window_host, .main, .of("menu"), &.{.{ .id = @enumFromInt(1), .label = "Copy" }}, .{ 0, 0 }, .of(&replies));
    try awaitPopupMenus(&window, 1);
    window.close();
    try expectNoReply(&replies);
}

test "a menu bar is set on the window, answers each item chosen from it, and is replaced or removed" {
    var window: HiddenWindow = .{};
    try window.open(1);
    defer window.close();
    const host = &window.window_host;
    var replies: Replies = .{};
    const file_menu: zui.ServiceRequest = .of("file menu");
    const open_item: zui.MenuItemId = @enumFromInt(1);
    const quit_item: zui.MenuItemId = @enumFromInt(2);
    try Host.zuiMenus.setBar(host, .main, file_menu, &.{
        .{ .label = "File", .submenu = &.{ .{ .id = open_item, .label = "Open", .shortcut = .{ .key = .o, .modifiers = .{ .control = true } } }, .separator, .{ .id = quit_item, .label = "Quit" } } },
        .{ .id = @enumFromInt(3), .label = "Help" },
    }, .of(&replies));
    const first_bar = (try awaitMenuBarReplacing(&window, null)).?;
    var seen: SeenMenu = .{};
    seen.read(first_bar, 0);
    try testing.expectEqual(@as(usize, 5), seen.item_count);
    try testing.expectEqualSlices(u16, W("File"), seen.items[0].labelUnits());
    try testing.expectEqualSlices(u16, W("Open\tCtrl+O"), seen.items[1].labelUnits());
    try testing.expectEqualSlices(u16, W("Help"), seen.items[4].labelUnits());

    const quit_command = seen.items[3].command;
    for ([_]struct { command: u32, item: zui.MenuItemId }{ .{ .command = quit_command, .item = quit_item }, .{ .command = seen.items[1].command, .item = open_item } }) |choice| {
        chooseFromMenuBar(&window, choice.command);
        const reply = try awaitReply(host, &replies);
        try testing.expectEqual(file_menu, reply.request);
        try testing.expectEqual(.menu_item_chosen, reply.kind);
        try testing.expectEqual(choice.item, reply.menu_item);
    }

    // While the user is in the bar's menus, a new bar waits for them to close.
    const edit_menu: zui.ServiceRequest = .of("edit menu");
    window.send(win32.WM_ENTERMENULOOP, 0, 0);
    try Host.zuiMenus.setBar(host, .main, edit_menu, &.{.{ .id = @enumFromInt(4), .label = "Undo" }}, .of(&replies));
    try testing.io.sleep(.fromMilliseconds(50), .awake);
    try testing.expectEqual(@as(?win32.HMENU, first_bar), win32.GetMenu(host.hwnd));
    window.send(win32.WM_EXITMENULOOP, 0, 0);
    const second_bar = (try awaitMenuBarReplacing(&window, first_bar)).?;
    seen = .{};
    seen.read(second_bar, 0);
    try testing.expectEqualSlices(u16, W("Undo"), seen.items[0].labelUnits());

    chooseFromMenuBar(&window, seen.items[0].command);
    const undo = try awaitReply(host, &replies);
    try testing.expectEqual(edit_menu, undo.request);
    try testing.expectEqual(@as(zui.MenuItemId, @enumFromInt(4)), undo.menu_item);

    // Windows may report a choice from the old bar after it was replaced.
    chooseFromMenuBar(&window, quit_command);
    const late_quit = try awaitReply(host, &replies);
    try testing.expectEqual(file_menu, late_quit.request);
    try testing.expectEqual(quit_item, late_quit.menu_item);

    try Host.zuiMenus.setBar(host, .main, .of("no menu"), &.{}, .of(&replies));
    try testing.expectEqual(@as(?win32.HMENU, null), try awaitMenuBarReplacing(&window, second_bar));
    try expectNoReply(&replies);
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

test "the system material is reported only where the window asked for it and the system has it" {
    for ([_]struct { material: zui.SystemMaterial, unavailable: bool }{
        .{ .material = .none, .unavailable = false },
        .{ .material = .window, .unavailable = true },
    }) |case| {
        var window: HiddenWindow = .{};
        window.window_host.system_material_unavailable = case.unavailable;
        window.window_host.forced_scale = 1;
        try window.window_host.init(testing.io, .{ .title = "zui host suite", .size = .{ 320, 240 }, .visible = false, .material = case.material });
        defer window.close();
        var polled: Polled = .{};
        polled.init();
        _ = polled.poll(&window.window_host);
        var environment: zui.Environment = .{ .system_material = true };
        for (polled.builder.events()) |event| if (event == .environment) environment.apply(event.environment);
        try testing.expect(!environment.system_material);
    }
}

const hdr_display: zui_host.windows.display.DisplayColor = .{ .hdr = true, .peak_nits = 1000, .sdr_white_nits = 200 };

fn openOnDisplay(window: *HiddenWindow, color: zui_host.windows.display.DisplayColor, output_formats: zui.OutputFormats) !void {
    window.window_host.forced_display_color = color;
    window.window_host.forced_scale = 1;
    try window.window_host.init(testing.io, .{ .title = "zui host suite", .size = .{ 320, 240 }, .visible = false, .output_formats = output_formats });
}

fn reportedHeadroom(polled: *const Polled) ?f32 {
    var headroom: ?f32 = null;
    for (polled.builder.events()) |event| if (event == .environment and event.environment == .hdr_headroom) {
        headroom = event.environment.hdr_headroom;
    };
    return headroom;
}

test "on an HDR display a window opened with scRGB gets an scRGB surface and the display's headroom" {
    var window: HiddenWindow = .{};
    try openOnDisplay(&window, hdr_display, Host.zui_output_formats);
    defer window.close();
    var polled: Polled = .{};
    polled.init();
    _ = polled.poll(&window.window_host);
    try testing.expectEqual(zui.OutputFormat.scrgb_fp16, window.window_host.zuiSurface(.main).outputFormat());
    try testing.expectEqual(@as(?f32, 5), reportedHeadroom(&polled));
}

test "a window opened only in SDR stays SDR on an HDR display, with no headroom" {
    var window: HiddenWindow = .{};
    try openOnDisplay(&window, hdr_display, .initOne(.sdr));
    defer window.close();
    var polled: Polled = .{};
    polled.init();
    _ = polled.poll(&window.window_host);
    try testing.expectEqual(zui.OutputFormat.sdr, window.window_host.zuiSurface(.main).outputFormat());
    try testing.expectEqual(@as(?f32, 1), reportedHeadroom(&polled));
}

test "turning HDR off returns the surface to SDR and the headroom to 1" {
    var window: HiddenWindow = .{};
    try openOnDisplay(&window, hdr_display, Host.zui_output_formats);
    defer window.close();
    var polled: Polled = .{};
    polled.init();
    _ = polled.poll(&window.window_host);

    window.window_host.forced_display_color = .sdr;
    window.send(win32.WM_DISPLAYCHANGE, 32, 0);
    _ = polled.poll(&window.window_host);
    try testing.expectEqual(zui.OutputFormat.sdr, window.window_host.zuiSurface(.main).outputFormat());
    try testing.expectEqual(@as(?f32, 1), reportedHeadroom(&polled));
}

test "the monitor a window is on reads as HDR with headroom, or as SDR" {
    var window: HiddenWindow = .{};
    try window.open(1);
    defer window.close();
    const monitor = win32.MonitorFromWindow(window.window_host.hwnd, win32.MONITOR_DEFAULTTONEAREST) orelse return error.NoMonitor;
    const color: zui_host.windows.display.DisplayColor = .read(monitor);
    try testing.expect(color.headroom() >= 1);
    if (!color.hdr) try testing.expectEqual(@as(f32, 1), color.headroom());
    if (color.hdr) try testing.expect(color.sdr_white_nits >= 80);
}

const FileChanges = zui_async.Stream(zui.FileChange, .{ .capacity = 64, .producers = .many });

/// Waits, a wake at a time and for at most two seconds, until a change of
/// `kind` to `path` has been published, and returns how many changes came
/// in until it did.
fn awaitChange(host: *Host, changes: *FileChanges, kind: zui.FileChange.Kind, path: []const u8) !usize {
    const deadline = host.now().addNanoseconds(2 * std.time.ns_per_s);
    var seen: usize = 0;
    while (host.now().isBefore(deadline)) {
        host.zuiWait(.{ .at = deadline });
        changes.zuiSwap();
        var items = changes.zuiView().items();
        while (items.next()) |change| {
            seen += 1;
            if (change.kind == kind and std.mem.eql(u8, change.pathBytes(), path)) return seen;
        }
    }
    return error.ChangeNotReported;
}

test "a watched directory reports files added, written, renamed and removed, in its subdirectories too" {
    var window: HiddenWindow = .{};
    try window.open(1);
    defer window.close();
    const host = &window.window_host;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    var directory_buffer: [128]u8 = undefined;
    const directory = try std.fmt.bufPrint(&directory_buffer, ".zig-cache/tmp/{s}", .{&tmp.sub_path});

    var changes: FileChanges = .{};
    try Host.zuiFileWatch.watch(host, directory, .of(&changes));

    try tmp.dir.writeFile(io, .{ .sub_path = "theme.zon", .data = ".{ .background = 0x202020 }" });
    _ = try awaitChange(host, &changes, .added, "theme.zon");
    try tmp.dir.writeFile(io, .{ .sub_path = "theme.zon", .data = ".{ .background = 0xf3f3f3 }" });
    _ = try awaitChange(host, &changes, .modified, "theme.zon");
    try tmp.dir.rename("theme.zon", tmp.dir, "light.zon", io);
    _ = try awaitChange(host, &changes, .renamed_to, "light.zon");
    try tmp.dir.createDir(io, "icons", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "icons/save.svg", .data = "<svg/>" });
    _ = try awaitChange(host, &changes, .added, "icons/save.svg");
    try tmp.dir.deleteFile(io, "light.zon");
    _ = try awaitChange(host, &changes, .removed, "light.zon");
}

test "watching a directory that does not exist fails, and so does watching more than the host can" {
    var window: HiddenWindow = .{};
    try window.open(1);
    defer window.close();
    const host = &window.window_host;
    var changes: FileChanges = .{};
    try testing.expectError(error.DirectoryUnavailable, Host.zuiFileWatch.watch(host, ".zig-cache/no such directory", .of(&changes)));
    for (0..zui_host.windows.file_watch.Watches.capacity) |_| try Host.zuiFileWatch.watch(host, ".", .of(&changes));
    try testing.expectError(error.TooManyWatches, Host.zuiFileWatch.watch(host, ".", .of(&changes)));
}

const toolbar_id = 0x1111_2222_3333_4444;
const save_id = 0x8000_0001_0000_0002;
const open_id = 0x0000_0005_0000_0006;

fn toolbar(open_state: zui.SemanticState, open_actions: zui.Actions) [3]zui.SemanticNode {
    const save_actions: zui.Actions = .initMany(&.{ .invoke, .focus });
    return .{
        .{ .id = toolbar_id, .parent = null, .role = .group, .label = "Toolbar", .value = .none, .bounds = .{ .x = 10, .y = 20, .width = 200, .height = 40 }, .state = .{}, .actions = .initEmpty() },
        .{ .id = save_id, .parent = 0, .role = .button, .label = "Save", .value = .none, .bounds = .{ .x = 12, .y = 24, .width = 60, .height = 30 }, .state = .{}, .actions = save_actions },
        .{ .id = open_id, .parent = 0, .role = .button, .label = "Open", .value = .none, .bounds = .{ .x = 80, .y = 24, .width = 60, .height = 30 }, .state = open_state, .actions = open_actions },
    };
}

fn openToolbarWindow(window: *HiddenWindow, polled: *Polled, open_state: zui.SemanticState, open_actions: zui.Actions) !void {
    try window.openWithSemantics(2, .{ .nodes = 8, .text_bytes = 64 });
    polled.init();
    _ = polled.poll(&window.window_host);
    const nodes = toolbar(open_state, open_actions);
    try testing.expectEqual(zui.SemanticsDropped{}, window.window_host.zuiSemantics(.main, &nodes));
}

fn expectAction(host: *Host, polled: *Polled, expected: zui.ActionEvent) !void {
    for (0..200) |_| {
        _ = polled.poll(host);
        for (polled.builder.events()) |event| if (event == .action and std.meta.eql(event.action, expected)) return;
        try testing.io.sleep(.fromMilliseconds(5), .awake);
    }
    return error.ActionNotReported;
}

test "the semantics read back through UI Automation: names, roles, ids, the tree and bounds in screen pixels" {
    var window: HiddenWindow = .{};
    var polled: Polled = .{};
    try openToolbarWindow(&window, &polled, .{}, .initOne(.invoke));
    defer window.close();

    var client: uia_client.Client = try .init();
    defer client.deinit();
    const window_element = try client.elementFromHandle(window.window_host.hwnd);
    defer window_element.release();
    const save = (try client.findByName(window_element, "Save")).?;
    defer save.release();
    var buffer: [64]u8 = undefined;
    try testing.expectEqualStrings("Save", try save.name(&buffer));
    try testing.expectEqualStrings("8000000100000002", try save.automationId(&buffer));
    try testing.expectEqual(uia.UIA_ButtonControlTypeId, try save.controlType());

    var origin: win32.POINT = .{};
    _ = win32.ClientToScreen(window.window_host.hwnd, &origin);
    try testing.expectEqual(win32.RECT{ .left = origin.x + 24, .top = origin.y + 48, .right = origin.x + 24 + 120, .bottom = origin.y + 48 + 60 }, try save.boundingRectangle());

    const walker = try client.rawViewWalker();
    defer walker.release();
    const group = (try walker.parent(save)).?;
    defer group.release();
    try testing.expectEqualStrings("Toolbar", try group.name(&buffer));
    try testing.expectEqual(uia.UIA_GroupControlTypeId, try group.controlType());
    const first = (try walker.firstChild(group)).?;
    defer first.release();
    try testing.expectEqualStrings("Save", try first.name(&buffer));
    const second = (try walker.nextSibling(first)).?;
    defer second.release();
    try testing.expectEqualStrings("Open", try second.name(&buffer));
    try testing.expectEqual(@as(?uia_client.Element, null), try walker.nextSibling(second));
    const window_again = (try walker.parent(group)).?;
    defer window_again.release();
    try testing.expectEqualStrings("zui host suite", try window_again.name(&buffer));
}

test "an assistive technology's focus arrives as a focus action, and a disabled element offers no invoke" {
    var window: HiddenWindow = .{};
    var polled: Polled = .{};
    try openToolbarWindow(&window, &polled, .{ .disabled = true }, .initEmpty());
    defer window.close();

    var client: uia_client.Client = try .init();
    defer client.deinit();
    const window_element = try client.elementFromHandle(window.window_host.hwnd);
    defer window_element.release();
    const save = (try client.findByName(window_element, "Save")).?;
    defer save.release();
    try save.setFocus();
    try expectAction(&window.window_host, &polled, .{ .target = save_id, .action = .focus });

    const open = (try client.findByName(window_element, "Open")).?;
    defer open.release();
    try testing.expect(!try open.invoke());
}

test "a window opened without room for semantics leaves UI Automation to Windows, and keeps none" {
    var window: HiddenWindow = .{};
    try window.open(1);
    defer window.close();
    try testing.expectEqual(@as(win32.LRESULT, 0), win32.SendMessageW(window.window_host.hwnd, win32.WM_GETOBJECT, 0, uia.UiaRootObjectId));
    const nodes = toolbar(.{}, .initEmpty());
    try testing.expectEqual(zui.SemanticsDropped{ .nodes = 3, .text_bytes = 15 }, window.window_host.zuiSemantics(.main, &nodes));
}

test "semantics past the window's room are cut from the end and reported" {
    var window: HiddenWindow = .{};
    try window.openWithSemantics(1, .{ .nodes = 2, .text_bytes = 9 });
    defer window.close();
    const nodes = toolbar(.{}, .initEmpty());
    try testing.expectEqual(zui.SemanticsDropped{ .nodes = 1, .text_bytes = 2 + 4 }, window.window_host.zuiSemantics(.main, &nodes));

    var client: uia_client.Client = try .init();
    defer client.deinit();
    const window_element = try client.elementFromHandle(window.window_host.hwnd);
    defer window_element.release();
    const cut = (try client.findByName(window_element, "Sa")).?;
    defer cut.release();
    try testing.expectEqual(@as(?uia_client.Element, null), try client.findByName(window_element, "Open"));
}

/// Every byte is half as wide as the font is tall.
const HalfWidthText = struct {
    pub fn zuiMeasure(_: *HalfWidthText, run: []const u8, key: zui.MeasureKey(u16)) [2]f32 {
        return .{ @as(f32, @floatFromInt(run.len)) * key.size / 2, key.size };
    }
};

const ControlsUi = zui.Context(.{ .Text = HalfWidthText, .features = .{ .semantics = true }, .limits = .{ .max_elements = 256 } });
const qualities = [_][]const u8{ "Low", "Medium", "High" };

/// A hidden window showing one of each `zui_widgets` control, whose frames
/// the test runs itself, so what UI Automation asks arrives in the next.
const ControlsWindow = struct {
    window: HiddenWindow = .{},
    text: HalfWidthText = .{},
    ui: ControlsUi = undefined,
    events: [64]zui.Event = undefined,
    text_buffer: [ControlsUi.limits.max_text_input_bytes + ControlsUi.limits.max_dropped_path_bytes]u8 = undefined,
    builder: zui.RecordBuilder = undefined,
    widgets: zui_widgets.Widgets(ControlsUi) = .{},
    saves: u32 = 0,
    autosave: bool = true,
    volume: f32 = 0.5,
    quality: usize = 0,
    details_open: bool = false,
    name_bytes: [32]u8 = undefined,
    name: zui_widgets.EditableText = undefined,
    /// The last frame listed the dropdown's options.
    options_shown: bool = false,
    /// How far the log is scrolled, as the last frame listed it.
    log_offset: f32 = 0,

    fn open(self: *ControlsWindow) !void {
        try self.window.openWithSemantics(1, .{ .nodes = 256, .text_bytes = 4096 });
        errdefer self.window.close();
        self.ui = try .init(testing.allocator, testing.io, &self.text);
        self.builder = .init(&self.events, &self.text_buffer);
        self.name = .init(&self.name_bytes, "Ada");
        self.frame();
    }

    fn close(self: *ControlsWindow) void {
        self.ui.deinit(testing.allocator);
        self.window.close();
    }

    fn frame(self: *ControlsWindow) void {
        _ = self.window.window_host.zuiPoll(.main, &self.builder);
        self.ui.beginFrame(&self.builder.record());
        self.declare();
        const drawn = self.ui.endFrame();
        _ = self.window.window_host.zuiSemantics(.main, drawn.semantics());
        self.options_shown = false;
        for (drawn.semantics()) |node| {
            self.options_shown = self.options_shown or node.role == .option;
            if (node.role == .scroll_area) self.log_offset = node.scroll.?.offset[1];
        }
        self.ui.release(drawn);
    }

    fn declare(self: *ControlsWindow) void {
        const ui = &self.ui;
        ui.open(.{ .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both, .child_gap = 4 } });
        defer ui.close();
        if (self.widgets.button(ui, .of("save"), "Save", .{})) self.saves += 1;
        _ = self.widgets.checkbox(ui, .of("autosave"), "Autosave", &self.autosave, .{});
        _ = self.widgets.slider(ui, .of("volume"), &self.volume, .{ .step = 0.1, .label = "Volume" });
        _ = self.widgets.textField(ui, .of("name"), &self.name, .{ .label = "Name" });
        _ = self.widgets.dropdown(ui, .of("quality"), &self.quality, &qualities, .{ .label = "Quality" });
        _ = self.widgets.disclosure(ui, .of("details"), "Details", &self.details_open);
        ui.open(.{ .id = .of("log"), .scroll = .{ .vertical = true }, .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(100), .height = .fixed(40) } }, .semantics = .{ .role = .scroll_area, .label = "Log" } });
        for (0..5) |_| ui.box(.{ .layout = .{ .sizing = .{ .width = .fixed(100), .height = .fixed(20) } } });
        ui.close();
    }

    /// Runs frames until `reached` holds, for at most two seconds.
    fn frameUntil(self: *ControlsWindow, comptime reached: fn (*const ControlsWindow) bool) !void {
        for (0..200) |_| {
            self.frame();
            if (reached(self)) return;
            try testing.io.sleep(.fromMilliseconds(10), .awake);
        }
        return error.FrameNeverCame;
    }
};

fn findNamed(client: *uia_client.Client, window_element: uia_client.Element, name: []const u8) !uia_client.Element {
    return try client.findByName(window_element, name) orelse error.ElementNotFound;
}

test "each zui_widgets control offers UI Automation the pattern that stands for it, with its state" {
    var controls: ControlsWindow = .{};
    try controls.open();
    defer controls.close();
    var client: uia_client.Client = try .init();
    defer client.deinit();
    const window_element = try client.elementFromHandle(controls.window.window_host.hwnd);
    defer window_element.release();
    var buffer: [64]u8 = undefined;

    const save = try findNamed(&client, window_element, "Save");
    defer save.release();
    try testing.expect(try save.hasPattern(uia.UIA_InvokePatternId));
    try testing.expect(!try save.hasPattern(uia.UIA_TogglePatternId));

    const autosave = try findNamed(&client, window_element, "Autosave");
    defer autosave.release();
    try testing.expectEqual(@as(?uia.ToggleState, .on), try autosave.toggleState());
    try testing.expect(!try autosave.hasPattern(uia.UIA_InvokePatternId));

    const volume = try findNamed(&client, window_element, "Volume");
    defer volume.release();
    const range = (try volume.range()).?;
    try testing.expectApproxEqAbs(@as(f64, 0.5), range.value, 1e-6);
    try testing.expectEqual(@as(f64, 0), range.min);
    try testing.expectEqual(@as(f64, 1), range.max);
    try testing.expect(!range.read_only);

    const name = try findNamed(&client, window_element, "Name");
    defer name.release();
    try testing.expectEqualStrings("Ada", (try name.valueText(&buffer)).?);
    try testing.expectEqual(@as(?bool, false), try name.valueIsReadOnly());
    try testing.expectError(error.AutomationFailed, name.setValueText(std.unicode.utf8ToUtf16LeStringLiteral("Grace")));

    const quality = try findNamed(&client, window_element, "Quality");
    defer quality.release();
    try testing.expectEqual(@as(?uia.ExpandCollapseState, .collapsed), try quality.expandCollapseState());
    try testing.expectEqualStrings("Low", (try quality.valueText(&buffer)).?);
    try testing.expectEqual(@as(?bool, true), try quality.valueIsReadOnly());
    try testing.expect(!try quality.hasPattern(uia.UIA_InvokePatternId));

    const details = try findNamed(&client, window_element, "Details");
    defer details.release();
    try testing.expectEqual(@as(?uia.ExpandCollapseState, .collapsed), try details.expandCollapseState());
    try testing.expect(try details.hasPattern(uia.UIA_InvokePatternId));
}

test "toggling, setting a range, expanding and selecting through UI Automation each arrive as the action that answers them" {
    var controls: ControlsWindow = .{};
    try controls.open();
    defer controls.close();
    var client: uia_client.Client = try .init();
    defer client.deinit();
    const window_element = try client.elementFromHandle(controls.window.window_host.hwnd);
    defer window_element.release();
    var buffer: [64]u8 = undefined;

    const autosave = try findNamed(&client, window_element, "Autosave");
    defer autosave.release();
    try testing.expect(try autosave.toggle());
    try controls.frameUntil(struct {
        fn reached(window: *const ControlsWindow) bool {
            return !window.autosave;
        }
    }.reached);
    try testing.expectEqual(@as(?uia.ToggleState, .off), try autosave.toggleState());

    const volume = try findNamed(&client, window_element, "Volume");
    defer volume.release();
    try testing.expect(try volume.setRangeValue(0.8));
    try controls.frameUntil(struct {
        fn reached(window: *const ControlsWindow) bool {
            return window.volume > 0.75;
        }
    }.reached);
    try testing.expectApproxEqAbs(@as(f32, 0.8), controls.volume, 1e-5);
    try testing.expectError(error.AutomationFailed, volume.setRangeValue(2));

    const quality = try findNamed(&client, window_element, "Quality");
    defer quality.release();
    try testing.expect(try quality.expand());
    try controls.frameUntil(struct {
        fn reached(window: *const ControlsWindow) bool {
            return window.options_shown;
        }
    }.reached);
    try testing.expectEqual(@as(?uia.ExpandCollapseState, .expanded), try quality.expandCollapseState());

    const high = try findNamed(&client, window_element, "High");
    defer high.release();
    try testing.expectEqual(@as(?bool, false), try high.isSelected());
    const list = (try high.selectionContainer()).?;
    defer list.release();
    const selected = (try list.firstSelected()).?;
    try testing.expectEqual(@as(i32, 1), selected.count);
    defer selected.first.?.release();
    try testing.expectEqualStrings("Low", try selected.first.?.name(&buffer));

    try testing.expect(try high.select());
    try controls.frameUntil(struct {
        fn reached(window: *const ControlsWindow) bool {
            return window.quality == 2;
        }
    }.reached);
    try testing.expectEqualStrings("High", (try quality.valueText(&buffer)).?);
    try testing.expectEqual(@as(?uia.ExpandCollapseState, .collapsed), try quality.expandCollapseState());
}

test "a client listening for a property hears it change when a frame changes it" {
    var controls: ControlsWindow = .{};
    try controls.open();
    defer controls.close();
    var client: uia_client.Client = try .init();
    defer client.deinit();
    const window_element = try client.elementFromHandle(controls.window.window_host.hwnd);
    defer window_element.release();
    var changes: uia_client.PropertyChanges = .{};
    try changes.listen(&client, window_element, uia.UIA_ToggleToggleStatePropertyId);
    defer client.stopListening();

    controls.frame();
    const autosave = try findNamed(&client, window_element, "Autosave");
    defer autosave.release();
    try testing.expect(try autosave.toggle());
    for (0..200) |_| {
        controls.frame();
        if (changes.seen.load(.acquire) != 0) break;
        try testing.io.sleep(.fromMilliseconds(10), .awake);
    }
    try testing.expect(changes.seen.load(.acquire) != 0);
    try testing.expectEqual(@as(i32, @intFromEnum(uia.ToggleState.off)), changes.last_integer.load(.acquire));
}

test "a scroll container scrolls through UI Automation by a notch, and to a place in its content" {
    var controls: ControlsWindow = .{};
    try controls.open();
    defer controls.close();
    var client: uia_client.Client = try .init();
    defer client.deinit();
    const window_element = try client.elementFromHandle(controls.window.window_host.hwnd);
    defer window_element.release();

    const log = try findNamed(&client, window_element, "Log");
    defer log.release();
    var scrolled = (try log.scrolled()).?;
    try testing.expectEqual([2]f64{ uia.UIA_ScrollPatternNoScroll, 0 }, scrolled.percent);
    try testing.expectEqual(@as(f64, 40), scrolled.view_size[1]);

    try testing.expect(try log.scrollBy(.no_amount, .small_increment));
    try controls.frameUntil(struct {
        fn reached(window: *const ControlsWindow) bool {
            return window.log_offset == Host.wheel_step;
        }
    }.reached);
    scrolled = (try log.scrolled()).?;
    try testing.expectApproxEqAbs(@as(f64, 100.0 * 40.0 / 60.0), scrolled.percent[1], 1e-4);

    try testing.expect(try log.setScrollPercent(uia.UIA_ScrollPatternNoScroll, 100));
    try controls.frameUntil(struct {
        fn reached(window: *const ControlsWindow) bool {
            return window.log_offset == 60;
        }
    }.reached);
    try testing.expectError(error.AutomationFailed, log.scrollBy(.small_increment, .no_amount));
}

test "through UI Automation a dialog closes, an element shows its menu, and a heading tells its level" {
    var window: HiddenWindow = .{};
    try window.openWithSemantics(1, .{ .nodes = 8, .text_bytes = 64 });
    defer window.close();
    var polled: Polled = .{};
    polled.init();
    _ = polled.poll(&window.window_host);
    const dialog_id = 0x0102_0304_0506_0708;
    const reset_id = 0x1112_1314_1516_1718;
    const nodes = [_]zui.SemanticNode{
        .{ .id = dialog_id, .parent = null, .role = .dialog, .label = "Settings", .value = .none, .bounds = .{ .x = 0, .y = 0, .width = 300, .height = 200 }, .state = .{}, .actions = .initOne(.dismiss) },
        .{ .id = 0x2122_2324_2526_2728, .parent = 0, .role = .heading, .label = "General", .value = .none, .bounds = .{ .x = 10, .y = 10, .width = 100, .height = 20 }, .state = .{}, .actions = .initEmpty(), .level = 2 },
        .{ .id = reset_id, .parent = 0, .role = .button, .label = "Reset", .value = .none, .bounds = .{ .x = 10, .y = 40, .width = 60, .height = 30 }, .state = .{}, .actions = .initMany(&.{ .invoke, .show_menu }) },
    };
    try testing.expectEqual(zui.SemanticsDropped{}, window.window_host.zuiSemantics(.main, &nodes));

    var client: uia_client.Client = try .init();
    defer client.deinit();
    const window_element = try client.elementFromHandle(window.window_host.hwnd);
    defer window_element.release();

    const heading = try findNamed(&client, window_element, "General");
    defer heading.release();
    try testing.expectEqual(@as(?i32, uia.HeadingLevel1 + 1), try heading.integerProperty(uia.UIA_HeadingLevelPropertyId));

    const reset = try findNamed(&client, window_element, "Reset");
    defer reset.release();
    try reset.showContextMenu();
    try expectAction(&window.window_host, &polled, .{ .target = reset_id, .action = .show_menu });

    const dialog = try findNamed(&client, window_element, "Settings");
    defer dialog.release();
    try testing.expect(try dialog.closeWindow());
    try expectAction(&window.window_host, &polled, .{ .target = dialog_id, .action = .dismiss });
    try testing.expect(!try reset.closeWindow());
}
