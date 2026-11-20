const std = @import("std");
const zui = @import("zui");
const wayland = @import("wayland.zig");
const linux = std.os.linux;
const Proxy = wayland.Proxy;

/// The seat's `wl_data_device`: the clipboard's selection, written and
/// read as text, and files dropped onto the window, read as a URI list.
/// Every transfer goes through a pipe the host's wait reads or writes as it
/// becomes ready, so neither end of a transfer waits on the other, and the
/// host may be both ends of one. Its buffers are fixed: what does not fit
/// one is left out and counted.
pub const DataDevice = struct {
    io: std.Io,
    device: ?*Proxy = null,

    /// The offer the compositor introduced last, until a selection or a
    /// drag names it.
    introduced_offer: ?Offer = null,
    selection_offer: ?Offer = null,
    dragged_offer: ?Offer = null,
    /// Dropped, and kept until its URI list has been read.
    dropped_offer: ?Offer = null,

    source: ?*Proxy = null,
    /// No selection has been named since `source` was set, so the
    /// clipboard holds the source's text.
    source_is_newest_selection: bool = false,
    source_text: [clipboard_text_capacity]u8 = undefined,
    source_len: usize = 0,
    sends: [send_capacity]Send = @splat(.{}),

    clipboard_read: ?ClipboardRead = null,
    clipboard_text: [clipboard_text_capacity]u8 = undefined,
    drop_read: ?Transfer = null,
    uri_list: [uri_list_capacity]u8 = undefined,

    /// UTF-8 bytes of text the clipboard is given, or a read answers
    /// with; a read counts the rest as left out.
    pub const clipboard_text_capacity = 64 * 1024;
    /// Bytes of a drop's URI list; whole lines past it are left out.
    pub const uri_list_capacity = 32 * 1024;
    /// Readers the clipboard's text is written to at once; one past them
    /// is closed unanswered.
    pub const send_capacity = 4;
    /// How long a transfer may take before it is given up.
    pub const transfer_timeout_ns = 2 * std.time.ns_per_s;

    /// The pipes `descriptors` waits on, in its order.
    pub const descriptor_count = 2 + send_capacity;

    const uri_list_mime = "text/uri-list";

    /// The text types a selection may offer, the one preferred first.
    const TextMime = enum {
        utf8,
        utf8_string,
        plain,

        const names = [_][:0]const u8{ "text/plain;charset=utf-8", "UTF8_STRING", "text/plain" };

        fn name(self: TextMime) [:0]const u8 {
            return names[@intFromEnum(self)];
        }

        fn of(mime: []const u8) ?TextMime {
            for (names, 0..) |known, index| if (std.mem.eql(u8, mime, known)) return @enumFromInt(index);
            return null;
        }
    };

    const Offer = struct {
        proxy: *Proxy,
        text_mime: ?TextMime = null,
        has_uri_list: bool = false,
        /// The drag-and-drop action the compositor chose; 0 for none.
        action: u32 = 0,

        fn learn(self: *Offer, mime: []const u8) void {
            if (TextMime.of(mime)) |text_mime| {
                if (self.text_mime == null or @intFromEnum(text_mime) < @intFromEnum(self.text_mime.?)) self.text_mime = text_mime;
            }
            if (std.mem.eql(u8, mime, uri_list_mime)) self.has_uri_list = true;
        }
    };

    const ClipboardRead = struct {
        request: zui.ServiceRequest,
        sink: zui.ServiceSink,
        waker: zui.Waker,
        transfer: Transfer,
    };

    /// A pipe read until its writer closes it.
    const Transfer = struct {
        fd: i32,
        len: usize = 0,
        left_out_bytes: usize = 0,
        deadline: zui.Instant,

        /// True once the writer has closed the pipe or it failed.
        fn readAvailable(self: *Transfer, buffer: []u8) bool {
            var overflow: [4096]u8 = undefined;
            while (true) {
                const into = if (self.len < buffer.len) buffer[self.len..] else &overflow;
                const result = linux.read(self.fd, into.ptr, into.len);
                switch (linux.errno(result)) {
                    .SUCCESS => {
                        if (result == 0) return true;
                        if (self.len < buffer.len) self.len += result else self.left_out_bytes += result;
                    },
                    .INTR => {},
                    .AGAIN => return false,
                    else => return true,
                }
            }
        }

        fn close(self: *Transfer) void {
            _ = linux.close(self.fd);
        }
    };

    /// The source's text written to one reader.
    const Send = struct {
        fd: i32 = -1,
        written: usize = 0,
        deadline: zui.Instant = .{ .nanoseconds = 0 },

        fn close(self: *Send) void {
            _ = linux.close(self.fd);
            self.* = .{};
        }
    };

    fn now(self: *const DataDevice) zui.Instant {
        return .fromTimestamp(std.Io.Timestamp.now(self.io, .awake));
    }

    /// Closes every transfer in flight and destroys the device's objects.
    pub fn deinit(self: *DataDevice) void {
        if (self.clipboard_read) |*read| read.transfer.close();
        if (self.drop_read) |*read| read.close();
        for (&self.sends) |*send| if (send.fd >= 0) send.close();
        for ([_]?Offer{ self.introduced_offer, self.selection_offer, self.dragged_offer }) |offer| if (offer) |held| destroyOffer(held.proxy);
        if (self.dropped_offer) |offer| destroyOffer(offer.proxy);
        if (self.source) |source| wayland.destroy(source, wayland.data_source_destroy);
        if (self.device) |device| {
            if (wayland.wl_proxy_get_version(device) >= 2) wayland.destroy(device, wayland.data_device_release) else wayland.wl_proxy_destroy(device);
        }
        self.* = .{ .io = self.io };
    }

    /// Makes `text` the clipboard's selection, offered as UTF-8 text, with
    /// the serial of the input event that asked for it. Readers already
    /// being written the last text are closed with what they have.
    pub fn writeSelection(self: *DataDevice, manager: ?*Proxy, text: []const u8, serial: u32) zui.ServiceError!void {
        if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
        if (text.len > clipboard_text_capacity) return error.TooLarge;
        const device = self.device orelse return error.Unavailable;
        const source_manager = manager orelse return error.Unavailable;
        const source = wayland.create(source_manager, wayland.data_device_manager_create_data_source, &wayland.wl_data_source_interface, wayland.wl_proxy_get_version(source_manager), .{wayland.no_id}) orelse return error.Unavailable;
        for (&self.sends) |*send| if (send.fd >= 0) send.close();
        if (self.source) |old| wayland.destroy(old, wayland.data_source_destroy);
        @memcpy(self.source_text[0..text.len], text);
        self.source_len = text.len;
        self.source = source;
        self.source_is_newest_selection = true;
        wayland.addListener(source, &source_listener, self);
        for (TextMime.names) |mime| wayland.send(source, wayland.data_source_offer, .{mime.ptr});
        wayland.send(device, wayland.data_device_set_selection, .{ source, serial });
    }

    /// Reads the clipboard's text and publishes it into `sink` once its
    /// owner has written it all: `""` when the clipboard holds no text, and
    /// `.failed` when its owner takes longer than `transfer_timeout_ns`.
    pub fn readSelection(self: *DataDevice, request: zui.ServiceRequest, sink: zui.ServiceSink, waker: zui.Waker) zui.ServiceError!void {
        if (self.clipboard_read != null) return error.Busy;
        if (self.source != null and self.source_is_newest_selection) {
            return publishClipboardText(request, sink, waker, self.source_text[0..self.source_len], 0);
        }
        const offer = self.selection_offer orelse return publishClipboardText(request, sink, waker, "", 0);
        const text_mime = offer.text_mime orelse return publishClipboardText(request, sink, waker, "", 0);
        const read_fd = receiveThroughPipe(offer.proxy, text_mime.name()) orelse return error.Unavailable;
        self.receiveClipboardFrom(request, sink, waker, read_fd);
    }

    /// Reads the clipboard's text from `read_fd`, which is then the
    /// device's to close.
    pub fn receiveClipboardFrom(self: *DataDevice, request: zui.ServiceRequest, sink: zui.ServiceSink, waker: zui.Waker, read_fd: i32) void {
        self.clipboard_read = .{ .request = request, .sink = sink, .waker = waker, .transfer = .{ .fd = read_fd, .deadline = self.now().addNanoseconds(transfer_timeout_ns) } };
    }

    /// Writes the source's text to a reader the compositor hands over,
    /// closing `fd` once it is written.
    pub fn sendSelectionTo(self: *DataDevice, fd: i32) void {
        const slot = for (&self.sends) |*send| {
            if (send.fd < 0) break send;
        } else {
            _ = linux.close(fd);
            return;
        };
        const flags = linux.fcntl(fd, linux.F.GETFL, 0);
        _ = linux.fcntl(fd, linux.F.SETFL, flags | nonblocking);
        slot.* = .{ .fd = fd, .deadline = self.now().addNanoseconds(transfer_timeout_ns) };
        self.writeAvailable(slot);
    }

    fn writeAvailable(self: *DataDevice, send: *Send) void {
        while (send.written < self.source_len) {
            const remaining = self.source_text[send.written..self.source_len];
            const result = writeWithoutPipeSignal(send.fd, remaining);
            switch (linux.errno(result)) {
                .SUCCESS => send.written += result,
                .INTR => {},
                .AGAIN => return,
                else => break,
            }
        }
        send.close();
    }

    /// Starts reading a drop's URI list from `read_fd`, which is then the
    /// device's to close.
    pub fn receiveDropFrom(self: *DataDevice, read_fd: i32) void {
        if (self.drop_read) |*read| read.close();
        self.drop_read = .{ .fd = read_fd, .deadline = self.now().addNanoseconds(transfer_timeout_ns) };
    }

    /// The pipes in flight, each negative while unused, which `poll`
    /// ignores.
    pub fn descriptors(self: *const DataDevice) [descriptor_count]linux.pollfd {
        var polled: [descriptor_count]linux.pollfd = undefined;
        polled[0] = .{ .fd = if (self.clipboard_read) |read| read.transfer.fd else -1, .events = linux.POLL.IN, .revents = 0 };
        polled[1] = .{ .fd = if (self.drop_read) |read| read.fd else -1, .events = linux.POLL.IN, .revents = 0 };
        for (self.sends, polled[2..]) |send, *descriptor| descriptor.* = .{ .fd = send.fd, .events = linux.POLL.OUT, .revents = 0 };
        return polled;
    }

    /// When the transfer in flight that started first is given up.
    pub fn nextDeadline(self: *const DataDevice) ?zui.Instant {
        var earliest: ?zui.Instant = null;
        if (self.clipboard_read) |read| earliest = earlier(earliest, read.transfer.deadline);
        if (self.drop_read) |read| earliest = earlier(earliest, read.deadline);
        for (self.sends) |send| if (send.fd >= 0) {
            earliest = earlier(earliest, send.deadline);
        };
        return earliest;
    }

    fn earlier(first: ?zui.Instant, second: zui.Instant) zui.Instant {
        const one = first orelse return second;
        return if (second.isBefore(one)) second else one;
    }

    /// A drop whose URI list has been read whole.
    pub const ReceivedDrop = struct {
        uri_list: []const u8,
        left_out_bytes: u32,
    };

    /// Moves each transfer `polled` (as `descriptors` gave it, after a
    /// poll) found ready, gives up those past their deadline, and returns
    /// a drop whose URI list is complete.
    pub fn transfer(self: *DataDevice, polled: []const linux.pollfd) ?ReceivedDrop {
        const now_instant = self.now();
        if (self.clipboard_read) |*read| {
            const past_deadline = !now_instant.isBefore(read.transfer.deadline);
            if (polled[0].revents != 0 and read.transfer.readAvailable(&self.clipboard_text)) {
                self.answerClipboardRead();
            } else if (past_deadline) {
                const pending = read.*;
                read.transfer.close();
                self.clipboard_read = null;
                const answer: zui.ServiceAnswer = .{ .request = pending.request, .outcome = .{ .failed = .unavailable } };
                pending.waker.wakeIf(pending.sink.publish(&answer));
            }
        }
        for (&self.sends, polled[2..]) |*send, descriptor| if (send.fd >= 0) {
            if (descriptor.revents != 0) self.writeAvailable(send) else if (!now_instant.isBefore(send.deadline)) send.close();
        };
        const read = if (self.drop_read) |*read| read else return null;
        if (!(polled[1].revents != 0 and read.readAvailable(&self.uri_list))) {
            if (!now_instant.isBefore(read.deadline)) self.endDrop();
            return null;
        }
        var whole_lines = self.uri_list[0..read.len];
        var left_out_bytes = read.left_out_bytes;
        if (left_out_bytes > 0) {
            const cut_line_start = if (std.mem.lastIndexOfScalar(u8, whole_lines, '\n')) |newline| newline + 1 else 0;
            left_out_bytes += whole_lines.len - cut_line_start;
            whole_lines = whole_lines[0..cut_line_start];
        }
        self.endDrop();
        return .{ .uri_list = whole_lines, .left_out_bytes = std.math.lossyCast(u32, left_out_bytes) };
    }

    fn answerClipboardRead(self: *DataDevice) void {
        const pending = self.clipboard_read.?;
        _ = linux.close(pending.transfer.fd);
        // Before the answer, so a read made as soon as it arrives is not
        // busy; the text stays put until the next read finishes.
        self.clipboard_read = null;
        const received = self.clipboard_text[0..pending.transfer.len];
        const len = if (pending.transfer.left_out_bytes > 0) wholeCharacters(received) else received.len;
        const left_out_bytes = pending.transfer.left_out_bytes + (received.len - len);
        publishClipboardText(pending.request, pending.sink, pending.waker, self.clipboard_text[0..len], left_out_bytes);
    }

    fn publishClipboardText(request: zui.ServiceRequest, sink: zui.ServiceSink, waker: zui.Waker, text: []const u8, left_out_bytes: usize) void {
        const answer: zui.ServiceAnswer = .{ .request = request, .outcome = .{ .clipboard_text = text }, .left_out_bytes = std.math.lossyCast(u32, left_out_bytes) };
        waker.wakeIf(sink.publish(&answer));
    }

    fn endDrop(self: *DataDevice) void {
        if (self.drop_read) |*read| read.close();
        self.drop_read = null;
        if (self.dropped_offer) |offer| {
            // Finishing a drop no action was chosen for is a protocol error.
            if (offer.action != 0 and wayland.wl_proxy_get_version(offer.proxy) >= 3) wayland.send(offer.proxy, wayland.data_offer_finish, .{});
            destroyOffer(offer.proxy);
        }
        self.dropped_offer = null;
    }

    // What the compositor reports of offers.

    /// An offer whose types follow, which a selection or a drag then
    /// names; one neither names is destroyed at the next.
    pub fn onDataOffer(self: *DataDevice, offer: *Proxy) void {
        if (self.introduced_offer) |unnamed| destroyOffer(unnamed.proxy);
        self.introduced_offer = .{ .proxy = offer };
        wayland.addListener(offer, &offer_listener, self);
    }

    fn takeIntroduced(self: *DataDevice, offer: ?*Proxy) ?Offer {
        const proxy = offer orelse return null;
        const introduced = self.introduced_offer orelse return null;
        if (introduced.proxy != proxy) return null;
        self.introduced_offer = null;
        return introduced;
    }

    /// The clipboard's selection changed, to nothing for null.
    pub fn onSelection(self: *DataDevice, offer: ?*Proxy) void {
        if (self.selection_offer) |old| destroyOffer(old.proxy);
        self.selection_offer = self.takeIntroduced(offer);
        self.source_is_newest_selection = false;
    }

    /// Accepts the drag when it offers a URI list, for copying.
    pub fn onDragEnter(self: *DataDevice, serial: u32, offer: ?*Proxy) void {
        if (self.dragged_offer) |old| destroyOffer(old.proxy);
        self.dragged_offer = self.takeIntroduced(offer);
        const dragged = self.dragged_offer orelse return;
        const accepted: ?[*:0]const u8 = if (dragged.has_uri_list) uri_list_mime else null;
        wayland.send(dragged.proxy, wayland.data_offer_accept, .{ serial, accepted });
        if (dragged.has_uri_list and wayland.wl_proxy_get_version(dragged.proxy) >= 3) {
            const copy = wayland.data_device_manager_dnd_action_copy;
            wayland.send(dragged.proxy, wayland.data_offer_set_actions, .{ @as(u32, copy), @as(u32, copy) });
        }
    }

    /// The drag left without dropping.
    pub fn onDragLeave(self: *DataDevice) void {
        if (self.dragged_offer) |dragged| destroyOffer(dragged.proxy);
        self.dragged_offer = null;
    }

    /// Asks for the dropped offer's URI list, which `transfer` returns
    /// once it has all arrived.
    pub fn onDrop(self: *DataDevice) void {
        const dragged = self.dragged_offer orelse return;
        self.dragged_offer = null;
        if (!dragged.has_uri_list) return destroyOffer(dragged.proxy);
        const read_fd = receiveThroughPipe(dragged.proxy, uri_list_mime) orelse return destroyOffer(dragged.proxy);
        self.endDrop();
        self.dropped_offer = dragged;
        self.receiveDropFrom(read_fd);
    }

    fn onOfferAction(self: *DataDevice, offer: *Proxy, action: u32) void {
        if (self.dragged_offer) |*dragged| if (dragged.proxy == offer) {
            dragged.action = action;
        };
    }

    fn onOfferMime(self: *DataDevice, offer: *Proxy, mime: []const u8) void {
        inline for (.{ &self.introduced_offer, &self.selection_offer, &self.dragged_offer }) |slot| {
            if (slot.*) |*held| if (held.proxy == offer) held.learn(mime);
        }
    }

    fn onSourceCancelled(self: *DataDevice, source: *Proxy) void {
        wayland.destroy(source, wayland.data_source_destroy);
        if (self.source == source) {
            self.source = null;
            self.source_is_newest_selection = false;
        }
    }

    fn destroyOffer(offer: *Proxy) void {
        wayland.destroy(offer, wayland.data_offer_destroy);
    }

    /// Asks the offer's owner to write `mime` into a pipe, and returns the
    /// pipe's end to read, which does not block.
    fn receiveThroughPipe(offer: *Proxy, mime: [:0]const u8) ?i32 {
        var ends: [2]i32 = undefined;
        if (linux.errno(linux.pipe2(&ends, .{ .CLOEXEC = true })) != .SUCCESS) return null;
        _ = linux.fcntl(ends[0], linux.F.SETFL, nonblocking);
        // libwayland sends a duplicate of the descriptor, so ours closes now.
        wayland.send(offer, wayland.data_offer_receive, .{ mime.ptr, ends[1] });
        _ = linux.close(ends[1]);
        return ends[0];
    }

    fn deviceFrom(data: ?*anyopaque) *DataDevice {
        return @ptrCast(@alignCast(data.?));
    }

    const offer_listener: wayland.DataOfferListener = .{
        .offer = struct {
            fn offer(data: ?*anyopaque, proxy: ?*Proxy, mime: [*:0]const u8) callconv(.c) void {
                deviceFrom(data).onOfferMime(proxy.?, std.mem.span(mime));
            }
        }.offer,
        .source_actions = ignoreAction,
        .action = struct {
            fn action(data: ?*anyopaque, proxy: ?*Proxy, chosen: u32) callconv(.c) void {
                deviceFrom(data).onOfferAction(proxy.?, chosen);
            }
        }.action,
    };

    const source_listener: wayland.DataSourceListener = .{
        .target = struct {
            fn target(_: ?*anyopaque, _: ?*Proxy, _: ?[*:0]const u8) callconv(.c) void {}
        }.target,
        .send = struct {
            fn send(data: ?*anyopaque, _: ?*Proxy, _: [*:0]const u8, fd: i32) callconv(.c) void {
                deviceFrom(data).sendSelectionTo(fd);
            }
        }.send,
        .cancelled = struct {
            fn cancelled(data: ?*anyopaque, source: ?*Proxy) callconv(.c) void {
                deviceFrom(data).onSourceCancelled(source.?);
            }
        }.cancelled,
        .dnd_drop_performed = ignoreSourceEvent,
        .dnd_finished = ignoreSourceEvent,
        .action = ignoreAction,
    };

    fn ignoreAction(_: ?*anyopaque, _: ?*Proxy, _: u32) callconv(.c) void {}
    fn ignoreSourceEvent(_: ?*anyopaque, _: ?*Proxy) callconv(.c) void {}
};

const nonblocking: usize = 1 << @bitOffsetOf(linux.O, "NONBLOCK");

/// Writes to a pipe whose reader may have closed it without raising
/// SIGPIPE, which would end the process: it is blocked around the write,
/// and the one the write raised is taken.
fn writeWithoutPipeSignal(fd: i32, bytes: []const u8) usize {
    var pipe_signal = std.posix.sigemptyset();
    std.posix.sigaddset(&pipe_signal, .PIPE);
    var previous_mask: std.posix.sigset_t = undefined;
    std.posix.sigprocmask(std.posix.SIG.BLOCK, &pipe_signal, &previous_mask);
    defer std.posix.sigprocmask(std.posix.SIG.SETMASK, &previous_mask, null);
    const result = linux.write(fd, bytes.ptr, bytes.len);
    if (linux.errno(result) == .PIPE and !std.posix.sigismember(&previous_mask, .PIPE)) {
        var taken: c_int = 0;
        _ = std.c.sigwait(&pipe_signal, &taken);
    }
    return result;
}

/// Room for the paths a URI list names, each followed by a 0 byte.
pub const DecodedPaths = struct {
    len: usize,
    left_out_bytes: u32,
};

/// The local paths a `text/uri-list` names, each followed by a 0 byte,
/// into `buffer`: `file:` URIs on no host, `localhost` or this machine's,
/// percent-decoded. Comments, other schemes and other hosts are skipped;
/// a path that does not fit whole is left out and counted.
pub fn pathsFromUriList(uri_list: []const u8, buffer: []u8) DecodedPaths {
    var hostname_buffer: linux.utsname = undefined;
    const this_host: []const u8 = if (linux.errno(linux.uname(&hostname_buffer)) == .SUCCESS) std.mem.sliceTo(&hostname_buffer.nodename, 0) else "";
    var decoded: DecodedPaths = .{ .len = 0, .left_out_bytes = 0 };
    var lines = std.mem.splitScalar(u8, uri_list, '\n');
    while (lines.next()) |line| {
        const uri = std.mem.trim(u8, line, " \t\r");
        if (uri.len == 0 or uri[0] == '#') continue;
        const encoded_path = localFilePath(uri, this_host) orelse continue;
        const room = buffer[decoded.len..];
        const path_len = percentDecode(encoded_path, room) catch |err| switch (err) {
            error.HoldsZeroByte => continue,
            error.NoRoom => {
                decoded.left_out_bytes +|= std.math.lossyCast(u32, encoded_path.len + 1);
                continue;
            },
        };
        room[path_len] = 0;
        decoded.len += path_len + 1;
    }
    return decoded;
}

/// The still-encoded path of a `file:` URI on this machine.
fn localFilePath(uri: []const u8, this_host: []const u8) ?[]const u8 {
    const scheme = "file:";
    if (uri.len < scheme.len or !std.ascii.eqlIgnoreCase(uri[0..scheme.len], scheme)) return null;
    const after_scheme = uri[scheme.len..];
    if (!std.mem.startsWith(u8, after_scheme, "//")) return if (std.mem.startsWith(u8, after_scheme, "/")) after_scheme else null;
    const authority_and_path = after_scheme[2..];
    const path_start = std.mem.indexOfScalar(u8, authority_and_path, '/') orelse return null;
    const host = authority_and_path[0..path_start];
    const local = host.len == 0 or std.ascii.eqlIgnoreCase(host, "localhost") or std.mem.eql(u8, host, this_host);
    return if (local) authority_and_path[path_start..] else null;
}

/// Decodes `%XX` escapes into `buffer`, leaving a `%` that starts none as
/// it is, with room left after it for a 0 byte. No path holds a 0 byte.
fn percentDecode(encoded: []const u8, buffer: []u8) error{ NoRoom, HoldsZeroByte }!usize {
    var len: usize = 0;
    var index: usize = 0;
    while (index < encoded.len) : (len += 1) {
        if (len + 1 >= buffer.len) return error.NoRoom;
        var byte = encoded[index];
        index += 1;
        if (byte == '%' and index + 2 <= encoded.len) {
            if (std.fmt.parseInt(u8, encoded[index..][0..2], 16)) |escaped| {
                byte = escaped;
                index += 2;
            } else |_| {}
        }
        if (byte == 0) return error.HoldsZeroByte;
        buffer[len] = byte;
    }
    return len;
}

/// How many bytes of `text` hold whole UTF-8 characters, when its end may
/// cut one short.
fn wholeCharacters(text: []const u8) usize {
    var start = text.len;
    while (start > 0) {
        start -= 1;
        if (text[start] & 0xC0 != 0x80) break;
    }
    const expected = std.unicode.utf8ByteSequenceLength(if (text.len > 0) text[start] else return 0) catch return text.len;
    return if (start + expected > text.len) start else text.len;
}

fn pathsOf(buffer: []const u8) std.mem.TokenIterator(u8, .scalar) {
    return std.mem.tokenizeScalar(u8, buffer, 0);
}

test "a URI list's local file URIs become their paths, decoded, and the rest is skipped" {
    const uri_list = "# dragged from a file manager\r\n" ++
        "file:///home/user/My%20Theme.zon\r\n" ++
        "file:///tmp/with space.txt\r\n" ++
        "https://ziglang.org/\r\n" ++
        "file://elsewhere.example/share/remote.txt\r\n" ++
        "file://localhost/etc/hosts\r\n" ++
        "file:/srv/one%2Fslash%zz\n" ++
        "file:///nul%00byte\r\n";
    var buffer: [256]u8 = undefined;
    const decoded = pathsFromUriList(uri_list, &buffer);
    var paths = pathsOf(buffer[0..decoded.len]);
    for ([_][]const u8{ "/home/user/My Theme.zon", "/tmp/with space.txt", "/etc/hosts", "/srv/one/slash%zz" }) |expected| {
        try std.testing.expectEqualStrings(expected, paths.next().?);
    }
    try std.testing.expectEqual(@as(?[]const u8, null), paths.next());
    try std.testing.expectEqual(@as(u32, 0), decoded.left_out_bytes);
}

test "a path that does not fit whole is left out and counted, and those after it still fit" {
    var buffer: [16]u8 = undefined;
    const decoded = pathsFromUriList("file:///a/long/path/name\r\nfile:///short\r\n", &buffer);
    try std.testing.expectEqualStrings("/short\x00", buffer[0..decoded.len]);
    try std.testing.expectEqual(@as(u32, "/a/long/path/name".len + 1), decoded.left_out_bytes);
}

test "text cut short keeps only its whole characters" {
    const check_mark = "\u{2713}";
    try std.testing.expectEqual(@as(usize, 2), wholeCharacters("ab" ++ check_mark[0..2]));
    try std.testing.expectEqual(@as(usize, 5), wholeCharacters("ab" ++ check_mark));
    try std.testing.expectEqual(@as(usize, 0), wholeCharacters(""));
}
