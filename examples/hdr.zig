//! Boxes of SDR white and of two and four times it, which an HDR monitor
//! shows brighter than SDR white and an SDR one shows alike.
//!
//! ```sh
//! zig build hdr                 # the window, until it is closed
//! zig build hdr -- --measure    # read the boxes back off the desktop in scRGB, then quit
//! ```

const std = @import("std");
const zui_host = @import("zui_host");
const zui_sokol = @import("zui_sokol");
const scrgb_capture = @import("scrgb_capture.zig");
const zui = zui_host.zui;
const Host = zui_host.Host;
const Renderer = zui_sokol.Renderer;

const Ui = zui.Context(zui_sokol.config(.{ .Color = zui.ExtendedColor }));

const Swatch = struct {
    id: zui.Id,
    label: []const u8,
    times_sdr_white: f32,
};

const swatches = [_]Swatch{
    .{ .id = .of("sdr white"), .label = "SDR white", .times_sdr_white = 1 },
    .{ .id = .of("twice"), .label = "2x", .times_sdr_white = 2 },
    .{ .id = .of("four times"), .label = "4x", .times_sdr_white = 4 },
};

const text_color: zui.ExtendedColor = .rgb(0xd0d0d0);

fn declare(ui: *Ui, format: zui.OutputFormat) void {
    const environment = ui.environment();
    ui.open(.{
        .id = .of("root"),
        .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both, .padding = .all(32), .child_gap = 24 },
        .decoration = .{ .background = .rgb(0x101010) },
    });
    var heading: [96]u8 = undefined;
    ui.text(std.fmt.bufPrint(&heading, "output {t}, headroom {d:.2}", .{ format, environment.hdr_headroom }) catch "output", .{ .size = 20, .color = text_color });
    {
        ui.open(.{ .layout = .{ .direction = .left_to_right, .child_gap = 24 } });
        defer ui.close();
        for (swatches) |swatch| {
            ui.open(.{ .layout = .{ .direction = .top_to_bottom, .child_gap = 8 } });
            defer ui.close();
            const white = swatch.times_sdr_white;
            ui.box(.{ .id = swatch.id, .layout = .{ .sizing = .{ .width = .fixed(160), .height = .fixed(160) } }, .decoration = .{ .background = .linear(white, white, white, 1) } });
            ui.text(swatch.label, .{ .size = 16, .color = text_color });
        }
    }
    ui.close();
}

pub fn main(init: std.process.Init) !void {
    comptime zui.checkHostAndRenderer(Host, Renderer);
    const gpa = init.gpa;
    const io = init.io;
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    var measure = false;
    for (arguments[1..]) |argument| {
        if (std.mem.eql(u8, argument, "--measure")) {
            measure = true;
        } else {
            std.debug.print("unknown argument \"{s}\"; expected --measure\n", .{argument});
            return error.UnknownArgument;
        }
    }

    const host = try gpa.create(Host);
    defer gpa.destroy(host);
    host.forced_scale = null;
    host.forced_display_color = null;
    try host.init(io, .{ .title = "zui: HDR white", .size = .{ 640, 320 }, .output_formats = zui.sharedOutputFormats(Host, Renderer) });
    defer host.deinit();

    var text: zui_sokol.Text = .{};
    var renderer: Renderer = try .initForSurface(&text, host.zuiSurface(.main));
    defer renderer.deinit();

    var ui: Ui = try .init(gpa, io, &text);
    defer ui.deinit(gpa);

    var events: [Ui.limits.max_events_per_frame]zui.Event = undefined;
    var text_buffer: [Ui.limits.max_text_input_bytes + Ui.limits.max_dropped_path_bytes]u8 = undefined;
    var builder: zui.RecordBuilder = .init(&events, &text_buffer);
    var frames: u32 = 0;
    while (host.zuiPoll(.main, &builder)) {
        const surface = host.zuiSurface(.main);
        ui.beginFrame(&builder.record());
        declare(&ui, surface.outputFormat());
        const frame = ui.endFrame();
        try renderer.zuiSubmit(surface, frame);
        host.zuiApply(.main, frame.requests());
        frames += 1;
        if (measure and frames == 3) {
            // Long enough for the compositor to show the window.
            try io.sleep(.fromMilliseconds(750), .awake);
            const measured = report(host, frame, surface.outputFormat(), ui.environment().hdr_headroom);
            ui.release(frame);
            return measured;
        }
        ui.release(frame);
        if (measure) ui.requestFrame();
        host.zuiWait(ui.nextFrame());
    }
}

/// Prints each box's color as the desktop shows it; fails when the window
/// is in scRGB and twice SDR white does not show brighter than SDR white.
fn report(host: *Host, frame: anytype, format: zui.OutputFormat, headroom: f32) !void {
    const pixels_per_unit = frame.params.scale * frame.params.zoom;
    var centers: [swatches.len][2]i32 = undefined;
    for (swatches, &centers) |swatch, *center| {
        const rect = frame.rectOf(swatch.id) orelse return error.SwatchNotLaidOut;
        center.* = .{ @intFromFloat((rect.x + rect.width / 2) * pixels_per_unit), @intFromFloat((rect.y + rect.height / 2) * pixels_per_unit) };
    }
    var colors: [swatches.len][4]f32 = undefined;
    try scrgb_capture.readScrgb(host.hwnd, &centers, &colors);
    std.debug.print("output {t}, headroom {d:.2}; the desktop shows, in scRGB (1.0 is 80 nits):\n", .{ format, headroom });
    for (swatches, colors) |swatch, color| {
        std.debug.print("  {s:<10} {d:.3} {d:.3} {d:.3}, {d:.2}x SDR white\n", .{ swatch.label, color[0], color[1], color[2], color[1] / colors[0][1] });
    }
    if (format == .scrgb_fp16 and !(colors[1][1] > colors[0][1] * 1.5)) return error.HdrWhiteNotBrighter;
}
