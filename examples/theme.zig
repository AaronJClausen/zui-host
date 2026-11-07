//! A window styled by a ZON theme file, restyled as soon as the file
//! changes: the host's file watch publishes each change into a source,
//! declaration sees the theme's file among them, and the loader reads and
//! parses it into a second source the next frame draws with.
//!
//! ```sh
//! zig build theme                          # edit examples/theme.zon while it runs
//! zig build theme -- --theme my/theme.zon  # watch another file
//! zig build theme -- --check               # rewrite a theme file, wait for the restyled frame, quit
//! ```

const std = @import("std");
const zui_host = @import("zui_host");
const zui_async = @import("zui_async");
const zui_sokol = @import("zui_sokol");
const zui = zui_host.zui;
const Host = zui_host.Host;
const Renderer = zui_sokol.Renderer;

const Theme = struct {
    background: u24,
    panel: u24,
    text: u24,
    accent: u24,

    const fallback: Theme = .{ .background = 0x202020, .panel = 0x2d2d2d, .text = 0xf3f3f3, .accent = 0x4cc2ff };
};

const ThemeSources = struct {
    theme_files: zui_async.Stream(zui.FileChange, .{ .capacity = 32 }) = .{},
    theme: zui_async.Latest(Theme) = .{},
};

const Ui = zui.Context(zui_sokol.config(.{ .Sources = ThemeSources }));
const root_id: zui.Id = .of("root");

const App = struct {
    sources: ThemeSources = .{},
    theme_path: []const u8,
    /// The theme file's name within the watched directory, as changes name it.
    theme_name: []const u8,
    /// Declaration saw the theme file change; the loader reads it.
    reload_requested: bool = false,

    fn declare(app: *App, ui: *Ui) void {
        var changes = ui.source(.theme_files).items();
        while (changes.next()) |change| {
            const names_theme = std.mem.eql(u8, change.pathBytes(), app.theme_name);
            if (change.kind == .rescan or (names_theme and change.kind != .removed and change.kind != .renamed_from)) app.reload_requested = true;
        }
        const theme = ui.source(.theme).get() orelse Theme.fallback;

        ui.open(.{
            .id = root_id,
            .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both, .padding = .all(32), .child_gap = 16 },
            .decoration = .{ .background = .rgb(theme.background) },
        });
        defer ui.close();
        ui.text("A theme from a file", .{ .size = 32, .color = .rgb(theme.text) });
        ui.text("Edit the theme file and save it: the next frame takes its colors.", .{ .size = 16, .color = .rgb(theme.text) });
        ui.open(.{
            .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(480), .height = .fit }, .padding = .all(20), .child_gap = 8 },
            .decoration = .{ .background = .rgb(theme.panel), .border = .{ .color = .rgb(theme.accent), .widths = .all(2) }, .corner_radius = .all(8) },
        });
        defer ui.close();
        ui.text(app.theme_path, .{ .size = 16, .color = .rgb(theme.accent) });
    }

    /// Runs between frames: reads the theme file when declaration asked,
    /// and publishes it for the next frame. A file that does not parse,
    /// as one caught half written, keeps the theme on screen.
    fn load(app: *App, io: std.Io, waker: zui.Waker) void {
        if (!app.reload_requested) return;
        app.reload_requested = false;
        const theme = readTheme(io, app.theme_path) catch |err| {
            std.debug.print("theme: kept the last theme, {s} did not load: {s}\n", .{ app.theme_path, @errorName(err) });
            return;
        };
        waker.wakeIf(app.sources.theme.publish(theme));
    }
};

fn readTheme(io: std.Io, path: []const u8) !Theme {
    var source: [4096]u8 = undefined;
    const bytes = try std.Io.Dir.cwd().readFile(io, path, source[0 .. source.len - 1]);
    source[bytes.len] = 0;
    var parse_memory: [4096]u8 = undefined;
    var parse_allocator: std.heap.FixedBufferAllocator = .init(&parse_memory);
    return std.zon.parse.fromSlice(Theme, parse_allocator.allocator(), source[0..bytes.len :0], null, .{});
}

fn writeTheme(io: std.Io, path: []const u8, theme: Theme) !void {
    var text: [256]u8 = undefined;
    const zon = try std.fmt.bufPrint(&text, ".{{\n    .background = 0x{x:0>6},\n    .panel = 0x{x:0>6},\n    .text = 0x{x:0>6},\n    .accent = 0x{x:0>6},\n}}\n", .{ theme.background, theme.panel, theme.text, theme.accent });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = zon });
}

fn rootBackground(frame: *const Ui.Frame) ?zui.Color {
    for (frame.commands()) |command| {
        if (command.id == root_id.hash and command.payload == .rectangle) return command.payload.rectangle.color;
    }
    return null;
}

/// What `--check` writes before the window opens, and then over it.
const check_themes = [2]Theme{
    .{ .background = 0x1e1e2e, .panel = 0x313244, .text = 0xcdd6f4, .accent = 0x89b4fa },
    .{ .background = 0xeff1f5, .panel = 0xdce0e8, .text = 0x4c4f69, .accent = 0x1e66f5 },
};
const check_directory = "zig-out/theme-check";
const check_deadline_ns = 10 * std.time.ns_per_s;

pub fn main(init: std.process.Init) !void {
    comptime zui.checkHostAndRenderer(Host, Renderer);
    const gpa = init.gpa;
    const io = init.io;
    var theme_path: []const u8 = "examples/theme.zon";
    var check = false;
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    var index: usize = 1;
    while (index < arguments.len) : (index += 1) {
        if (std.mem.eql(u8, arguments[index], "--check")) {
            check = true;
        } else if (std.mem.eql(u8, arguments[index], "--theme") and index + 1 < arguments.len) {
            index += 1;
            theme_path = arguments[index];
        } else {
            std.debug.print("unknown argument \"{s}\"; expected --theme <path> or --check\n", .{arguments[index]});
            return error.UnknownArgument;
        }
    }
    if (check) {
        theme_path = check_directory ++ "/theme.zon";
        try std.Io.Dir.cwd().createDirPath(io, check_directory);
        try writeTheme(io, theme_path, check_themes[0]);
    }

    const app = try gpa.create(App);
    defer gpa.destroy(app);
    app.* = .{ .theme_path = theme_path, .theme_name = std.fs.path.basename(theme_path) };

    const host = try gpa.create(Host);
    defer gpa.destroy(host);
    host.forced_scale = null;
    host.system_material_unavailable = false;
    try host.init(io, .{ .title = "zui: a theme from a file", .size = .{ 720, 360 } });
    defer host.deinit();
    const waker = host.zuiWaker();
    const directory = std.fs.path.dirname(theme_path) orelse ".";
    try Host.zuiFileWatch.watch(host, directory, .of(&app.sources.theme_files));
    app.reload_requested = true;
    app.load(io, waker);

    var text: zui_sokol.Text = .{};
    var renderer: Renderer = try .initForSurface(&text, host.zuiSurface(.main));
    defer renderer.deinit();

    var ui: Ui = try .init(gpa, io, &text);
    defer ui.deinit(gpa);

    var events: [Ui.limits.max_events_per_frame]zui.Event = undefined;
    var text_buffer: [Ui.limits.max_text_input_bytes + Ui.limits.max_dropped_path_bytes]u8 = undefined;
    var builder: zui.RecordBuilder = .init(&events, &text_buffer);
    var rewritten_at: ?zui.Instant = null;
    const check_deadline = host.now().addNanoseconds(check_deadline_ns);
    while (host.zuiPoll(.main, &builder)) {
        ui.beginFrame(&builder.recordWith(Ui.Deliveries), &app.sources);
        app.declare(&ui);
        const frame = ui.endFrame();
        try renderer.zuiSubmit(host.zuiSurface(.main), frame);
        host.zuiApply(.main, frame.requests());
        const background = rootBackground(frame);
        const frame_number = frame.number;
        ui.release(frame);
        app.load(io, waker);

        if (check) {
            const drawn = background orelse return error.RootNotDrawn;
            if (rewritten_at) |written| {
                if (drawn.eql(.rgb(check_themes[1].background))) {
                    const latency_ns = host.now().nanoseconds - written.nanoseconds;
                    std.debug.print("theme: restyled in frame {d}, {d:.1} ms after the file was rewritten\n", .{ frame_number, @as(f64, @floatFromInt(latency_ns)) / std.time.ns_per_ms });
                    return;
                }
            } else if (drawn.eql(.rgb(check_themes[0].background))) {
                try writeTheme(io, theme_path, check_themes[1]);
                rewritten_at = host.now();
            }
            if (!host.now().isBefore(check_deadline)) {
                std.debug.print("theme: no frame drew the rewritten theme within {d} s\n", .{check_deadline_ns / std.time.ns_per_s});
                return error.ThemeNotRestyled;
            }
            host.zuiWait(switch (ui.nextFrame(&app.sources)) {
                .on_event => .{ .at = check_deadline },
                else => |next| next,
            });
        } else {
            host.zuiWait(ui.nextFrame(&app.sources));
        }
    }
}
