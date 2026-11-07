//! A window that lets the desktop show through it where the system has a
//! material (Mica on Windows 11), and draws a solid background where it
//! does not, with the same application code: `declare` reads only
//! `Environment.system_material`.
//!
//! ```sh
//! zig build material                                  # Mica on Windows 11
//! zig build material -- --transient                   # Acrylic, which blurs what is behind the window
//! zig build material -- --no-system-material          # the fallback Windows 10 shows
//! zig build material -- --screenshot material.bmp     # save what the screen shows, then quit
//! ```

const std = @import("std");
const zui_host = @import("zui_host");
const zui_sokol = @import("zui_sokol");
const capture = @import("capture.zig");
const zui = zui_host.zui;
const Host = zui_host.Host;
const Renderer = zui_sokol.Renderer;

const Ui = zui.Context(zui_sokol.config(.{}));

const Palette = struct {
    background: zui.Color,
    card: zui.Color,
    text: zui.Color,
    muted: zui.Color,

    const light: Palette = .{ .background = .rgb(0xf3f3f3), .card = .rgba(0xffffffb0), .text = .rgb(0x1b1b1b), .muted = .rgb(0x5f5f5f) };
    const dark: Palette = .{ .background = .rgb(0x202020), .card = .rgba(0x2d2d2db0), .text = .rgb(0xf3f3f3), .muted = .rgb(0xb4b4b4) };

    fn of(environment: *const zui.Environment) Palette {
        return if (environment.theme == .dark) dark else light;
    }
};

fn declare(ui: *Ui) void {
    const environment = ui.environment();
    const palette: Palette = .of(environment);
    ui.open(.{
        .id = .of("root"),
        .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both, .padding = .all(32), .child_gap = 16 },
        .decoration = .{ .background = if (environment.system_material) null else palette.background },
    });
    ui.text("The desktop through the window", .{ .size = 32, .color = palette.text });
    ui.text(if (environment.system_material) "The system's material shows wherever nothing is drawn." else "No system material here: the root draws the theme's background.", .{ .size = 16, .color = palette.muted });
    {
        ui.open(.{
            .layout = .{ .direction = .top_to_bottom, .sizing = .{ .width = .fixed(420), .height = .fit }, .padding = .all(20), .child_gap = 8 },
            .decoration = .{ .background = palette.card, .corner_radius = .all(8) },
        });
        defer ui.close();
        ui.text("A card with a background of its own", .{ .size = 16, .color = palette.text });
        ui.text("Its color is partly transparent, so the material tints it.", .{ .size = 16, .color = palette.muted });
    }
    ui.close();
}

pub fn main(init: std.process.Init) !void {
    comptime zui.checkHostAndRenderer(Host, Renderer);
    const gpa = init.gpa;
    const io = init.io;
    var screenshot_path: ?[]const u8 = null;
    var no_system_material = false;
    var material: zui.SystemMaterial = .window;
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    var index: usize = 1;
    while (index < arguments.len) : (index += 1) {
        if (std.mem.eql(u8, arguments[index], "--no-system-material")) {
            no_system_material = true;
        } else if (std.mem.eql(u8, arguments[index], "--transient")) {
            material = .transient;
        } else if (std.mem.eql(u8, arguments[index], "--screenshot") and index + 1 < arguments.len) {
            index += 1;
            screenshot_path = arguments[index];
        } else {
            std.debug.print("unknown argument \"{s}\"; expected --no-system-material, --transient or --screenshot <path>\n", .{arguments[index]});
            return error.UnknownArgument;
        }
    }

    const host = try gpa.create(Host);
    defer gpa.destroy(host);
    host.forced_scale = null;
    host.system_material_unavailable = no_system_material;
    try host.init(io, .{ .title = "zui: the desktop through the window", .size = .{ 720, 360 }, .material = material });
    defer host.deinit();

    var text: zui_sokol.Text = .{};
    var renderer: Renderer = try .initForSurface(&text, host.zuiSurface(.main));
    defer renderer.deinit();
    renderer.clear_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 };

    var ui: Ui = try .init(gpa, io, &text);
    defer ui.deinit(gpa);

    var events: [Ui.limits.max_events_per_frame]zui.Event = undefined;
    var text_buffer: [Ui.limits.max_text_input_bytes + Ui.limits.max_dropped_path_bytes]u8 = undefined;
    var builder: zui.RecordBuilder = .init(&events, &text_buffer);
    var frames: u32 = 0;
    while (host.zuiPoll(.main, &builder)) {
        ui.beginFrame(&builder.record());
        declare(&ui);
        const frame = ui.endFrame();
        try renderer.zuiSubmit(host.zuiSurface(.main), frame);
        host.zuiApply(.main, frame.requests());
        ui.release(frame);
        frames += 1;
        if (screenshot_path) |path| {
            if (frames == 3) {
                // Long enough for the compositor to show the window and its backdrop.
                try io.sleep(.fromMilliseconds(750), .awake);
                try capture.saveScreenArea(gpa, io, host.hwnd, path);
                std.debug.print("system material: {}\n", .{ui.environment().system_material});
                break;
            }
            ui.requestFrame();
        }
        host.zuiWait(ui.nextFrame());
    }
}
