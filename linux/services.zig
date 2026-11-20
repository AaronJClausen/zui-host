const std = @import("std");
const zui = @import("zui");
const dbus = @import("dbus.zig");
const linux = std.os.linux;

const bus_service: dbus.Header = .{ .type = .method_call, .destination = "org.freedesktop.DBus", .path = "/org/freedesktop/DBus", .interface = "org.freedesktop.DBus" };

const notification_daemon = struct {
    const service = "org.freedesktop.Notifications";
    const path = "/org/freedesktop/Notifications";
    const interface = service;
    const signals_rule = "type='signal',sender='" ++ service ++ "',interface='" ++ interface ++ "',path='" ++ path ++ "'";
    const default_action = "default";
    const default_action_label = "Open";
    const application_name = "zui";
    const daemon_chooses_timeout: i32 = -1;
};

const portal = struct {
    const service = "org.freedesktop.portal.Desktop";
    const path = "/org/freedesktop/portal/desktop";
    const file_chooser = "org.freedesktop.portal.FileChooser";
    const open_uri = "org.freedesktop.portal.OpenURI";
    const request_interface = "org.freedesktop.portal.Request";
    const request_path_prefix = path ++ "/request/";
    const response_rule_start = "type='signal',sender='" ++ service ++ "',interface='" ++ request_interface ++ "',member='Response',path='";
    /// The dialog is not attached to the window, which would take
    /// exporting the window's surface to the portal.
    const no_parent_window = "";
    const glob_pattern: u32 = 0;
    const response_chosen: u32 = 0;
    const response_canceled: u32 = 1;
    const response_ended_otherwise: u32 = 2;
};

/// The host's own connection to the session bus for its services, which
/// holds a file dialog's answer of up to 64 KiB.
pub const Connection = dbus.ConnectionOf(64 * 1024);

/// The state of the host's services on the polling thread, which both
/// makes every call and publishes every answer: a call only sends, and
/// what the bus answers is read and published by the poll or the wait.
pub const Services = struct {
    bus: Connection = .{},
    /// The name the bus gave `bus`, which names the portal's request
    /// objects; empty until the bus has said it.
    unique_name: Text(name_capacity) = .{},
    /// The notification showing, or waiting for the daemon's number for it.
    notification: ?ShownNotification = null,
    /// The notification the last one replaced, answered by the next poll.
    replaced_notification: ?PendingAnswer = null,
    notification_signals_watched: bool = false,
    file_dialog: ?OpenDialog = null,
    chosen_paths: [chosen_paths_capacity]u8 = undefined,
    next_handle_token: u32 = 1,
    message_body: [message_body_capacity]u8 = undefined,
    /// Hands nothing to the bus when set.
    fake: ?*ServiceFake = null,

    /// UTF-8 bytes of a URL `open` hands over.
    pub const url_capacity = 4 * 1024;
    /// UTF-8 bytes of a notification's title and body; the rest is cut at
    /// a character.
    pub const notification_title_capacity = 256;
    pub const notification_body_capacity = 2 * 1024;
    /// UTF-8 bytes of the paths a file dialog answers with; paths past it
    /// are counted as left out.
    pub const chosen_paths_capacity = 32 * 1024;
    /// Filters a file dialog takes; more is `error.TooLarge`.
    pub const filter_capacity = 16;
    /// The bytes of a call's arguments: a file dialog whose strings and
    /// filters do not fit is `error.TooLarge`.
    pub const message_body_capacity = 12 * 1024;
    /// D-Bus's longest name.
    const name_capacity = 255;
    const request_path_capacity = portal.request_path_prefix.len + name_capacity + 1 + handle_token_capacity;
    const handle_token_capacity = "zui".len + 10;
    /// How long a call waits for room in the bus's socket, which a bus
    /// that reads its messages always has.
    const send_timeout_ns = 100 * std.time.ns_per_ms;

    comptime {
        std.debug.assert(message_body_capacity + 1024 <= Connection.send_capacity);
        std.debug.assert(url_capacity + 256 <= message_body_capacity);
    }

    const ShownNotification = struct {
        answer_to: PendingAnswer,
        /// Until the daemon has numbered it, a second notification is busy.
        awaiting_daemon: bool,
        /// The `Notify` call the daemon is to answer.
        call_serial: u32 = 0,
        /// The daemon's number for it once it has answered, which its
        /// signals name.
        id: u32 = 0,
        daemon_name: Text(name_capacity) = .{},
    };

    const OpenDialog = struct {
        answer_to: PendingAnswer,
        /// Until the portal has answered the call, whose reply names its
        /// connection and the request it made.
        awaiting_portal: bool,
        call_serial: u32 = 0,
        request_path: Text(request_path_capacity) = .{},
        portal_name: Text(name_capacity) = .{},
    };

    /// Connects to the session bus at `address` and learns the name it
    /// gives the connection, giving up at `deadline`. Without a bus, every
    /// call is `error.Unavailable`.
    pub fn open(self: *Services, io: std.Io, address: []const u8, deadline: zui.Instant) void {
        self.connect(io, address, deadline) catch self.bus.close();
    }

    fn connect(self: *Services, io: std.Io, address: []const u8, deadline: zui.Instant) !void {
        try self.bus.open(io, address, deadline);
        var hello = bus_service;
        hello.member = "Hello";
        var watch: HelloWatch = .{ .serial = try self.bus.send(io, hello, "", deadline), .services = self };
        while (self.unique_name.len == 0) {
            if (watch.refused or !self.bus.waitFor(io, linux.POLL.IN, deadline)) return error.BusUnavailable;
            try self.bus.receive(&watch);
        }
    }

    const HelloWatch = struct {
        serial: u32,
        services: *Services,
        refused: bool = false,

        pub fn onMessage(self: *HelloWatch, message: dbus.Message) void {
            const header = message.header;
            if (header.reply_serial != self.serial) return;
            var body = message.body;
            const name = if (header.type == .method_return and std.mem.eql(u8, header.signature, "s")) body.string() catch "" else "";
            if (!self.services.unique_name.set(name) or name.len == 0) self.refused = true;
        }
    };

    /// Closes the dialog still open and the notification still showing,
    /// neither answered, and the connection.
    pub fn close(self: *Services, io: std.Io) void {
        if (self.bus.isOpen()) {
            if (self.file_dialog) |*open_dialog| {
                _ = self.bus.send(io, .{
                    .type = .method_call,
                    .flags = .{ .no_reply_expected = true },
                    .destination = portal.service,
                    .path = open_dialog.request_path.slice(),
                    .interface = portal.request_interface,
                    .member = "Close",
                }, "", self.sendDeadline(io)) catch {};
            }
            if (self.notification) |shown| if (!shown.awaiting_daemon) {
                var body: dbus.Writer = .{ .buffer = &self.message_body };
                body.uint32(shown.id);
                _ = self.bus.send(io, .{
                    .type = .method_call,
                    .flags = .{ .no_reply_expected = true },
                    .destination = notification_daemon.service,
                    .path = notification_daemon.path,
                    .interface = notification_daemon.interface,
                    .member = "CloseNotification",
                    .signature = "u",
                }, body.buffer[0..body.len], self.sendDeadline(io)) catch {};
            };
        }
        self.bus.close();
        self.notification = null;
        self.replaced_notification = null;
        self.file_dialog = null;
    }

    /// The socket to wait on beside the display; -1 without a bus, which
    /// `poll` passes over.
    pub fn descriptor(self: *const Services) i32 {
        return self.bus.fd;
    }

    /// Sends the notification to the daemon, replacing the one showing,
    /// each part cut at a character to its capacity. Busy until the daemon
    /// has numbered the last one, which the poll reads.
    pub fn showNotification(self: *Services, io: std.Io, request: zui.ServiceRequest, notification: zui.Notification, sink: zui.ServiceSink) zui.ServiceError!void {
        if (!isBusText(notification.title) or !isBusText(notification.body)) return error.InvalidUtf8;
        if (self.notification) |shown| if (shown.awaiting_daemon) return error.Busy;
        const title = cutAtCharacter(notification.title, notification_title_capacity);
        const body_text = cutAtCharacter(notification.body, notification_body_capacity);
        const pending: PendingAnswer = .{ .request = request, .sink = sink };
        if (self.fake) |fake| {
            fake.recordNotification(title, body_text);
            return self.replaceNotification(.{ .answer_to = pending, .awaiting_daemon = true });
        }
        if (!self.bus.isOpen()) return error.Unavailable;
        if (!self.notification_signals_watched) {
            try self.changeMatch(io, "AddMatch", &.{notification_daemon.signals_rule});
            self.notification_signals_watched = true;
        }
        const replaced_id = if (self.notification) |shown| shown.id else 0;
        var body: dbus.Writer = .{ .buffer = &self.message_body };
        body.string(notification_daemon.application_name);
        body.uint32(replaced_id);
        body.string("");
        body.string(title);
        body.string(body_text);
        body.stringArray(&.{ notification_daemon.default_action, notification_daemon.default_action_label });
        const hints = body.beginArray(8);
        body.endArray(hints);
        body.int32(notification_daemon.daemon_chooses_timeout);
        const serial = try self.send(io, .{
            .type = .method_call,
            .destination = notification_daemon.service,
            .path = notification_daemon.path,
            .interface = notification_daemon.interface,
            .member = "Notify",
            .signature = "susssasa{sv}i",
        }, &body);
        self.replaceNotification(.{ .answer_to = pending, .awaiting_daemon = true, .call_serial = serial });
    }

    fn replaceNotification(self: *Services, next: ShownNotification) void {
        if (self.notification) |shown| self.replaced_notification = shown.answer_to;
        self.notification = next;
    }

    /// Asks the portal for the dialog, refusing one while a dialog is
    /// still open.
    pub fn showFileDialog(self: *Services, io: std.Io, request: zui.ServiceRequest, window: zui.WindowId, dialog: zui.FileDialog, sink: zui.ServiceSink) zui.ServiceError!void {
        if (self.file_dialog != null) return error.Busy;
        if (dialog.filters.len > filter_capacity) return error.TooLarge;
        try validateDialogText(dialog);
        const pending: PendingAnswer = .{ .request = request, .window = window, .sink = sink };
        if (self.fake) |fake| {
            fake.recordDialog(dialog);
            self.file_dialog = .{ .answer_to = pending, .awaiting_portal = true };
            return;
        }
        if (!self.bus.isOpen() or self.unique_name.len == 0) return error.Unavailable;

        var token_buffer: [handle_token_capacity]u8 = undefined;
        const token = std.fmt.bufPrint(&token_buffer, "zui{d}", .{self.next_handle_token}) catch unreachable;
        self.next_handle_token +%= 1;
        var opening: OpenDialog = .{ .answer_to = pending, .awaiting_portal = true };
        opening.request_path = requestPath(self.unique_name.slice(), token);
        try self.watchResponse(io, opening.request_path.slice());
        errdefer self.unwatchResponse(io, opening.request_path.slice());

        var body: dbus.Writer = .{ .buffer = &self.message_body };
        body.string(portal.no_parent_window);
        body.string(if (dialog.title.len > 0) dialog.title else defaultTitle(dialog.kind));
        writeDialogOptions(&body, dialog, token);
        opening.call_serial = try self.send(io, .{
            .type = .method_call,
            .destination = portal.service,
            .path = portal.path,
            .interface = portal.file_chooser,
            .member = if (dialog.kind == .save_file) "SaveFile" else "OpenFile",
            .signature = "ssa{sv}",
        }, &body);
        self.file_dialog = opening;
    }

    /// Hands `url` to the portal, which opens it with the handler for its
    /// scheme, refusing what is not a URL the system may open.
    pub fn openUrl(self: *Services, io: std.Io, url: []const u8) zui.ServiceError!void {
        if (!zui.isOpenableUrl(url)) return error.InvalidUrl;
        if (!isBusText(url)) return error.InvalidUtf8;
        if (url.len > url_capacity) return error.TooLarge;
        if (self.fake) |fake| return fake.recordOpenedUrl(url);
        if (!self.bus.isOpen()) return error.Unavailable;
        var body: dbus.Writer = .{ .buffer = &self.message_body };
        body.string(portal.no_parent_window);
        body.string(url);
        const options = body.beginArray(8);
        body.endArray(options);
        _ = try self.send(io, .{
            .type = .method_call,
            .flags = .{ .no_reply_expected = true },
            .destination = portal.service,
            .path = portal.path,
            .interface = portal.open_uri,
            .member = "OpenURI",
            .signature = "ssa{sv}",
        }, &body);
    }

    fn sendDeadline(_: *const Services, io: std.Io) zui.Instant {
        return zui.Instant.fromTimestamp(std.Io.Timestamp.now(io, .awake)).addNanoseconds(send_timeout_ns);
    }

    /// A bus that fails to take the message is closed, and what waits on
    /// it is answered by the next poll.
    fn send(self: *Services, io: std.Io, header: dbus.Header, body: *const dbus.Writer) zui.ServiceError!u32 {
        if (body.overflowed) return error.TooLarge;
        return self.bus.send(io, header, body.buffer[0..body.len], self.sendDeadline(io)) catch |err| switch (err) {
            error.MessageTooLarge => error.TooLarge,
            error.ConnectionLost => {
                self.bus.close();
                return error.Unavailable;
            },
        };
    }

    fn changeMatch(self: *Services, io: std.Io, member: []const u8, rule_parts: []const []const u8) zui.ServiceError!void {
        var body_buffer: [portal.response_rule_start.len + request_path_capacity + 16]u8 = undefined;
        var body: dbus.Writer = .{ .buffer = &body_buffer };
        body.stringOfParts(rule_parts);
        var change = bus_service;
        change.member = member;
        change.signature = "s";
        change.flags.no_reply_expected = true;
        _ = try self.send(io, change, &body);
    }

    fn watchResponse(self: *Services, io: std.Io, request_path: []const u8) zui.ServiceError!void {
        try self.changeMatch(io, "AddMatch", &.{ portal.response_rule_start, request_path, "'" });
    }

    fn unwatchResponse(self: *Services, io: std.Io, request_path: []const u8) void {
        if (self.bus.isOpen()) self.changeMatch(io, "RemoveMatch", &.{ portal.response_rule_start, request_path, "'" }) catch {};
    }

    /// Publishes what is due without the bus: the notification the last
    /// one replaced, the fake's answers, and, once the bus is lost, a
    /// failure for each call still waiting on it.
    pub fn publishPending(self: *Services, io: std.Io, waker: zui.Waker) void {
        if (self.replaced_notification) |replaced| {
            self.replaced_notification = null;
            publish(replaced, .notification_dismissed, waker);
        }
        if (self.fake) |fake| {
            if (self.notification) |*shown| if (shown.awaiting_daemon) {
                shown.awaiting_daemon = false;
                if (fake.takeScriptedNotification()) |outcome| self.answerNotification(io, switch (outcome) {
                    .activated => .notification_activated,
                    .dismissed => .notification_dismissed,
                }, waker);
            };
            if (self.file_dialog) |open_dialog| {
                self.file_dialog = null;
                var paths: ChosenPaths = .{ .buffer = &self.chosen_paths };
                const outcome = fake.answerDialog(&paths);
                publishWithLeftOut(open_dialog.answer_to, outcome, paths.left_out_bytes, waker);
            }
            return;
        }
        if (!self.bus.isOpen()) {
            if (self.notification != null) self.answerNotification(io, .{ .failed = .unavailable }, waker);
            if (self.file_dialog) |open_dialog| {
                self.file_dialog = null;
                publish(open_dialog.answer_to, .{ .failed = .unavailable }, waker);
            }
        }
    }

    /// Reads what the bus sent, without waiting, and publishes what it
    /// answered. A bus that hung up is closed.
    pub fn receive(self: *Services, io: std.Io, waker: zui.Waker) void {
        if (!self.bus.isOpen()) return;
        var receiver: Receiver = .{ .services = self, .io = io, .waker = waker };
        self.bus.receive(&receiver) catch self.bus.close();
    }

    const Receiver = struct {
        services: *Services,
        io: std.Io,
        waker: zui.Waker,

        pub fn onMessage(self: *Receiver, message: dbus.Message) void {
            self.services.readMessage(self.io, message, self.waker);
        }

        pub fn onMessageTooLarge(self: *Receiver, header: dbus.Header, len: usize) void {
            self.services.readMessageTooLarge(self.io, header, len, self.waker);
        }
    };

    fn readMessage(self: *Services, io: std.Io, message: dbus.Message, waker: zui.Waker) void {
        const header = message.header;
        var body = message.body;
        switch (header.type) {
            .method_return, .@"error" => {
                const reply_serial = header.reply_serial orelse return;
                if (self.notification) |*shown| if (shown.awaiting_daemon and shown.call_serial == reply_serial) {
                    return self.readNotifyReply(io, shown, header, &body, waker);
                };
                if (self.file_dialog) |*open_dialog| if (open_dialog.awaiting_portal and open_dialog.call_serial == reply_serial) {
                    return self.readFileDialogReply(io, open_dialog, header, &body, waker);
                };
            },
            .signal => {
                if (isSignal(header, notification_daemon.interface, "ActionInvoked", "us")) {
                    const id = body.uint32() catch return;
                    const action = body.string() catch return;
                    if (std.mem.eql(u8, action, notification_daemon.default_action) and self.isFromShownNotification(header, id)) {
                        self.answerNotification(io, .notification_activated, waker);
                    }
                } else if (isSignal(header, notification_daemon.interface, "NotificationClosed", "uu")) {
                    const id = body.uint32() catch return;
                    if (self.isFromShownNotification(header, id)) self.answerNotification(io, .notification_dismissed, waker);
                } else if (isSignal(header, portal.request_interface, "Response", "ua{sv}")) {
                    if (!self.isFromOpenDialog(header)) return;
                    const response = body.uint32() catch return;
                    self.answerFileDialog(io, response, &body, 0, waker);
                }
            },
            else => {},
        }
    }

    /// A dialog's answer too large for the connection to hold answers with
    /// no paths, all of them counted as left out.
    fn readMessageTooLarge(self: *Services, io: std.Io, header: dbus.Header, len: usize, waker: zui.Waker) void {
        if (header.type != .signal or !isSignal(header, portal.request_interface, "Response", "ua{sv}") or !self.isFromOpenDialog(header)) return;
        var nothing: dbus.Reader = .{ .bytes = "" };
        self.answerFileDialog(io, portal.response_chosen, &nothing, std.math.lossyCast(u32, len), waker);
    }

    fn readNotifyReply(self: *Services, io: std.Io, shown: *ShownNotification, header: dbus.Header, body: *dbus.Reader, waker: zui.Waker) void {
        const id = if (header.type == .method_return and std.mem.eql(u8, header.signature, "u")) body.uint32() catch null else null;
        const daemon_name = header.sender orelse "";
        if (id == null or !shown.daemon_name.set(daemon_name)) return self.answerNotification(io, .{ .failed = .unavailable }, waker);
        shown.id = id.?;
        shown.awaiting_daemon = false;
    }

    fn readFileDialogReply(self: *Services, io: std.Io, open_dialog: *OpenDialog, header: dbus.Header, body: *dbus.Reader, waker: zui.Waker) void {
        const handle = if (header.type == .method_return and std.mem.eql(u8, header.signature, "o")) body.string() catch null else null;
        if (handle == null or !open_dialog.portal_name.set(header.sender orelse "")) {
            self.unwatchResponse(io, open_dialog.request_path.slice());
            const answer_to = open_dialog.answer_to;
            self.file_dialog = null;
            return publish(answer_to, .{ .failed = .unavailable }, waker);
        }
        open_dialog.awaiting_portal = false;
        // A portal before version 0.9 makes its request at a path of its own choosing.
        if (!std.mem.eql(u8, handle.?, open_dialog.request_path.slice())) {
            self.unwatchResponse(io, open_dialog.request_path.slice());
            if (!open_dialog.request_path.set(handle.?)) return self.answerFileDialog(io, std.math.maxInt(u32), body, 0, waker);
            self.watchResponse(io, open_dialog.request_path.slice()) catch {};
        }
    }

    fn isFromShownNotification(self: *const Services, header: dbus.Header, id: u32) bool {
        const shown = self.notification orelse return false;
        if (shown.awaiting_daemon or shown.id != id) return false;
        return std.mem.eql(u8, header.path orelse "", notification_daemon.path) and std.mem.eql(u8, header.sender orelse "", shown.daemon_name.slice());
    }

    fn isFromOpenDialog(self: *const Services, header: dbus.Header) bool {
        const open_dialog = self.file_dialog orelse return false;
        if (open_dialog.awaiting_portal) return false;
        return std.mem.eql(u8, header.path orelse "", open_dialog.request_path.slice()) and std.mem.eql(u8, header.sender orelse "", open_dialog.portal_name.slice());
    }

    /// With none showing, the daemon's signals, which it sends for every
    /// application's notifications, are no longer read.
    fn answerNotification(self: *Services, io: std.Io, outcome: zui.ServiceAnswer.Outcome, waker: zui.Waker) void {
        const shown = self.notification orelse return;
        self.notification = null;
        if (self.notification_signals_watched and self.bus.isOpen()) {
            self.changeMatch(io, "RemoveMatch", &.{notification_daemon.signals_rule}) catch {};
            self.notification_signals_watched = false;
        }
        publish(shown.answer_to, outcome, waker);
    }

    /// `results` is the `a{sv}` after the response, whose `uris` are the
    /// files chosen.
    fn answerFileDialog(self: *Services, io: std.Io, response: u32, results: *dbus.Reader, left_out_bytes: u32, waker: zui.Waker) void {
        const open_dialog = self.file_dialog orelse return;
        self.unwatchResponse(io, open_dialog.request_path.slice());
        self.file_dialog = null;
        var paths: ChosenPaths = .{ .buffer = &self.chosen_paths, .left_out_bytes = left_out_bytes };
        const outcome: zui.ServiceAnswer.Outcome = switch (response) {
            portal.response_chosen => chosen: {
                readChosenUris(results, &paths) catch {};
                break :chosen .{ .files_chosen = paths.list() };
            },
            portal.response_canceled, portal.response_ended_otherwise => .canceled,
            else => .{ .failed = .unavailable },
        };
        publishWithLeftOut(open_dialog.answer_to, outcome, paths.left_out_bytes, waker);
    }
};

/// `/org/freedesktop/portal/desktop/request/SENDER/TOKEN`, where SENDER is
/// the connection's unique name without its `:` and with each `.` an `_`.
fn requestPath(unique_name: []const u8, token: []const u8) Text(Services.request_path_capacity) {
    var path: Text(Services.request_path_capacity) = .{};
    path.append(portal.request_path_prefix);
    const sender = if (std.mem.startsWith(u8, unique_name, ":")) unique_name[1..] else unique_name;
    for (sender) |byte| path.append(&.{if (byte == '.') '_' else byte});
    path.append("/");
    path.append(token);
    return path;
}

fn defaultTitle(kind: zui.FileDialog.Kind) []const u8 {
    return switch (kind) {
        .open_file => "Open a File",
        .open_files => "Open Files",
        .save_file => "Save a File",
        .choose_folder => "Choose a Folder",
    };
}

fn validateDialogText(dialog: zui.FileDialog) zui.ServiceError!void {
    for ([_][]const u8{ dialog.title, dialog.directory, dialog.file_name }) |text| {
        if (!isBusText(text)) return error.InvalidUtf8;
    }
    for (dialog.filters) |filter| {
        if (!isBusText(filter.name)) return error.InvalidUtf8;
        for (filter.extensions) |extension| if (!isBusText(extension)) return error.InvalidUtf8;
    }
}

/// The options of `OpenFile` and `SaveFile`, an `a{sv}`.
fn writeDialogOptions(body: *dbus.Writer, dialog: zui.FileDialog, handle_token: []const u8) void {
    const options = body.beginArray(8);
    body.beginVariantEntry("handle_token", "s");
    body.string(handle_token);
    switch (dialog.kind) {
        .open_file, .save_file => {},
        .open_files => {
            body.beginVariantEntry("multiple", "b");
            body.boolean(true);
        },
        .choose_folder => {
            body.beginVariantEntry("directory", "b");
            body.boolean(true);
        },
    }
    if (dialog.kind == .save_file and dialog.file_name.len > 0) {
        body.beginVariantEntry("current_name", "s");
        body.string(dialog.file_name);
    }
    if (dialog.directory.len > 0) {
        body.beginVariantEntry("current_folder", "ay");
        writeAbsolutePath(body, dialog.directory);
    }
    if (dialog.filters.len > 0) {
        body.beginVariantEntry("filters", "a(sa(us))");
        const filters = body.beginArray(8);
        for (dialog.filters) |filter| {
            body.beginStruct();
            body.string(filter.name);
            const patterns = body.beginArray(8);
            for (filter.extensions) |extension| {
                body.beginStruct();
                body.uint32(portal.glob_pattern);
                body.stringOfParts(&.{ "*.", extension });
            }
            if (filter.extensions.len == 0) {
                body.beginStruct();
                body.uint32(portal.glob_pattern);
                body.string("*");
            }
            body.endArray(patterns);
        }
        body.endArray(filters);
    }
    body.endArray(options);
}

/// An `ay` ending in a 0 byte, as the portal takes a folder: `directory`
/// made absolute from the working directory.
fn writeAbsolutePath(body: *dbus.Writer, directory: []const u8) void {
    const array = body.beginArray(1);
    if (directory[0] != '/') {
        var working_directory: [linux.PATH_MAX]u8 = undefined;
        const result = linux.getcwd(&working_directory, working_directory.len);
        if (linux.errno(result) == .SUCCESS) {
            body.bytes(std.mem.sliceTo(&working_directory, 0));
            body.byte('/');
        }
    }
    body.bytes(directory);
    body.byte(0);
    body.endArray(array);
}

fn readChosenUris(results: *dbus.Reader, paths: *ChosenPaths) dbus.Reader.Error!void {
    const results_end = try results.beginArray(8);
    while (results.position < results_end) {
        try results.beginStruct();
        const key = try results.string();
        const value_signature = try results.variantSignature();
        if (!std.mem.eql(u8, key, "uris") or !std.mem.eql(u8, value_signature, "as")) {
            try results.skip(value_signature);
            continue;
        }
        const uris_end = try results.beginArray(4);
        while (results.position < uris_end) paths.addFileUri(try results.string());
    }
}

/// Each path chosen, in UTF-8 followed by a 0 byte, in `buffer`.
const ChosenPaths = struct {
    buffer: []u8,
    len: usize = 0,
    /// Paths that did not fit whole, counted with their 0 bytes, and URIs
    /// that name no local file.
    left_out_bytes: u32 = 0,

    fn addPath(self: *ChosenPaths, path: []const u8) void {
        if (path.len + 1 > self.buffer.len - self.len) return self.leaveOut(path.len + 1);
        @memcpy(self.buffer[self.len..][0..path.len], path);
        self.buffer[self.len + path.len] = 0;
        self.len += path.len + 1;
    }

    /// A `file://` URI as the path it names, its `%XX` escapes decoded.
    fn addFileUri(self: *ChosenPaths, uri: []const u8) void {
        const encoded = encodedPathOfFileUri(uri) orelse return self.leaveOut(uri.len + 1);
        const decoded_len = percentDecodedLength(encoded) orelse return self.leaveOut(uri.len + 1);
        if (decoded_len + 1 > self.buffer.len - self.len) return self.leaveOut(decoded_len + 1);
        self.len += percentDecode(encoded, self.buffer[self.len..]);
        self.buffer[self.len] = 0;
        self.len += 1;
    }

    fn leaveOut(self: *ChosenPaths, len: usize) void {
        self.left_out_bytes +|= std.math.lossyCast(u32, len);
    }

    fn list(self: *const ChosenPaths) []const u8 {
        return self.buffer[0..self.len];
    }
};

/// The path of a URI naming a file on this machine, still escaped: after
/// `file://` with no host, or `localhost`.
fn encodedPathOfFileUri(uri: []const u8) ?[]const u8 {
    const scheme = "file://";
    if (uri.len < scheme.len or !std.ascii.eqlIgnoreCase(uri[0..scheme.len], scheme)) return null;
    const after_scheme = uri[scheme.len..];
    const path = if (std.mem.startsWith(u8, after_scheme, "localhost/")) after_scheme["localhost".len..] else after_scheme;
    if (!std.mem.startsWith(u8, path, "/")) return null;
    return path;
}

/// Null for an escape that is cut short, not hexadecimal, or a 0 byte.
fn percentDecodedLength(encoded: []const u8) ?usize {
    var len: usize = 0;
    var index: usize = 0;
    while (index < encoded.len) : (len += 1) {
        if (encoded[index] != '%') {
            index += 1;
            continue;
        }
        if (index + 3 > encoded.len) return null;
        const value = std.fmt.parseInt(u8, encoded[index + 1 ..][0..2], 16) catch return null;
        if (value == 0) return null;
        index += 3;
    }
    return len;
}

/// Decodes what `percentDecodedLength` accepts into `out`, which holds it.
fn percentDecode(encoded: []const u8, out: []u8) usize {
    var len: usize = 0;
    var index: usize = 0;
    while (index < encoded.len) : (len += 1) {
        if (encoded[index] == '%') {
            out[len] = std.fmt.parseInt(u8, encoded[index + 1 ..][0..2], 16) catch unreachable;
            index += 3;
        } else {
            out[len] = encoded[index];
            index += 1;
        }
    }
    return len;
}

/// The bus disconnects a client that sends a string that is not UTF-8 or
/// holds a 0 byte.
fn isBusText(text: []const u8) bool {
    return std.unicode.utf8ValidateSlice(text) and std.mem.indexOfScalar(u8, text, 0) == null;
}

/// Valid UTF-8 cut before the first character that ends past `capacity`.
fn cutAtCharacter(utf8: []const u8, capacity: usize) []const u8 {
    if (utf8.len <= capacity) return utf8;
    var end = capacity;
    while (end > 0 and utf8[end] & 0xC0 == 0x80) end -= 1;
    return utf8[0..end];
}

fn isSignal(header: dbus.Header, interface: []const u8, member: []const u8, signature: []const u8) bool {
    return std.mem.eql(u8, header.interface orelse "", interface) and std.mem.eql(u8, header.member orelse "", member) and std.mem.eql(u8, header.signature, signature);
}

const PendingAnswer = struct { request: zui.ServiceRequest, window: zui.WindowId = .main, sink: zui.ServiceSink };

fn publish(pending: PendingAnswer, outcome: zui.ServiceAnswer.Outcome, waker: zui.Waker) void {
    publishWithLeftOut(pending, outcome, 0, waker);
}

fn publishWithLeftOut(pending: PendingAnswer, outcome: zui.ServiceAnswer.Outcome, left_out_bytes: u32, waker: zui.Waker) void {
    const answer: zui.ServiceAnswer = .{ .request = pending.request, .window = pending.window, .outcome = outcome, .left_out_bytes = left_out_bytes };
    waker.wakeIf(pending.sink.publish(&answer));
}

/// Text of up to `capacity` bytes, kept whole or not at all.
fn Text(comptime capacity: usize) type {
    return struct {
        const Self = @This();

        bytes: [capacity]u8 = undefined,
        len: usize = 0,
        overflowed: bool = false,

        fn set(self: *Self, text: []const u8) bool {
            self.* = .{};
            self.append(text);
            return !self.overflowed;
        }

        fn append(self: *Self, text: []const u8) void {
            if (text.len > capacity - self.len) {
                self.overflowed = true;
                return;
            }
            @memcpy(self.bytes[self.len..][0..text.len], text);
            self.len += text.len;
        }

        fn slice(self: *const Self) []const u8 {
            return self.bytes[0..self.len];
        }
    };
}

/// For tests: what the host would have handed to the bus, kept instead of
/// handing it over, so nothing shows and no browser opens. Its answers are
/// published by the poll after the call, as the bus's would be.
pub const ServiceFake = struct {
    opened_url: [Services.url_capacity]u8 = undefined,
    opened_url_len: usize = 0,
    /// How the next notification shown is answered; null leaves it showing.
    scripted_notification: ?NotificationOutcome = null,
    notifications_shown: u32 = 0,
    /// The last notification's text as it would have been sent, cut.
    notification_title: [Services.notification_title_capacity]u8 = undefined,
    notification_title_len: usize = 0,
    notification_body: [Services.notification_body_capacity]u8 = undefined,
    notification_body_len: usize = 0,
    /// The paths the next file dialog answers, each followed by a 0 byte;
    /// none cancels it.
    scripted_paths: [1024]u8 = undefined,
    scripted_paths_len: usize = 0,
    file_dialogs_shown: u32 = 0,
    /// The last dialog asked for; valid once `file_dialogs_shown` counts it.
    seen_dialog: SeenDialog = .{},

    pub const NotificationOutcome = enum { activated, dismissed };

    /// The settings of a dialog the host would have asked for, the
    /// strings cut to 64 bytes.
    pub const SeenDialog = struct {
        kind: zui.FileDialog.Kind = .open_file,
        title: [64]u8 = undefined,
        title_len: usize = 0,
        filter_count: usize = 0,
        first_filter_name: [64]u8 = undefined,
        first_filter_name_len: usize = 0,

        pub fn titleText(self: *const SeenDialog) []const u8 {
            return self.title[0..self.title_len];
        }

        pub fn firstFilterName(self: *const SeenDialog) []const u8 {
            return self.first_filter_name[0..self.first_filter_name_len];
        }
    };

    /// Answers the next notification shown as though the user had done this.
    pub fn scriptNotification(self: *ServiceFake, outcome: NotificationOutcome) void {
        self.scripted_notification = outcome;
    }

    /// Answers the next file dialog with `paths`, each followed by a 0
    /// byte, as though the user had chosen them; empty cancels it.
    pub fn scriptFileDialog(self: *ServiceFake, paths: []const u8) void {
        self.scripted_paths_len = copyInto(&self.scripted_paths, paths);
    }

    /// How many file dialogs the host would have asked the portal for.
    pub fn fileDialogsShown(self: *const ServiceFake) u32 {
        return self.file_dialogs_shown;
    }

    /// How many notifications the host would have sent the daemon.
    pub fn notificationsShown(self: *const ServiceFake) u32 {
        return self.notifications_shown;
    }

    /// The last notification's title, as it would have been sent.
    pub fn notificationTitle(self: *const ServiceFake) []const u8 {
        return self.notification_title[0..self.notification_title_len];
    }

    /// The last notification's body, as it would have been sent.
    pub fn notificationBody(self: *const ServiceFake) []const u8 {
        return self.notification_body[0..self.notification_body_len];
    }

    /// The last URL the host would have opened.
    pub fn openedUrl(self: *const ServiceFake) ?[]const u8 {
        return if (self.opened_url_len == 0) null else self.opened_url[0..self.opened_url_len];
    }

    fn recordOpenedUrl(self: *ServiceFake, url: []const u8) void {
        self.opened_url_len = copyInto(&self.opened_url, url);
    }

    fn recordNotification(self: *ServiceFake, title: []const u8, body: []const u8) void {
        self.notification_title_len = copyInto(&self.notification_title, title);
        self.notification_body_len = copyInto(&self.notification_body, body);
        self.notifications_shown += 1;
    }

    fn takeScriptedNotification(self: *ServiceFake) ?NotificationOutcome {
        defer self.scripted_notification = null;
        return self.scripted_notification;
    }

    fn recordDialog(self: *ServiceFake, dialog: zui.FileDialog) void {
        const seen = &self.seen_dialog;
        seen.* = .{ .kind = dialog.kind, .filter_count = dialog.filters.len };
        seen.title_len = copyInto(&seen.title, dialog.title);
        if (dialog.filters.len > 0) seen.first_filter_name_len = copyInto(&seen.first_filter_name, dialog.filters[0].name);
        self.file_dialogs_shown += 1;
    }

    fn answerDialog(self: *const ServiceFake, paths: *ChosenPaths) zui.ServiceAnswer.Outcome {
        const scripted = self.scripted_paths[0..self.scripted_paths_len];
        if (scripted.len == 0) return .canceled;
        var chosen = std.mem.tokenizeScalar(u8, scripted, 0);
        while (chosen.next()) |path| paths.addPath(path);
        return .{ .files_chosen = paths.list() };
    }

    fn copyInto(buffer: []u8, text: []const u8) usize {
        const len = @min(text.len, buffer.len);
        @memcpy(buffer[0..len], text[0..len]);
        return len;
    }
};

const testing = std.testing;

/// The answers published, kept as replies.
const Answers = struct {
    replies: [8]Reply = undefined,
    count: usize = 0,

    const Reply = zui.ServiceReply(1024);

    fn sink(self: *Answers) zui.ServiceSink {
        return .{ .context = self, .publishFn = publishAnswer };
    }

    fn publishAnswer(context: *anyopaque, answer: *const zui.ServiceAnswer) zui.Wake {
        const self: *Answers = @ptrCast(@alignCast(context));
        self.replies[self.count] = .of(answer);
        self.count += 1;
        return if (self.count == 1) .needed else .already_pending;
    }

    fn last(self: *const Answers) *const Reply {
        return &self.replies[self.count - 1];
    }
};

const CountedWakes = struct {
    count: u32 = 0,

    fn waker(self: *CountedWakes) zui.Waker {
        return .{ .context = self, .wakeFn = wake };
    }

    fn wake(context: *anyopaque) void {
        const self: *CountedWakes = @ptrCast(@alignCast(context));
        self.count += 1;
    }
};

test "a notification is refused when its text is not UTF-8 or holds a 0 byte, cut at a character, and busy until the next poll" {
    var fake: ServiceFake = .{};
    var services: Services = .{ .fake = &fake };
    var answers: Answers = .{};
    var wakes: CountedWakes = .{};
    const io = testing.io;
    try testing.expectError(error.InvalidUtf8, services.showNotification(io, .of("saved"), .{ .title = "\xff" }, answers.sink()));
    try testing.expectError(error.InvalidUtf8, services.showNotification(io, .of("saved"), .{ .title = "Saved", .body = "a\x00b" }, answers.sink()));

    const title = "x" ** (Services.notification_title_capacity - 1) ++ "\u{E9}";
    try services.showNotification(io, .of("saved"), .{ .title = title, .body = "zui" }, answers.sink());
    try testing.expectEqualStrings("x" ** (Services.notification_title_capacity - 1), fake.notificationTitle());
    try testing.expectEqualStrings("zui", fake.notificationBody());
    try testing.expectError(error.Busy, services.showNotification(io, .of("again"), .{ .title = "Saved" }, answers.sink()));
    services.publishPending(io, wakes.waker());
    try testing.expectEqual(@as(usize, 0), answers.count);

    fake.scriptNotification(.activated);
    try services.showNotification(io, .of("again"), .{ .title = "Saved" }, answers.sink());
    try testing.expectEqual(@as(usize, 0), answers.count);
    services.publishPending(io, wakes.waker());
    try testing.expectEqual(@as(usize, 2), answers.count);
    try testing.expectEqual(zui.ServiceRequest.of("saved"), answers.replies[0].request);
    try testing.expectEqual(.notification_dismissed, answers.replies[0].kind);
    try testing.expectEqual(zui.ServiceRequest.of("again"), answers.replies[1].request);
    try testing.expectEqual(.notification_activated, answers.replies[1].kind);
    try testing.expectEqual(@as(u32, 1), wakes.count);
    try testing.expectEqual(@as(u32, 2), fake.notificationsShown());
}

test "one file dialog at a time, its strings and filters checked, answered by the next poll" {
    var fake: ServiceFake = .{};
    var services: Services = .{ .fake = &fake };
    var answers: Answers = .{};
    var wakes: CountedWakes = .{};
    const io = testing.io;
    const filter: zui.FileFilter = .{ .name = "Themes", .extensions = &.{"zon"} };
    try testing.expectError(error.TooLarge, services.showFileDialog(io, .of("open"), .main, .{ .filters = &([_]zui.FileFilter{filter} ** (Services.filter_capacity + 1)) }, answers.sink()));
    try testing.expectError(error.InvalidUtf8, services.showFileDialog(io, .of("open"), .main, .{ .filters = &.{.{ .name = "Themes", .extensions = &.{"z\xffn"} }} }, answers.sink()));
    try testing.expectEqual(@as(u32, 0), fake.fileDialogsShown());

    fake.scriptFileDialog("/zui/a.zon\x00/zui/b.zon\x00");
    try services.showFileDialog(io, .of("open"), .main, .{ .kind = .open_files, .title = "Open themes", .filters = &.{filter} }, answers.sink());
    try testing.expectError(error.Busy, services.showFileDialog(io, .of("again"), .main, .{}, answers.sink()));
    try testing.expectEqual(zui.FileDialog.Kind.open_files, fake.seen_dialog.kind);
    try testing.expectEqualStrings("Open themes", fake.seen_dialog.titleText());
    try testing.expectEqualStrings("Themes", fake.seen_dialog.firstFilterName());
    services.publishPending(io, wakes.waker());
    try testing.expectEqual(.files_chosen, answers.last().kind);
    try testing.expectEqualStrings("/zui/a.zon\x00/zui/b.zon\x00", answers.last().bytes[0..answers.last().len]);

    fake.scriptFileDialog("");
    try services.showFileDialog(io, .of("again"), .main, .{}, answers.sink());
    services.publishPending(io, wakes.waker());
    try testing.expectEqual(.canceled, answers.last().kind);
}

test "a URL the system may not open, one too long or one that is not UTF-8 is refused, and the fake keeps the rest" {
    var fake: ServiceFake = .{};
    var services: Services = .{ .fake = &fake };
    const io = testing.io;
    for ([_][]const u8{ "/usr/bin/sh", "file:///usr/bin/sh", "sh" }) |not_a_url| {
        try testing.expectError(error.InvalidUrl, services.openUrl(io, not_a_url));
    }
    try testing.expectError(error.InvalidUtf8, services.openUrl(io, "https://example.com/\xff"));
    try testing.expectError(error.TooLarge, services.openUrl(io, "https://example.com/" ++ "a" ** Services.url_capacity));
    try testing.expectEqual(@as(?[]const u8, null), fake.openedUrl());
    try services.openUrl(io, "https://ziglang.org/");
    try testing.expectEqualStrings("https://ziglang.org/", fake.openedUrl().?);
}

test "without a bus, every call is unavailable at once" {
    var services: Services = .{};
    var answers: Answers = .{};
    const io = testing.io;
    try testing.expectError(error.Unavailable, services.showNotification(io, .of("saved"), .{ .title = "Saved" }, answers.sink()));
    try testing.expectError(error.Unavailable, services.showFileDialog(io, .of("open"), .main, .{}, answers.sink()));
    try testing.expectError(error.Unavailable, services.openUrl(io, "https://ziglang.org/"));
    services.open(io, "unix:path=/nonexistent/zui-host-bus", zui.Instant.fromTimestamp(std.Io.Timestamp.now(io, .awake)).addNanoseconds(std.time.ns_per_s));
    try testing.expectEqual(@as(i32, -1), services.descriptor());
    try testing.expectError(error.Unavailable, services.openUrl(io, "https://ziglang.org/"));
}

test "file URIs become paths with their escapes decoded, and what names no local file or does not fit is counted" {
    var buffer: [24]u8 = undefined;
    var paths: ChosenPaths = .{ .buffer = &buffer };
    paths.addFileUri("file:///home/a%20b.zon");
    paths.addFileUri("FILE://localhost/c%C3%A9");
    paths.addFileUri("sftp://host/x");
    paths.addFileUri("file://host/x");
    paths.addFileUri("file:///bad%2");
    paths.addFileUri("file:///nul%00");
    paths.addFileUri("file:///too/long/to/fit");
    try testing.expectEqualStrings("/home/a b.zon\x00/c\u{E9}\x00", paths.list());
    const left_out_uris = "sftp://host/x".len + "file://host/x".len + "file:///bad%2".len + "file:///nul%00".len + 4;
    try testing.expectEqual(@as(u32, left_out_uris + "/too/long/to/fit".len + 1), paths.left_out_bytes);
}

test "the portal's request path is built from the connection's unique name and the token" {
    try testing.expectEqualStrings("/org/freedesktop/portal/desktop/request/1_42/zui7", requestPath(":1.42", "zui7").slice());
}

test "text is cut before a character that ends past the capacity" {
    try testing.expectEqualStrings("h\u{E9}", cutAtCharacter("h\u{E9}", 3));
    try testing.expectEqualStrings("h", cutAtCharacter("h\u{E9}", 2));
    try testing.expectEqualStrings("ab", cutAtCharacter("ab\u{1F600}", 5));
}

fn decodeMessage(buffer: []u8, header: dbus.Header, body: []const u8) !dbus.Message {
    return dbus.decode(try dbus.encode(buffer, header, body));
}

test "the daemon's number for a notification, then its signals, answer it, and another sender's are ignored" {
    var services: Services = .{};
    var answers: Answers = .{};
    var wakes: CountedWakes = .{};
    const io = testing.io;
    services.notification = .{ .answer_to = .{ .request = .of("saved"), .sink = answers.sink() }, .awaiting_daemon = true, .call_serial = 5 };
    var buffer: [512]u8 = undefined;
    var body_buffer: [64]u8 = undefined;
    var body: dbus.Writer = .{ .buffer = &body_buffer };
    body.uint32(17);
    services.readMessage(io, try decodeMessage(&buffer, .{ .type = .method_return, .reply_serial = 5, .sender = ":1.9", .signature = "u" }, body_buffer[0..body.len]), wakes.waker());
    try testing.expectEqual(@as(u32, 17), services.notification.?.id);

    body = .{ .buffer = &body_buffer };
    body.uint32(17);
    body.string("default");
    const action_invoked: dbus.Header = .{ .type = .signal, .path = notification_daemon.path, .interface = notification_daemon.interface, .member = "ActionInvoked", .sender = ":1.10", .signature = "us" };
    services.readMessage(io, try decodeMessage(&buffer, action_invoked, body_buffer[0..body.len]), wakes.waker());
    try testing.expectEqual(@as(usize, 0), answers.count);
    var from_daemon = action_invoked;
    from_daemon.sender = ":1.9";
    services.readMessage(io, try decodeMessage(&buffer, from_daemon, body_buffer[0..body.len]), wakes.waker());
    try testing.expectEqual(.notification_activated, answers.last().kind);
    try testing.expect(services.notification == null);
}

test "the portal's response answers the dialog with its URIs as paths, or canceled" {
    var services: Services = .{};
    var answers: Answers = .{};
    var wakes: CountedWakes = .{};
    const io = testing.io;
    const request_path = "/org/freedesktop/portal/desktop/request/1_42/zui1";
    var buffer: [1024]u8 = undefined;
    var body_buffer: [512]u8 = undefined;
    for ([_]u32{ portal.response_chosen, portal.response_canceled, 7 }) |response| {
        services.file_dialog = .{ .answer_to = .{ .request = .of("open"), .sink = answers.sink() }, .awaiting_portal = false };
        _ = services.file_dialog.?.request_path.set(request_path);
        _ = services.file_dialog.?.portal_name.set(":1.3");
        var body: dbus.Writer = .{ .buffer = &body_buffer };
        body.uint32(response);
        const results = body.beginArray(8);
        body.beginVariantEntry("current_filter", "(sa(us))");
        body.beginStruct();
        body.string("Themes");
        const patterns = body.beginArray(8);
        body.endArray(patterns);
        body.beginVariantEntry("uris", "as");
        body.stringArray(&.{ "file:///zui/a%20b.zon", "file:///zui/c.zon" });
        body.endArray(results);
        services.readMessage(io, try decodeMessage(&buffer, .{ .type = .signal, .path = request_path, .interface = portal.request_interface, .member = "Response", .sender = ":1.3", .signature = "ua{sv}" }, body_buffer[0..body.len]), wakes.waker());
        try testing.expect(services.file_dialog == null);
    }
    try testing.expectEqual(.files_chosen, answers.replies[0].kind);
    try testing.expectEqualStrings("/zui/a b.zon\x00/zui/c.zon\x00", answers.replies[0].bytes[0..answers.replies[0].len]);
    try testing.expectEqual(.canceled, answers.replies[1].kind);
    try testing.expectEqual(.failed, answers.replies[2].kind);
}

fn nowIn(io: std.Io) zui.Instant {
    return zui.Instant.fromTimestamp(std.Io.Timestamp.now(io, .awake));
}

const ReplyWatch = struct {
    serial: u32,
    answered: bool = false,
    body: [8 * 1024]u8 = undefined,
    body_len: usize = 0,

    pub fn onMessage(self: *ReplyWatch, message: dbus.Message) void {
        if (message.header.type != .method_return or message.header.reply_serial != self.serial) return;
        self.body_len = ServiceFake.copyInto(&self.body, message.body.bytes);
        self.answered = true;
    }

    fn reader(self: *const ReplyWatch) dbus.Reader {
        return .{ .bytes = self.body[0..self.body_len] };
    }
};

fn awaitReply(connection: anytype, io: std.Io, serial: u32, deadline: zui.Instant) !ReplyWatch {
    var watch: ReplyWatch = .{ .serial = serial };
    while (!watch.answered) {
        if (!connection.waitFor(io, linux.POLL.IN, deadline)) return error.Timeout;
        try connection.receive(&watch);
    }
    return watch;
}

fn callBus(connection: anytype, io: std.Io, member: []const u8, signature: []const u8, body: []const u8, deadline: zui.Instant) !ReplyWatch {
    var call = bus_service;
    call.member = member;
    call.signature = signature;
    return awaitReply(connection, io, try connection.send(io, call, body, deadline), deadline);
}

fn connectAndSayHello(connection: *dbus.Connection, io: std.Io, address: []const u8, deadline: zui.Instant) !void {
    try connection.open(io, address, deadline);
    _ = try callBus(connection, io, "Hello", "", "", deadline);
}

/// Retries while the connection a test before this one played the name
/// with has not yet been dropped by the bus.
fn takeName(connection: *dbus.Connection, io: std.Io, name: []const u8, deadline: zui.Instant) !void {
    var body_buffer: [128]u8 = undefined;
    var body: dbus.Writer = .{ .buffer = &body_buffer };
    body.string(name);
    const do_not_queue = 4;
    body.uint32(do_not_queue);
    const primary_owner = 1;
    while (true) {
        const reply = try callBus(connection, io, "RequestName", "su", body_buffer[0..body.len], deadline);
        var result = reply.reader();
        if (try result.uint32() == primary_owner) return;
        if (!nowIn(io).isBefore(deadline)) return error.Timeout;
    }
}

/// A bus that starts a service for this name would start a real one for
/// the test, which might show itself on the desktop.
fn isActivatable(connection: *dbus.Connection, io: std.Io, name: []const u8, deadline: zui.Instant) !bool {
    const watch = try callBus(connection, io, "ListActivatableNames", "", "", deadline);
    if (watch.body_len == watch.body.len) return error.ReplyTooLarge;
    var names = watch.reader();
    const names_end = try names.beginArray(4);
    while (names.position < names_end) if (std.mem.eql(u8, try names.string(), name)) return true;
    return false;
}

/// The last method call named `member`, its body copied.
const PlayedCall = struct {
    member: []const u8,
    found: bool = false,
    serial: u32 = 0,
    flags: dbus.Flags = .{},
    sender: Text(Services.name_capacity) = .{},
    signature: Text(32) = .{},
    body: [Services.message_body_capacity]u8 = undefined,
    body_len: usize = 0,

    pub fn onMessage(self: *PlayedCall, message: dbus.Message) void {
        const header = message.header;
        if (header.type != .method_call or !std.mem.eql(u8, header.member orelse "", self.member)) return;
        self.found = true;
        self.serial = header.serial;
        self.flags = header.flags;
        _ = self.sender.set(header.sender orelse "");
        _ = self.signature.set(header.signature);
        self.body_len = ServiceFake.copyInto(&self.body, message.body.bytes);
    }

    fn arguments(self: *const PlayedCall) dbus.Reader {
        return .{ .bytes = self.body[0..self.body_len] };
    }

    fn reply(self: *const PlayedCall, connection: *dbus.Connection, io: std.Io, signature: []const u8, body: []const u8, deadline: zui.Instant) !void {
        _ = try connection.send(io, .{ .type = .method_return, .reply_serial = self.serial, .destination = self.sender.slice(), .signature = signature }, body, deadline);
    }
};

fn awaitCall(played: *dbus.Connection, io: std.Io, member: []const u8, deadline: zui.Instant) !PlayedCall {
    var call: PlayedCall = .{ .member = member };
    while (!call.found) {
        if (!played.waitFor(io, linux.POLL.IN, deadline)) return error.Timeout;
        try played.receive(&call);
    }
    return call;
}

fn pumpUntil(services: *Services, io: std.Io, answers: *const Answers, count: usize, deadline: zui.Instant) !void {
    var wakes: CountedWakes = .{};
    while (answers.count < count) {
        services.publishPending(io, wakes.waker());
        if (answers.count >= count) return;
        if (!services.bus.waitFor(io, linux.POLL.IN, deadline)) return error.Timeout;
        services.receive(io, wakes.waker());
    }
}

fn pumpWhile(services: *Services, io: std.Io, comptime still: fn (*const Services) bool, deadline: zui.Instant) !void {
    var wakes: CountedWakes = .{};
    while (still(services)) {
        if (!services.bus.waitFor(io, linux.POLL.IN, deadline)) return error.Timeout;
        services.receive(io, wakes.waker());
    }
}

fn notificationAwaitsDaemon(services: *const Services) bool {
    return services.notification != null and services.notification.?.awaiting_daemon;
}

fn dialogAwaitsPortal(services: *const Services) bool {
    return services.file_dialog != null and services.file_dialog.?.awaiting_portal;
}

/// Sends a signal through `connection`, then waits for the bus to answer
/// a call made after it, by which time it has routed the signal.
fn sendSignalAndSync(connection: *dbus.Connection, io: std.Io, header: dbus.Header, body: []const u8, deadline: zui.Instant) !void {
    _ = try connection.send(io, header, body, deadline);
    _ = try callBus(connection, io, "GetId", "", "", deadline);
}

fn notificationSignal(member: []const u8, signature: []const u8, destination: ?[]const u8) dbus.Header {
    return .{ .type = .signal, .path = notification_daemon.path, .interface = notification_daemon.interface, .member = member, .signature = signature, .destination = destination };
}

test "through a bus daemon, notifications reach the daemon and its signals answer them, and another sender's do not" {
    const address = std.mem.span(std.c.getenv("ZUI_HOST_TEST_SESSION_BUS") orelse return error.SkipZigTest);
    const io = testing.io;
    const deadline = nowIn(io).addNanoseconds(5 * std.time.ns_per_s);
    var services: Services = .{};
    services.open(io, address, deadline);
    defer services.close(io);
    try testing.expect(services.unique_name.len > 0);
    var answers: Answers = .{};

    var played_daemon: dbus.Connection = .{};
    defer played_daemon.close();
    try connectAndSayHello(&played_daemon, io, address, deadline);
    if (!try isActivatable(&played_daemon, io, notification_daemon.service, deadline)) {
        try services.showNotification(io, .of("unanswered"), .{ .title = "Nobody listens" }, answers.sink());
        try pumpUntil(&services, io, &answers, 1, deadline);
        try testing.expectEqual(.failed, answers.last().kind);
    } else {
        std.debug.print("skipped the missing daemon: this bus would start one\n", .{});
        answers.count = 1;
    }
    try takeName(&played_daemon, io, notification_daemon.service, deadline);

    const title = "t" ** (Services.notification_title_capacity - 1) ++ "\u{E9}";
    try services.showNotification(io, .of("saved"), .{ .title = title, .body = "zui" }, answers.sink());
    const notify = try awaitCall(&played_daemon, io, "Notify", deadline);
    try testing.expectEqualStrings("susssasa{sv}i", notify.signature.slice());
    var arguments = notify.arguments();
    try testing.expectEqualStrings("zui", try arguments.string());
    try testing.expectEqual(@as(u32, 0), try arguments.uint32());
    try testing.expectEqualStrings("", try arguments.string());
    try testing.expectEqualStrings("t" ** (Services.notification_title_capacity - 1), try arguments.string());
    try testing.expectEqualStrings("zui", try arguments.string());
    const actions_end = try arguments.beginArray(4);
    try testing.expectEqualStrings("default", try arguments.string());
    _ = try arguments.string();
    try testing.expectEqual(actions_end, arguments.position);
    try arguments.skip("a{sv}");
    try testing.expectEqual(@as(u32, @bitCast(@as(i32, -1))), try arguments.uint32());

    var body_buffer: [64]u8 = undefined;
    var body: dbus.Writer = .{ .buffer = &body_buffer };
    body.uint32(42);
    try notify.reply(&played_daemon, io, "u", body_buffer[0..body.len], deadline);
    try pumpWhile(&services, io, notificationAwaitsDaemon, deadline);

    var impostor: dbus.Connection = .{};
    defer impostor.close();
    try connectAndSayHello(&impostor, io, address, deadline);
    body = .{ .buffer = &body_buffer };
    body.uint32(42);
    body.string("default");
    try sendSignalAndSync(&impostor, io, notificationSignal("ActionInvoked", "us", null), body_buffer[0..body.len], deadline);
    try sendSignalAndSync(&impostor, io, notificationSignal("ActionInvoked", "us", services.unique_name.slice()), body_buffer[0..body.len], deadline);
    try sendSignalAndSync(&played_daemon, io, notificationSignal("ActionInvoked", "us", null), body_buffer[0..body.len], deadline);
    try pumpUntil(&services, io, &answers, 2, deadline);
    try testing.expectEqual(zui.ServiceRequest.of("saved"), answers.last().request);
    try testing.expectEqual(.notification_activated, answers.last().kind);

    inline for (.{ 0, 43 }, .{ "first", "second" }) |expected_replaced_id, name| {
        try services.showNotification(io, .of(name), .{ .title = name }, answers.sink());
        const shown = try awaitCall(&played_daemon, io, "Notify", deadline);
        var shown_arguments = shown.arguments();
        _ = try shown_arguments.string();
        try testing.expectEqual(@as(u32, expected_replaced_id), try shown_arguments.uint32());
        body = .{ .buffer = &body_buffer };
        body.uint32(43);
        try shown.reply(&played_daemon, io, "u", body_buffer[0..body.len], deadline);
        try pumpWhile(&services, io, notificationAwaitsDaemon, deadline);
    }
    try pumpUntil(&services, io, &answers, 3, deadline);
    try testing.expectEqual(zui.ServiceRequest.of("first"), answers.last().request);
    try testing.expectEqual(.notification_dismissed, answers.last().kind);

    body = .{ .buffer = &body_buffer };
    body.uint32(43);
    const closed_by_user = 2;
    body.uint32(closed_by_user);
    try sendSignalAndSync(&played_daemon, io, notificationSignal("NotificationClosed", "uu", null), body_buffer[0..body.len], deadline);
    try pumpUntil(&services, io, &answers, 4, deadline);
    try testing.expectEqual(zui.ServiceRequest.of("second"), answers.last().request);
    try testing.expectEqual(.notification_dismissed, answers.last().kind);
}

fn responseSignal(request_path: []const u8, destination: ?[]const u8) dbus.Header {
    return .{ .type = .signal, .path = request_path, .interface = portal.request_interface, .member = "Response", .signature = "ua{sv}", .destination = destination };
}

/// The portal's answer to a dialog's call: the request's path, which is
/// the one the host predicted.
fn replyWithRequestPath(call: *const PlayedCall, played_portal: *dbus.Connection, io: std.Io, services: *const Services, token: []const u8, deadline: zui.Instant) !Text(Services.request_path_capacity) {
    const predicted = requestPath(services.unique_name.slice(), token);
    try testing.expectEqualStrings(predicted.slice(), services.file_dialog.?.request_path.slice());
    var body_buffer: [512]u8 = undefined;
    var body: dbus.Writer = .{ .buffer = &body_buffer };
    body.string(predicted.slice());
    try call.reply(played_portal, io, "o", body_buffer[0..body.len], deadline);
    return predicted;
}

/// Reads `OpenFile`'s or `SaveFile`'s options into what the test checks.
const SeenOptions = struct {
    handle_token: Text(32) = .{},
    multiple: bool = false,
    current_name: Text(64) = .{},
    current_folder: Text(linux.PATH_MAX) = .{},
    filter_count: usize = 0,
    first_filter_name: Text(32) = .{},
    first_filter_patterns: [2]Text(16) = .{ .{}, .{} },
    last_filter_pattern: Text(16) = .{},

    fn read(arguments: *dbus.Reader) !SeenOptions {
        var seen: SeenOptions = .{};
        const options_end = try arguments.beginArray(8);
        while (arguments.position < options_end) {
            try arguments.beginStruct();
            const key = try arguments.string();
            const value_signature = try arguments.variantSignature();
            if (std.mem.eql(u8, key, "handle_token")) {
                _ = seen.handle_token.set(try arguments.string());
            } else if (std.mem.eql(u8, key, "multiple")) {
                seen.multiple = try arguments.boolean();
            } else if (std.mem.eql(u8, key, "current_name")) {
                _ = seen.current_name.set(try arguments.string());
            } else if (std.mem.eql(u8, key, "current_folder")) {
                _ = seen.current_folder.set(try arguments.byteArray());
            } else if (std.mem.eql(u8, key, "filters")) {
                try testing.expectEqualStrings("a(sa(us))", value_signature);
                const filters_end = try arguments.beginArray(8);
                while (arguments.position < filters_end) : (seen.filter_count += 1) {
                    try arguments.beginStruct();
                    const name = try arguments.string();
                    if (seen.filter_count == 0) _ = seen.first_filter_name.set(name);
                    const patterns_end = try arguments.beginArray(8);
                    var pattern_index: usize = 0;
                    while (arguments.position < patterns_end) : (pattern_index += 1) {
                        try arguments.beginStruct();
                        try testing.expectEqual(portal.glob_pattern, try arguments.uint32());
                        const pattern = try arguments.string();
                        if (seen.filter_count == 0 and pattern_index < 2) _ = seen.first_filter_patterns[pattern_index].set(pattern);
                        _ = seen.last_filter_pattern.set(pattern);
                    }
                }
            } else {
                try arguments.skip(value_signature);
            }
        }
        return seen;
    }
};

test "through a bus daemon, the portal's file chooser answers paths or a cancel, one dialog at a time, and opens URLs" {
    const address = std.mem.span(std.c.getenv("ZUI_HOST_TEST_SESSION_BUS") orelse return error.SkipZigTest);
    const io = testing.io;
    const deadline = nowIn(io).addNanoseconds(5 * std.time.ns_per_s);
    var played_portal: dbus.Connection = .{};
    defer played_portal.close();
    try connectAndSayHello(&played_portal, io, address, deadline);
    try takeName(&played_portal, io, portal.service, deadline);
    var services: Services = .{};
    services.open(io, address, deadline);
    defer services.close(io);
    var answers: Answers = .{};

    const filters = [_]zui.FileFilter{ .{ .name = "Themes", .extensions = &.{ "zon", "json" } }, .{ .name = "All", .extensions = &.{} } };
    try services.showFileDialog(io, .of("open"), .main, .{ .kind = .open_files, .title = "Open themes", .directory = "themes", .filters = &filters }, answers.sink());
    try testing.expectError(error.Busy, services.showFileDialog(io, .of("again"), .main, .{}, answers.sink()));
    const open_file = try awaitCall(&played_portal, io, "OpenFile", deadline);
    try testing.expectEqualStrings("ssa{sv}", open_file.signature.slice());
    var arguments = open_file.arguments();
    try testing.expectEqualStrings("", try arguments.string());
    try testing.expectEqualStrings("Open themes", try arguments.string());
    const options = try SeenOptions.read(&arguments);
    try testing.expect(options.multiple);
    try testing.expect(std.mem.startsWith(u8, options.current_folder.slice(), "/"));
    try testing.expect(std.mem.endsWith(u8, options.current_folder.slice(), "/themes\x00"));
    try testing.expectEqual(@as(usize, 2), options.filter_count);
    try testing.expectEqualStrings("Themes", options.first_filter_name.slice());
    try testing.expectEqualStrings("*.zon", options.first_filter_patterns[0].slice());
    try testing.expectEqualStrings("*.json", options.first_filter_patterns[1].slice());
    try testing.expectEqualStrings("*", options.last_filter_pattern.slice());

    const request_path = try replyWithRequestPath(&open_file, &played_portal, io, &services, options.handle_token.slice(), deadline);
    try pumpWhile(&services, io, dialogAwaitsPortal, deadline);
    var body_buffer: [512]u8 = undefined;
    var body: dbus.Writer = .{ .buffer = &body_buffer };
    body.uint32(portal.response_chosen);
    const results = body.beginArray(8);
    body.beginVariantEntry("uris", "as");
    body.stringArray(&.{ "file:///zui/a%20b.zon", "file:///zui/c.zon" });
    body.endArray(results);

    var impostor: dbus.Connection = .{};
    defer impostor.close();
    try connectAndSayHello(&impostor, io, address, deadline);
    try sendSignalAndSync(&impostor, io, responseSignal(request_path.slice(), services.unique_name.slice()), body_buffer[0..body.len], deadline);
    try sendSignalAndSync(&played_portal, io, responseSignal(request_path.slice(), null), body_buffer[0..body.len], deadline);
    try pumpUntil(&services, io, &answers, 1, deadline);
    try testing.expectEqual(@as(usize, 1), answers.count);
    try testing.expectEqual(zui.ServiceRequest.of("open"), answers.last().request);
    try testing.expectEqual(.files_chosen, answers.last().kind);
    try testing.expectEqualStrings("/zui/a b.zon\x00/zui/c.zon\x00", answers.last().bytes[0..answers.last().len]);

    try services.showFileDialog(io, .of("save"), .main, .{ .kind = .save_file, .file_name = "notes.txt" }, answers.sink());
    const save_file = try awaitCall(&played_portal, io, "SaveFile", deadline);
    arguments = save_file.arguments();
    _ = try arguments.string();
    _ = try arguments.string();
    const save_options = try SeenOptions.read(&arguments);
    try testing.expectEqualStrings("notes.txt", save_options.current_name.slice());
    const save_path = try replyWithRequestPath(&save_file, &played_portal, io, &services, save_options.handle_token.slice(), deadline);
    try pumpWhile(&services, io, dialogAwaitsPortal, deadline);
    body = .{ .buffer = &body_buffer };
    body.uint32(portal.response_canceled);
    const no_results = body.beginArray(8);
    body.endArray(no_results);
    try sendSignalAndSync(&played_portal, io, responseSignal(save_path.slice(), null), body_buffer[0..body.len], deadline);
    try pumpUntil(&services, io, &answers, 2, deadline);
    try testing.expectEqual(zui.ServiceRequest.of("save"), answers.last().request);
    try testing.expectEqual(.canceled, answers.last().kind);

    try services.openUrl(io, "https://ziglang.org/");
    const open_uri = try awaitCall(&played_portal, io, "OpenURI", deadline);
    try testing.expect(open_uri.flags.no_reply_expected);
    arguments = open_uri.arguments();
    try testing.expectEqualStrings("", try arguments.string());
    try testing.expectEqualStrings("https://ziglang.org/", try arguments.string());
    try arguments.skip("a{sv}");
}
