//! What the desktop says over D-Bus: the theme, contrast and reduced
//! motion from the XDG desktop portal's settings on the session bus, and
//! from the system bus whether the machine runs on battery (UPower), saves
//! power (power-profiles-daemon) and is about to sleep (logind).

const std = @import("std");
const zui = @import("zui");
const dbus = @import("dbus.zig");

/// One fact the desktop reported, current or changed.
pub const Report = union(enum) {
    theme: zui.Environment.Theme,
    contrast: zui.Environment.Contrast,
    reduced_motion: bool,
    on_battery: bool,
    power_saver: bool,
    /// True before the system sleeps, false after it wakes.
    preparing_for_sleep: bool,
};

/// Which services answered. A service that is not running, or a bus that
/// cannot be reached, leaves its settings at zui's defaults.
pub const Sources = struct {
    settings_portal: bool = false,
    upower: bool = false,
    power_profiles: bool = false,
};

/// The buses to connect to, as D-Bus address lists; null connects to none.
pub const Addresses = struct {
    session: ?[]const u8,
    system: ?[]const u8,
};

const bus_service: dbus.Header = .{ .type = .method_call, .destination = "org.freedesktop.DBus", .path = "/org/freedesktop/DBus", .interface = "org.freedesktop.DBus" };

const portal = struct {
    const service = "org.freedesktop.portal.Desktop";
    const path = "/org/freedesktop/portal/desktop";
    const interface = "org.freedesktop.portal.Settings";
    const appearance = "org.freedesktop.appearance";
    const setting_changed_rule = "type='signal',sender='" ++ service ++ "',interface='" ++ interface ++ "',member='SettingChanged',path='" ++ path ++ "',arg0='" ++ appearance ++ "'";
};

const properties_interface = "org.freedesktop.DBus.Properties";

const upower = struct {
    const service = "org.freedesktop.UPower";
    const path = "/org/freedesktop/UPower";
    const changed_rule = "type='signal',sender='" ++ service ++ "',interface='" ++ properties_interface ++ "',member='PropertiesChanged',path='" ++ path ++ "'";
};

/// The daemon's first name, which later versions still answer to.
const power_profiles = struct {
    const service = "net.hadess.PowerProfiles";
    const path = "/net/hadess/PowerProfiles";
    const changed_rule = "type='signal',sender='" ++ service ++ "',interface='" ++ properties_interface ++ "',member='PropertiesChanged',path='" ++ path ++ "'";
};

const login_manager = struct {
    const service = "org.freedesktop.login1";
    const prepare_for_sleep_rule = "type='signal',sender='" ++ service ++ "',interface='org.freedesktop.login1.Manager',member='PrepareForSleep',path='/org/freedesktop/login1'";
};

pub const DesktopBus = struct {
    session: dbus.Connection = .{},
    system: dbus.Connection = .{},
    sources: Sources = .{},
    awaited: Awaited = .{},

    /// The serials of the replies still to come.
    const Awaited = struct {
        settings: ?u32 = null,
        on_battery: ?u32 = null,
        power_profile: ?u32 = null,
    };

    /// The addresses in `DBUS_SESSION_BUS_ADDRESS` and
    /// `DBUS_SYSTEM_BUS_ADDRESS`, or the buses' usual sockets without them.
    pub fn addressesFromEnvironment(session_buffer: []u8) Addresses {
        const session: ?[]const u8 = if (std.c.getenv("DBUS_SESSION_BUS_ADDRESS")) |address|
            std.mem.span(address)
        else if (std.c.getenv("XDG_RUNTIME_DIR")) |runtime_directory|
            std.fmt.bufPrint(session_buffer, "unix:path={s}/bus", .{std.mem.span(runtime_directory)}) catch null
        else
            null;
        const system: []const u8 = if (std.c.getenv("DBUS_SYSTEM_BUS_ADDRESS")) |address| std.mem.span(address) else "unix:path=/var/run/dbus/system_bus_socket";
        return .{ .session = session, .system = system };
    }

    /// Connects to each bus, subscribes to the changes and asks for the
    /// current values, which arrive through `receive`. A bus that does not
    /// answer by `deadline` is left closed.
    pub fn open(self: *DesktopBus, io: std.Io, addresses: Addresses, deadline: zui.Instant) void {
        self.* = .{};
        if (addresses.session) |address| self.openSession(io, address, deadline) catch self.closeBus(.session);
        if (addresses.system) |address| self.openSystem(io, address, deadline) catch self.closeBus(.system);
    }

    fn openSession(self: *DesktopBus, io: std.Io, address: []const u8, deadline: zui.Instant) !void {
        try self.session.open(io, address, deadline);
        try sayHello(&self.session, io, deadline);
        try addMatch(&self.session, io, portal.setting_changed_rule, deadline);
        var body_buffer: [64]u8 = undefined;
        var body: dbus.Writer = .{ .buffer = &body_buffer };
        const namespaces = body.beginArray(4);
        body.string(portal.appearance);
        body.endArray(namespaces);
        self.awaited.settings = try self.session.send(io, .{
            .type = .method_call,
            .destination = portal.service,
            .path = portal.path,
            .interface = portal.interface,
            .member = "ReadAll",
            .signature = "as",
        }, body_buffer[0..body.len], deadline);
    }

    fn openSystem(self: *DesktopBus, io: std.Io, address: []const u8, deadline: zui.Instant) !void {
        try self.system.open(io, address, deadline);
        try sayHello(&self.system, io, deadline);
        for ([_][]const u8{ upower.changed_rule, power_profiles.changed_rule, login_manager.prepare_for_sleep_rule }) |rule| try addMatch(&self.system, io, rule, deadline);
        self.awaited.on_battery = try getProperty(&self.system, io, upower.service, upower.path, upower.service, "OnBattery", deadline);
        self.awaited.power_profile = try getProperty(&self.system, io, power_profiles.service, power_profiles.path, power_profiles.service, "ActiveProfile", deadline);
    }

    fn sayHello(connection: *dbus.Connection, io: std.Io, deadline: zui.Instant) !void {
        var hello = bus_service;
        hello.member = "Hello";
        _ = try connection.send(io, hello, "", deadline);
    }

    fn addMatch(connection: *dbus.Connection, io: std.Io, rule: []const u8, deadline: zui.Instant) !void {
        var body_buffer: [512]u8 = undefined;
        var body: dbus.Writer = .{ .buffer = &body_buffer };
        body.string(rule);
        var add_match = bus_service;
        add_match.member = "AddMatch";
        add_match.signature = "s";
        add_match.flags.no_reply_expected = true;
        _ = try connection.send(io, add_match, body_buffer[0..body.len], deadline);
    }

    fn getProperty(connection: *dbus.Connection, io: std.Io, service: []const u8, path: []const u8, interface: []const u8, property: []const u8, deadline: zui.Instant) !u32 {
        var body_buffer: [128]u8 = undefined;
        var body: dbus.Writer = .{ .buffer = &body_buffer };
        body.string(interface);
        body.string(property);
        return connection.send(io, .{
            .type = .method_call,
            .destination = service,
            .path = path,
            .interface = properties_interface,
            .member = "Get",
            .signature = "ss",
        }, body_buffer[0..body.len], deadline);
    }

    pub fn close(self: *DesktopBus) void {
        self.closeBus(.session);
        self.closeBus(.system);
    }

    const Bus = enum { session, system };

    /// Its settings keep the values last reported.
    fn closeBus(self: *DesktopBus, bus: Bus) void {
        switch (bus) {
            .session => {
                self.session.close();
                self.awaited.settings = null;
            },
            .system => {
                self.system.close();
                self.awaited.on_battery = null;
                self.awaited.power_profile = null;
            },
        }
    }

    pub fn awaitingReplies(self: *const DesktopBus) bool {
        const awaited = self.awaited;
        return awaited.settings != null or awaited.on_battery != null or awaited.power_profile != null;
    }

    /// The sockets to wait on beside the display; a closed one is -1,
    /// which `poll` passes over.
    pub fn descriptors(self: *const DesktopBus) [2]i32 {
        return .{ self.session.fd, self.system.fd };
    }

    /// Reads what either bus sent, without waiting, and calls
    /// `listener.onDesktopReport(report)` for each fact in it. A bus that
    /// hung up is closed.
    pub fn receive(self: *DesktopBus, listener: anytype) void {
        inline for (.{ Bus.session, Bus.system }) |bus| {
            const connection = &@field(self, @tagName(bus));
            if (connection.isOpen()) {
                var receiver: Receiver(@TypeOf(listener), bus) = .{ .desktop = self, .listener = listener };
                connection.receive(&receiver) catch self.closeBus(bus);
            }
        }
    }

    fn Receiver(comptime Listener: type, comptime bus: Bus) type {
        return struct {
            desktop: *DesktopBus,
            listener: Listener,

            pub fn onMessage(self: *@This(), message: dbus.Message) void {
                if (bus == .session) self.desktop.readSessionMessage(message, self.listener) else self.desktop.readSystemMessage(message, self.listener);
            }
        };
    }

    pub fn readSessionMessage(self: *DesktopBus, message: dbus.Message, listener: anytype) void {
        var body = message.body;
        const header = message.header;
        switch (header.type) {
            .method_return, .@"error" => if (takeAwaited(&self.awaited.settings, header.reply_serial)) {
                if (header.type == .@"error" or !std.mem.eql(u8, header.signature, "a{sa{sv}}")) return;
                self.sources.settings_portal = true;
                readAllSettings(&body, listener) catch {};
            },
            .signal => if (isSignal(header, portal.interface, "SettingChanged") and std.mem.eql(u8, header.signature, "ssv")) {
                readSettingChanged(&body, listener) catch {};
            },
            else => {},
        }
    }

    pub fn readSystemMessage(self: *DesktopBus, message: dbus.Message, listener: anytype) void {
        var body = message.body;
        const header = message.header;
        switch (header.type) {
            .method_return, .@"error" => {
                const answered_on_battery = takeAwaited(&self.awaited.on_battery, header.reply_serial);
                const answered_power_profile = takeAwaited(&self.awaited.power_profile, header.reply_serial);
                if (header.type == .@"error" or !std.mem.eql(u8, header.signature, "v")) return;
                if (answered_on_battery) if (readBoolean(&body) catch null) |on_battery| {
                    self.sources.upower = true;
                    listener.onDesktopReport(.{ .on_battery = on_battery });
                };
                if (answered_power_profile) if (readString(&body) catch null) |profile| {
                    self.sources.power_profiles = true;
                    listener.onDesktopReport(.{ .power_saver = std.mem.eql(u8, profile, "power-saver") });
                };
            },
            .signal => {
                if (isSignal(header, properties_interface, "PropertiesChanged") and std.mem.eql(u8, header.signature, "sa{sv}as")) {
                    readPropertiesChanged(&body, listener) catch {};
                } else if (isSignal(header, "org.freedesktop.login1.Manager", "PrepareForSleep") and std.mem.eql(u8, header.signature, "b")) {
                    if (body.boolean() catch null) |sleeping| listener.onDesktopReport(.{ .preparing_for_sleep = sleeping });
                }
            },
            else => {},
        }
    }
};

fn takeAwaited(awaited: *?u32, reply_serial: ?u32) bool {
    if (awaited.* == null or awaited.* != reply_serial) return false;
    awaited.* = null;
    return true;
}

fn isSignal(header: dbus.Header, interface: []const u8, member: []const u8) bool {
    return std.mem.eql(u8, header.interface orelse "", interface) and std.mem.eql(u8, header.member orelse "", member);
}

/// `ReadAll`'s answer, `a{sa{sv}}`: settings by namespace.
fn readAllSettings(body: *dbus.Reader, listener: anytype) dbus.Reader.Error!void {
    const namespaces_end = try body.beginArray(8);
    while (body.position < namespaces_end) {
        try body.beginStruct();
        const namespace = try body.string();
        const settings_end = try body.beginArray(8);
        if (!std.mem.eql(u8, namespace, portal.appearance)) {
            body.position = settings_end;
            continue;
        }
        while (body.position < settings_end) {
            try body.beginStruct();
            const key = try body.string();
            try readAppearanceSetting(body, key, listener);
        }
    }
}

/// `SettingChanged`'s arguments, `ssv`.
fn readSettingChanged(body: *dbus.Reader, listener: anytype) dbus.Reader.Error!void {
    if (!std.mem.eql(u8, try body.string(), portal.appearance)) return;
    const key = try body.string();
    try readAppearanceSetting(body, key, listener);
}

/// A key's variant: each setting the host reads is a `u`.
fn readAppearanceSetting(body: *dbus.Reader, key: []const u8, listener: anytype) dbus.Reader.Error!void {
    const value_signature = try body.variantSignature();
    if (!std.mem.eql(u8, value_signature, "u")) return body.skip(value_signature);
    const value = try body.uint32();
    if (std.mem.eql(u8, key, "color-scheme")) {
        // 0 is no preference, 1 prefers dark and 2 prefers light.
        listener.onDesktopReport(.{ .theme = if (value == 1) .dark else .light });
    } else if (std.mem.eql(u8, key, "contrast")) {
        listener.onDesktopReport(.{ .contrast = if (value == 1) .high else .normal });
    } else if (std.mem.eql(u8, key, "reduced-motion")) {
        listener.onDesktopReport(.{ .reduced_motion = value == 1 });
    }
}

/// `PropertiesChanged`'s arguments, `sa{sv}as`, from UPower or
/// power-profiles-daemon.
fn readPropertiesChanged(body: *dbus.Reader, listener: anytype) dbus.Reader.Error!void {
    const interface = try body.string();
    const is_upower = std.mem.eql(u8, interface, upower.service);
    const is_power_profiles = std.mem.eql(u8, interface, power_profiles.service);
    if (!is_upower and !is_power_profiles) return;
    const changed_end = try body.beginArray(8);
    while (body.position < changed_end) {
        try body.beginStruct();
        const property = try body.string();
        const value_signature = try body.variantSignature();
        if (is_upower and std.mem.eql(u8, property, "OnBattery") and std.mem.eql(u8, value_signature, "b")) {
            listener.onDesktopReport(.{ .on_battery = try body.boolean() });
        } else if (is_power_profiles and std.mem.eql(u8, property, "ActiveProfile") and std.mem.eql(u8, value_signature, "s")) {
            listener.onDesktopReport(.{ .power_saver = std.mem.eql(u8, try body.string(), "power-saver") });
        } else {
            try body.skip(value_signature);
        }
    }
}

fn readBoolean(body: *dbus.Reader) dbus.Reader.Error!?bool {
    if (!std.mem.eql(u8, try body.variantSignature(), "b")) return null;
    return try body.boolean();
}

fn readString(body: *dbus.Reader) dbus.Reader.Error!?[]const u8 {
    if (!std.mem.eql(u8, try body.variantSignature(), "s")) return null;
    return try body.string();
}

const testing = std.testing;

const Reports = struct {
    list: [8]Report = undefined,
    count: usize = 0,

    pub fn onDesktopReport(self: *Reports, report: Report) void {
        self.list[self.count] = report;
        self.count += 1;
    }

    fn all(self: *const Reports) []const Report {
        return self.list[0..self.count];
    }
};

fn decodeMessage(buffer: []u8, header: dbus.Header, body: []const u8) !dbus.Message {
    return dbus.decode(try dbus.encode(buffer, header, body));
}

test "the portal's settings are the theme, contrast and reduced motion, and other keys are passed over" {
    var body_buffer: [512]u8 = undefined;
    var body: dbus.Writer = .{ .buffer = &body_buffer };
    const namespaces = body.beginArray(8);
    for ([_][]const u8{ "org.gnome.desktop.interface", portal.appearance }) |namespace| {
        body.beginStruct();
        body.string(namespace);
        const settings = body.beginArray(8);
        body.beginStruct();
        body.string("accent-color");
        body.signature("(ddd)");
        body.beginStruct();
        for (0..3) |_| {
            body.alignTo(8);
            body.bytes(&@as([8]u8, @splat(0)));
        }
        for ([_][]const u8{ "color-scheme", "contrast", "reduced-motion" }) |key| {
            body.beginStruct();
            body.string(key);
            body.signature("u");
            body.uint32(1);
        }
        body.endArray(settings);
    }
    body.endArray(namespaces);

    var desktop: DesktopBus = .{ .awaited = .{ .settings = 4 } };
    var reports: Reports = .{};
    var buffer: [1024]u8 = undefined;
    desktop.readSessionMessage(try decodeMessage(&buffer, .{ .type = .method_return, .reply_serial = 4, .signature = "a{sa{sv}}" }, body_buffer[0..body.len]), &reports);
    try testing.expectEqualSlices(Report, &.{ .{ .theme = .dark }, .{ .contrast = .high }, .{ .reduced_motion = true } }, reports.all());
    try testing.expect(desktop.sources.settings_portal);
    try testing.expect(!desktop.awaitingReplies());
}

test "a changed setting is reported, and the portal's error leaves the settings unanswered" {
    var body_buffer: [128]u8 = undefined;
    var body: dbus.Writer = .{ .buffer = &body_buffer };
    body.string(portal.appearance);
    body.string("color-scheme");
    body.signature("v");
    body.signature("u");
    body.uint32(2);
    var desktop: DesktopBus = .{ .awaited = .{ .settings = 4 } };
    var reports: Reports = .{};
    var buffer: [512]u8 = undefined;
    desktop.readSessionMessage(try decodeMessage(&buffer, .{ .type = .signal, .path = portal.path, .interface = portal.interface, .member = "SettingChanged", .signature = "ssv" }, body_buffer[0..body.len]), &reports);
    try testing.expectEqualSlices(Report, &.{.{ .theme = .light }}, reports.all());

    desktop.readSessionMessage(try decodeMessage(&buffer, .{ .type = .@"error", .reply_serial = 4, .error_name = "org.freedesktop.DBus.Error.ServiceUnknown" }, ""), &reports);
    try testing.expect(!desktop.sources.settings_portal);
    try testing.expect(!desktop.awaitingReplies());
}

test "UPower's battery, the power profile and logind's sleep are reported from replies and signals" {
    var desktop: DesktopBus = .{ .awaited = .{ .on_battery = 3, .power_profile = 4 } };
    var reports: Reports = .{};
    var buffer: [512]u8 = undefined;
    var body_buffer: [256]u8 = undefined;

    var body: dbus.Writer = .{ .buffer = &body_buffer };
    body.signature("b");
    body.boolean(true);
    desktop.readSystemMessage(try decodeMessage(&buffer, .{ .type = .method_return, .reply_serial = 3, .signature = "v" }, body_buffer[0..body.len]), &reports);
    body = .{ .buffer = &body_buffer };
    body.signature("s");
    body.string("power-saver");
    desktop.readSystemMessage(try decodeMessage(&buffer, .{ .type = .method_return, .reply_serial = 4, .signature = "v" }, body_buffer[0..body.len]), &reports);
    try testing.expect(desktop.sources.upower and desktop.sources.power_profiles);

    body = .{ .buffer = &body_buffer };
    body.string(upower.service);
    const changed = body.beginArray(8);
    body.beginStruct();
    body.string("Percentage");
    body.signature("d");
    body.alignTo(8);
    body.bytes(&@as([8]u8, @splat(0)));
    body.beginStruct();
    body.string("OnBattery");
    body.signature("b");
    body.boolean(false);
    body.endArray(changed);
    const invalidated = body.beginArray(4);
    body.endArray(invalidated);
    desktop.readSystemMessage(try decodeMessage(&buffer, .{ .type = .signal, .path = upower.path, .interface = properties_interface, .member = "PropertiesChanged", .signature = "sa{sv}as" }, body_buffer[0..body.len]), &reports);

    body = .{ .buffer = &body_buffer };
    body.boolean(true);
    desktop.readSystemMessage(try decodeMessage(&buffer, .{ .type = .signal, .path = "/org/freedesktop/login1", .interface = "org.freedesktop.login1.Manager", .member = "PrepareForSleep", .signature = "b" }, body_buffer[0..body.len]), &reports);

    try testing.expectEqualSlices(Report, &.{ .{ .on_battery = true }, .{ .power_saver = true }, .{ .on_battery = false }, .{ .preparing_for_sleep = true } }, reports.all());
}

test "without a bus to connect to, nothing is awaited and no source answers" {
    var desktop: DesktopBus = .{};
    const deadline = zui.Instant.fromTimestamp(std.Io.Timestamp.now(testing.io, .awake)).addNanoseconds(std.time.ns_per_s);
    desktop.open(testing.io, .{ .session = "unix:path=/nonexistent/zui-host-bus", .system = null }, deadline);
    defer desktop.close();
    try testing.expect(!desktop.awaitingReplies());
    try testing.expectEqual([2]i32{ -1, -1 }, desktop.descriptors());
}

const ReplyWatch = struct {
    serial: u32,
    answered: bool = false,

    pub fn onMessage(self: *ReplyWatch, message: dbus.Message) void {
        if (message.header.type == .method_return and message.header.reply_serial == self.serial) self.answered = true;
    }
};

fn awaitReply(connection: *dbus.Connection, io: std.Io, serial: u32, deadline: zui.Instant) !void {
    var watch: ReplyWatch = .{ .serial = serial };
    while (!watch.answered) {
        if (!connection.waitFor(io, std.os.linux.POLL.IN, deadline)) return error.Timeout;
        try connection.receive(&watch);
    }
}

/// The `ReadAll` call a played portal is to answer.
const ReadAllWatch = struct {
    serial: ?u32 = null,
    sender: [64]u8 = undefined,
    sender_len: usize = 0,

    pub fn onMessage(self: *ReadAllWatch, message: dbus.Message) void {
        const header = message.header;
        if (header.type != .method_call or !std.mem.eql(u8, header.member orelse "", "ReadAll")) return;
        const sender = header.sender orelse return;
        if (sender.len > self.sender.len) return;
        @memcpy(self.sender[0..sender.len], sender);
        self.sender_len = sender.len;
        self.serial = header.serial;
    }
};

fn connectAndSayHello(connection: *dbus.Connection, io: std.Io, address: []const u8, deadline: zui.Instant) !void {
    try connection.open(io, address, deadline);
    var hello = bus_service;
    hello.member = "Hello";
    try awaitReply(connection, io, try connection.send(io, hello, "", deadline), deadline);
}

fn takePortalName(connection: *dbus.Connection, io: std.Io, deadline: zui.Instant) !void {
    var body_buffer: [128]u8 = undefined;
    var body: dbus.Writer = .{ .buffer = &body_buffer };
    body.string(portal.service);
    const do_not_queue = 4;
    body.uint32(do_not_queue);
    var request_name = bus_service;
    request_name.member = "RequestName";
    request_name.signature = "su";
    try awaitReply(connection, io, try connection.send(io, request_name, body_buffer[0..body.len], deadline), deadline);
}

/// A `SettingChanged` signal, or with `reply_to` the answer to `ReadAll`.
fn sendColorScheme(connection: *dbus.Connection, io: std.Io, reply_to: ?*const ReadAllWatch, value: u32, deadline: zui.Instant) !void {
    var body_buffer: [256]u8 = undefined;
    var body: dbus.Writer = .{ .buffer = &body_buffer };
    if (reply_to == null) {
        body.string(portal.appearance);
        body.string("color-scheme");
        body.signature("u");
        body.uint32(value);
    } else {
        const namespaces = body.beginArray(8);
        body.beginStruct();
        body.string(portal.appearance);
        const settings = body.beginArray(8);
        body.beginStruct();
        body.string("color-scheme");
        body.signature("u");
        body.uint32(value);
        body.endArray(settings);
        body.endArray(namespaces);
    }
    const header: dbus.Header = if (reply_to) |call|
        .{ .type = .method_return, .reply_serial = call.serial, .destination = call.sender[0..call.sender_len], .signature = "a{sa{sv}}" }
    else
        .{ .type = .signal, .path = portal.path, .interface = portal.interface, .member = "SettingChanged", .signature = "ssv" };
    _ = try connection.send(io, header, body_buffer[0..body.len], deadline);
}

fn receiveReportsBefore(desktop: *DesktopBus, reports: *Reports, io: std.Io, deadline: zui.Instant) !void {
    if (!desktop.session.waitFor(io, std.os.linux.POLL.IN, deadline)) return error.Timeout;
    desktop.receive(reports);
}

test "through a bus daemon, the portal's answer and its signals reach the host, and another sender's do not" {
    const address = std.mem.span(std.c.getenv("ZUI_HOST_TEST_SESSION_BUS") orelse return error.SkipZigTest);
    const io = testing.io;
    const deadline = zui.Instant.fromTimestamp(std.Io.Timestamp.now(io, .awake)).addNanoseconds(5 * std.time.ns_per_s);
    var played_portal: dbus.Connection = .{};
    defer played_portal.close();
    try connectAndSayHello(&played_portal, io, address, deadline);
    try takePortalName(&played_portal, io, deadline);

    var desktop: DesktopBus = .{};
    desktop.open(io, .{ .session = address, .system = null }, deadline);
    defer desktop.close();
    var read_all: ReadAllWatch = .{};
    while (read_all.serial == null) {
        if (!played_portal.waitFor(io, std.os.linux.POLL.IN, deadline)) return error.Timeout;
        try played_portal.receive(&read_all);
    }
    try sendColorScheme(&played_portal, io, &read_all, 1, deadline);
    var reports: Reports = .{};
    while (desktop.awaitingReplies()) try receiveReportsBefore(&desktop, &reports, io, deadline);
    try testing.expect(desktop.sources.settings_portal);

    var impostor: dbus.Connection = .{};
    defer impostor.close();
    try connectAndSayHello(&impostor, io, address, deadline);
    try sendColorScheme(&impostor, io, null, 1, deadline);
    var get_id = bus_service;
    get_id.member = "GetId";
    // The bus has routed the impostor's signal once it answers a call sent after it.
    try awaitReply(&impostor, io, try impostor.send(io, get_id, "", deadline), deadline);
    try sendColorScheme(&played_portal, io, null, 2, deadline);
    while (reports.count < 2) try receiveReportsBefore(&desktop, &reports, io, deadline);
    try testing.expectEqualSlices(Report, &.{ .{ .theme = .dark }, .{ .theme = .light } }, reports.all());
}
