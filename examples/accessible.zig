//! A few `zui_widgets` controls with `features.semantics` on, for checking
//! the UI Automation bridge with Narrator or Accessibility Insights.
//!
//! ```sh
//! zig build accessible                     # interactive window
//! zig build accessible -- --frames 30      # draw 30 frames, then quit
//! ```

const std = @import("std");
const zui_host = @import("zui_host");
const zui_sokol = @import("zui_sokol");
const zui_app = @import("zui_app");
const zui_widgets = @import("zui_widgets");
const zui = zui_host.zui;

const Ui = zui.Context(zui_sokol.config(.{ .features = .{ .semantics = true } }));
const Widgets = zui_widgets.Widgets(Ui);

pub fn main(init: std.process.Init) !void {
    try zui_app.run(AccessibleApp, init, .{ .title = "zui: accessibility", .size = .{ 560, 360 } });
}

const AccessibleApp = struct {
    pub const Host = zui_host.Host;
    pub const Renderer = SokolRenderer;
    pub const Text = zui_sokol.Text;

    host: *Host = undefined,
    widgets: Widgets = .{},
    saves: u32 = 0,
    autosave: bool = true,
    volume: f32 = 0.5,
    name_bytes: [64]u8 = undefined,
    name: zui_widgets.EditableText = undefined,
    frame_limit: ?u32 = null,
    frames: u32 = 0,

    pub fn init(app: *AccessibleApp, start: zui_app.Start(AccessibleApp)) !void {
        app.* = .{ .host = start.host };
        app.name = .init(&app.name_bytes, "Ada");
        if (start.process) |process| {
            const arguments = try process.minimal.args.toSlice(process.arena.allocator());
            if (arguments.len == 3 and std.mem.eql(u8, arguments[1], "--frames")) {
                app.frame_limit = try std.fmt.parseInt(u32, arguments[2], 10);
            } else if (arguments.len != 1) {
                std.debug.print("expected no arguments, or --frames <count>\n", .{});
                return error.UnknownArgument;
            }
        }
    }

    pub fn zuiDeclare(app: *AccessibleApp, ui: *Ui) void {
        ui.open(.{
            .id = .of("root"),
            .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both, .padding = .all(24), .child_gap = 16 },
            .decoration = .{ .background = .rgb(0x1c1c26) },
        });
        defer ui.close();
        if (app.widgets.button(ui, .of("save"), "Save", .{})) app.saves += 1;
        var saved_bytes: [32]u8 = undefined;
        const saved = std.fmt.bufPrint(&saved_bytes, "Saved {d} times", .{app.saves}) catch unreachable;
        ui.open(.{ .id = .of("saved"), .semantics = .{ .role = .label, .label = saved } });
        app.widgets.label(ui, saved);
        ui.close();
        _ = app.widgets.checkbox(ui, .of("autosave"), "Autosave", &app.autosave, .{});
        _ = app.widgets.slider(ui, .of("volume"), &app.volume, .{ .label = "Volume" });
        _ = app.widgets.textField(ui, .of("name"), &app.name, .{ .label = "Name" });
    }

    pub fn zuiLoader(app: *AccessibleApp, _: *const Ui, _: std.Io) void {
        app.frames += 1;
        if (app.frame_limit) |limit| {
            if (app.frames >= limit) app.host.close() else app.host.zuiWaker().wake();
        }
    }
};

const SokolRenderer = struct {
    pub const zui_surfaces: zui.SurfaceKinds = zui_host.Host.zui_surfaces;
    pub const ImageHandle = zui_sokol.Renderer.ImageHandle;

    sokol: zui_sokol.Renderer,

    pub fn init(self: *SokolRenderer, surface: zui.Surface, text: *const zui_sokol.Text) !void {
        self.sokol = try .initForSurface(text, surface);
    }

    pub fn deinit(self: *SokolRenderer) void {
        self.sokol.deinit();
    }

    pub fn zuiSubmit(self: *SokolRenderer, surface: zui.Surface, frame: anytype) !void {
        try self.sokol.zuiSubmit(surface, frame);
    }
};
