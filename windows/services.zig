const std = @import("std");
const zui = @import("zui");
const win32 = @import("win32.zig");
const file_dialog = @import("file_dialog.zig");
const menu = @import("menu.zig");

const W = std.unicode.utf8ToUtf16LeStringLiteral;

/// What the host's services hand to the window thread, which answers every
/// call, so answers never come from two threads at once. A call claims its
/// slot under `lock`, and the window thread frees it once it has answered.
pub const Services = struct {
    lock: win32.SRWLOCK = .{},
    clipboard_read: ?PendingAnswer = null,
    url_pending: bool = false,
    url: [url_capacity:0]u16 = undefined,
    notification_pending: ?PendingAnswer = null,
    notification_title: NotificationTitle = @splat(0),
    notification_body: NotificationBody = @splat(0),
    /// Claimed until the dialog has been answered, so its strings stay put
    /// while it shows.
    file_dialog_pending: ?PendingAnswer = null,
    file_dialog: file_dialog.CopiedDialog = .{},
    /// Claimed until the menu has been answered, as a file dialog is; the
    /// two share the rule that one shows at a time.
    popup_menu_pending: ?PendingAnswer = null,
    popup_menu: menu.CopiedMenu = .{},
    /// In the owning window's client pixels.
    popup_menu_position: win32.POINT = .{},
    /// Only the window thread uses these.
    popup_menu_running: bool = false,
    clipboard_text: [clipboard_text_capacity]u8 = undefined,
    /// The notification showing, answered when the user clicks it, it times
    /// out or is closed, or the next one replaces it.
    notification_shown: ?PendingAnswer = null,
    notify_icon_added: bool = false,
    file_dialog_running: bool = false,
    /// Null while the fake stands in for `Show`.
    file_dialog_shown: ?*file_dialog.IFileDialog = null,
    chosen_paths: [chosen_paths_capacity]u8 = undefined,
    /// The window a file dialog or a popup menu is open over.
    dialog_or_menu_owner: ?win32.HWND = null,
    /// The owner closes once the open dialog has; nothing is answered then.
    window_closing: bool = false,
    /// Hands nothing to the system when set.
    fake: ?*ServiceFake = null,

    /// `INTERNET_MAX_URL_LENGTH`, in UTF-16 units.
    pub const url_capacity = 2083;
    /// UTF-8 bytes of the clipboard's text a read answers with; the rest is
    /// counted as left out.
    pub const clipboard_text_capacity = 64 * 1024;
    /// The window's icon in the notification area, which shows its
    /// notifications.
    pub const notify_icon_id = 1;
    /// UTF-8 bytes of the paths a file dialog answers with; paths past it
    /// are counted as left out.
    pub const chosen_paths_capacity = 32 * 1024;

    /// As `NOTIFYICONDATAW` holds them, each ending in a 0.
    pub const NotificationTitle = @FieldType(win32.NOTIFYICONDATAW, "szInfoTitle");
    pub const NotificationBody = @FieldType(win32.NOTIFYICONDATAW, "szInfo");

    /// The commands Windows reports for each bar and for a popup, kept
    /// apart so a command always names the menu it came from.
    pub const first_bar_command = [2]usize{ 1, 1 + menu.CopiedMenu.entry_capacity };
    pub const first_popup_menu_command = 1 + 2 * menu.CopiedMenu.entry_capacity;

    fn dialogOrMenuClaimed(self: *const Services) bool {
        return self.file_dialog_pending != null or self.popup_menu_pending != null;
    }

    pub fn claimClipboardRead(self: *Services, request: zui.ServiceRequest, sink: zui.ServiceSink) zui.ServiceError!void {
        win32.AcquireSRWLockExclusive(&self.lock);
        defer win32.ReleaseSRWLockExclusive(&self.lock);
        if (self.clipboard_read != null) return error.Busy;
        self.clipboard_read = .{ .request = request, .sink = sink };
    }

    pub fn releaseClipboardRead(self: *Services) void {
        win32.AcquireSRWLockExclusive(&self.lock);
        defer win32.ReleaseSRWLockExclusive(&self.lock);
        self.clipboard_read = null;
    }

    /// Copies `url` for the window thread to hand over, refusing what is not
    /// a URL the system may open.
    pub fn claimUrl(self: *Services, url: []const u8) zui.ServiceError!void {
        if (!zui.isOpenableUrl(url)) return error.InvalidUrl;
        const units = std.unicode.calcUtf16LeLen(url) catch return error.InvalidUtf8;
        if (units > url_capacity) return error.TooLarge;
        win32.AcquireSRWLockExclusive(&self.lock);
        defer win32.ReleaseSRWLockExclusive(&self.lock);
        if (self.url_pending) return error.Busy;
        _ = std.unicode.utf8ToUtf16Le(&self.url, url) catch unreachable;
        self.url[units] = 0;
        self.url_pending = true;
    }

    pub fn releaseUrl(self: *Services) void {
        win32.AcquireSRWLockExclusive(&self.lock);
        defer win32.ReleaseSRWLockExclusive(&self.lock);
        self.url_pending = false;
    }

    /// Copies the notification's text for the window thread to show, each
    /// part cut at a character to what the notification area holds.
    pub fn claimNotification(self: *Services, request: zui.ServiceRequest, notification: zui.Notification, sink: zui.ServiceSink) zui.ServiceError!void {
        if (!std.unicode.utf8ValidateSlice(notification.title) or !std.unicode.utf8ValidateSlice(notification.body)) return error.InvalidUtf8;
        win32.AcquireSRWLockExclusive(&self.lock);
        defer win32.ReleaseSRWLockExclusive(&self.lock);
        if (self.notification_pending != null) return error.Busy;
        utf16CutToFit(notification.title, &self.notification_title);
        utf16CutToFit(notification.body, &self.notification_body);
        self.notification_pending = .{ .request = request, .sink = sink };
    }

    pub fn releaseNotification(self: *Services) void {
        win32.AcquireSRWLockExclusive(&self.lock);
        defer win32.ReleaseSRWLockExclusive(&self.lock);
        self.notification_pending = null;
    }

    /// Copies the dialog's settings for the window thread to show over
    /// `window`, refusing one while a dialog or a popup menu is still
    /// waiting or open, over any window.
    pub fn claimFileDialog(self: *Services, request: zui.ServiceRequest, window: zui.WindowId, dialog: zui.FileDialog, sink: zui.ServiceSink) zui.ServiceError!void {
        win32.AcquireSRWLockExclusive(&self.lock);
        defer win32.ReleaseSRWLockExclusive(&self.lock);
        if (self.dialogOrMenuClaimed()) return error.Busy;
        try self.file_dialog.copy(dialog);
        self.file_dialog_pending = .{ .request = request, .window = window, .sink = sink };
    }

    pub fn releaseFileDialog(self: *Services) void {
        win32.AcquireSRWLockExclusive(&self.lock);
        defer win32.ReleaseSRWLockExclusive(&self.lock);
        self.file_dialog_pending = null;
    }

    /// Copies the menu for the window thread to show over `window` at
    /// `position`, in its client pixels, refusing one while a dialog or a
    /// popup menu is still waiting or open, over any window.
    pub fn claimPopupMenu(self: *Services, request: zui.ServiceRequest, window: zui.WindowId, items: []const zui.MenuItem, position: win32.POINT, sink: zui.ServiceSink) zui.ServiceError!void {
        win32.AcquireSRWLockExclusive(&self.lock);
        defer win32.ReleaseSRWLockExclusive(&self.lock);
        if (self.dialogOrMenuClaimed()) return error.Busy;
        try self.popup_menu.copy(items);
        self.popup_menu_position = position;
        self.popup_menu_pending = .{ .request = request, .window = window, .sink = sink };
    }

    pub fn releasePopupMenu(self: *Services) void {
        win32.AcquireSRWLockExclusive(&self.lock);
        defer win32.ReleaseSRWLockExclusive(&self.lock);
        self.popup_menu_pending = null;
    }

    /// On the window thread, which owns the menu. `TrackPopupMenuEx` runs
    /// the menu's modal loop, which keeps dispatching the window's messages,
    /// and returns when the user has chosen or closed it. When the window
    /// was asked to close meanwhile, nothing is answered, and
    /// `close_message` is posted again to close it. Windows shows one menu
    /// at a time, so none shows while `bar_menus_open`.
    pub fn showPopupMenu(self: *Services, hwnd: win32.HWND, close_message: win32.UINT, bar_menus_open: bool, waker: zui.Waker) void {
        win32.AcquireSRWLockExclusive(&self.lock);
        const pending = self.popup_menu_pending orelse {
            win32.ReleaseSRWLockExclusive(&self.lock);
            return;
        };
        win32.ReleaseSRWLockExclusive(&self.lock);

        self.popup_menu_running = true;
        self.dialog_or_menu_owner = hwnd;
        const outcome: zui.ServiceAnswer.Outcome = if (bar_menus_open) .{ .failed = .unavailable } else self.runPopupMenu(hwnd);
        self.popup_menu_running = false;
        self.dialog_or_menu_owner = null;
        // Before the answer, so a menu shown as soon as it arrives is not busy.
        self.releasePopupMenu();
        if (self.window_closing) {
            self.window_closing = false;
            _ = win32.PostMessageW(hwnd, close_message, 0, 0);
            return;
        }
        publish(pending, outcome, waker);
    }

    fn runPopupMenu(self: *Services, hwnd: win32.HWND) zui.ServiceAnswer.Outcome {
        const popup = menu.build(&self.popup_menu, .popup, first_popup_menu_command) orelse return .{ .failed = .unavailable };
        defer _ = win32.DestroyMenu(popup);
        var position = self.popup_menu_position;
        _ = win32.ClientToScreen(hwnd, &position);
        const command: usize = if (self.fake) |fake|
            fake.standInForTrackPopupMenu(popup, &self.popup_menu, position, self)
        else
            @intCast(@max(win32.TrackPopupMenuEx(popup, win32.TPM_RETURNCMD | win32.TPM_NONOTIFY | win32.TPM_RIGHTBUTTON, position.x, position.y, hwnd, null), 0));
        const chosen = self.popup_menu.itemOfCommand(command, first_popup_menu_command) orelse return .canceled;
        return .{ .menu_item_chosen = chosen };
    }

    /// On the window thread, which owns the dialog. `Show` runs the dialog's
    /// modal loop, which keeps dispatching the window's messages, and
    /// returns when the user has chosen or canceled. When the window was
    /// asked to close meanwhile, nothing is answered, and `close_message` is
    /// posted again to close it.
    pub fn showFileDialog(self: *Services, hwnd: win32.HWND, close_message: win32.UINT, waker: zui.Waker) void {
        win32.AcquireSRWLockExclusive(&self.lock);
        const pending = self.file_dialog_pending orelse {
            win32.ReleaseSRWLockExclusive(&self.lock);
            return;
        };
        win32.ReleaseSRWLockExclusive(&self.lock);

        var paths: file_dialog.ChosenPaths = .{ .buffer = &self.chosen_paths };
        self.file_dialog_running = true;
        self.dialog_or_menu_owner = hwnd;
        const outcome = self.runFileDialog(hwnd, &paths);
        self.file_dialog_running = false;
        self.dialog_or_menu_owner = null;
        // Before the answer, so a dialog shown as soon as it arrives is not
        // busy; the paths stay put, since only this thread writes them.
        self.releaseFileDialog();
        if (self.window_closing) {
            self.window_closing = false;
            _ = win32.PostMessageW(hwnd, close_message, 0, 0);
            return;
        }
        const answer: zui.ServiceAnswer = .{ .request = pending.request, .window = pending.window, .outcome = outcome, .left_out_bytes = paths.left_out_bytes };
        waker.wakeIf(pending.sink.publish(&answer));
    }

    fn runFileDialog(self: *Services, hwnd: win32.HWND, paths: *file_dialog.ChosenPaths) zui.ServiceAnswer.Outcome {
        const dialog = file_dialog.create(&self.file_dialog) orelse return .{ .failed = .unavailable };
        defer dialog.release();
        if (self.fake) |fake| return fake.standInForShow(dialog, self, paths);
        self.file_dialog_shown = dialog;
        const shown = dialog.vtable.Show(dialog, hwnd);
        self.file_dialog_shown = null;
        return file_dialog.collectAnswer(dialog, self.file_dialog.kind, shown, paths);
    }

    /// On the window thread, when `hwnd` is to close: true when a file
    /// dialog or a popup menu is open over it, which is closed first, and
    /// the window closed after it.
    pub fn closeDialogOrMenuFirst(self: *Services, hwnd: win32.HWND) bool {
        if (self.dialog_or_menu_owner != hwnd) return false;
        self.window_closing = true;
        if (self.file_dialog_shown) |dialog| file_dialog.cancelShown(dialog);
        if (self.popup_menu_running and self.fake == null) _ = win32.EndMenu();
        return true;
    }

    /// On the window thread, which owns `hwnd`, as the clipboard asks of
    /// whoever opens it.
    pub fn answerClipboardRead(self: *Services, hwnd: win32.HWND, waker: zui.Waker) void {
        win32.AcquireSRWLockExclusive(&self.lock);
        const pending = self.clipboard_read orelse {
            win32.ReleaseSRWLockExclusive(&self.lock);
            return;
        };
        win32.ReleaseSRWLockExclusive(&self.lock);

        var answer: zui.ServiceAnswer = .{ .request = pending.request, .outcome = .{ .failed = .unavailable } };
        if (win32.OpenClipboard(hwnd) != 0) {
            defer _ = win32.CloseClipboard();
            answer.outcome = .{ .clipboard_text = "" };
            if (win32.GetClipboardData(win32.CF_UNICODETEXT)) |memory| if (win32.GlobalLock(memory)) |locked| {
                defer _ = win32.GlobalUnlock(memory);
                const units: [*]const u16 = @ptrCast(@alignCast(locked));
                const capacity = win32.GlobalSize(memory) / 2;
                const text = units[0 .. std.mem.indexOfScalar(u16, units[0..capacity], 0) orelse capacity];
                const converted = utf8FromClipboard(text, &self.clipboard_text);
                answer.outcome = .{ .clipboard_text = self.clipboard_text[0..converted.len] };
                answer.left_out_bytes = converted.left_out_bytes;
            };
        }
        // Before the answer, so a read made as soon as it arrives is not
        // busy; the text stays put, since only this thread writes it.
        self.releaseClipboardRead();
        waker.wakeIf(pending.sink.publish(&answer));
    }

    /// On the window thread. A system that then fails to open the URL shows
    /// its own error; nothing is answered.
    pub fn openUrl(self: *Services, hwnd: win32.HWND) void {
        defer self.releaseUrl();
        const url = std.mem.sliceTo(&self.url, 0);
        if (self.fake) |fake| return fake.recordOpenedUrl(url);
        _ = win32.ShellExecuteW(hwnd, W("open"), url, null, null, win32.SW_SHOWNORMAL);
    }

    /// On the window thread: shows the claimed notification as a balloon of
    /// the window's notification-area icon, which Windows 10 and 11 show
    /// as a toast. The icon's `callback_message` brings back what became of
    /// it, for `answerNotifyIconEvent`.
    pub fn showNotification(self: *Services, hwnd: win32.HWND, callback_message: win32.UINT, title: []const u16, waker: zui.Waker) void {
        var balloon: win32.NOTIFYICONDATAW = .{ .hWnd = hwnd, .uID = notify_icon_id, .uFlags = win32.NIF_INFO, .dwInfoFlags = win32.NIIF_INFO };
        win32.AcquireSRWLockExclusive(&self.lock);
        const pending = self.notification_pending orelse {
            win32.ReleaseSRWLockExclusive(&self.lock);
            return;
        };
        balloon.szInfoTitle = self.notification_title;
        balloon.szInfo = self.notification_body;
        self.notification_pending = null;
        win32.ReleaseSRWLockExclusive(&self.lock);

        if (self.notification_shown) |replaced| publish(replaced, .notification_dismissed, waker);
        self.notification_shown = pending;
        if (!self.notify_icon_added) {
            var icon: win32.NOTIFYICONDATAW = .{
                .hWnd = hwnd,
                .uID = notify_icon_id,
                .uFlags = win32.NIF_MESSAGE | win32.NIF_ICON | win32.NIF_TIP,
                .uCallbackMessage = callback_message,
                .hIcon = win32.LoadIconW(null, win32.IDI_APPLICATION),
            };
            const tip_len = @min(title.len, icon.szTip.len - 1);
            @memcpy(icon.szTip[0..tip_len], title[0..tip_len]);
            if (!self.notifyIcon(win32.NIM_ADD, &icon)) return self.answerShown(.{ .failed = .unavailable }, waker);
            self.notify_icon_added = true;
            icon.uVersion = win32.NOTIFYICON_VERSION_4;
            _ = self.notifyIcon(win32.NIM_SETVERSION, &icon);
        }
        if (!self.notifyIcon(win32.NIM_MODIFY, &balloon)) {
            self.answerShown(.{ .failed = .unavailable }, waker);
            return self.removeNotifyIcon(hwnd);
        }
        if (self.fake) |fake| if (fake.takeScriptedNotificationEvent()) |event| {
            _ = win32.PostMessageW(hwnd, callback_message, 0, notifyIconEventLparam(event));
        };
    }

    /// On the window thread, for the icon's callback message: with
    /// `NOTIFYICON_VERSION_4`, the event is the low word of `lparam`.
    pub fn answerNotifyIconEvent(self: *Services, hwnd: win32.HWND, lparam: win32.LPARAM, waker: zui.Waker) void {
        const outcome: zui.ServiceAnswer.Outcome = switch (win32.loword(lparam)) {
            win32.NIN_BALLOONUSERCLICK => .notification_activated,
            win32.NIN_BALLOONTIMEOUT, win32.NIN_BALLOONHIDE => .notification_dismissed,
            else => return,
        };
        if (self.notification_shown == null) return;
        self.answerShown(outcome, waker);
        self.removeNotifyIcon(hwnd);
    }

    /// On the window thread, when the balloon has ended or the window closes.
    pub fn removeNotifyIcon(self: *Services, hwnd: win32.HWND) void {
        if (!self.notify_icon_added) return;
        _ = self.notifyIcon(win32.NIM_DELETE, &.{ .hWnd = hwnd, .uID = notify_icon_id });
        self.notify_icon_added = false;
    }

    fn answerShown(self: *Services, outcome: zui.ServiceAnswer.Outcome, waker: zui.Waker) void {
        const shown = self.notification_shown orelse return;
        self.notification_shown = null;
        publish(shown, outcome, waker);
    }

    fn notifyIcon(self: *Services, message: win32.DWORD, data: *const win32.NOTIFYICONDATAW) bool {
        if (self.fake) |fake| return fake.recordNotifyIcon(message, data);
        return win32.Shell_NotifyIconW(message, data) != 0;
    }
};

const PendingAnswer = struct { request: zui.ServiceRequest, window: zui.WindowId = .main, sink: zui.ServiceSink };

fn publish(pending: PendingAnswer, outcome: zui.ServiceAnswer.Outcome, waker: zui.Waker) void {
    const answer: zui.ServiceAnswer = .{ .request = pending.request, .window = pending.window, .outcome = outcome };
    waker.wakeIf(pending.sink.publish(&answer));
}

/// One window's menu bar: what a call claims for the window thread to set,
/// and the bars shown, which answer each item chosen.
pub const MenuBar = struct {
    lock: win32.SRWLOCK = .{},
    /// Claimed until the window thread has set the bar.
    pending: ?PendingAnswer = null,
    claimed: menu.CopiedMenu = .{},
    /// Only the window thread uses these. The bar shown and the one before
    /// it, which answers a choice made from it that Windows reports after
    /// it was replaced.
    shown_bars: [2]ShownBar = .{ .{}, .{} },
    current_bar: u1 = 0,
    /// While the user is in the bar's menus, which a new bar must not
    /// destroy; it is set once they close.
    menus_open: bool = false,
    deferred: bool = false,

    const ShownBar = struct {
        answer_to: ?PendingAnswer = null,
        item_ids: [menu.CopiedMenu.entry_capacity]?zui.MenuItemId = undefined,
        command_count: usize = 0,

        fn itemOfCommand(self: *const ShownBar, command: usize, first_command: usize) ?zui.MenuItemId {
            if (command < first_command or command - first_command >= self.command_count) return null;
            return self.item_ids[command - first_command];
        }
    };

    /// Copies the bar for the window thread to set, refusing one while the
    /// last is still waiting to be set.
    pub fn claim(self: *MenuBar, request: zui.ServiceRequest, window: zui.WindowId, items: []const zui.MenuItem, sink: zui.ServiceSink) zui.ServiceError!void {
        win32.AcquireSRWLockExclusive(&self.lock);
        defer win32.ReleaseSRWLockExclusive(&self.lock);
        if (self.pending != null) return error.Busy;
        try self.claimed.copy(items);
        self.pending = .{ .request = request, .window = window, .sink = sink };
    }

    pub fn release(self: *MenuBar) void {
        win32.AcquireSRWLockExclusive(&self.lock);
        defer win32.ReleaseSRWLockExclusive(&self.lock);
        self.pending = null;
    }

    /// On the window thread: replaces the window's bar with the claimed
    /// one, or removes it for one without items. Deferred while the user
    /// is in the bar's menus, until `endMenuLoop`.
    pub fn set(self: *MenuBar, hwnd: win32.HWND, waker: zui.Waker) void {
        if (self.menus_open) {
            self.deferred = true;
            return;
        }
        win32.AcquireSRWLockExclusive(&self.lock);
        const pending = self.pending orelse {
            win32.ReleaseSRWLockExclusive(&self.lock);
            return;
        };
        win32.ReleaseSRWLockExclusive(&self.lock);

        const replaced = self.replace(hwnd, pending);
        // Before any answer, so a bar set as soon as it arrives is not busy;
        // the copy is not read again until the next bar is claimed.
        self.release();
        if (!replaced) publish(pending, .{ .failed = .unavailable }, waker);
    }

    fn replace(self: *MenuBar, hwnd: win32.HWND, pending: PendingAnswer) bool {
        const next: u1 = self.current_bar +% 1;
        const first_command = Services.first_bar_command[next];
        const bar: ?win32.HMENU = if (self.claimed.entry_count == 0) null else menu.build(&self.claimed, .bar, first_command) orelse return false;
        const replaced = win32.GetMenu(hwnd);
        if (win32.SetMenu(hwnd, bar) == 0) {
            if (bar) |unset| _ = win32.DestroyMenu(unset);
            return false;
        }
        if (replaced) |old| _ = win32.DestroyMenu(old);

        const shown = &self.shown_bars[next];
        shown.* = .{ .answer_to = if (bar == null) null else pending, .command_count = self.claimed.entry_count };
        for (shown.item_ids[0..shown.command_count], 0..) |*id, index| id.* = self.claimed.itemOfCommand(first_command + index, first_command);
        self.current_bar = next;
        return true;
    }

    /// On the window thread, for `WM_COMMAND` from a menu: answers the bar
    /// the command came from.
    pub fn answerCommand(self: *MenuBar, command: usize, waker: zui.Waker) void {
        for (&self.shown_bars, Services.first_bar_command) |*shown, first_command| {
            const chosen = shown.itemOfCommand(command, first_command) orelse continue;
            const answer_to = shown.answer_to orelse return;
            return publish(answer_to, .{ .menu_item_chosen = chosen }, waker);
        }
    }

    /// On the window thread, for `WM_ENTERMENULOOP`: `popup` is false for
    /// the bar's menus.
    pub fn beginMenuLoop(self: *MenuBar, popup: bool) void {
        if (!popup) self.menus_open = true;
    }

    /// On the window thread, for `WM_EXITMENULOOP`: a bar that arrived
    /// while the user was in the old one's menus is set now, through
    /// `set_menu_bar_message`, after any command they chose from the old.
    pub fn endMenuLoop(self: *MenuBar, hwnd: win32.HWND, set_menu_bar_message: win32.UINT) void {
        self.menus_open = false;
        if (!self.deferred) return;
        self.deferred = false;
        _ = win32.PostMessageW(hwnd, set_menu_bar_message, 0, 0);
    }
};

/// What Windows sends the icon's callback message with, under
/// `NOTIFYICON_VERSION_4`: the event, and the icon's id in the high word.
pub fn notifyIconEventLparam(event: win32.UINT) win32.LPARAM {
    return @bitCast(@as(usize, event) | @as(usize, Services.notify_icon_id) << 16);
}

/// For tests: what the host would have handed to the system, kept instead
/// of handing it over, so no browser opens.
pub const ServiceFake = struct {
    opened_url: [Services.url_capacity * 3]u8 = undefined,
    opened_url_len: std.atomic.Value(usize) = .init(0),
    /// The notification-area event the next balloon is answered with, as
    /// though the user had clicked it or let it go; 0 for none.
    scripted_notification_event: std.atomic.Value(win32.UINT) = .init(0),
    /// Each `Shell_NotifyIconW` call the host would have made, by message.
    notify_icon_calls: [notify_icon_messages]std.atomic.Value(u32) = @splat(.init(0)),
    /// The last balloon's text, valid once `notify_icon_calls` counts its
    /// `NIM_MODIFY`.
    balloon_title: Services.NotificationTitle = @splat(0),
    balloon_body: Services.NotificationBody = @splat(0),
    /// The paths the next file dialog answers, each followed by a 0 byte;
    /// none cancels it.
    scripted_paths: [1024]u8 = undefined,
    scripted_paths_len: std.atomic.Value(usize) = .init(0),
    /// Keeps the next file dialog open, dispatching the window's messages as
    /// the dialog's own loop would, until `releaseHeldFileDialog`.
    hold_file_dialog_open: std.atomic.Value(bool) = .init(false),
    file_dialogs_shown: std.atomic.Value(u32) = .init(0),
    /// The last dialog as the shell holds it, read back from the dialog
    /// itself where it has a getter; valid once `file_dialogs_shown` counts it.
    seen_dialog: SeenDialog = .{},
    /// The item the next popup menu answers, as though the user had chosen
    /// it; `no_menu_item` closes it.
    scripted_menu_item: std.atomic.Value(u64) = .init(no_menu_item),
    /// Keeps the next popup menu open, dispatching the window's messages as
    /// the menu's own loop would, until `releaseHeldPopupMenu`.
    hold_popup_menu_open: std.atomic.Value(bool) = .init(false),
    popup_menus_shown: std.atomic.Value(u32) = .init(0),
    /// The last popup menu as Windows holds it, read back from its `HMENU`;
    /// valid once `popup_menus_shown` counts it.
    seen_popup_menu: SeenMenu = .{},

    const notify_icon_messages = win32.NIM_SETVERSION + 1;
    const no_menu_item = std.math.maxInt(u64);

    /// A menu read back item by item, depth first, each submenu's items
    /// after it.
    pub const SeenMenu = struct {
        /// In screen pixels.
        position: win32.POINT = .{},
        items: [item_capacity]Item = undefined,
        item_count: usize = 0,

        pub const item_capacity = 32;

        pub const Item = struct {
            /// 0 for the menu's own items.
            depth: usize,
            label: [64]u16,
            label_len: usize,
            /// `GetMenuState`'s flags: `MF_GRAYED`, `MF_CHECKED`, `MF_SEPARATOR`, `MF_POPUP`.
            state: u32,
            /// What choosing it reports; 0 for a separator or a submenu.
            command: u32,

            pub fn labelUnits(self: *const Item) []const u16 {
                return self.label[0..self.label_len];
            }
        };

        /// Reads `handle` and its submenus, up to `item_capacity` items.
        pub fn read(self: *SeenMenu, handle: win32.HMENU, depth: usize) void {
            const count = win32.GetMenuItemCount(handle);
            var position: c_int = 0;
            while (position < count and self.item_count < item_capacity) : (position += 1) {
                const item = &self.items[self.item_count];
                self.item_count += 1;
                const by_position: win32.UINT = @intCast(position);
                item.depth = depth;
                item.label_len = @intCast(@max(win32.GetMenuStringW(handle, by_position, &item.label, item.label.len, win32.MF_BYPOSITION), 0));
                item.state = win32.GetMenuState(handle, by_position, win32.MF_BYPOSITION);
                item.command = 0;
                if (win32.GetSubMenu(handle, position)) |submenu| {
                    self.read(submenu, depth + 1);
                } else if (item.state & win32.MF_SEPARATOR == 0) {
                    item.command = win32.GetMenuItemID(handle, position);
                }
            }
        }
    };

    /// Answers the next popup menu with `item`, as though the user had
    /// chosen it; null closes it.
    pub fn scriptPopupMenu(self: *ServiceFake, item: ?zui.MenuItemId) void {
        self.scripted_menu_item.store(if (item) |chosen| @intFromEnum(chosen) else no_menu_item, .release);
    }

    pub fn popupMenusShown(self: *const ServiceFake) u32 {
        return self.popup_menus_shown.load(.acquire);
    }

    pub fn releaseHeldPopupMenu(self: *ServiceFake, hwnd: win32.HWND) void {
        self.hold_popup_menu_open.store(false, .release);
        _ = win32.PostMessageW(hwnd, win32.WM_NULL, 0, 0);
    }

    /// What `TrackPopupMenuEx` would have returned had the user chosen the
    /// scripted item.
    fn standInForTrackPopupMenu(self: *ServiceFake, popup: win32.HMENU, copied: *const menu.CopiedMenu, position: win32.POINT, services: *const Services) usize {
        self.seen_popup_menu = .{ .position = position };
        self.seen_popup_menu.read(popup, 0);
        _ = self.popup_menus_shown.fetchAdd(1, .release);
        self.dispatchWhileHeld(&self.hold_popup_menu_open, services);
        if (services.window_closing) return 0;
        const scripted = self.scripted_menu_item.load(.acquire);
        if (scripted == no_menu_item) return 0;
        return copied.commandOfItem(@enumFromInt(scripted), Services.first_popup_menu_command) orelse 0;
    }

    fn dispatchWhileHeld(_: *ServiceFake, held: *const std.atomic.Value(bool), services: *const Services) void {
        while (held.load(.acquire) and !services.window_closing) {
            var message: win32.MSG = undefined;
            if (win32.GetMessageW(&message, null, 0, 0) <= 0) {
                win32.PostQuitMessage(0);
                break;
            }
            _ = win32.TranslateMessage(&message);
            _ = win32.DispatchMessageW(&message);
        }
    }

    pub const SeenDialog = struct {
        options: u32 = 0,
        file_name: [260]u16 = undefined,
        file_name_len: usize = 0,
        folder: [1024]u16 = undefined,
        folder_len: usize = 0,
        filter_count: usize = 0,
        first_filter_name: [64]u16 = undefined,
        first_filter_name_len: usize = 0,
        first_filter_pattern: [64]u16 = undefined,
        first_filter_pattern_len: usize = 0,

        pub fn fileName(self: *const SeenDialog) []const u16 {
            return self.file_name[0..self.file_name_len];
        }

        pub fn folderPath(self: *const SeenDialog) []const u16 {
            return self.folder[0..self.folder_len];
        }

        pub fn firstFilterName(self: *const SeenDialog) []const u16 {
            return self.first_filter_name[0..self.first_filter_name_len];
        }

        pub fn firstFilterPattern(self: *const SeenDialog) []const u16 {
            return self.first_filter_pattern[0..self.first_filter_pattern_len];
        }

        fn copyInto(buffer: []u16, units: []const u16) usize {
            const len = @min(units.len, buffer.len);
            @memcpy(buffer[0..len], units[0..len]);
            return len;
        }
    };

    /// Answers the next file dialog with `paths`, each followed by a 0
    /// byte, as though the user had chosen them; empty cancels it.
    pub fn scriptFileDialog(self: *ServiceFake, paths: []const u8) void {
        const len = @min(paths.len, self.scripted_paths.len);
        @memcpy(self.scripted_paths[0..len], paths[0..len]);
        self.scripted_paths_len.store(len, .release);
    }

    pub fn fileDialogsShown(self: *const ServiceFake) u32 {
        return self.file_dialogs_shown.load(.acquire);
    }

    pub fn releaseHeldFileDialog(self: *ServiceFake, hwnd: win32.HWND) void {
        self.hold_file_dialog_open.store(false, .release);
        _ = win32.PostMessageW(hwnd, win32.WM_NULL, 0, 0);
    }

    fn standInForShow(self: *ServiceFake, dialog: *file_dialog.IFileDialog, services: *const Services, paths: *file_dialog.ChosenPaths) zui.ServiceAnswer.Outcome {
        self.recordDialog(dialog, &services.file_dialog);
        self.dispatchWhileHeld(&self.hold_file_dialog_open, services);
        if (services.window_closing) return .canceled;
        const scripted = self.scripted_paths[0..self.scripted_paths_len.load(.acquire)];
        if (scripted.len == 0) return .canceled;
        var chosen = std.mem.tokenizeScalar(u8, scripted, 0);
        while (chosen.next()) |path| paths.addUtf8(path);
        return .{ .files_chosen = paths.list() };
    }

    fn recordDialog(self: *ServiceFake, dialog: *file_dialog.IFileDialog, copied: *const file_dialog.CopiedDialog) void {
        const seen = &self.seen_dialog;
        seen.* = .{};
        _ = dialog.vtable.GetOptions(dialog, &seen.options);
        var name: ?[*:0]u16 = null;
        if (win32.succeeded(dialog.vtable.GetFileName(dialog, &name))) if (name) |given| {
            defer file_dialog.CoTaskMemFree(@ptrCast(given));
            seen.file_name_len = SeenDialog.copyInto(&seen.file_name, std.mem.span(given));
        };
        var folder: ?*file_dialog.IShellItem = null;
        if (win32.succeeded(dialog.vtable.GetFolder(dialog, &folder))) if (folder) |item| {
            defer item.release();
            if (item.fileSystemPath()) |path| {
                defer file_dialog.CoTaskMemFree(@ptrCast(path));
                seen.folder_len = SeenDialog.copyInto(&seen.folder, std.mem.span(path));
            }
        };
        const filters = copied.filterSpecs();
        seen.filter_count = filters.len;
        if (filters.len > 0) {
            seen.first_filter_name_len = SeenDialog.copyInto(&seen.first_filter_name, std.mem.span(filters[0].pszName));
            seen.first_filter_pattern_len = SeenDialog.copyInto(&seen.first_filter_pattern, std.mem.span(filters[0].pszSpec));
        }
        _ = self.file_dialogs_shown.fetchAdd(1, .release);
    }

    /// The last URL the host would have opened.
    pub fn openedUrl(self: *const ServiceFake) ?[]const u8 {
        const len = self.opened_url_len.load(.acquire);
        return if (len == 0) null else self.opened_url[0..len];
    }

    pub const NotificationOutcome = enum { activated, dismissed };

    /// Answers the next notification shown as though the user had done this.
    pub fn scriptNotification(self: *ServiceFake, outcome: NotificationOutcome) void {
        self.scripted_notification_event.store(switch (outcome) {
            .activated => win32.NIN_BALLOONUSERCLICK,
            .dismissed => win32.NIN_BALLOONTIMEOUT,
        }, .release);
    }

    pub fn notifyIconCalls(self: *const ServiceFake, message: win32.DWORD) u32 {
        return self.notify_icon_calls[message].load(.acquire);
    }

    fn recordOpenedUrl(self: *ServiceFake, url: [:0]const u16) void {
        const len = std.unicode.utf16LeToUtf8(&self.opened_url, url) catch 0;
        self.opened_url_len.store(len, .release);
    }

    fn takeScriptedNotificationEvent(self: *ServiceFake) ?win32.UINT {
        const event = self.scripted_notification_event.swap(0, .acq_rel);
        return if (event == 0) null else event;
    }

    fn recordNotifyIcon(self: *ServiceFake, message: win32.DWORD, data: *const win32.NOTIFYICONDATAW) bool {
        if (message == win32.NIM_MODIFY and data.uFlags & win32.NIF_INFO != 0) {
            self.balloon_title = data.szInfoTitle;
            self.balloon_body = data.szInfo;
        }
        _ = self.notify_icon_calls[message].fetchAdd(1, .release);
        return true;
    }
};

const Converted = struct { len: usize, left_out_bytes: u32 };

/// The clipboard's UTF-16 as UTF-8, a lone surrogate replaced, cut at a
/// character when it does not fit `buffer`.
pub fn utf8FromClipboard(units: []const u16, buffer: []u8) Converted {
    var len: usize = 0;
    var index: usize = 0;
    while (index < units.len) {
        const unit = units[index];
        const pairs_with_next = std.unicode.utf16IsHighSurrogate(unit) and index + 1 < units.len and std.unicode.utf16IsLowSurrogate(units[index + 1]);
        const codepoint: u21 = if (pairs_with_next)
            std.unicode.utf16DecodeSurrogatePair(units[index..][0..2]) catch unreachable
        else if (std.unicode.utf16IsHighSurrogate(unit) or std.unicode.utf16IsLowSurrogate(unit))
            std.unicode.replacement_character
        else
            unit;
        const encoded_len = std.unicode.utf8CodepointSequenceLength(codepoint) catch unreachable;
        if (encoded_len > buffer.len - len) break;
        len += std.unicode.utf8Encode(codepoint, buffer[len..]) catch unreachable;
        index += if (pairs_with_next) 2 else 1;
    }
    return .{ .len = len, .left_out_bytes = std.math.lossyCast(u32, std.unicode.calcWtf8Len(units[index..])) };
}

/// Valid UTF-8 as UTF-16 in `buffer`, ending in a 0, cut at a character
/// when it does not fit.
pub fn utf16CutToFit(utf8: []const u8, buffer: []u16) void {
    var len: usize = 0;
    var codepoints = std.unicode.Utf8View.initUnchecked(utf8).iterator();
    while (codepoints.nextCodepoint()) |codepoint| {
        if (codepoint < 0x10000) {
            if (len + 1 > buffer.len - 1) break;
            buffer[len] = @intCast(codepoint);
            len += 1;
        } else {
            if (len + 2 > buffer.len - 1) break;
            const above_plane_zero = codepoint - 0x10000;
            buffer[len] = @intCast(0xD800 + (above_plane_zero >> 10));
            buffer[len + 1] = @intCast(0xDC00 + (above_plane_zero & 0x3FF));
            len += 2;
        }
    }
    buffer[len] = 0;
}

const NoSource = struct {
    fn publish(_: *anyopaque, _: *const zui.ServiceAnswer) zui.Wake {
        return .already_pending;
    }
};

test "a call made while the window thread has not answered the last of its kind is busy, until it has" {
    var services: Services = .{};
    var nothing: u8 = 0;
    const sink: zui.ServiceSink = .{ .context = &nothing, .publishFn = NoSource.publish };
    try services.claimClipboardRead(.of("first"), sink);
    try std.testing.expectError(error.Busy, services.claimClipboardRead(.of("second"), sink));
    services.releaseClipboardRead();
    try services.claimClipboardRead(.of("second"), sink);

    try services.claimUrl("https://ziglang.org/");
    try std.testing.expectError(error.Busy, services.claimUrl("https://example.com/"));
    services.releaseUrl();
    try services.claimUrl("https://example.com/");
    try std.testing.expectEqualSlices(u16, W("https://example.com/"), std.mem.sliceTo(&services.url, 0));
}

test "a file dialog and a popup menu share one claim, and a menu bar waits for the last to be set" {
    var services: Services = .{};
    var nothing: u8 = 0;
    const sink: zui.ServiceSink = .{ .context = &nothing, .publishFn = NoSource.publish };
    const items = [_]zui.MenuItem{.{ .id = @enumFromInt(1), .label = "Copy" }};
    const second: zui.WindowId = @enumFromInt(1);
    try services.claimPopupMenu(.of("menu"), .main, &items, .{}, sink);
    try std.testing.expectError(error.Busy, services.claimFileDialog(.of("open"), second, .{}, sink));
    try std.testing.expectError(error.Busy, services.claimPopupMenu(.of("menu"), second, &items, .{}, sink));
    services.releasePopupMenu();
    try services.claimFileDialog(.of("open"), second, .{}, sink);
    try std.testing.expectError(error.Busy, services.claimPopupMenu(.of("menu"), .main, &items, .{}, sink));
    services.releaseFileDialog();

    var bars: [2]MenuBar = .{ .{}, .{} };
    try bars[0].claim(.of("bar"), .main, &items, sink);
    try bars[1].claim(.of("bar"), second, &items, sink);
    try services.claimPopupMenu(.of("menu"), .main, &items, .{}, sink);
    try std.testing.expectError(error.Busy, bars[0].claim(.of("bar"), .main, &items, sink));
    bars[0].release();
    try bars[0].claim(.of("bar"), .main, &items, sink);
}

test "the clipboard's text becomes UTF-8 with lone surrogates replaced, cut at a character when it does not fit" {
    const text = [_]u16{ 'h', 0xE9, 0xD83D, 0xDE00, 0xDC00, '!' };
    var buffer: [16]u8 = undefined;
    const whole = utf8FromClipboard(&text, &buffer);
    try std.testing.expectEqualStrings("h\u{E9}\u{1F600}\u{FFFD}!", buffer[0..whole.len]);
    try std.testing.expectEqual(@as(u32, 0), whole.left_out_bytes);

    var small: [5]u8 = undefined;
    const cut = utf8FromClipboard(&text, &small);
    try std.testing.expectEqualStrings("h\u{E9}", small[0..cut.len]);
    try std.testing.expectEqual(@as(u32, 4 + 3 + 1), cut.left_out_bytes);
}

test "a notification's text becomes UTF-16 ending in a 0, cut before a character that does not fit" {
    var buffer: [5]u16 = undefined;
    utf16CutToFit("h\u{E9}", &buffer);
    try std.testing.expectEqualSlices(u16, &.{ 'h', 0xE9, 0 }, buffer[0..3]);
    utf16CutToFit("ab\u{1F600}!", &buffer);
    try std.testing.expectEqualSlices(u16, &.{ 'a', 'b', 0xD83D, 0xDE00, 0 }, &buffer);
    utf16CutToFit("abc\u{1F600}", &buffer);
    try std.testing.expectEqualSlices(u16, &.{ 'a', 'b', 'c', 0 }, buffer[0..4]);
}

test "a notification is refused when its text is not UTF-8, or while the last is still waiting for the window thread" {
    var services: Services = .{};
    var nothing: u8 = 0;
    const sink: zui.ServiceSink = .{ .context = &nothing, .publishFn = NoSource.publish };
    try std.testing.expectError(error.InvalidUtf8, services.claimNotification(.of("saved"), .{ .title = "\xff" }, sink));
    try std.testing.expectError(error.InvalidUtf8, services.claimNotification(.of("saved"), .{ .title = "Saved", .body = "\xc3" }, sink));
    try services.claimNotification(.of("saved"), .{ .title = "Saved " ++ "x" ** 100, .body = "zui" }, sink);
    try std.testing.expectError(error.Busy, services.claimNotification(.of("again"), .{ .title = "Saved" }, sink));
    try std.testing.expectEqual(@as(u16, 0), services.notification_title[services.notification_title.len - 1]);
    try std.testing.expectEqualSlices(u16, W("zui"), std.mem.sliceTo(&services.notification_body, 0));
    services.releaseNotification();
    try services.claimNotification(.of("again"), .{ .title = "Saved" }, sink);
}
