const std = @import("std");
const zui = @import("zui");
const win32 = @import("win32.zig");

const W = std.unicode.utf8ToUtf16LeStringLiteral;

/// What the host's services hand to the window thread, which answers every
/// call, so answers never come from two threads at once. A call claims its
/// slot under `lock`, and the window thread frees it once it has answered.
pub const Services = struct {
    lock: win32.SRWLOCK = .{},
    clipboard_read: ?PendingAnswer = null,
    url_pending: bool = false,
    url: [url_capacity:0]u16 = undefined,
    /// Only the window thread uses it.
    clipboard_text: [clipboard_text_capacity]u8 = undefined,
    /// Hands nothing to the system when set.
    fake: ?*ServiceFake = null,

    /// `INTERNET_MAX_URL_LENGTH`, in UTF-16 units.
    pub const url_capacity = 2083;
    /// UTF-8 bytes of the clipboard's text a read answers with; the rest is
    /// counted as left out.
    pub const clipboard_text_capacity = 64 * 1024;

    const PendingAnswer = struct { request: zui.ServiceRequest, sink: zui.ServiceSink };

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

    /// On the window thread, which owns `hwnd`, as the clipboard asks of
    /// whoever opens it.
    pub fn answerClipboardRead(self: *Services, hwnd: win32.HWND, waker: zui.Waker) void {
        win32.AcquireSRWLockExclusive(&self.lock);
        const pending = self.clipboard_read orelse {
            win32.ReleaseSRWLockExclusive(&self.lock);
            return;
        };
        win32.ReleaseSRWLockExclusive(&self.lock);
        defer self.releaseClipboardRead();

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
};

/// For tests: what the host would have handed to the system, kept instead
/// of handing it over, so no browser opens.
pub const ServiceFake = struct {
    opened_url: [Services.url_capacity * 3]u8 = undefined,
    opened_url_len: std.atomic.Value(usize) = .init(0),

    /// The last URL the host would have opened.
    pub fn openedUrl(self: *const ServiceFake) ?[]const u8 {
        const len = self.opened_url_len.load(.acquire);
        return if (len == 0) null else self.opened_url[0..len];
    }

    fn recordOpenedUrl(self: *ServiceFake, url: [:0]const u16) void {
        const len = std.unicode.utf16LeToUtf8(&self.opened_url, url) catch 0;
        self.opened_url_len.store(len, .release);
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
