//! A D-Bus client of the host's own, over a Unix socket: just enough of
//! the wire format to call a method, subscribe to signals and read the
//! replies, into fixed buffers, so it allocates nothing.

const std = @import("std");
const zui = @import("zui");
const linux = std.os.linux;

pub const MessageType = enum(u8) { method_call = 1, method_return = 2, @"error" = 3, signal = 4, _ };

pub const Flags = packed struct(u8) {
    no_reply_expected: bool = false,
    no_auto_start: bool = false,
    _: u6 = 0,
};

pub const Header = struct {
    type: MessageType,
    flags: Flags = .{},
    serial: u32 = 0,
    path: ?[]const u8 = null,
    interface: ?[]const u8 = null,
    member: ?[]const u8 = null,
    error_name: ?[]const u8 = null,
    reply_serial: ?u32 = null,
    destination: ?[]const u8 = null,
    sender: ?[]const u8 = null,
    /// The body's types; empty for a message without a body.
    signature: []const u8 = "",
};

const FieldCode = enum(u8) { path = 1, interface = 2, member = 3, error_name = 4, reply_serial = 5, destination = 6, sender = 7, signature = 8, _ };

const fixed_header_len = 16;
const protocol_version = 1;
const max_message_len = 1 << 27;
/// The protocol allows 32 nested arrays and 32 nested structs.
const max_nesting = 64;

/// Writes values in little-endian order, each aligned from the start of
/// `buffer`, which must itself start a message or a message's body.
pub const Writer = struct {
    buffer: []u8,
    len: usize = 0,
    overflowed: bool = false,

    pub const Array = struct { length_at: usize, elements_at: usize };

    pub fn alignTo(self: *Writer, alignment: usize) void {
        const aligned = std.mem.alignForward(usize, self.len, alignment);
        if (aligned > self.buffer.len) {
            self.overflowed = true;
            return;
        }
        @memset(self.buffer[self.len..aligned], 0);
        self.len = aligned;
    }

    pub fn bytes(self: *Writer, data: []const u8) void {
        if (data.len > self.buffer.len - self.len) {
            self.overflowed = true;
            return;
        }
        @memcpy(self.buffer[self.len..][0..data.len], data);
        self.len += data.len;
    }

    pub fn byte(self: *Writer, value: u8) void {
        self.bytes(&.{value});
    }

    pub fn uint32(self: *Writer, value: u32) void {
        self.alignTo(4);
        var encoded: [4]u8 = undefined;
        std.mem.writeInt(u32, &encoded, value, .little);
        self.bytes(&encoded);
    }

    pub fn boolean(self: *Writer, value: bool) void {
        self.uint32(@intFromBool(value));
    }

    /// Also an object path, which is written as a string is.
    pub fn string(self: *Writer, text: []const u8) void {
        self.uint32(@intCast(text.len));
        self.bytes(text);
        self.byte(0);
    }

    pub fn signature(self: *Writer, text: []const u8) void {
        self.byte(@intCast(text.len));
        self.bytes(text);
        self.byte(0);
    }

    pub fn beginArray(self: *Writer, element_alignment: usize) Array {
        self.uint32(0);
        const length_at = self.len -| 4;
        self.alignTo(element_alignment);
        return .{ .length_at = length_at, .elements_at = self.len };
    }

    pub fn endArray(self: *Writer, array: Array) void {
        if (self.overflowed) return;
        std.mem.writeInt(u32, self.buffer[array.length_at..][0..4], @intCast(self.len - array.elements_at), .little);
    }

    /// Also a dictionary entry, which is aligned as a struct is.
    pub fn beginStruct(self: *Writer) void {
        self.alignTo(8);
    }
};

/// Encodes a whole message into `buffer`, its body already encoded by a
/// `Writer` of its own.
pub fn encode(buffer: []u8, header: Header, body: []const u8) error{MessageTooLarge}![]const u8 {
    var writer: Writer = .{ .buffer = buffer };
    writer.byte('l');
    writer.byte(@intFromEnum(header.type));
    writer.byte(@bitCast(header.flags));
    writer.byte(protocol_version);
    writer.uint32(@intCast(body.len));
    writer.uint32(header.serial);
    const fields = writer.beginArray(8);
    const text_fields = [_]struct { FieldCode, []const u8, ?[]const u8 }{
        .{ .path, "o", header.path },
        .{ .interface, "s", header.interface },
        .{ .member, "s", header.member },
        .{ .error_name, "s", header.error_name },
        .{ .destination, "s", header.destination },
        .{ .sender, "s", header.sender },
    };
    for (text_fields) |text_field| if (text_field[2]) |value| {
        writer.beginStruct();
        writer.byte(@intFromEnum(text_field[0]));
        writer.signature(text_field[1]);
        writer.string(value);
    };
    if (header.reply_serial) |reply_serial| {
        writer.beginStruct();
        writer.byte(@intFromEnum(FieldCode.reply_serial));
        writer.signature("u");
        writer.uint32(reply_serial);
    }
    if (header.signature.len > 0) {
        writer.beginStruct();
        writer.byte(@intFromEnum(FieldCode.signature));
        writer.signature("g");
        writer.signature(header.signature);
    }
    writer.endArray(fields);
    writer.alignTo(8);
    writer.bytes(body);
    if (writer.overflowed) return error.MessageTooLarge;
    return buffer[0..writer.len];
}

/// Reads values aligned from the start of `bytes`, in the sender's byte order.
pub const Reader = struct {
    bytes: []const u8,
    position: usize = 0,
    endian: std.builtin.Endian = .little,

    pub const Error = error{Malformed};

    pub fn alignTo(self: *Reader, alignment: usize) Error!void {
        const aligned = std.mem.alignForward(usize, self.position, alignment);
        if (aligned > self.bytes.len) return error.Malformed;
        self.position = aligned;
    }

    fn take(self: *Reader, len: usize) Error![]const u8 {
        if (len > self.bytes.len - self.position) return error.Malformed;
        defer self.position += len;
        return self.bytes[self.position..][0..len];
    }

    pub fn byte(self: *Reader) Error!u8 {
        return (try self.take(1))[0];
    }

    pub fn uint32(self: *Reader) Error!u32 {
        try self.alignTo(4);
        return std.mem.readInt(u32, (try self.take(4))[0..4], self.endian);
    }

    pub fn boolean(self: *Reader) Error!bool {
        return try self.uint32() != 0;
    }

    /// Also an object path.
    pub fn string(self: *Reader) Error![]const u8 {
        const len = try self.uint32();
        const text = try self.take(len);
        if (try self.byte() != 0) return error.Malformed;
        return text;
    }

    pub fn signature(self: *Reader) Error![]const u8 {
        const len = try self.byte();
        const text = try self.take(len);
        if (try self.byte() != 0) return error.Malformed;
        return text;
    }

    /// Returns the position the array's elements end at.
    pub fn beginArray(self: *Reader, element_alignment: usize) Error!usize {
        const len = try self.uint32();
        try self.alignTo(element_alignment);
        if (len > self.bytes.len - self.position) return error.Malformed;
        return self.position + len;
    }

    /// Also a dictionary entry.
    pub fn beginStruct(self: *Reader) Error!void {
        try self.alignTo(8);
    }

    /// A variant's signature, looking through variants inside it.
    pub fn variantSignature(self: *Reader) Error![]const u8 {
        var inner = try self.signature();
        var depth: usize = 0;
        while (std.mem.eql(u8, inner, "v")) : (depth += 1) {
            if (depth == max_nesting) return error.Malformed;
            inner = try self.signature();
        }
        return inner;
    }

    /// Skips one value of the single complete type `type_signature`.
    pub fn skip(self: *Reader, type_signature: []const u8) Error!void {
        var rest = type_signature;
        try self.skipOne(&rest, 0);
        if (rest.len != 0) return error.Malformed;
    }

    fn skipOne(self: *Reader, rest: *[]const u8, depth: usize) Error!void {
        if (depth > max_nesting or rest.len == 0) return error.Malformed;
        const code = rest.*[0];
        switch (code) {
            'a' => {
                const element_len = try completeTypeLength(rest.*[1..], depth + 1);
                const end = try self.beginArray(alignmentOf(rest.*[1]));
                self.position = end;
                rest.* = rest.*[1 + element_len ..];
                return;
            },
            '(', '{' => {
                const close: u8 = if (code == '(') ')' else '}';
                try self.beginStruct();
                rest.* = rest.*[1..];
                while (rest.len > 0 and rest.*[0] != close) try self.skipOne(rest, depth + 1);
                if (rest.len == 0) return error.Malformed;
                rest.* = rest.*[1..];
                return;
            },
            'v' => {
                const inner = try self.signature();
                var inner_rest = inner;
                try self.skipOne(&inner_rest, depth + 1);
                if (inner_rest.len != 0) return error.Malformed;
            },
            's', 'o' => _ = try self.string(),
            'g' => _ = try self.signature(),
            'y', 'b', 'n', 'q', 'i', 'u', 'h', 'x', 't', 'd' => {
                const size = alignmentOf(code);
                try self.alignTo(size);
                _ = try self.take(size);
            },
            else => return error.Malformed,
        }
        rest.* = rest.*[1..];
    }
};

fn alignmentOf(code: u8) usize {
    return switch (code) {
        'y', 'g', 'v' => 1,
        'n', 'q' => 2,
        'x', 't', 'd', '(', '{' => 8,
        else => 4,
    };
}

fn completeTypeLength(type_signature: []const u8, depth: usize) Reader.Error!usize {
    if (depth > max_nesting or type_signature.len == 0) return error.Malformed;
    switch (type_signature[0]) {
        'a' => return 1 + try completeTypeLength(type_signature[1..], depth + 1),
        '(', '{' => {
            const close: u8 = if (type_signature[0] == '(') ')' else '}';
            var len: usize = 1;
            while (len < type_signature.len) {
                if (type_signature[len] == close) return len + 1;
                len += try completeTypeLength(type_signature[len..], depth + 1);
            }
            return error.Malformed;
        },
        'y', 'b', 'n', 'q', 'i', 'u', 'h', 'x', 't', 'd', 's', 'o', 'g', 'v' => return 1,
        else => return error.Malformed,
    }
}

pub const Message = struct {
    header: Header,
    body: Reader,
};

fn endianOf(marker: u8) error{Malformed}!std.builtin.Endian {
    return switch (marker) {
        'l' => .little,
        'B' => .big,
        else => error.Malformed,
    };
}

/// The whole length of the message `prefix` starts, or null until its
/// fixed header has arrived.
pub fn messageLength(prefix: []const u8) error{Malformed}!?usize {
    if (prefix.len < fixed_header_len) return null;
    const endian = try endianOf(prefix[0]);
    const body_len = std.mem.readInt(u32, prefix[4..8], endian);
    const fields_len = std.mem.readInt(u32, prefix[12..16], endian);
    const total = std.mem.alignForward(u64, fixed_header_len + @as(u64, fields_len), 8) + body_len;
    if (total > max_message_len) return error.Malformed;
    return @intCast(total);
}

/// The message's header and a reader over its body; both point into
/// `message`.
pub fn decode(message: []const u8) error{Malformed}!Message {
    const total = try messageLength(message) orelse return error.Malformed;
    if (total != message.len or message[3] != protocol_version) return error.Malformed;
    var reader: Reader = .{ .bytes = message, .position = 4, .endian = try endianOf(message[0]) };
    const body_len = try reader.uint32();
    var header: Header = .{ .type = @enumFromInt(message[1]), .flags = @bitCast(message[2]), .serial = try reader.uint32() };
    const fields_end = try reader.beginArray(8);
    while (reader.position < fields_end) {
        try reader.beginStruct();
        const code: FieldCode = @enumFromInt(try reader.byte());
        const value_signature = try reader.signature();
        const is_text = std.mem.eql(u8, value_signature, "s") or std.mem.eql(u8, value_signature, "o");
        switch (code) {
            .path => header.path = if (is_text) try reader.string() else return error.Malformed,
            .interface => header.interface = if (is_text) try reader.string() else return error.Malformed,
            .member => header.member = if (is_text) try reader.string() else return error.Malformed,
            .error_name => header.error_name = if (is_text) try reader.string() else return error.Malformed,
            .destination => header.destination = if (is_text) try reader.string() else return error.Malformed,
            .sender => header.sender = if (is_text) try reader.string() else return error.Malformed,
            .reply_serial => header.reply_serial = if (std.mem.eql(u8, value_signature, "u")) try reader.uint32() else return error.Malformed,
            .signature => header.signature = if (std.mem.eql(u8, value_signature, "g")) try reader.signature() else return error.Malformed,
            _ => try reader.skip(value_signature),
        }
    }
    const body_start = std.mem.alignForward(usize, fields_end, 8);
    if (body_start + body_len != message.len) return error.Malformed;
    return .{ .header = header, .body = .{ .bytes = message[body_start..], .endian = reader.endian } };
}

/// Where a bus listens, from a D-Bus address list such as
/// `unix:path=/run/user/1000/bus;unix:abstract=/tmp/dbus-x`: the first
/// entry naming a Unix socket. Returns the address's length.
pub fn unixSocketAddress(address_list: []const u8, socket_address: *linux.sockaddr.un) ?linux.socklen_t {
    var entries = std.mem.splitScalar(u8, address_list, ';');
    while (entries.next()) |entry| {
        const prefix = "unix:";
        if (!std.mem.startsWith(u8, entry, prefix)) continue;
        var pairs = std.mem.splitScalar(u8, entry[prefix.len..], ',');
        while (pairs.next()) |pair| {
            const equals = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
            const key = pair[0..equals];
            const is_abstract = std.mem.eql(u8, key, "abstract");
            if (!is_abstract and !std.mem.eql(u8, key, "path")) continue;
            socket_address.* = .{ .path = @splat(0) };
            const name_start: usize = @intFromBool(is_abstract);
            // A path keeps a 0 byte after it; an abstract name is counted exactly.
            const name_capacity = socket_address.path.len - name_start - @intFromBool(!is_abstract);
            const name_len = unescape(pair[equals + 1 ..], socket_address.path[name_start..][0..name_capacity]) orelse continue;
            if (name_len == 0) continue;
            return @intCast(@offsetOf(linux.sockaddr.un, "path") + name_start + name_len);
        }
    }
    return null;
}

/// Decodes an address value's `%XX` escapes into `out`.
fn unescape(value: []const u8, out: []u8) ?usize {
    var len: usize = 0;
    var index: usize = 0;
    while (index < value.len) : (len += 1) {
        if (len == out.len) return null;
        if (value[index] == '%') {
            if (index + 3 > value.len) return null;
            out[len] = std.fmt.parseInt(u8, value[index + 1 ..][0..2], 16) catch return null;
            index += 3;
        } else {
            out[len] = value[index];
            index += 1;
        }
    }
    return len;
}

/// One connection to a bus, read without blocking once it is open.
pub const Connection = struct {
    fd: i32 = -1,
    next_serial: u32 = 1,
    received: [receive_capacity]u8 = undefined,
    received_len: usize = 0,
    /// The rest of a message too large for `received`, still to be read
    /// past.
    bytes_to_discard: usize = 0,

    pub const receive_capacity = 16 * 1024;
    const send_capacity = 1024;

    pub const OpenError = error{ NoBusAddress, BusUnavailable, AuthenticationFailed };
    pub const SendError = error{ MessageTooLarge, ConnectionLost };

    pub fn isOpen(self: *const Connection) bool {
        return self.fd >= 0;
    }

    /// Connects to the bus at `address_list` and authenticates as this
    /// process's user, giving up at `deadline`.
    pub fn open(self: *Connection, io: std.Io, address_list: []const u8, deadline: zui.Instant) OpenError!void {
        var socket_address: linux.sockaddr.un = undefined;
        const address_len = unixSocketAddress(address_list, &socket_address) orelse return error.NoBusAddress;
        const socket = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK, 0);
        if (linux.errno(socket) != .SUCCESS) return error.BusUnavailable;
        self.* = .{ .fd = @intCast(socket) };
        errdefer self.close();
        switch (linux.errno(linux.connect(self.fd, &socket_address, address_len))) {
            .SUCCESS => {},
            .AGAIN, .INPROGRESS => if (!self.waitFor(io, linux.POLL.OUT, deadline)) return error.BusUnavailable,
            else => return error.BusUnavailable,
        }
        self.authenticate(io, deadline) catch return error.AuthenticationFailed;
    }

    /// Takes a socket that is already connected and authenticated, as a
    /// test's pair of sockets is.
    pub fn adopt(self: *Connection, fd: i32) void {
        self.* = .{ .fd = fd };
    }

    pub fn close(self: *Connection) void {
        if (self.fd >= 0) _ = linux.close(self.fd);
        self.fd = -1;
    }

    /// SASL's EXTERNAL mechanism: the bus checks the user id against the
    /// socket's peer credentials.
    fn authenticate(self: *Connection, io: std.Io, deadline: zui.Instant) !void {
        var command_buffer: [64]u8 = undefined;
        var uid_buffer: [16]u8 = undefined;
        const uid = std.fmt.bufPrint(&uid_buffer, "{d}", .{linux.getuid()}) catch unreachable;
        const command = std.fmt.bufPrint(&command_buffer, "\x00AUTH EXTERNAL {x}\r\n", .{uid}) catch unreachable;
        try self.writeAll(io, command, deadline);
        const line_end = while (true) {
            if (std.mem.indexOf(u8, self.received[0..self.received_len], "\r\n")) |end| break end;
            if (self.received_len == self.received.len) return error.AuthenticationFailed;
            if (!self.waitFor(io, linux.POLL.IN, deadline)) return error.AuthenticationFailed;
            const read = linux.read(self.fd, self.received[self.received_len..].ptr, self.received.len - self.received_len);
            switch (linux.errno(read)) {
                .SUCCESS => if (read == 0) return error.AuthenticationFailed else {
                    self.received_len += read;
                },
                .AGAIN, .INTR => {},
                else => return error.AuthenticationFailed,
            }
        };
        if (!std.mem.startsWith(u8, self.received[0..line_end], "OK ")) return error.AuthenticationFailed;
        self.consume(line_end + 2);
        try self.writeAll(io, "BEGIN\r\n", deadline);
    }

    /// Sends a message with the next serial, which it returns. A reply
    /// carries the serial as its `reply_serial`.
    pub fn send(self: *Connection, io: std.Io, header: Header, body: []const u8, deadline: zui.Instant) SendError!u32 {
        var buffer: [send_capacity]u8 = undefined;
        var numbered = header;
        numbered.serial = self.next_serial;
        self.next_serial = if (self.next_serial == std.math.maxInt(u32)) 1 else self.next_serial + 1;
        const message = try encode(&buffer, numbered, body);
        self.writeAll(io, message, deadline) catch return error.ConnectionLost;
        return numbered.serial;
    }

    fn writeAll(self: *Connection, io: std.Io, data: []const u8, deadline: zui.Instant) error{ConnectionLost}!void {
        var written: usize = 0;
        while (written < data.len) {
            const sent = linux.sendto(self.fd, data[written..].ptr, data.len - written, linux.MSG.NOSIGNAL, null, 0);
            switch (linux.errno(sent)) {
                .SUCCESS => written += sent,
                .INTR => {},
                .AGAIN => if (!self.waitFor(io, linux.POLL.OUT, deadline)) return error.ConnectionLost,
                else => return error.ConnectionLost,
            }
        }
    }

    /// Waits until the socket is ready for `events` or the deadline passes.
    pub fn waitFor(self: *const Connection, io: std.Io, events: i16, deadline: zui.Instant) bool {
        while (true) {
            const remaining_ns = deadline.nanoseconds -| zui.Instant.fromTimestamp(std.Io.Timestamp.now(io, .awake)).nanoseconds;
            if (remaining_ns == 0) return false;
            var descriptor = [_]linux.pollfd{.{ .fd = self.fd, .events = events, .revents = 0 }};
            const timeout_ms: i32 = @intCast(@min(std.math.divCeil(u64, remaining_ns, std.time.ns_per_ms) catch unreachable, std.math.maxInt(i32)));
            const ready = linux.poll(&descriptor, 1, timeout_ms);
            switch (linux.errno(ready)) {
                .SUCCESS => if (ready > 0) return descriptor[0].revents & events != 0,
                .INTR => {},
                else => return false,
            }
        }
    }

    /// Reads what the bus has sent, without waiting, and calls
    /// `receiver.onMessage(message)` for each whole message. A message
    /// too large to hold, or one that does not decode, is passed over.
    pub fn receive(self: *Connection, receiver: anytype) error{ConnectionLost}!void {
        while (true) {
            const read = linux.read(self.fd, self.received[self.received_len..].ptr, self.received.len - self.received_len);
            switch (linux.errno(read)) {
                .SUCCESS => {
                    if (read == 0) return error.ConnectionLost;
                    self.received_len += read;
                    try self.dispatchReceived(receiver);
                },
                .INTR => {},
                .AGAIN => return,
                else => return error.ConnectionLost,
            }
        }
    }

    fn dispatchReceived(self: *Connection, receiver: anytype) error{ConnectionLost}!void {
        var start: usize = 0;
        while (start < self.received_len) {
            if (self.bytes_to_discard > 0) {
                const discarded = @min(self.bytes_to_discard, self.received_len - start);
                self.bytes_to_discard -= discarded;
                start += discarded;
                continue;
            }
            const available = self.received[start..self.received_len];
            const total = (messageLength(available) catch return error.ConnectionLost) orelse break;
            if (total > self.received.len) {
                self.bytes_to_discard = total;
                continue;
            }
            if (available.len < total) break;
            if (decode(available[0..total])) |message| receiver.onMessage(message) else |_| {}
            start += total;
        }
        self.consume(start);
    }

    fn consume(self: *Connection, len: usize) void {
        std.mem.copyForwards(u8, self.received[0 .. self.received_len - len], self.received[len..self.received_len]);
        self.received_len -= len;
    }
};

const testing = std.testing;

fn encodeSignal(buffer: []u8, member: []const u8, body_signature: []const u8, body: []const u8) ![]const u8 {
    return encode(buffer, .{ .type = .signal, .serial = 7, .path = "/a/b", .interface = "a.b.C", .member = member, .signature = body_signature }, body);
}

test "a message decodes to the header and body it was encoded with" {
    var body_buffer: [64]u8 = undefined;
    var body: Writer = .{ .buffer = &body_buffer };
    body.string("org.freedesktop.appearance");
    body.string("color-scheme");
    body.signature("u");
    body.uint32(1);
    var buffer: [256]u8 = undefined;
    const encoded = try encodeSignal(&buffer, "SettingChanged", "ssv", body_buffer[0..body.len]);
    try testing.expectEqual(encoded.len, (try messageLength(encoded)).?);

    var message = try decode(encoded);
    try testing.expectEqual(MessageType.signal, message.header.type);
    try testing.expectEqual(@as(u32, 7), message.header.serial);
    try testing.expectEqualStrings("/a/b", message.header.path.?);
    try testing.expectEqualStrings("SettingChanged", message.header.member.?);
    try testing.expectEqualStrings("ssv", message.header.signature);
    try testing.expectEqualStrings("org.freedesktop.appearance", try message.body.string());
    try testing.expectEqualStrings("color-scheme", try message.body.string());
    try testing.expectEqualStrings("u", try message.body.variantSignature());
    try testing.expectEqual(@as(u32, 1), try message.body.uint32());
}

test "a value of any type is skipped whole, arrays by their length" {
    var buffer: [256]u8 = undefined;
    var writer: Writer = .{ .buffer = &buffer };
    writer.byte(3);
    const outer = writer.beginArray(8);
    for (0..2) |_| {
        writer.beginStruct();
        writer.string("key");
        writer.signature("(ddd)");
        writer.beginStruct();
        for (0..3) |_| {
            writer.alignTo(8);
            writer.bytes(&@as([8]u8, @splat(0)));
        }
    }
    writer.endArray(outer);
    writer.string("after");
    try testing.expect(!writer.overflowed);

    var reader: Reader = .{ .bytes = buffer[0..writer.len] };
    try reader.skip("y");
    try reader.skip("a{sv}");
    try testing.expectEqualStrings("after", try reader.string());

    reader = .{ .bytes = buffer[0..writer.len] };
    try testing.expectError(error.Malformed, reader.skip("a{sv"));
    try testing.expectError(error.Malformed, reader.skip("yy"));
}

test "a truncated or misdeclared message does not decode" {
    var buffer: [256]u8 = undefined;
    const encoded = try encodeSignal(&buffer, "Changed", "", "");
    try testing.expectError(error.Malformed, decode(encoded[0 .. encoded.len - 1]));
    var corrupted = buffer;
    corrupted[0] = 'x';
    try testing.expectError(error.Malformed, decode(corrupted[0..encoded.len]));
    try testing.expectEqual(@as(?usize, null), try messageLength(encoded[0..15]));
}

test "a bus address names a Unix socket by path or abstract name, escapes decoded" {
    var socket_address: linux.sockaddr.un = undefined;
    const path_len = unixSocketAddress("tcp:host=localhost,port=1;unix:guid=00,path=/run/user/1000/b%75s", &socket_address).?;
    try testing.expectEqualStrings("/run/user/1000/bus", std.mem.sliceTo(&socket_address.path, 0));
    try testing.expectEqual(@offsetOf(linux.sockaddr.un, "path") + "/run/user/1000/bus".len, path_len);

    const abstract_len = unixSocketAddress("unix:abstract=/tmp/dbus-x", &socket_address).?;
    try testing.expectEqual(@as(u8, 0), socket_address.path[0]);
    try testing.expectEqualStrings("/tmp/dbus-x", socket_address.path[1..][0.."/tmp/dbus-x".len]);
    try testing.expectEqual(@offsetOf(linux.sockaddr.un, "path") + 1 + "/tmp/dbus-x".len, abstract_len);

    try testing.expectEqual(@as(?linux.socklen_t, null), unixSocketAddress("unix:tmpdir=/tmp", &socket_address));
    try testing.expectEqual(@as(?linux.socklen_t, null), unixSocketAddress("unix:path=/bad%2", &socket_address));
}

const Collected = struct {
    members: [4][16]u8 = undefined,
    count: usize = 0,

    pub fn onMessage(self: *Collected, message: Message) void {
        const member = message.header.member orelse return;
        @memcpy(self.members[self.count][0..member.len], member);
        self.count += 1;
    }
};

fn socketPair() ![2]i32 {
    var fds: [2]i32 = undefined;
    if (linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK, 0, &fds)) != .SUCCESS) return error.NoSocketPair;
    return fds;
}

test "messages that arrive in pieces are dispatched once whole, and one too large to hold is passed over" {
    const fds = try socketPair();
    defer _ = linux.close(fds[1]);
    var connection: Connection = .{};
    connection.adopt(fds[0]);
    defer connection.close();

    var buffer: [256]u8 = undefined;
    const first = try encodeSignal(&buffer, "First", "", "");
    var collected: Collected = .{};
    _ = linux.write(fds[1], first.ptr, 10);
    try connection.receive(&collected);
    try testing.expectEqual(@as(usize, 0), collected.count);
    _ = linux.write(fds[1], first[10..].ptr, first.len - 10);
    try connection.receive(&collected);
    try testing.expectEqual(@as(usize, 1), collected.count);

    var oversized: [Connection.receive_capacity + 64]u8 = undefined;
    var body: Writer = .{ .buffer = &oversized };
    body.string(&@as([Connection.receive_capacity]u8, @splat('x')));
    var large_message: [Connection.receive_capacity + 256]u8 = undefined;
    const large = try encodeSignal(&large_message, "Large", "s", oversized[0..body.len]);
    var written: usize = 0;
    while (written < large.len) {
        const sent = linux.write(fds[1], large[written..].ptr, large.len - written);
        if (linux.errno(sent) == .SUCCESS) written += sent;
        try connection.receive(&collected);
    }
    const last = try encodeSignal(&buffer, "Last", "", "");
    _ = linux.write(fds[1], last.ptr, last.len);
    try connection.receive(&collected);
    try testing.expectEqual(@as(usize, 2), collected.count);
    try testing.expectEqualStrings("Last", collected.members[1][0..4]);
}

test "authentication answers the bus's OK, then begins, and a refusal fails" {
    for ([_][]const u8{ "OK 0123456789abcdef0123456789abcdef\r\n", "REJECTED EXTERNAL\r\n" }) |answer| {
        const fds = try socketPair();
        defer _ = linux.close(fds[1]);
        _ = linux.write(fds[1], answer.ptr, answer.len);
        var connection: Connection = .{};
        connection.adopt(fds[0]);
        defer connection.close();
        const deadline = zui.Instant.fromTimestamp(std.Io.Timestamp.now(testing.io, .awake)).addNanoseconds(std.time.ns_per_s);
        const result = connection.authenticate(testing.io, deadline);
        var sent: [128]u8 = undefined;
        const sent_len = linux.read(fds[1], &sent, sent.len);
        if (answer[0] == 'O') {
            try result;
            try testing.expect(std.mem.startsWith(u8, sent[0..sent_len], "\x00AUTH EXTERNAL "));
            try testing.expect(std.mem.endsWith(u8, sent[0..sent_len], "\r\nBEGIN\r\n"));
        } else {
            try testing.expectError(error.AuthenticationFailed, result);
        }
    }
}
