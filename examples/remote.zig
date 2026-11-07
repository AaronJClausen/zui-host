//! ```sh
//! zig build remote                         # the tour runs in a second process; this one draws it
//! zig build remote -- --check tour.bmp     # switch screens by key, check what came back, save it, quit
//! zig build remote -- --serve 7420         # only the tour, waiting for a viewer on port 7420
//! zig build remote -- --connect 7420       # only the viewer, joining a tour served on port 7420
//! ```

const std = @import("std");
const zui_host = @import("zui_host");
const zui_sokol = @import("zui_sokol");
const zui_app = @import("zui_app");
const zui_wire = @import("zui_wire");
const tour = @import("zui_sokol_tour");
const capture = @import("capture.zig");
const zui = zui_host.zui;
const Ui = tour.kit.Ui;

const Mode = union(enum) {
    /// Serves the tour in a child process of its own, and draws it.
    both: ?[]const u8,
    serve: u16,
    connect: u16,
};

pub fn main(init: std.process.Init) !void {
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    switch (try parseMode(arguments)) {
        .serve => |port| {
            serve_port = port;
            try zui_app.run(TourOverWire, init, .{ .title = "zui tour over the wire" });
        },
        .connect => |port| try view(init.gpa, init.io, port, null),
        .both => |check_path| {
            var child = try std.process.spawn(init.io, .{ .argv = &.{ arguments[0], "--serve", "0" }, .stdout = .pipe });
            defer child.kill(init.io);
            var line_buffer: [64]u8 = undefined;
            var child_output = child.stdout.?.reader(init.io, &line_buffer);
            const line = try child_output.interface.takeDelimiterExclusive('\n');
            const port = try std.fmt.parseInt(u16, std.mem.trim(u8, line, " \r"), 10);
            try view(init.gpa, init.io, port, check_path);
            const ended = try child.wait(init.io);
            std.debug.print("the tour's process ended: {any}\n", .{ended});
            if (ended != .exited or ended.exited != 0) return error.TourProcessFailed;
        },
    }
}

/// The port `--serve` listens on, 0 for any; the one it got is printed.
var serve_port: u16 = 0;

/// zui-sokol's tour, unchanged, on zui_wire's host and renderer: its input
/// comes from the viewer and its frames go back to it.
const TourOverWire = struct {
    pub const Host = zui_wire.Host(Ui);
    pub const Renderer = zui_wire.Renderer(Ui);
    pub const Text = zui_sokol.Text;

    tour: tour.App,
    sources: *tour.kit.Sources,

    pub fn init(app: *TourOverWire, start: zui_app.Start(TourOverWire)) !void {
        var address: std.Io.net.IpAddress = .{ .ip4 = .loopback(serve_port) };
        var server = try address.listen(start.io, .{});
        defer server.deinit(start.io);
        var stdout_buffer: [64]u8 = undefined;
        var stdout = std.Io.File.stdout().writer(start.io, &stdout_buffer);
        try stdout.interface.print("{d}\n", .{server.socket.address.getPort()});
        try stdout.interface.flush();
        try start.host.attach(start.gpa, try server.accept(start.io));

        app.* = .{ .tour = undefined, .sources = &app.tour.sources };
        app.tour.init(start.io, start.host.now());
        app.tour.host_waker = start.waker;
    }

    pub fn deinit(app: *TourOverWire) void {
        app.tour.deinit();
    }

    pub fn zuiRecord(app: *TourOverWire, record: *zui.RecordBuilder) void {
        record.params.zoom = app.tour.zoom;
        for (app.tour.environment_changes.drain()) |change| record.append(.{ .environment = change });
    }

    pub fn zuiDeclare(app: *TourOverWire, ui: *Ui) void {
        app.tour.declare(ui);
    }

    pub fn zuiLoader(app: *TourOverWire, ui: *const Ui, _: std.Io) void {
        // The tour's loaders only read `ui`; they take it as zui-sokol's own loop gives it.
        app.tour.afterFrame(@constCast(ui));
    }
};

/// Draws the tour served on `port` in a window of this host, with
/// zui-sokol's renderer, until the window or the connection closes. With
/// `check_path`, the input is scripted and the run ends by itself.
fn view(gpa: std.mem.Allocator, io: std.Io, port: u16, check_path: ?[]const u8) !void {
    const host = try gpa.create(zui_host.Host);
    defer gpa.destroy(host);
    host.forced_scale = null;
    host.system_material_unavailable = false;
    try host.init(io, .{ .title = "zui tour, drawn here, running elsewhere", .size = .{ 1440, 900 } });
    defer host.deinit();
    var text: zui_sokol.Text = .{};
    var renderer: zui_sokol.Renderer = try .initForSurface(&text, host.zuiSurface(.main));
    defer renderer.deinit();
    renderer.clear_color = tour.kit.Palette.forEnvironment(&.{}).background;

    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(port) };
    const client = try gpa.create(zui_wire.Client(Ui));
    defer gpa.destroy(client);
    try client.init(gpa, io, try address.connect(io, .{ .mode = .stream }), .{ .waker = host.zuiWaker(), .fingerprint = zui_wire.fingerprintOf(&text) });
    defer client.deinit();

    const path = check_path orelse {
        while (try client.frame(host, &renderer)) {}
        return;
    };
    var script: Script = .{ .started_at = host.now() };
    while (client.poll(host)) {
        const now = client.builder.params.now;
        if (script.done) {
            try capture.saveClientArea(gpa, io, host.hwnd, path);
            std.debug.print("saved {s}\n", .{path});
            host.close();
        } else if (now.secondsSince(script.started_at) > Script.patience_seconds) {
            std.debug.print("the tour never showed {t}; {d} frames came back\n", .{ Script.steps[script.step].screen, client.framesReceived() });
            return error.CheckFailed;
        }
        script.post(&client.builder, now);
        client.send();
        if (try client.present(host, &renderer)) script.saw(client.shownFrame(), now);
        if (client.isClosed()) return error.TourClosedEarly;
        host.zuiWait(.{ .at = now.addNanoseconds(Script.poll_interval_ns) });
    }
}

/// Presses Ctrl and a digit for each screen in turn, and moves on once a
/// frame that came back shows that screen's tagline.
const Script = struct {
    started_at: zui.Instant,
    step: usize = 0,
    pressed: bool = false,
    done: bool = false,

    const patience_seconds = 20;
    const poll_interval_ns = 50 * std.time.ns_per_ms;

    const Step = struct { screen: tour.kit.Screen, key: ?zui.Key };
    const steps = [_]Step{
        .{ .screen = .welcome, .key = null },
        .{ .screen = .layout_lab, .key = .digit_2 },
        .{ .screen = .gallery, .key = .digit_4 },
        .{ .screen = .typography, .key = .digit_9 },
    };

    fn post(self: *Script, record: *zui.RecordBuilder, now: zui.Instant) void {
        if (self.done or self.pressed) return;
        const key = steps[self.step].key orelse return;
        const control: zui.Modifiers = .{ .control = true };
        record.append(.{ .key_down = .{ .key = key, .modifiers = control, .at = now } });
        record.append(.{ .key_up = .{ .key = key, .modifiers = control, .at = now } });
        self.pressed = true;
    }

    fn saw(self: *Script, frame: anytype, now: zui.Instant) void {
        if (self.done or !showsTagline(frame, steps[self.step].screen.info().tagline)) return;
        std.debug.print("{t}: frame {d}, {d} commands, {d:.0} ms into the run\n", .{ steps[self.step].screen, frame.number, frame.commands().len, now.secondsSince(self.started_at) * 1000 });
        self.step += 1;
        self.pressed = false;
        self.done = self.step == steps.len;
    }

    /// The tagline's first line is one text command; the rail names every
    /// screen, so the title alone would not tell them apart.
    fn showsTagline(frame: anytype, tagline: []const u8) bool {
        for (frame.commands()) |command| switch (command.payload) {
            .text => |text| if (text.content.len >= 8 and std.mem.startsWith(u8, tagline, text.content)) return true,
            else => {},
        };
        return false;
    }
};

fn parseMode(arguments: []const [:0]const u8) !Mode {
    if (arguments.len == 1) return .{ .both = null };
    if (arguments.len == 3) {
        const value = arguments[2];
        if (std.mem.eql(u8, arguments[1], "--check")) return .{ .both = value };
        if (std.mem.eql(u8, arguments[1], "--serve")) return .{ .serve = try std.fmt.parseInt(u16, value, 10) };
        if (std.mem.eql(u8, arguments[1], "--connect")) return .{ .connect = try std.fmt.parseInt(u16, value, 10) };
    }
    std.debug.print("expected no arguments, --check <path.bmp>, --serve <port> or --connect <port>\n", .{});
    return error.UnknownArgument;
}
