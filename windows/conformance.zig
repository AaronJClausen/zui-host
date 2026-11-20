//! zui's host suite and the Windows host's own tests, each against a
//! hidden window. Messages are sent, not posted, so each one has reached
//! the window before the test polls.

const std = @import("std");
const zui_host = @import("zui_host");
const zui = zui_host.zui;
const zui_testing = @import("zui_testing");
const zui_async = @import("zui_async");
const Host = zui_host.Host;
const win32 = zui_host.windows.win32;
const keys = zui_host.windows.keys;
const uia = zui_host.windows.uia;
const uia_client = @import("uia_client.zig");

const testing = std.testing;

const HiddenWindow = struct {
    window_host: Host = undefined,

    /// With `forced_scale` set, a pixel is that many layout units at a zoom of 1.
    fn open(self: *HiddenWindow, forced_scale: ?f32) !void {
        try self.openWithSemantics(forced_scale, .{});
    }

    fn openWithSemantics(self: *HiddenWindow, forced_scale: ?f32, semantics: zui.SemanticsCapacity) !void {
        self.window_host.forced_scale = forced_scale;
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
