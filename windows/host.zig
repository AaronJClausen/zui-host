const std = @import("std");
const zui = @import("zui");
pub const win32 = @import("win32.zig");
pub const keys = @import("keys.zig");
pub const file_watch = @import("file_watch.zig");

const W = std.unicode.utf8ToUtf16LeStringLiteral;

/// zui's host contract on a Win32 window, with its message loop on a thread
/// of its own, so the window keeps drawing while the user drags its edges
/// or moves it: Windows runs those drags in a loop of its own.
///
/// It reports per-monitor scale, input, the environment (dark mode, high
/// contrast, animations, power), lifecycle events from console control
/// events, the session ending and the system sleeping, and dropped files;
/// it sets the cursor and places the IME window; it watches directories
/// for changes; and it waits for `nextFrame` on its wake, its input and a
/// high-resolution timer.
///
/// `init` opens the window and `deinit` closes it; the host must not move
/// in between, since its window thread holds a pointer to it.
///
/// ```zig
/// const App = struct {
///     pub const Host = zui_host.Host;
///     pub const Renderer = zui_sokol.Renderer;
///     // ...
/// };
/// ```
pub const Host = struct {
    pub const zui_surfaces: zui.SurfaceKinds = .initOne(.win32);
    pub const zui_capabilities: zui.HostCapabilities = .{ .windows = .one, .system_material = true };
    pub const zuiClipboard = Clipboard;

    /// Watches up to `file_watch.Watches.capacity` directories, each with
    /// its subdirectories, until `deinit`.
    pub const zuiFileWatch = struct {
        pub fn watch(host: *Host, directory: []const u8, sink: zui.FileChangeSink) zui.FileWatchError!void {
            return host.file_watches.start(directory, sink, host.zuiWaker());
        }
    };

    /// Layout units scrolled per notch of the mouse wheel.
    pub const wheel_step = 40;

    io: std.Io,
    /// Physical pixels per layout unit in place of the display's, for tests
    /// and captures that must not depend on the monitor.
    forced_scale: ?f32 = null,
    /// Behaves as on Windows 10, which has no Mica or Acrylic for a window,
    /// so the fallback can be seen on Windows 11.
    system_material_unavailable: bool = false,
    hwnd: win32.HWND,
    window_thread: std.Thread,
    window_created: win32.HANDLE,
    woken: win32.HANDLE,
    input_arrived: win32.HANDLE,
    timer: win32.HANDLE,
    low_memory: ?win32.HANDLE,
    was_low_on_memory: bool,
    /// The poll after the one that delivered a terminate request reports
    /// the window closed.
    terminate_delivered: bool,
    /// What the last poll converted pixels to layout units by.
    pixels_per_unit: f32,

    lock: win32.SRWLOCK,
    /// Shared with the window thread, under `lock`.
    inbox: Inbox,
    requests: zui.HostRequests,

    /// Only the window thread reads and writes these.
    window: WindowThreadState,

    file_watches: file_watch.Watches,

    const event_capacity = 512;
    const text_capacity = 1024;
    const path_capacity = 16 * 1024;
    const longest_path = 32 * 1024;
    const wm_apply_requests = win32.WM_APP + 1;
    const wm_close_window = win32.WM_APP + 2;

    const Inbox = struct {
        /// Positions are in physical pixels until a poll converts them.
        events: [event_capacity]zui.Event = undefined,
        event_count: usize = 0,
        text: [text_capacity]u8 = undefined,
        text_len: usize = 0,
        paths: [path_capacity]u8 = undefined,
        path_len: usize = 0,
        dropped_events: u32 = 0,
        dropped_bytes: u32 = 0,
        closed: bool = false,
        client_size: [2]u32 = .{ 0, 0 },
        dpi: u32 = win32.USER_DEFAULT_SCREEN_DPI,

        fn push(self: *Inbox, event: zui.Event) void {
            if (self.event_count == event_capacity) {
                self.dropped_events +|= 1;
                return;
            }
            self.events[self.event_count] = event;
            self.event_count += 1;
        }

        /// Consecutive characters become one text event.
        fn pushText(self: *Inbox, utf8: []const u8) void {
            if (utf8.len > text_capacity - self.text_len) {
                self.dropped_bytes +|= @intCast(utf8.len);
                return;
            }
            const start = self.text_len;
            @memcpy(self.text[start..][0..utf8.len], utf8);
            self.text_len += utf8.len;
            if (self.event_count > 0) {
                const last = &self.events[self.event_count - 1];
                if (last.* == .text and last.text.ptr + last.text.len == self.text[start..].ptr) {
                    last.text = self.text[start - last.text.len .. self.text_len];
                    return;
                }
            }
            self.push(.{ .text = self.text[start..self.text_len] });
        }

        fn clear(self: *Inbox) void {
            self.event_count = 0;
            self.text_len = 0;
            self.path_len = 0;
            self.dropped_events = 0;
            self.dropped_bytes = 0;
        }
    };

    const WindowThreadState = struct {
        tracking_mouse: bool = false,
        buttons_down: u8 = 0,
        high_surrogate: ?u16 = null,
        environment: zui.Environment = .{},
        cursors: std.EnumArray(zui.Cursor, ?win32.HCURSOR) = .initFill(null),
        applied: zui.HostRequests = .{},
        ime_enabled: bool = true,
        path_utf16: [longest_path]u16 = undefined,
        init_error: ?anyerror = null,
        options: zui.WindowOptions = .{},
        /// Windows took the backdrop the window asked for.
        backdrop_applied: bool = false,
    };

    pub fn init(self: *Host, io: std.Io, options: zui.WindowOptions) !void {
        const forced_scale = self.forced_scale;
        const system_material_unavailable = self.system_material_unavailable;
        self.* = .{
            .io = io,
            .forced_scale = forced_scale,
            .system_material_unavailable = system_material_unavailable,
            .hwnd = undefined,
            .window_thread = undefined,
            .window_created = try manualResetEvent(),
            .woken = try manualResetEvent(),
            .input_arrived = try manualResetEvent(),
            .timer = win32.CreateWaitableTimerExW(null, null, win32.CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, win32.TIMER_ALL_ACCESS) orelse
                win32.CreateWaitableTimerExW(null, null, 0, win32.TIMER_ALL_ACCESS) orelse return error.NoTimer,
            .low_memory = win32.CreateMemoryResourceNotification(0),
            .was_low_on_memory = false,
            .terminate_delivered = false,
            .pixels_per_unit = 1,
            .lock = .{},
            .inbox = .{},
            .requests = .{},
            .window = .{ .options = options },
            .file_watches = .{},
        };
        _ = win32.SetProcessDpiAwarenessContext(win32.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        self.window_thread = try std.Thread.spawn(.{}, runWindowThread, .{self});
        if (win32.WaitForSingleObject(self.window_created, 10 * std.time.ms_per_s) != win32.WAIT_OBJECT_0) return error.WindowThreadDidNotStart;
        if (self.window.init_error) |err| {
            self.window_thread.join();
            return err;
        }
        _ = console_host.cmpxchgStrong(null, self, .acq_rel, .monotonic);
        _ = win32.SetConsoleCtrlHandler(onConsoleControl, 1);
    }

    pub fn deinit(self: *Host) void {
        if (console_host.cmpxchgStrong(self, null, .acq_rel, .monotonic) == null) _ = win32.SetConsoleCtrlHandler(onConsoleControl, 0);
        self.file_watches.stopAll();
        _ = win32.PostMessageW(self.hwnd, wm_close_window, 0, 0);
        self.window_thread.join();
        for ([_]?win32.HANDLE{ self.window_created, self.woken, self.input_arrived, self.timer, self.low_memory }) |handle| {
            if (handle) |open| _ = win32.CloseHandle(open);
        }
    }

    fn manualResetEvent() !win32.HANDLE {
        return win32.CreateEventW(null, 1, 0, null) orelse error.NoEvent;
    }

    pub fn now(self: *const Host) zui.Instant {
        return .fromTimestamp(std.Io.Timestamp.now(self.io, .awake));
    }

    pub fn zuiPoll(self: *Host, window: zui.WindowId, record: *zui.RecordBuilder) bool {
        std.debug.assert(window == .main);
        if (self.terminate_delivered) return false;
        win32.AcquireSRWLockExclusive(&self.lock);
        defer win32.ReleaseSRWLockExclusive(&self.lock);
        _ = win32.ResetEvent(self.input_arrived);
        const inbox = &self.inbox;
        if (inbox.closed) return false;

        const scale = self.forced_scale orelse @as(f32, @floatFromInt(inbox.dpi)) / win32.USER_DEFAULT_SCREEN_DPI;
        const pixels_per_unit = scale * record.params.zoom;
        self.pixels_per_unit = pixels_per_unit;
        record.begin(.{
            .now = self.now(),
            .viewport = .{ @as(f32, @floatFromInt(inbox.client_size[0])) / pixels_per_unit, @as(f32, @floatFromInt(inbox.client_size[1])) / pixels_per_unit },
            .scale = scale,
        });
        for (inbox.events[0..inbox.event_count]) |queued| {
            const converted = inLayoutUnits(queued, pixels_per_unit);
            switch (converted) {
                .text => |text| record.appendText(text),
                .files_dropped => |drop| record.appendFilesDropped(drop),
                .lifecycle => |change| {
                    if (change == .terminate_requested) self.terminate_delivered = true;
                    record.append(converted);
                },
                else => record.append(converted),
            }
        }
        record.dropped_events +|= inbox.dropped_events;
        record.dropped_text_bytes +|= inbox.dropped_bytes;
        inbox.clear();

        if (self.low_memory) |notification| {
            var low: win32.BOOL = 0;
            _ = win32.QueryMemoryResourceNotification(notification, &low);
            if (low != 0 and !self.was_low_on_memory) record.append(.{ .lifecycle = .low_memory });
            self.was_low_on_memory = low != 0;
        }
        return true;
    }

    fn inLayoutUnits(queued: zui.Event, pixels_per_unit: f32) zui.Event {
        var converted = queued;
        switch (converted) {
            .pointer_down, .pointer_up => |*press| scalePosition(&press.pointer.position, pixels_per_unit),
            .pointer_move => |*move| scalePosition(&move.pointer.position, pixels_per_unit),
            .wheel => |*wheel| scalePosition(&wheel.position, pixels_per_unit),
            .files_dropped => |*drop| scalePosition(&drop.position, pixels_per_unit),
            else => {},
        }
        return converted;
    }

    fn scalePosition(position: *[2]f32, pixels_per_unit: f32) void {
        position.* = .{ position[0] / pixels_per_unit, position[1] / pixels_per_unit };
    }

    pub fn zuiWaker(self: *Host) zui.Waker {
        return .{ .context = self, .wakeFn = wake };
    }

    fn wake(context: *anyopaque) void {
        const self: *Host = @ptrCast(@alignCast(context));
        _ = win32.SetEvent(self.woken);
    }

    /// Returns on a wake or input, and for `.at` also at the instant. The
    /// wake is cleared after the wait, so one that came before it ends it.
    pub fn zuiWait(self: *Host, next: zui.NextFrame) void {
        defer _ = win32.ResetEvent(self.woken);
        const handles = [_]win32.HANDLE{ self.woken, self.input_arrived, self.timer };
        switch (next) {
            .immediately => {},
            .on_event => _ = win32.WaitForMultipleObjects(2, &handles, 0, win32.INFINITE),
            .at => |instant| {
                const remaining = instant.nanoseconds -| self.now().nanoseconds;
                if (remaining == 0) return;
                // Negative: relative, in 100 ns units, rounded up so it never fires early.
                const due: i64 = -@as(i64, @intCast((remaining + 99) / 100));
                if (win32.SetWaitableTimer(self.timer, &due, 0, null, null, 0) == 0) return;
                _ = win32.WaitForMultipleObjects(3, &handles, 0, win32.INFINITE);
                _ = win32.CancelWaitableTimer(self.timer);
                // A high-resolution timer can still fire a few microseconds
                // before the awake clock reaches the instant.
                while (self.now().isBefore(instant) and win32.WaitForMultipleObjects(2, &handles, 0, 0) == win32.WAIT_TIMEOUT) {
                    std.atomic.spinLoopHint();
                }
            },
        }
    }

    pub fn zuiSurface(self: *Host, window: zui.WindowId) zui.Surface {
        std.debug.assert(window == .main);
        return .{ .win32 = .{ .hwnd = self.hwnd } };
    }

    pub fn zuiApply(self: *Host, window: zui.WindowId, requests: zui.HostRequests) void {
        std.debug.assert(window == .main);
        win32.AcquireSRWLockExclusive(&self.lock);
        const changed = !std.meta.eql(self.requests, requests);
        self.requests = requests;
        win32.ReleaseSRWLockExclusive(&self.lock);
        if (changed) _ = win32.PostMessageW(self.hwnd, wm_apply_requests, 0, 0);
    }

    /// Closes the window as its close button does: the next poll returns
    /// false.
    pub fn close(self: *Host) void {
        _ = win32.SendMessageW(self.hwnd, win32.WM_CLOSE, 0, 0);
    }

    /// The window's client area, in physical pixels.
    pub fn clientSize(self: *Host) [2]u32 {
        win32.AcquireSRWLockExclusive(&self.lock);
        defer win32.ReleaseSRWLockExclusive(&self.lock);
        return self.inbox.client_size;
    }

    fn deliver(self: *Host, event_to_queue: zui.Event) void {
        win32.AcquireSRWLockExclusive(&self.lock);
        defer win32.ReleaseSRWLockExclusive(&self.lock);
        self.inbox.push(event_to_queue);
        _ = win32.SetEvent(self.input_arrived);
    }

    fn deliverText(self: *Host, utf8: []const u8) void {
        win32.AcquireSRWLockExclusive(&self.lock);
        defer win32.ReleaseSRWLockExclusive(&self.lock);
        self.inbox.pushText(utf8);
        _ = win32.SetEvent(self.input_arrived);
    }

    /// Something changed that needs a frame but carries no event, such as
    /// the window's size.
    fn signalInput(self: *Host) void {
        _ = win32.SetEvent(self.input_arrived);
    }

    // =================================================================
    // The window thread
    // =================================================================

    const class_name = W("zui_host_window");

    fn runWindowThread(self: *Host) void {
        const hwnd = self.createWindow() catch |err| {
            self.window.init_error = err;
            _ = win32.SetEvent(self.window_created);
            return;
        };
        self.hwnd = hwnd;
        _ = win32.SetEvent(self.window_created);

        var message: win32.MSG = undefined;
        while (win32.GetMessageW(&message, null, 0, 0) > 0) {
            _ = win32.TranslateMessage(&message);
            _ = win32.DispatchMessageW(&message);
        }
    }

    fn createWindow(self: *Host) !win32.HWND {
        const instance = win32.GetModuleHandleW(null);
        for (std.enums.values(zui.Cursor)) |cursor| self.window.cursors.set(cursor, win32.LoadCursorW(null, cursorResource(cursor)));
        const class: win32.WNDCLASSEXW = .{
            .style = win32.CS_OWNDC | win32.CS_HREDRAW | win32.CS_VREDRAW,
            .lpfnWndProc = windowProcedure,
            .hInstance = instance,
            .hCursor = self.window.cursors.get(.default),
            .lpszClassName = class_name,
        };
        // Fails harmlessly when an earlier host registered it.
        _ = win32.RegisterClassExW(&class);

        const options = self.window.options;
        var title: [256:0]u16 = undefined;
        const title_len = std.unicode.utf8ToUtf16Le(title[0 .. title.len - 1], options.title[0..@min(options.title.len, 255)]) catch 0;
        title[title_len] = 0;
        const style = windowStyle(options);

        const hwnd = win32.CreateWindowExW(0, class_name, &title, style, win32.CW_USEDEFAULT, win32.CW_USEDEFAULT, win32.CW_USEDEFAULT, win32.CW_USEDEFAULT, null, null, instance, null) orelse return error.WindowNotCreated;
        _ = win32.SetWindowLongPtrW(hwnd, win32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));

        const dpi = win32.GetDpiForWindow(hwnd);
        var frame: win32.RECT = .{
            .right = @intCast(options.size[0] * dpi / win32.USER_DEFAULT_SCREEN_DPI),
            .bottom = @intCast(options.size[1] * dpi / win32.USER_DEFAULT_SCREEN_DPI),
        };
        _ = win32.AdjustWindowRectExForDpi(&frame, style, 0, 0, dpi);
        _ = win32.SetWindowPos(hwnd, null, 0, 0, frame.right - frame.left, frame.bottom - frame.top, win32.SWP_NOMOVE | win32.SWP_NOZORDER | win32.SWP_NOACTIVATE);
        self.recordClientSize(hwnd, dpi);

        win32.DragAcceptFiles(hwnd, 1);
        self.window.backdrop_applied = self.applyMaterial(hwnd, options.material);
        self.setImeEnabled(hwnd, false);
        self.reportEnvironment(hwnd, true);
        if (options.visible) _ = win32.ShowWindow(hwnd, win32.SW_SHOWNORMAL);
        return hwnd;
    }

    fn windowStyle(options: zui.WindowOptions) win32.DWORD {
        return if (options.resizable) win32.WS_OVERLAPPEDWINDOW else win32.WS_OVERLAPPEDWINDOW & ~(win32.WS_THICKFRAME | win32.WS_MAXIMIZEBOX);
    }

    fn recordClientSize(self: *Host, hwnd: win32.HWND, dpi: u32) void {
        var client: win32.RECT = .{};
        _ = win32.GetClientRect(hwnd, &client);
        win32.AcquireSRWLockExclusive(&self.lock);
        defer win32.ReleaseSRWLockExclusive(&self.lock);
        self.inbox.client_size = .{ @intCast(@max(client.right - client.left, 0)), @intCast(@max(client.bottom - client.top, 0)) };
        self.inbox.dpi = dpi;
        _ = win32.SetEvent(self.input_arrived);
    }

    fn windowProcedure(hwnd: win32.HWND, message: win32.UINT, wparam: win32.WPARAM, lparam: win32.LPARAM) callconv(.winapi) win32.LRESULT {
        const address: usize = @bitCast(win32.GetWindowLongPtrW(hwnd, win32.GWLP_USERDATA));
        if (address == 0) return win32.DefWindowProcW(hwnd, message, wparam, lparam);
        const self: *Host = @ptrFromInt(address);
        return self.handleMessage(hwnd, message, wparam, lparam);
    }

    fn handleMessage(self: *Host, hwnd: win32.HWND, message: win32.UINT, wparam: win32.WPARAM, lparam: win32.LPARAM) win32.LRESULT {
        const at = self.now();
        switch (message) {
            win32.WM_CLOSE => {
                win32.AcquireSRWLockExclusive(&self.lock);
                self.inbox.closed = true;
                _ = win32.SetEvent(self.input_arrived);
                win32.ReleaseSRWLockExclusive(&self.lock);
                return 0;
            },
            wm_close_window => {
                _ = win32.DestroyWindow(hwnd);
                return 0;
            },
            win32.WM_DESTROY => {
                win32.PostQuitMessage(0);
                return 0;
            },
            win32.WM_SIZE => self.recordClientSize(hwnd, win32.GetDpiForWindow(hwnd)),
            win32.WM_DPICHANGED => {
                const suggested: *const win32.RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
                _ = win32.SetWindowPos(hwnd, null, suggested.left, suggested.top, suggested.right - suggested.left, suggested.bottom - suggested.top, win32.SWP_NOZORDER | win32.SWP_NOACTIVATE);
                self.recordClientSize(hwnd, win32.hiword(wparam));
                return 0;
            },
            win32.WM_PAINT => {
                var paint: win32.PAINTSTRUCT = undefined;
                const hdc = win32.BeginPaint(hwnd, &paint);
                // Black is fully transparent where the frame is extended, so
                // a renderer's composed swapchain shows over the backdrop
                // rather than over the white of a window never painted.
                if (self.window.backdrop_applied) if (hdc) |painted| if (win32.GetStockObject(win32.BLACK_BRUSH)) |black| {
                    _ = win32.FillRect(painted, &paint.rcPaint, black);
                };
                _ = win32.EndPaint(hwnd, &paint);
                self.signalInput();
                return 0;
            },
            win32.WM_ERASEBKGND => return 1,
            win32.WM_MOUSEMOVE => {
                if (!self.window.tracking_mouse) {
                    var track: win32.TRACKMOUSEEVENT = .{ .dwFlags = win32.TME_LEAVE, .hwndTrack = hwnd };
                    self.window.tracking_mouse = win32.TrackMouseEvent(&track) != 0;
                }
                self.deliver(.{ .pointer_move = .{ .pointer = mouse(lparam, at) } });
                return 0;
            },
            win32.WM_MOUSELEAVE => {
                self.window.tracking_mouse = false;
                self.deliver(.{ .pointer_leave = .mouse });
                return 0;
            },
            win32.WM_LBUTTONDOWN, win32.WM_RBUTTONDOWN, win32.WM_MBUTTONDOWN => {
                if (self.window.buttons_down == 0) _ = win32.SetCapture(hwnd);
                self.window.buttons_down += 1;
                self.deliver(.{ .pointer_down = .{ .pointer = mouse(lparam, at), .button = buttonOf(message) } });
                return 0;
            },
            win32.WM_LBUTTONUP, win32.WM_RBUTTONUP, win32.WM_MBUTTONUP => {
                self.window.buttons_down -|= 1;
                if (self.window.buttons_down == 0) _ = win32.ReleaseCapture();
                self.deliver(.{ .pointer_up = .{ .pointer = mouse(lparam, at), .button = buttonOf(message) } });
                return 0;
            },
            win32.WM_MOUSEWHEEL, win32.WM_MOUSEHWHEEL => {
                const screen = win32.pointFromLparam(lparam);
                var point: win32.POINT = .{ .x = screen[0], .y = screen[1] };
                _ = win32.ScreenToClient(hwnd, &point);
                const notches = @as(f32, @floatFromInt(@as(i16, @bitCast(win32.hiword(wparam))))) / 120;
                // Windows' vertical wheel is positive away from the user,
                // toward the start of the content; its horizontal one is
                // positive to the right, toward the end.
                const delta: [2]f32 = if (message == win32.WM_MOUSEWHEEL) .{ 0, -notches * wheel_step } else .{ notches * wheel_step, 0 };
                self.deliver(.{ .wheel = .{ .position = .{ @floatFromInt(point.x), @floatFromInt(point.y) }, .delta = delta, .at = at } });
                return 0;
            },
            win32.WM_KEYDOWN, win32.WM_SYSKEYDOWN, win32.WM_KEYUP, win32.WM_SYSKEYUP => {
                const key_event: zui.KeyEvent = .{
                    .key = keys.keyFromVirtualKey(wparam),
                    .modifiers = heldModifiers(),
                    .repeat = (message == win32.WM_KEYDOWN or message == win32.WM_SYSKEYDOWN) and lparam & (1 << 30) != 0,
                    .scancode = @intCast((@as(usize, @bitCast(lparam)) >> 16) & 0x1FF),
                    .at = at,
                };
                const down = message == win32.WM_KEYDOWN or message == win32.WM_SYSKEYDOWN;
                self.deliver(if (down) .{ .key_down = key_event } else .{ .key_up = key_event });
                // Alt+F4 and the system menu still work.
                if (message == win32.WM_SYSKEYDOWN or message == win32.WM_SYSKEYUP) return win32.DefWindowProcW(hwnd, message, wparam, lparam);
                return 0;
            },
            win32.WM_CHAR => {
                self.typeCharacter(@truncate(wparam));
                return 0;
            },
            win32.WM_SETFOCUS, win32.WM_KILLFOCUS => {
                self.deliver(.{ .environment = .{ .window_focused = message == win32.WM_SETFOCUS } });
                return 0;
            },
            win32.WM_SETCURSOR => if (win32.loword(lparam) == win32.HTCLIENT) {
                _ = win32.SetCursor(self.window.cursors.get(self.window.applied.cursor));
                return 1;
            },
            wm_apply_requests => {
                self.applyRequests(hwnd);
                return 0;
            },
            win32.WM_DROPFILES => {
                self.receiveDrop(@ptrFromInt(wparam), at);
                return 0;
            },
            win32.WM_QUERYENDSESSION => {
                self.deliver(.{ .lifecycle = .terminate_requested });
                return 1;
            },
            win32.WM_POWERBROADCAST => switch (wparam) {
                win32.PBT_APMSUSPEND => self.deliver(.{ .lifecycle = .@"suspend" }),
                win32.PBT_APMRESUMEAUTOMATIC => self.deliver(.{ .lifecycle = .@"resume" }),
                win32.PBT_APMPOWERSTATUSCHANGE => self.reportEnvironment(hwnd, false),
                else => {},
            },
            win32.WM_SETTINGCHANGE, win32.WM_THEMECHANGED => self.reportEnvironment(hwnd, false),
            else => {},
        }
        return win32.DefWindowProcW(hwnd, message, wparam, lparam);
    }

    fn mouse(lparam: win32.LPARAM, at: zui.Instant) zui.Pointer {
        const point = win32.pointFromLparam(lparam);
        return .{ .id = .mouse, .kind = .mouse, .position = .{ @floatFromInt(point[0]), @floatFromInt(point[1]) }, .at = at };
    }

    fn buttonOf(message: win32.UINT) zui.Button {
        return switch (message) {
            win32.WM_RBUTTONDOWN, win32.WM_RBUTTONUP => .secondary,
            win32.WM_MBUTTONDOWN, win32.WM_MBUTTONUP => .middle,
            else => .primary,
        };
    }

    fn heldModifiers() zui.Modifiers {
        const held = struct {
            fn key(virtual_key: c_int) bool {
                return win32.GetKeyState(virtual_key) < 0;
            }
        }.key;
        return .{ .shift = held(0x10), .control = held(0x11), .alt = held(0x12), .super = held(0x5B) or held(0x5C) };
    }

    /// One UTF-16 unit of typed text; a surrogate pair arrives as two.
    fn typeCharacter(self: *Host, unit: u16) void {
        if (std.unicode.utf16IsHighSurrogate(unit)) {
            self.window.high_surrogate = unit;
            return;
        }
        const high = self.window.high_surrogate;
        self.window.high_surrogate = null;
        // Control characters are keys: Enter, Backspace, Escape, Ctrl+letters.
        if (unit < 0x20 or unit == 0x7F) return;
        const codepoint: u21 = if (std.unicode.utf16IsLowSurrogate(unit))
            std.unicode.utf16DecodeSurrogatePair(&.{ high orelse return, unit }) catch return
        else
            unit;
        var utf8: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(codepoint, &utf8) catch return;
        self.deliverText(utf8[0..len]);
    }

    fn receiveDrop(self: *Host, drop: win32.HDROP, at: zui.Instant) void {
        defer win32.DragFinish(drop);
        var point: win32.POINT = .{};
        _ = win32.DragQueryPoint(drop, &point);
        const count = win32.DragQueryFileW(drop, 0xFFFFFFFF, null, 0);

        win32.AcquireSRWLockExclusive(&self.lock);
        defer win32.ReleaseSRWLockExclusive(&self.lock);
        const inbox = &self.inbox;
        const start = inbox.path_len;
        for (0..count) |index| {
            const path_utf16 = &self.window.path_utf16;
            const len = win32.DragQueryFileW(drop, @intCast(index), path_utf16, path_utf16.len);
            const needed = std.unicode.calcWtf8Len(path_utf16[0..len]) + 1;
            if (len == 0 or needed > path_capacity - inbox.path_len) {
                inbox.dropped_bytes +|= @intCast(needed);
                continue;
            }
            inbox.path_len += std.unicode.wtf16LeToWtf8(inbox.paths[inbox.path_len..], path_utf16[0..len]);
            inbox.paths[inbox.path_len] = 0;
            inbox.path_len += 1;
        }
        if (inbox.path_len == start) return;
        inbox.push(.{ .files_dropped = .{
            .position = .{ @floatFromInt(point.x), @floatFromInt(point.y) },
            .path_list = inbox.paths[start..inbox.path_len],
            .at = at,
        } });
        _ = win32.SetEvent(self.input_arrived);
    }

    fn applyRequests(self: *Host, hwnd: win32.HWND) void {
        win32.AcquireSRWLockExclusive(&self.lock);
        const requests = self.requests;
        const pixels_per_unit = self.pixels_per_unit;
        win32.ReleaseSRWLockExclusive(&self.lock);

        if (requests.cursor != self.window.applied.cursor and self.window.tracking_mouse) {
            _ = win32.SetCursor(self.window.cursors.get(requests.cursor));
        }
        self.window.applied = requests;

        const area = requests.text_input orelse return self.setImeEnabled(hwnd, false);
        self.setImeEnabled(hwnd, true);
        const context = win32.ImmGetContext(hwnd) orelse return;
        defer _ = win32.ImmReleaseContext(hwnd, context);
        const caret: win32.RECT = .{
            .left = @intFromFloat(area.caret.x * pixels_per_unit),
            .top = @intFromFloat(area.caret.y * pixels_per_unit),
            .right = @intFromFloat((area.caret.x + area.caret.width) * pixels_per_unit),
            .bottom = @intFromFloat((area.caret.y + area.caret.height) * pixels_per_unit),
        };
        _ = win32.ImmSetCompositionWindow(context, &.{ .dwStyle = win32.CFS_FORCE_POSITION, .ptCurrentPos = .{ .x = caret.left, .y = caret.top } });
        _ = win32.ImmSetCandidateWindow(context, &.{ .dwStyle = win32.CFS_EXCLUDE, .ptCurrentPos = .{ .x = caret.left, .y = caret.bottom }, .rcArea = caret });
    }

    /// Without an editable focused, keys go to the application rather than
    /// to an IME composing text nobody asked for.
    fn setImeEnabled(self: *Host, hwnd: win32.HWND, enabled: bool) void {
        if (self.window.ime_enabled == enabled) return;
        self.window.ime_enabled = enabled;
        _ = win32.ImmAssociateContextEx(hwnd, null, if (enabled) win32.IACE_DEFAULT else 0);
    }

    /// Asks DWM for the backdrop, which it draws wherever the client area is
    /// transparent. Windows 10 and Windows 11 before 22H2 refuse the
    /// attribute, and the window keeps its own background.
    fn applyMaterial(self: *const Host, hwnd: win32.HWND, material: zui.SystemMaterial) bool {
        if (material == .none or self.system_material_unavailable) return false;
        const backdrop: win32.DWORD = switch (material) {
            .none => unreachable,
            .window => win32.DWMSBT_MAINWINDOW,
            .transient => win32.DWMSBT_TRANSIENTWINDOW,
        };
        if (win32.DwmSetWindowAttribute(hwnd, win32.DWMWA_SYSTEMBACKDROP_TYPE, &backdrop, @sizeOf(win32.DWORD)) != 0) return false;
        const whole_window: win32.MARGINS = .{ .left = -1, .right = -1, .top = -1, .bottom = -1 };
        return win32.DwmExtendFrameIntoClientArea(hwnd, &whole_window) == 0;
    }

    /// Reports each setting that differs from what was last reported, or
    /// every one on the first call.
    fn reportEnvironment(self: *Host, hwnd: win32.HWND, first: bool) void {
        const reported = &self.window.environment;
        const theme = readTheme();
        if (first or theme != reported.theme) {
            reported.theme = theme;
            self.deliver(.{ .environment = .{ .theme = theme } });
            const dark: win32.BOOL = @intFromBool(theme == .dark);
            _ = win32.DwmSetWindowAttribute(hwnd, win32.DWMWA_USE_IMMERSIVE_DARK_MODE, &dark, @sizeOf(win32.BOOL));
        }
        const contrast = readContrast();
        if (first or contrast != reported.contrast) {
            reported.contrast = contrast;
            self.deliver(.{ .environment = .{ .contrast = contrast } });
        }
        const reduced_motion = readReducedMotion();
        if (first or reduced_motion != reported.reduced_motion) {
            reported.reduced_motion = reduced_motion;
            self.deliver(.{ .environment = .{ .reduced_motion = reduced_motion } });
        }
        const power = readPower();
        if (first or power != reported.power) {
            reported.power = power;
            self.deliver(.{ .environment = .{ .power = power } });
        }
        const reduced_transparency = !readTransparencyEnabled();
        if (first or reduced_transparency != reported.reduced_transparency) {
            reported.reduced_transparency = reduced_transparency;
            self.deliver(.{ .environment = .{ .reduced_transparency = reduced_transparency } });
        }
        const system_material = self.window.backdrop_applied and !reduced_transparency;
        if (first or system_material != reported.system_material) {
            reported.system_material = system_material;
            self.deliver(.{ .environment = .{ .system_material = system_material } });
        }
    }

    /// Settings > Personalization > Colors > Transparency effects.
    fn readTransparencyEnabled() bool {
        return readPersonalization(W("EnableTransparency"), 1) != 0;
    }

    fn readTheme() zui.Environment.Theme {
        return if (readPersonalization(W("AppsUseLightTheme"), 1) == 0) .dark else .light;
    }

    fn readPersonalization(value: [*:0]const u16, default: win32.DWORD) win32.DWORD {
        var data: win32.DWORD = default;
        var size: win32.DWORD = @sizeOf(win32.DWORD);
        if (win32.RegGetValueW(win32.HKEY_CURRENT_USER, W("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize"), value, win32.RRF_RT_REG_DWORD, null, &data, &size) != 0) return default;
        return data;
    }

    fn readContrast() zui.Environment.Contrast {
        var high_contrast: win32.HIGHCONTRASTW = .{};
        if (win32.SystemParametersInfoW(win32.SPI_GETHIGHCONTRAST, @sizeOf(win32.HIGHCONTRASTW), &high_contrast, 0) == 0) return .normal;
        return if (high_contrast.dwFlags & win32.HCF_HIGHCONTRASTON != 0) .high else .normal;
    }

    fn readReducedMotion() bool {
        var animates: win32.BOOL = 1;
        if (win32.SystemParametersInfoW(win32.SPI_GETCLIENTAREAANIMATION, 0, &animates, 0) == 0) return false;
        return animates == 0;
    }

    fn readPower() zui.Environment.Power {
        var status: win32.SYSTEM_POWER_STATUS = undefined;
        if (win32.GetSystemPowerStatus(&status) == 0) return .plugged;
        if (status.SystemStatusFlag & 1 != 0) return .saver;
        return if (status.ACLineStatus == 0) .battery else .plugged;
    }

    fn cursorResource(cursor: zui.Cursor) usize {
        return switch (cursor) {
            .default => win32.IDC_ARROW,
            .pointer, .grab => win32.IDC_HAND,
            .text => win32.IDC_IBEAM,
            .crosshair => win32.IDC_CROSS,
            .move, .grabbing => win32.IDC_SIZEALL,
            .not_allowed => win32.IDC_NO,
            .wait => win32.IDC_WAIT,
            .progress => win32.IDC_APPSTARTING,
            .help => win32.IDC_HELP,
            .resize_horizontal => win32.IDC_SIZEWE,
            .resize_vertical => win32.IDC_SIZENS,
            .resize_nwse => win32.IDC_SIZENWSE,
            .resize_nesw => win32.IDC_SIZENESW,
        };
    }
};

/// The console's control handler has no context, so it reaches the host
/// that registered it through here.
var console_host: std.atomic.Value(?*Host) = .init(null);

/// Runs on a thread Windows starts for it. Ctrl+C, Ctrl+Break, closing the
/// console, logging off and shutting down all ask the application to end.
pub fn onConsoleControl(control: win32.DWORD) callconv(.winapi) win32.BOOL {
    const host = console_host.load(.acquire) orelse return 0;
    switch (control) {
        win32.CTRL_C_EVENT, win32.CTRL_BREAK_EVENT, win32.CTRL_CLOSE_EVENT, win32.CTRL_LOGOFF_EVENT, win32.CTRL_SHUTDOWN_EVENT => {
            host.deliver(.{ .lifecycle = .terminate_requested });
            return 1;
        },
        else => return 0,
    }
}

/// The clipboard, as text. Both calls may fail while another application
/// holds the clipboard open.
pub const Clipboard = struct {
    /// The clipboard's text as UTF-8 in `buffer`, or null when it holds no
    /// text or the text does not fit.
    pub fn read(host: *Host, buffer: []u8) ?[]u8 {
        if (win32.OpenClipboard(host.hwnd) == 0) return null;
        defer _ = win32.CloseClipboard();
        const memory = win32.GetClipboardData(win32.CF_UNICODETEXT) orelse return null;
        const locked = win32.GlobalLock(memory) orelse return null;
        defer _ = win32.GlobalUnlock(memory);
        const units: [*]const u16 = @ptrCast(@alignCast(locked));
        const capacity = win32.GlobalSize(memory) / 2;
        const text = units[0 .. std.mem.indexOfScalar(u16, units[0..capacity], 0) orelse capacity];
        if (std.unicode.calcWtf8Len(text) > buffer.len) return null;
        return buffer[0..std.unicode.wtf16LeToWtf8(buffer, text)];
    }

    pub fn write(host: *Host, text: []const u8) error{ InvalidUtf8, ClipboardUnavailable, OutOfMemory }!void {
        const units = std.unicode.calcUtf16LeLen(text) catch return error.InvalidUtf8;
        const memory = win32.GlobalAlloc(win32.GMEM_MOVEABLE, (units + 1) * 2) orelse return error.OutOfMemory;
        {
            const locked = win32.GlobalLock(memory) orelse {
                _ = win32.GlobalFree(memory);
                return error.OutOfMemory;
            };
            defer _ = win32.GlobalUnlock(memory);
            const destination: [*]u16 = @ptrCast(@alignCast(locked));
            _ = std.unicode.utf8ToUtf16Le(destination[0..units], text) catch unreachable;
            destination[units] = 0;
        }
        if (win32.OpenClipboard(host.hwnd) == 0) {
            _ = win32.GlobalFree(memory);
            return error.ClipboardUnavailable;
        }
        defer _ = win32.CloseClipboard();
        _ = win32.EmptyClipboard();
        if (win32.SetClipboardData(win32.CF_UNICODETEXT, memory) == null) {
            _ = win32.GlobalFree(memory);
            return error.ClipboardUnavailable;
        }
    }
};

test {
    _ = keys;
    _ = file_watch;
}
