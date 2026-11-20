const std = @import("std");
const zui = @import("zui");
pub const win32 = @import("win32.zig");
pub const keys = @import("keys.zig");
pub const file_watch = @import("file_watch.zig");
pub const display = @import("display.zig");
pub const uia = @import("uia.zig");
pub const accessibility = @import("accessibility.zig");
pub const services = @import("services.zig");
pub const file_dialog = @import("file_dialog.zig");
pub const menu = @import("menu.zig");
pub const chrome = @import("chrome.zig");

const W = std.unicode.utf8ToUtf16LeStringLiteral;

/// zui's host contract on Win32 windows, with their message loop on a
/// thread of its own, so a window keeps drawing while the user drags its
/// edges or moves it: Windows runs those drags in a loop of its own.
///
/// It reports per-monitor scale, input, the environment (dark mode, high
/// contrast, animations, power, HDR headroom), lifecycle events from console control
/// events, the session ending and the system sleeping, and dropped files;
/// it sets the cursor and places the IME window; it reads and writes the
/// clipboard, opens URLs, shows notifications, file dialogs and menus; it
/// leaves the title bar to the application when asked, answering the
/// window manager from the frame's chrome regions; it watches directories
/// for changes; it bridges `Frame.semantics()` to UI Automation, reporting
/// what an assistive technology asks for as `action` events; and it waits
/// for `nextFrame` on its wake, its input and a high-resolution timer.
///
/// `init` opens `.main`, and `zuiOpenWindow` up to `max_windows - 1` more,
/// each with its own events, scale, requests, chrome, accessibility and
/// menu bar. A message-only window anchors the window thread and owns the
/// clipboard and the notification icon, so every service works whichever
/// windows are open. `deinit` closes them all; the host must not move in
/// between, since its window thread holds pointers into it.
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
    pub const zui_capabilities: zui.HostCapabilities = .{ .windows = .many, .system_material = true, .custom_title_bar = true };
    /// `.scrgb_fp16` while the window's monitor runs in HDR, when the
    /// window was opened with it.
    pub const zui_output_formats: zui.OutputFormats = .initMany(&.{ .sdr, .scrgb_fp16 });

    /// The windows open at once, `.main` among them.
    pub const max_windows = 4;

    /// The clipboard, as text. `read` answers from the window thread with
    /// up to `services.Services.clipboard_text_capacity` bytes, or
    /// `.failed` while another application holds the clipboard open.
    pub const zuiClipboard = struct {
        pub fn write(host: *Host, text: []const u8) zui.ServiceError!void {
            const units = std.unicode.calcUtf16LeLen(text) catch return error.InvalidUtf8;
            const memory = win32.GlobalAlloc(win32.GMEM_MOVEABLE, (units + 1) * 2) orelse return error.Unavailable;
            {
                const locked = win32.GlobalLock(memory) orelse {
                    _ = win32.GlobalFree(memory);
                    return error.Unavailable;
                };
                defer _ = win32.GlobalUnlock(memory);
                const destination: [*]u16 = @ptrCast(@alignCast(locked));
                _ = std.unicode.utf8ToUtf16Le(destination[0..units], text) catch unreachable;
                destination[units] = 0;
            }
            if (win32.OpenClipboard(host.anchor) == 0) {
                _ = win32.GlobalFree(memory);
                return error.Unavailable;
            }
            defer _ = win32.CloseClipboard();
            _ = win32.EmptyClipboard();
            // On success the memory is the clipboard's, not ours to free.
            if (win32.SetClipboardData(win32.CF_UNICODETEXT, memory) == null) {
                _ = win32.GlobalFree(memory);
                return error.Unavailable;
            }
        }

        pub fn read(host: *Host, request: zui.ServiceRequest, sink: zui.ServiceSink) zui.ServiceError!void {
            try host.services.claimClipboardRead(request, sink);
            if (win32.PostMessageW(host.anchor, wm_read_clipboard, 0, 0) == 0) {
                host.services.releaseClipboardRead();
                return error.Unavailable;
            }
        }
    };

    /// Hands a URL to the system's handler for its scheme, from the window
    /// thread, refusing paths and `file:` URLs.
    pub const zuiOpenUrl = struct {
        pub fn open(host: *Host, url: []const u8) zui.ServiceError!void {
            try host.services.claimUrl(url);
            if (win32.PostMessageW(host.anchor, wm_open_url, 0, 0) == 0) {
                host.services.releaseUrl();
                return error.Unavailable;
            }
        }
    };

    /// A balloon of the application's notification-area icon, which
    /// Windows 10 and 11 show as a toast: its title cut at a character to
    /// 63 UTF-16 units and its body to 255. It answers
    /// `.notification_activated` when clicked and `.notification_dismissed`
    /// when it times out, is closed, or the next one replaces it; one still
    /// showing at `deinit` is not answered.
    pub const zuiNotifications = struct {
        pub fn show(host: *Host, request: zui.ServiceRequest, notification: zui.Notification, sink: zui.ServiceSink) zui.ServiceError!void {
            try host.services.claimNotification(request, notification, sink);
            if (win32.PostMessageW(host.anchor, wm_show_notification, 0, 0) == 0) {
                host.services.releaseNotification();
                return error.Unavailable;
            }
        }
    };

    /// The shell's dialogs, `IFileOpenDialog` and `IFileSaveDialog`, shown
    /// on the window thread and owned by the window named, one at a time
    /// over all windows. They answer `.files_chosen` with file-system
    /// paths, up to `services.Services.chosen_paths_capacity` bytes of
    /// them, or `.canceled`, naming the window. One still open when its
    /// window closes is closed and not answered; a window that is not open
    /// is `error.Unavailable`.
    pub const zuiFileDialogs = struct {
        pub fn show(host: *Host, window: zui.WindowId, request: zui.ServiceRequest, dialog: zui.FileDialog, sink: zui.ServiceSink) zui.ServiceError!void {
            const target = host.windowById(window) orelse return error.Unavailable;
            try host.services.claimFileDialog(request, window, dialog, sink);
            if (win32.PostMessageW(target.hwnd, wm_show_file_dialog, 0, 0) == 0) {
                host.services.releaseFileDialog();
                return error.Unavailable;
            }
        }
    };

    /// Windows' own menus, built on the window thread from up to
    /// `menu.CopiedMenu.entry_capacity` items with labels shown as written
    /// and shortcuts after them. `popup` shows a context menu over the
    /// window named at a position in its layout units with
    /// `TrackPopupMenuEx`, one at a time with a file dialog over all
    /// windows, and answers the item chosen or `.canceled`; one still open
    /// when its window closes is closed and not answered. `setBar` replaces
    /// the window's menu bar, or removes it given no items, and answers
    /// each item chosen from it; the client area shrinks by the bar's
    /// height. A window with a custom title bar has no room for a native
    /// bar, which would sit hidden under the drawn one, so there `setBar`
    /// is `error.Unavailable` and the application draws its menus in its
    /// title bar. A window that is not open is `error.Unavailable`.
    pub const zuiMenus = struct {
        pub fn popup(host: *Host, window: zui.WindowId, request: zui.ServiceRequest, items: []const zui.MenuItem, position: [2]f32, sink: zui.ServiceSink) zui.ServiceError!void {
            const target = host.windowById(window) orelse return error.Unavailable;
            const in_client_pixels: win32.POINT = .{
                .x = std.math.lossyCast(i32, @round(position[0] * target.pixels_per_unit)),
                .y = std.math.lossyCast(i32, @round(position[1] * target.pixels_per_unit)),
            };
            try host.services.claimPopupMenu(request, window, items, in_client_pixels, sink);
            if (win32.PostMessageW(target.hwnd, wm_show_popup_menu, 0, 0) == 0) {
                host.services.releasePopupMenu();
                return error.Unavailable;
            }
        }

        pub fn setBar(host: *Host, window: zui.WindowId, request: zui.ServiceRequest, items: []const zui.MenuItem, sink: zui.ServiceSink) zui.ServiceError!void {
            const target = host.windowById(window) orelse return error.Unavailable;
            if (target.custom_title_bar) return error.Unavailable;
            try target.menu_bar.claim(request, window, items, sink);
            if (win32.PostMessageW(target.hwnd, wm_set_menu_bar, 0, 0) == 0) {
                target.menu_bar.release();
                return error.Unavailable;
            }
        }
    };

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
    /// Every monitor shows color this way, for tests that must not depend
    /// on the display.
    forced_display_color: ?display.DisplayColor = null,
    /// Answers services as a test says instead of handing them to the
    /// system, so nothing opens or shows.
    service_fake: ?*services.ServiceFake = null,
    /// The main window's handle, while it is open.
    hwnd: win32.HWND,
    /// The message-only window that anchors the window thread: it opens and
    /// closes the others, and owns the clipboard and the notification icon.
    anchor: win32.HWND,
    window_thread: std.Thread,
    window_created: win32.HANDLE,
    woken: win32.HANDLE,
    input_arrived: win32.HANDLE,
    timer: win32.HANDLE,
    low_memory: ?win32.HANDLE,
    /// The id the next window opened takes; ids are never given twice.
    next_window_id: u32,
    /// The main window's title, which the notification icon shows.
    notification_tip: [128]u16,
    notification_tip_len: usize,

    /// Guards each window's inbox, requests and `in_use`.
    lock: win32.SRWLOCK,
    windows: [max_windows]Window,

    /// Only the window thread reads and writes these.
    dropped_path_utf16: [longest_path]u16,
    anchor_init_error: ?anyerror,
    closing: bool,
    anchor_destroyed: bool,

    file_watches: file_watch.Watches,

    services: services.Services,

    const event_capacity = 512;
    const text_capacity = 1024;
    const path_capacity = 16 * 1024;
    const longest_path = 32 * 1024;
    const wm_apply_requests = win32.WM_APP + 1;
    const wm_close_window = win32.WM_APP + 2;
    const wm_semantics_changed = win32.WM_APP + 3;
    const wm_read_clipboard = win32.WM_APP + 4;
    const wm_open_url = win32.WM_APP + 5;
    const wm_show_notification = win32.WM_APP + 6;
    /// What the notification-area icon sends the anchor when its balloon is
    /// shown, clicked, timed out or closed.
    pub const wm_notify_icon = win32.WM_APP + 7;
    const wm_show_file_dialog = win32.WM_APP + 8;
    const wm_show_popup_menu = win32.WM_APP + 9;
    const wm_set_menu_bar = win32.WM_APP + 10;
    /// To the anchor, sent: `wparam` is the slot to create a window in.
    const wm_open_window = win32.WM_APP + 11;
    /// To the anchor: close every window, then the anchor.
    const wm_close_host = win32.WM_APP + 12;

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
        output_format: zui.OutputFormat = .sdr,

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
        init_error: ?anyerror = null,
        options: zui.WindowOptions = .{},
        /// Windows took the backdrop the window asked for.
        backdrop_applied: bool = false,
        monitor: ?win32.HMONITOR = null,
        title: [256:0]u16 = @splat(0),
        title_len: usize = 0,
        tracking_non_client: bool = false,
        /// The caption button a press began on, as its hit-test code; its
        /// release on the same button works it.
        pressed_caption_button: ?usize = null,
    };

    /// One of the host's windows: what it shares with the UI thread under
    /// the host's `lock`, what only the window thread touches, and its
    /// chrome, accessibility bridge and menu bar, each with a lock of its
    /// own.
    pub const Window = struct {
        host: *Host,
        id: zui.WindowId = .main,
        /// Holds an open window. Set under the host's `lock`; the window
        /// thread clears it once the window is destroyed.
        in_use: bool = false,
        hwnd: win32.HWND = undefined,
        /// What the last poll converted pixels to layout units by.
        pixels_per_unit: f32 = 1,
        was_low_on_memory: bool = false,
        /// The poll after the one that delivered a terminate request reports
        /// the window closed.
        terminate_delivered: bool = false,
        /// The window was opened with `title_bar = .custom`.
        custom_title_bar: bool = false,
        chrome_snapshot: chrome.ChromeSnapshot = .{},
        inbox: Inbox = .{},
        requests: zui.HostRequests = .{},
        thread_state: WindowThreadState = .{},
        accessibility: accessibility.Bridge = undefined,
        menu_bar: services.MenuBar = .{},

        fn deliver(self: *Window, event_to_queue: zui.Event) void {
            win32.AcquireSRWLockExclusive(&self.host.lock);
            defer win32.ReleaseSRWLockExclusive(&self.host.lock);
            self.inbox.push(event_to_queue);
            _ = win32.SetEvent(self.host.input_arrived);
        }

        fn deliverText(self: *Window, utf8: []const u8) void {
            win32.AcquireSRWLockExclusive(&self.host.lock);
            defer win32.ReleaseSRWLockExclusive(&self.host.lock);
            self.inbox.pushText(utf8);
            _ = win32.SetEvent(self.host.input_arrived);
        }

        fn deliverAction(context: *anyopaque, action: zui.ActionEvent) void {
            const self: *Window = @ptrCast(@alignCast(context));
            self.deliver(.{ .action = action });
        }

        /// Something changed that needs a frame but carries no event, such as
        /// the window's size.
        fn signalInput(self: *Window) void {
            _ = win32.SetEvent(self.host.input_arrived);
        }

        fn recordClientSize(self: *Window, hwnd: win32.HWND, dpi: u32) void {
            var client: win32.RECT = .{};
            _ = win32.GetClientRect(hwnd, &client);
            win32.AcquireSRWLockExclusive(&self.host.lock);
            defer win32.ReleaseSRWLockExclusive(&self.host.lock);
            self.inbox.client_size = .{ @intCast(@max(client.right - client.left, 0)), @intCast(@max(client.bottom - client.top, 0)) };
            self.inbox.dpi = dpi;
            _ = win32.SetEvent(self.host.input_arrived);
        }

        fn handleMessage(self: *Window, hwnd: win32.HWND, message: win32.UINT, wparam: win32.WPARAM, lparam: win32.LPARAM) win32.LRESULT {
            const host = self.host;
            const at = host.now();
            const state = &self.thread_state;
            switch (message) {
                win32.WM_CLOSE => {
                    win32.AcquireSRWLockExclusive(&host.lock);
                    self.inbox.closed = true;
                    _ = win32.SetEvent(host.input_arrived);
                    win32.ReleaseSRWLockExclusive(&host.lock);
                    return 0;
                },
                wm_close_window => {
                    if (host.services.closeDialogOrMenuFirst(hwnd)) return 0;
                    _ = win32.DestroyWindow(hwnd);
                    return 0;
                },
                win32.WM_DESTROY => {
                    self.accessibility.disconnect(hwnd);
                    return 0;
                },
                win32.WM_NCDESTROY => {
                    host.freeWindow(self);
                    return 0;
                },
                win32.WM_SIZE => {
                    self.recordClientSize(hwnd, win32.GetDpiForWindow(hwnd));
                    if (wparam == win32.SIZE_MAXIMIZED or wparam == win32.SIZE_RESTORED) self.reportMaximized(wparam == win32.SIZE_MAXIMIZED);
                },
                win32.WM_NCCALCSIZE => if (self.custom_title_bar and wparam != 0) return calculateClientWithoutCaption(hwnd, lparam),
                win32.WM_NCHITTEST => if (self.custom_title_bar) return self.hitTestNonClient(hwnd, lparam),
                win32.WM_NCMOUSEMOVE => if (self.custom_title_bar and !chrome.isResizeCode(@bitCast(wparam))) {
                    if (!state.tracking_non_client) {
                        var track: win32.TRACKMOUSEEVENT = .{ .dwFlags = win32.TME_LEAVE | win32.TME_NONCLIENT, .hwndTrack = hwnd };
                        state.tracking_non_client = win32.TrackMouseEvent(&track) != 0;
                    }
                    self.deliver(.{ .pointer_move = .{ .pointer = nonClientMouse(hwnd, lparam, at) } });
                },
                win32.WM_NCMOUSELEAVE => if (self.custom_title_bar) {
                    state.tracking_non_client = false;
                    if (state.pressed_caption_button != null) {
                        state.pressed_caption_button = null;
                        self.deliver(.{ .pointer_cancel = .mouse });
                    }
                    if (!state.tracking_mouse) self.deliver(.{ .pointer_leave = .mouse });
                },
                win32.WM_NCLBUTTONDOWN, win32.WM_NCLBUTTONDBLCLK => if (self.custom_title_bar and chrome.isCaptionButtonCode(wparam)) {
                    state.pressed_caption_button = wparam;
                    self.deliver(.{ .pointer_down = .{ .pointer = nonClientMouse(hwnd, lparam, at), .button = .primary } });
                    return 0;
                },
                // The press ends as a cancel, not a release: the host works the
                // button, so zui shows the press but reports no click, and an
                // application acting on `clicked` for the keyboard and assistive
                // technologies never works it twice.
                win32.WM_NCLBUTTONUP => if (self.custom_title_bar and chrome.isCaptionButtonCode(wparam)) {
                    self.deliver(.{ .pointer_cancel = .mouse });
                    const pressed = state.pressed_caption_button;
                    state.pressed_caption_button = null;
                    if (pressed == wparam) workCaptionButton(hwnd, wparam);
                    return 0;
                },
                win32.WM_MOVE => if (win32.MonitorFromWindow(hwnd, win32.MONITOR_DEFAULTTONEAREST) != state.monitor) self.reportDisplayColor(hwnd, false),
                win32.WM_DISPLAYCHANGE => self.reportDisplayColor(hwnd, false),
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
                    if (state.backdrop_applied) if (hdc) |painted| if (win32.GetStockObject(win32.BLACK_BRUSH)) |black| {
                        _ = win32.FillRect(painted, &paint.rcPaint, black);
                    };
                    _ = win32.EndPaint(hwnd, &paint);
                    self.signalInput();
                    return 0;
                },
                win32.WM_ERASEBKGND => return 1,
                win32.WM_MOUSEMOVE => {
                    if (!state.tracking_mouse) {
                        var track: win32.TRACKMOUSEEVENT = .{ .dwFlags = win32.TME_LEAVE, .hwndTrack = hwnd };
                        state.tracking_mouse = win32.TrackMouseEvent(&track) != 0;
                    }
                    self.deliver(.{ .pointer_move = .{ .pointer = mouse(lparam, at) } });
                    return 0;
                },
                win32.WM_MOUSELEAVE => {
                    state.tracking_mouse = false;
                    self.deliver(.{ .pointer_leave = .mouse });
                    return 0;
                },
                win32.WM_LBUTTONDOWN, win32.WM_RBUTTONDOWN, win32.WM_MBUTTONDOWN => {
                    if (state.buttons_down == 0) _ = win32.SetCapture(hwnd);
                    state.buttons_down += 1;
                    self.deliver(.{ .pointer_down = .{ .pointer = mouse(lparam, at), .button = buttonOf(message) } });
                    return 0;
                },
                win32.WM_LBUTTONUP, win32.WM_RBUTTONUP, win32.WM_MBUTTONUP => {
                    state.buttons_down -|= 1;
                    if (state.buttons_down == 0) _ = win32.ReleaseCapture();
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
                    _ = win32.SetCursor(state.cursors.get(state.applied.cursor));
                    return 1;
                },
                wm_apply_requests => {
                    self.applyRequests(hwnd);
                    return 0;
                },
                wm_semantics_changed => {
                    self.accessibility.announceChanges();
                    return 0;
                },
                wm_show_file_dialog => {
                    host.services.showFileDialog(hwnd, wm_close_window, host.zuiWaker());
                    return 0;
                },
                wm_show_popup_menu => {
                    host.services.showPopupMenu(hwnd, wm_close_window, host.anyMenuBarOpen(), host.zuiWaker());
                    return 0;
                },
                wm_set_menu_bar => {
                    self.menu_bar.set(hwnd, host.zuiWaker());
                    return 0;
                },
                win32.WM_COMMAND => {
                    const from_a_menu = win32.hiword(wparam) == 0 and lparam == 0;
                    if (from_a_menu) self.menu_bar.answerCommand(win32.loword(wparam), host.zuiWaker());
                    return 0;
                },
                win32.WM_ENTERMENULOOP => self.menu_bar.beginMenuLoop(wparam != 0),
                win32.WM_EXITMENULOOP => self.menu_bar.endMenuLoop(hwnd, wm_set_menu_bar),
                win32.WM_GETOBJECT => if (self.accessibility.answerGetObject(hwnd, wparam, lparam)) |answered| return answered,
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

        /// The system's own borders first, then the top resize band the caption
        /// left behind, then the frame's chrome regions, the last on top.
        fn hitTestNonClient(self: *Window, hwnd: win32.HWND, lparam: win32.LPARAM) win32.LRESULT {
            const system_answer = win32.DefWindowProcW(hwnd, win32.WM_NCHITTEST, 0, lparam);
            if (chrome.isResizeCode(system_answer)) return system_answer;
            const screen = win32.pointFromLparam(lparam);
            var point: win32.POINT = .{ .x = screen[0], .y = screen[1] };
            _ = win32.ScreenToClient(hwnd, &point);
            const resizable = self.thread_state.options.resizable;
            if (resizable and win32.IsZoomed(hwnd) == 0) {
                const band = resizeBandThickness(win32.GetDpiForWindow(hwnd));
                if (point.y >= 0 and point.y < band) {
                    var client: win32.RECT = .{};
                    _ = win32.GetClientRect(hwnd, &client);
                    if (point.x < band) return win32.HTTOPLEFT;
                    if (point.x >= client.right - band) return win32.HTTOPRIGHT;
                    return win32.HTTOP;
                }
            }
            const kind = self.chrome_snapshot.kindAt(point) orelse return win32.HTCLIENT;
            const code = chrome.hitTestCode(kind);
            if (!resizable and chrome.isResizeCode(code)) return win32.HTCLIENT;
            return code;
        }

        fn reportMaximized(self: *Window, maximized: bool) void {
            const environment = &self.thread_state.environment;
            if (maximized == environment.window_maximized) return;
            environment.window_maximized = maximized;
            self.deliver(.{ .environment = .{ .window_maximized = maximized } });
        }

        /// One UTF-16 unit of typed text; a surrogate pair arrives as two.
        fn typeCharacter(self: *Window, unit: u16) void {
            const state = &self.thread_state;
            if (std.unicode.utf16IsHighSurrogate(unit)) {
                state.high_surrogate = unit;
                return;
            }
            const high = state.high_surrogate;
            state.high_surrogate = null;
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

        fn receiveDrop(self: *Window, drop: win32.HDROP, at: zui.Instant) void {
            defer win32.DragFinish(drop);
            var point: win32.POINT = .{};
            _ = win32.DragQueryPoint(drop, &point);
            const count = win32.DragQueryFileW(drop, 0xFFFFFFFF, null, 0);

            const host = self.host;
            win32.AcquireSRWLockExclusive(&host.lock);
            defer win32.ReleaseSRWLockExclusive(&host.lock);
            const inbox = &self.inbox;
            const start = inbox.path_len;
            for (0..count) |index| {
                const path_utf16 = &host.dropped_path_utf16;
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
            _ = win32.SetEvent(host.input_arrived);
        }

        fn applyRequests(self: *Window, hwnd: win32.HWND) void {
            const state = &self.thread_state;
            win32.AcquireSRWLockExclusive(&self.host.lock);
            const requests = self.requests;
            const pixels_per_unit = self.pixels_per_unit;
            win32.ReleaseSRWLockExclusive(&self.host.lock);

            if (requests.cursor != state.applied.cursor and state.tracking_mouse) {
                _ = win32.SetCursor(state.cursors.get(requests.cursor));
            }
            state.applied = requests;

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
        fn setImeEnabled(self: *Window, hwnd: win32.HWND, enabled: bool) void {
            if (self.thread_state.ime_enabled == enabled) return;
            self.thread_state.ime_enabled = enabled;
            _ = win32.ImmAssociateContextEx(hwnd, null, if (enabled) win32.IACE_DEFAULT else 0);
        }

        /// Asks DWM for the backdrop, which it draws wherever the client area is
        /// transparent. Windows 10 and Windows 11 before 22H2 refuse the
        /// attribute, and the window keeps its own background.
        fn applyMaterial(self: *const Window, hwnd: win32.HWND, material: zui.SystemMaterial) bool {
            if (material == .none or self.host.system_material_unavailable) return false;
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
        fn reportEnvironment(self: *Window, hwnd: win32.HWND, first: bool) void {
            const reported = &self.thread_state.environment;
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
            const system_material = self.thread_state.backdrop_applied and !reduced_transparency;
            if (first or system_material != reported.system_material) {
                reported.system_material = system_material;
                self.deliver(.{ .environment = .{ .system_material = system_material } });
            }
            if (first) {
                reported.custom_title_bar = self.custom_title_bar;
                self.deliver(.{ .environment = .{ .custom_title_bar = self.custom_title_bar } });
                reported.window_maximized = win32.IsZoomed(hwnd) != 0;
                self.deliver(.{ .environment = .{ .window_maximized = reported.window_maximized } });
            }
            self.reportDisplayColor(hwnd, first);
        }

        /// Picks the surface's format for the monitor the window is on, and
        /// reports the headroom the window can show: 1 in `.sdr`. Read again
        /// when the window moves to another monitor, the displays change, or a
        /// setting does.
        fn reportDisplayColor(self: *Window, hwnd: win32.HWND, first: bool) void {
            const state = &self.thread_state;
            const monitor = win32.MonitorFromWindow(hwnd, win32.MONITOR_DEFAULTTONEAREST);
            state.monitor = monitor;
            const color: display.DisplayColor = self.host.forced_display_color orelse if (monitor) |shown_on| .read(shown_on) else .sdr;
            const format: zui.OutputFormat = if (color.hdr and state.options.output_formats.contains(.scrgb_fp16)) .scrgb_fp16 else .sdr;
            win32.AcquireSRWLockExclusive(&self.host.lock);
            const format_changed = format != self.inbox.output_format;
            self.inbox.output_format = format;
            win32.ReleaseSRWLockExclusive(&self.host.lock);

            const reported = &state.environment;
            const headroom = if (format == .scrgb_fp16) color.headroom() else 1;
            if (first or headroom != reported.hdr_headroom) {
                reported.hdr_headroom = headroom;
                self.deliver(.{ .environment = .{ .hdr_headroom = headroom } });
            } else if (format_changed) {
                self.signalInput();
            }
        }
    };

    pub fn init(self: *Host, io: std.Io, options: zui.WindowOptions) !void {
        const forced_scale = self.forced_scale;
        const system_material_unavailable = self.system_material_unavailable;
        const forced_display_color = self.forced_display_color;
        const service_fake = self.service_fake;
        self.* = .{
            .io = io,
            .forced_scale = forced_scale,
            .system_material_unavailable = system_material_unavailable,
            .forced_display_color = forced_display_color,
            .service_fake = service_fake,
            .hwnd = undefined,
            .anchor = undefined,
            .window_thread = undefined,
            .window_created = try manualResetEvent(),
            .woken = try manualResetEvent(),
            .input_arrived = try manualResetEvent(),
            .timer = win32.CreateWaitableTimerExW(null, null, win32.CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, win32.TIMER_ALL_ACCESS) orelse
                win32.CreateWaitableTimerExW(null, null, 0, win32.TIMER_ALL_ACCESS) orelse return error.NoTimer,
            .low_memory = win32.CreateMemoryResourceNotification(0),
            .next_window_id = 1,
            .notification_tip = @splat(0),
            .notification_tip_len = 0,
            .lock = .{},
            .windows = undefined,
            .dropped_path_utf16 = undefined,
            .anchor_init_error = null,
            .closing = false,
            .anchor_destroyed = false,
            .file_watches = .{},
            .services = .{ .fake = service_fake },
        };
        for (&self.windows) |*window| window.* = .{ .host = self };
        self.notification_tip_len = std.unicode.utf8ToUtf16Le(self.notification_tip[0 .. self.notification_tip.len - 1], options.title[0..@min(options.title.len, self.notification_tip.len - 1)]) catch 0;
        try self.prepareWindow(&self.windows[0], .main, options);
        errdefer self.windows[0].accessibility.deinit();
        _ = win32.SetProcessDpiAwarenessContext(win32.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        self.window_thread = try std.Thread.spawn(.{}, runWindowThread, .{self});
        if (win32.WaitForSingleObject(self.window_created, 10 * std.time.ms_per_s) != win32.WAIT_OBJECT_0) return error.WindowThreadDidNotStart;
        const init_error: ?anyerror = if (self.anchor_init_error != null) self.anchor_init_error else self.windows[0].thread_state.init_error;
        if (init_error) |err| {
            self.window_thread.join();
            return err;
        }
        self.hwnd = self.windows[0].hwnd;
        _ = console_host.cmpxchgStrong(null, self, .acq_rel, .monotonic);
        _ = win32.SetConsoleCtrlHandler(onConsoleControl, 1);
    }

    pub fn deinit(self: *Host) void {
        if (console_host.cmpxchgStrong(self, null, .acq_rel, .monotonic) == null) _ = win32.SetConsoleCtrlHandler(onConsoleControl, 0);
        self.file_watches.stopAll();
        _ = win32.PostMessageW(self.anchor, wm_close_host, 0, 0);
        self.window_thread.join();
        for ([_]?win32.HANDLE{ self.window_created, self.woken, self.input_arrived, self.timer, self.low_memory }) |handle| {
            if (handle) |open| _ = win32.CloseHandle(open);
        }
    }

    /// Opens a window as `init` opens `.main`, hidden or shown as `options`
    /// say, and returns once it exists.
    pub fn zuiOpenWindow(self: *Host, options: zui.WindowOptions) zui.OpenWindowError!zui.WindowId {
        const slot = self.freeSlot() orelse return error.TooManyWindows;
        const window = &self.windows[slot];
        const id: zui.WindowId = @enumFromInt(self.next_window_id);
        self.prepareWindow(window, id, options) catch return error.WindowNotCreated;
        _ = win32.SendMessageW(self.anchor, wm_open_window, slot, 0);
        if (window.thread_state.init_error != null) {
            window.accessibility.deinit();
            return error.WindowNotCreated;
        }
        self.next_window_id += 1;
        return id;
    }

    /// Closes `window` and frees its slot, once a file dialog or popup menu
    /// open over it has closed; its id polls false from now on.
    pub fn zuiCloseWindow(self: *Host, id: zui.WindowId) void {
        const window = self.windowById(id) orelse return;
        win32.AcquireSRWLockExclusive(&self.lock);
        window.inbox.closed = true;
        win32.ReleaseSRWLockExclusive(&self.lock);
        _ = win32.SendMessageW(window.hwnd, wm_close_window, 0, 0);
    }

    fn freeSlot(self: *Host) ?usize {
        win32.AcquireSRWLockExclusive(&self.lock);
        defer win32.ReleaseSRWLockExclusive(&self.lock);
        for (self.windows, 0..) |window, slot| if (!window.in_use) return slot;
        return null;
    }

    fn prepareWindow(self: *Host, window: *Window, id: zui.WindowId, options: zui.WindowOptions) !void {
        window.* = .{ .host = self, .id = id, .custom_title_bar = options.title_bar == .custom, .thread_state = .{ .options = options } };
        try window.accessibility.init(options.semantics, .{ .context = window, .deliverFn = Window.deliverAction }, wheel_step);
    }

    /// The open window `id` names, or null.
    pub fn windowById(self: *Host, id: zui.WindowId) ?*Window {
        win32.AcquireSRWLockExclusive(&self.lock);
        defer win32.ReleaseSRWLockExclusive(&self.lock);
        for (&self.windows) |*window| if (window.in_use and window.id == id) return window;
        return null;
    }

    fn openWindowOrPanic(self: *Host, id: zui.WindowId) *Window {
        return self.windowById(id) orelse std.debug.panic("zui_host: window {d} is not open", .{@intFromEnum(id)});
    }

    /// `service_fake` set after `init`, for an application under
    /// `zui_app`, which starts every field at its default before `init`.
    /// Call it before the first service call, from the thread that makes
    /// them.
    ///
    /// ```zig
    /// pub fn init(app: *App, start: zui_app.Start(App)) !void {
    ///     if (app.checking) start.host.fakeServices(&app.service_fake);
    /// }
    /// ```
    pub fn fakeServices(self: *Host, fake: *services.ServiceFake) void {
        win32.AcquireSRWLockExclusive(&self.services.lock);
        defer win32.ReleaseSRWLockExclusive(&self.services.lock);
        self.service_fake = fake;
        self.services.fake = fake;
    }

    fn manualResetEvent() !win32.HANDLE {
        return win32.CreateEventW(null, 1, 0, null) orelse error.NoEvent;
    }

    pub fn now(self: *const Host) zui.Instant {
        return .fromTimestamp(std.Io.Timestamp.now(self.io, .awake));
    }

    pub fn zuiPoll(self: *Host, id: zui.WindowId, record: *zui.RecordBuilder) bool {
        const window = self.windowById(id) orelse return false;
        if (window.terminate_delivered) return false;
        win32.AcquireSRWLockExclusive(&self.lock);
        defer win32.ReleaseSRWLockExclusive(&self.lock);
        _ = win32.ResetEvent(self.input_arrived);
        const inbox = &window.inbox;
        if (inbox.closed) return false;

        const scale = self.forced_scale orelse @as(f32, @floatFromInt(inbox.dpi)) / win32.USER_DEFAULT_SCREEN_DPI;
        const pixels_per_unit = scale * record.params.zoom;
        window.pixels_per_unit = pixels_per_unit;
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
                    if (change == .terminate_requested) window.terminate_delivered = true;
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
            if (low != 0 and !window.was_low_on_memory) record.append(.{ .lifecycle = .low_memory });
            window.was_low_on_memory = low != 0;
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

    /// Returns on a wake or input in any window, and for `.at` also at the
    /// instant. The wake is cleared after the wait, so one that came before
    /// it ends it.
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

    /// In `.scrgb_fp16` while the window's monitor runs in HDR, if the
    /// window was opened with it, and in `.sdr` otherwise. Asking for a
    /// window that is not open panics.
    pub fn zuiSurface(self: *Host, id: zui.WindowId) zui.Surface {
        const window = self.openWindowOrPanic(id);
        win32.AcquireSRWLockExclusive(&self.lock);
        defer win32.ReleaseSRWLockExclusive(&self.lock);
        return .{ .win32 = .{ .hwnd = window.hwnd, .format = window.inbox.output_format } };
    }

    pub fn zuiApply(self: *Host, id: zui.WindowId, requests: zui.HostRequests) void {
        const window = self.windowById(id) orelse return;
        win32.AcquireSRWLockExclusive(&self.lock);
        const changed = !std.meta.eql(window.requests, requests);
        window.requests = requests;
        win32.ReleaseSRWLockExclusive(&self.lock);
        if (changed) _ = win32.PostMessageW(window.hwnd, wm_apply_requests, 0, 0);
    }

    /// Keeps what fits of the frame's semantics for UI Automation, and has
    /// the window thread tell listening clients what changed.
    pub fn zuiSemantics(self: *Host, id: zui.WindowId, nodes: []const zui.SemanticNode) zui.SemanticsDropped {
        const window = self.windowById(id) orelse return .{};
        const dropped = window.accessibility.publish(nodes, window.pixels_per_unit);
        if (window.accessibility.hasRoom() and uia.UiaClientsAreListening() != 0) _ = win32.PostMessageW(window.hwnd, wm_semantics_changed, 0, 0);
        return dropped;
    }

    /// Keeps up to `chrome.ChromeSnapshot.capacity` of `regions`, in
    /// physical pixels, for the window thread to answer `WM_NCHITTEST` from;
    /// the rest are cut from the end and counted in `chrome_snapshot.dropped`.
    /// A window opened with a native title bar keeps none.
    pub fn zuiChromeRegions(self: *Host, id: zui.WindowId, regions: []const zui.ChromeRegion) void {
        const window = self.windowById(id) orelse return;
        if (!window.custom_title_bar) return;
        window.chrome_snapshot.publish(regions, window.pixels_per_unit);
    }

    /// Closes the main window as its close button does: the next poll
    /// returns false.
    pub fn close(self: *Host) void {
        _ = win32.SendMessageW(self.hwnd, win32.WM_CLOSE, 0, 0);
    }

    /// Minimizes the main window as its minimize button does, for an
    /// application that works its drawn caption buttons from `clicked`, as
    /// the keyboard and Narrator press them.
    pub fn minimize(self: *Host) void {
        _ = win32.PostMessageW(self.hwnd, win32.WM_SYSCOMMAND, win32.SC_MINIMIZE, 0);
    }

    /// Maximizes the main window, or restores it when it is maximized.
    pub fn toggleMaximized(self: *Host) void {
        _ = win32.PostMessageW(self.hwnd, win32.WM_SYSCOMMAND, if (win32.IsZoomed(self.hwnd) != 0) win32.SC_RESTORE else win32.SC_MAXIMIZE, 0);
    }

    /// The main window's client area, in physical pixels.
    pub fn clientSize(self: *Host) [2]u32 {
        const window = self.windowById(.main) orelse return .{ 0, 0 };
        win32.AcquireSRWLockExclusive(&self.lock);
        defer win32.ReleaseSRWLockExclusive(&self.lock);
        return window.inbox.client_size;
    }

    /// What the last poll of `window` converted pixels to layout units by.
    pub fn pixelsPerUnit(self: *Host, id: zui.WindowId) f32 {
        const window = self.windowById(id) orelse return 1;
        return window.pixels_per_unit;
    }

    fn deliverToEveryWindow(self: *Host, event: zui.Event) void {
        win32.AcquireSRWLockExclusive(&self.lock);
        defer win32.ReleaseSRWLockExclusive(&self.lock);
        for (&self.windows) |*window| if (window.in_use) window.inbox.push(event);
        _ = win32.SetEvent(self.input_arrived);
    }

    // =================================================================
    // The window thread
    // =================================================================

    const class_name = W("zui_host_window");
    const anchor_class_name = W("zui_host_anchor");

    fn runWindowThread(self: *Host) void {
        // A single-threaded apartment, as the shell's modal dialogs need.
        const com_initialized = win32.succeeded(win32.CoInitializeEx(null, win32.COINIT_APARTMENTTHREADED));
        defer if (com_initialized) win32.CoUninitialize();
        self.anchor = self.createAnchor() catch |err| {
            self.anchor_init_error = err;
            _ = win32.SetEvent(self.window_created);
            return;
        };
        self.createWindow(&self.windows[0]);
        if (self.windows[0].thread_state.init_error != null) _ = win32.DestroyWindow(self.anchor);
        _ = win32.SetEvent(self.window_created);

        var message: win32.MSG = undefined;
        while (win32.GetMessageW(&message, null, 0, 0) > 0) {
            _ = win32.TranslateMessage(&message);
            _ = win32.DispatchMessageW(&message);
        }
    }

    fn createAnchor(self: *Host) !win32.HWND {
        const instance = win32.GetModuleHandleW(null);
        const class: win32.WNDCLASSEXW = .{ .lpfnWndProc = anchorProcedure, .hInstance = instance, .lpszClassName = anchor_class_name };
        // Fails harmlessly when an earlier host registered it.
        _ = win32.RegisterClassExW(&class);
        const anchor = win32.CreateWindowExW(0, anchor_class_name, W("zui host"), 0, 0, 0, 0, 0, win32.HWND_MESSAGE, null, instance, null) orelse return error.WindowNotCreated;
        _ = win32.SetWindowLongPtrW(anchor, win32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
        return anchor;
    }

    fn anchorProcedure(hwnd: win32.HWND, message: win32.UINT, wparam: win32.WPARAM, lparam: win32.LPARAM) callconv(.winapi) win32.LRESULT {
        const address: usize = @bitCast(win32.GetWindowLongPtrW(hwnd, win32.GWLP_USERDATA));
        if (address == 0) return win32.DefWindowProcW(hwnd, message, wparam, lparam);
        const self: *Host = @ptrFromInt(address);
        return self.handleAnchorMessage(hwnd, message, wparam, lparam);
    }

    fn handleAnchorMessage(self: *Host, hwnd: win32.HWND, message: win32.UINT, wparam: win32.WPARAM, lparam: win32.LPARAM) win32.LRESULT {
        switch (message) {
            wm_open_window => {
                self.createWindow(&self.windows[wparam]);
                return 0;
            },
            wm_close_host => {
                self.closing = true;
                for (&self.windows) |*window| if (window.in_use) {
                    _ = win32.SendMessageW(window.hwnd, wm_close_window, 0, 0);
                };
                self.destroyAnchorOnceEveryWindowIs();
                return 0;
            },
            win32.WM_DESTROY => {
                self.services.removeNotifyIcon(hwnd);
                win32.PostQuitMessage(0);
                return 0;
            },
            wm_read_clipboard => {
                self.services.answerClipboardRead(hwnd, self.zuiWaker());
                return 0;
            },
            wm_open_url => {
                self.services.openUrl(hwnd);
                return 0;
            },
            wm_show_notification => {
                self.services.showNotification(hwnd, wm_notify_icon, self.notification_tip[0..self.notification_tip_len], self.zuiWaker());
                return 0;
            },
            wm_notify_icon => {
                self.services.answerNotifyIconEvent(hwnd, lparam, self.zuiWaker());
                return 0;
            },
            else => {},
        }
        return win32.DefWindowProcW(hwnd, message, wparam, lparam);
    }

    /// On the window thread, as a window's last message arrives.
    fn freeWindow(self: *Host, window: *Window) void {
        window.accessibility.deinit();
        win32.AcquireSRWLockExclusive(&self.lock);
        window.in_use = false;
        win32.ReleaseSRWLockExclusive(&self.lock);
        if (self.closing) self.destroyAnchorOnceEveryWindowIs();
    }

    fn destroyAnchorOnceEveryWindowIs(self: *Host) void {
        if (self.anchor_destroyed) return;
        for (self.windows) |window| if (window.in_use) return;
        self.anchor_destroyed = true;
        _ = win32.DestroyWindow(self.anchor);
    }

    /// Whether the user is in any window's menu bar, while no other menu
    /// can show.
    fn anyMenuBarOpen(self: *const Host) bool {
        for (self.windows) |window| if (window.in_use and window.menu_bar.menus_open) return true;
        return false;
    }

    /// Creates `window`'s Win32 window, which takes the slot, or leaves
    /// why it could not in `init_error`.
    fn createWindow(self: *Host, window: *Window) void {
        const hwnd = createWin32Window(window) catch |err| {
            window.thread_state.init_error = err;
            return;
        };
        window.hwnd = hwnd;
        win32.AcquireSRWLockExclusive(&self.lock);
        window.in_use = true;
        win32.ReleaseSRWLockExclusive(&self.lock);
    }

    fn createWin32Window(window: *Window) !win32.HWND {
        const instance = win32.GetModuleHandleW(null);
        const state = &window.thread_state;
        for (std.enums.values(zui.Cursor)) |cursor| state.cursors.set(cursor, win32.LoadCursorW(null, cursorResource(cursor)));
        const class: win32.WNDCLASSEXW = .{
            .style = win32.CS_OWNDC | win32.CS_HREDRAW | win32.CS_VREDRAW,
            .lpfnWndProc = windowProcedure,
            .hInstance = instance,
            .hCursor = state.cursors.get(.default),
            .lpszClassName = class_name,
        };
        // Fails harmlessly when an earlier host registered it.
        _ = win32.RegisterClassExW(&class);

        const options = state.options;
        const title = &state.title;
        state.title_len = std.unicode.utf8ToUtf16Le(title[0 .. title.len - 1], options.title[0..@min(options.title.len, 255)]) catch 0;
        title[state.title_len] = 0;
        const style = windowStyle(options);

        const hwnd = win32.CreateWindowExW(0, class_name, title, style, win32.CW_USEDEFAULT, win32.CW_USEDEFAULT, win32.CW_USEDEFAULT, win32.CW_USEDEFAULT, null, null, instance, null) orelse return error.WindowNotCreated;
        window.accessibility.hwnd = hwnd;
        _ = win32.SetWindowLongPtrW(hwnd, win32.GWLP_USERDATA, @bitCast(@intFromPtr(window)));

        const dpi = win32.GetDpiForWindow(hwnd);
        var frame: win32.RECT = .{
            .right = @intCast(options.size[0] * dpi / win32.USER_DEFAULT_SCREEN_DPI),
            .bottom = @intCast(options.size[1] * dpi / win32.USER_DEFAULT_SCREEN_DPI),
        };
        _ = win32.AdjustWindowRectExForDpi(&frame, style, 0, 0, dpi);
        _ = win32.SetWindowPos(hwnd, null, 0, 0, frame.right - frame.left, frame.bottom - frame.top, win32.SWP_NOMOVE | win32.SWP_NOZORDER | win32.SWP_NOACTIVATE);
        if (window.custom_title_bar) dropCaption(hwnd, .{ frame.right - frame.left, frame.bottom - frame.top }, options.size, dpi);
        window.recordClientSize(hwnd, dpi);

        win32.DragAcceptFiles(hwnd, 1);
        state.backdrop_applied = window.applyMaterial(hwnd, options.material);
        window.setImeEnabled(hwnd, false);
        window.reportEnvironment(hwnd, true);
        if (options.visible) _ = win32.ShowWindow(hwnd, win32.SW_SHOWNORMAL);
        return hwnd;
    }

    /// Has Windows ask `WM_NCCALCSIZE` again, which now leaves out the
    /// caption, then sizes the window so its client area is `size` again.
    fn dropCaption(hwnd: win32.HWND, window_size: [2]i32, size: [2]u32, dpi: u32) void {
        const unchanged = win32.SWP_NOMOVE | win32.SWP_NOZORDER | win32.SWP_NOACTIVATE;
        _ = win32.SetWindowPos(hwnd, null, 0, 0, 0, 0, unchanged | win32.SWP_NOSIZE | win32.SWP_FRAMECHANGED);
        var client: win32.RECT = .{};
        _ = win32.GetClientRect(hwnd, &client);
        const wanted: [2]i32 = .{ @intCast(size[0] * dpi / win32.USER_DEFAULT_SCREEN_DPI), @intCast(size[1] * dpi / win32.USER_DEFAULT_SCREEN_DPI) };
        _ = win32.SetWindowPos(hwnd, null, 0, 0, window_size[0] + wanted[0] - client.right, window_size[1] + wanted[1] - client.bottom, unchanged);
    }

    /// The height of the resize band a window keeps at its top without a
    /// caption, as the system's frame is on its other sides.
    fn resizeBandThickness(dpi: u32) i32 {
        return win32.GetSystemMetricsForDpi(win32.SM_CYSIZEFRAME, dpi) + win32.GetSystemMetricsForDpi(win32.SM_CXPADDEDBORDER, dpi);
    }

    fn windowStyle(options: zui.WindowOptions) win32.DWORD {
        return if (options.resizable) win32.WS_OVERLAPPEDWINDOW else win32.WS_OVERLAPPEDWINDOW & ~(win32.WS_THICKFRAME | win32.WS_MAXIMIZEBOX);
    }

    fn windowProcedure(hwnd: win32.HWND, message: win32.UINT, wparam: win32.WPARAM, lparam: win32.LPARAM) callconv(.winapi) win32.LRESULT {
        const address: usize = @bitCast(win32.GetWindowLongPtrW(hwnd, win32.GWLP_USERDATA));
        if (address == 0) return win32.DefWindowProcW(hwnd, message, wparam, lparam);
        const window: *Window = @ptrFromInt(address);
        return window.handleMessage(hwnd, message, wparam, lparam);
    }

    fn mouse(lparam: win32.LPARAM, at: zui.Instant) zui.Pointer {
        const point = win32.pointFromLparam(lparam);
        return .{ .id = .mouse, .kind = .mouse, .position = .{ @floatFromInt(point[0]), @floatFromInt(point[1]) }, .at = at };
    }

    /// A non-client mouse message carries a screen point; zui takes client
    /// pixels.
    fn nonClientMouse(hwnd: win32.HWND, lparam: win32.LPARAM, at: zui.Instant) zui.Pointer {
        const screen = win32.pointFromLparam(lparam);
        var point: win32.POINT = .{ .x = screen[0], .y = screen[1] };
        _ = win32.ScreenToClient(hwnd, &point);
        return .{ .id = .mouse, .kind = .mouse, .position = .{ @floatFromInt(point.x), @floatFromInt(point.y) }, .at = at };
    }

    /// The system's frame on the left, right and bottom stays, so DWM keeps
    /// the border, the rounded corners and the shadow; only the caption
    /// goes. A maximized window reaches past its monitor by the frame's
    /// thickness, which the client top leaves out.
    fn calculateClientWithoutCaption(hwnd: win32.HWND, lparam: win32.LPARAM) win32.LRESULT {
        const params: *win32.NCCALCSIZE_PARAMS = @ptrFromInt(@as(usize, @bitCast(lparam)));
        const proposed_top = params.rgrc[0].top;
        const answered = win32.DefWindowProcW(hwnd, win32.WM_NCCALCSIZE, 1, lparam);
        if (answered != 0) return answered;
        params.rgrc[0].top = proposed_top;
        if (win32.IsZoomed(hwnd) != 0) params.rgrc[0].top += resizeBandThickness(win32.GetDpiForWindow(hwnd));
        return 0;
    }

    /// Through `WM_SYSCOMMAND`, as the system's own buttons, so Windows
    /// animates it and a close arrives as `WM_CLOSE`.
    fn workCaptionButton(hwnd: win32.HWND, code: usize) void {
        const command: usize = switch (code) {
            win32.HTMINBUTTON => win32.SC_MINIMIZE,
            win32.HTMAXBUTTON => if (win32.IsZoomed(hwnd) != 0) win32.SC_RESTORE else win32.SC_MAXIMIZE,
            win32.HTCLOSE => win32.SC_CLOSE,
            else => return,
        };
        _ = win32.PostMessageW(hwnd, win32.WM_SYSCOMMAND, command, 0);
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
/// console, logging off and shutting down all ask the application to end,
/// in every window.
pub fn onConsoleControl(control: win32.DWORD) callconv(.winapi) win32.BOOL {
    const host = console_host.load(.acquire) orelse return 0;
    switch (control) {
        win32.CTRL_C_EVENT, win32.CTRL_BREAK_EVENT, win32.CTRL_CLOSE_EVENT, win32.CTRL_LOGOFF_EVENT, win32.CTRL_SHUTDOWN_EVENT => {
            host.deliverToEveryWindow(.{ .lifecycle = .terminate_requested });
            return 1;
        },
        else => return 0,
    }
}

test {
    _ = keys;
    _ = file_watch;
    _ = display;
    _ = accessibility;
    _ = services;
    _ = file_dialog;
    _ = menu;
    _ = chrome;
}
