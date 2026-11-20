//! Every host service from one window: a button for each, its answer shown
//! beside it. Declaration only notes what was asked for; the loader makes
//! each call between frames through `zui_app.ServicesOf`, and every answer
//! comes back through one source, so a replay shows the same answers
//! without opening anything.
//!
//! ```sh
//! zig build services                 # interactive window; right-click for the context menu
//! zig build services -- --check      # every service against the host's fake, in a hidden window, then quit
//! ```

const std = @import("std");
const builtin = @import("builtin");
const zui_host = @import("zui_host");
const zui_sokol = @import("zui_sokol");
const zui_app = @import("zui_app");
const zui_async = @import("zui_async");
const zui_widgets = @import("zui_widgets");
const zui = zui_host.zui;
const win32 = zui_host.windows.win32;
const host_services = if (builtin.os.tag == .windows) zui_host.windows.services else zui_host.linux.services;

const ServiceReply = zui.ServiceReply(16 * 1024);
const ServiceSources = struct {
    replies: zui_async.Stream(ServiceReply, .{ .capacity = 4 }) = .{},
};
const Ui = zui.Context(zui_sokol.config(.{ .Sources = ServiceSources }));
const Widgets = zui_widgets.Widgets(Ui);
const services = zui_app.ServicesOf(zui_host.Host);

const Action = enum {
    pick_file,
    save_file,
    notify,
    popup_menu,
    toggle_menu_bar,
    copy,
    paste,
    open_url,

    fn title(action: Action) []const u8 {
        return switch (action) {
            .pick_file => "Pick a file",
            .save_file => "Save a file",
            .notify => "Show a notification",
            .popup_menu => "Open a popup menu",
            .toggle_menu_bar => "Set or clear the menu bar",
            .copy => "Copy",
            .paste => "Paste",
            .open_url => "Open ziglang.org",
        };
    }

    fn request(action: Action) zui.ServiceRequest {
        return switch (action) {
            inline else => |named| comptime .of(@tagName(named)),
        };
    }

    fn menuItem(action: Action) zui.MenuItemId {
        return @enumFromInt(@as(u32, @intFromEnum(action)) + 1);
    }

    fn ofMenuItem(item: zui.MenuItemId) ?Action {
        const index = @intFromEnum(item);
        if (index == 0 or index > std.enums.values(Action).len) return null;
        return @enumFromInt(index - 1);
    }

    /// Whether the host offers the service, so the check presses its
    /// button. The check works a menu bar through Win32.
    fn isOffered(action: Action) bool {
        return switch (action) {
            .pick_file, .save_file => services.has_file_dialogs,
            .notify => services.has_notifications,
            .popup_menu => services.has_menus,
            .toggle_menu_bar => services.has_menu_bar and builtin.os.tag == .windows,
            .copy, .paste => services.has_clipboard,
            .open_url => services.has_open_url,
        };
    }

    fn buttonId(action: Action) zui.Id {
        return switch (action) {
            inline else => |named| comptime .of(@tagName(named)),
        };
    }
};

const url = "https://ziglang.org";
const copy_shortcut: zui.Chord = .{ .key = .c, .modifiers = .{ .control = true } };
const paste_shortcut: zui.Chord = .{ .key = .v, .modifiers = .{ .control = true } };
const open_shortcut: zui.Chord = .{ .key = .o, .modifiers = .{ .control = true } };
const save_shortcut: zui.Chord = .{ .key = .s, .modifiers = .{ .control = true } };

const popup_items = [_]zui.MenuItem{
    .{ .id = Action.menuItem(.copy), .label = "Copy", .shortcut = copy_shortcut },
    .{ .id = Action.menuItem(.paste), .label = "Paste", .shortcut = paste_shortcut },
    .separator,
    .{ .id = Action.menuItem(.notify), .label = "Show a notification" },
};

const menu_bar_items = [_]zui.MenuItem{
    .{ .label = "File", .submenu = &.{
        .{ .id = Action.menuItem(.pick_file), .label = "Pick a file...", .shortcut = open_shortcut },
        .{ .id = Action.menuItem(.save_file), .label = "Save a file...", .shortcut = save_shortcut },
    } },
    .{ .label = "Edit", .submenu = &.{
        .{ .id = Action.menuItem(.copy), .label = "Copy", .shortcut = copy_shortcut },
        .{ .id = Action.menuItem(.paste), .label = "Paste", .shortcut = paste_shortcut },
    } },
    .{ .label = "Help", .submenu = &.{
        .{ .id = Action.menuItem(.open_url), .label = "Open ziglang.org" },
    } },
};

const text_filters = [_]zui.FileFilter{
    .{ .name = "Zig sources", .extensions = &.{ "zig", "zon" } },
    .{ .name = "Text", .extensions = &.{"txt"} },
};

/// One line of text an answer is shown as.
const AnswerLine = struct {
    bytes: [256]u8 = undefined,
    len: usize = 0,

    fn set(self: *AnswerLine, comptime format: []const u8, arguments: anytype) void {
        const written = std.fmt.bufPrint(&self.bytes, format, arguments) catch {
            const cut = "(too long to show)";
            @memcpy(self.bytes[0..cut.len], cut);
            self.len = cut.len;
            return;
        };
        self.len = written.len;
    }

    fn slice(self: *const AnswerLine) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub fn main(init: std.process.Init) !void {
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    var checking = false;
    for (arguments[1..]) |argument| {
        if (std.mem.eql(u8, argument, "--check")) {
            checking = true;
        } else {
            std.debug.print("unknown argument \"{s}\"; expected --check\n", .{argument});
            return error.UnknownArgument;
        }
    }

    const runner = try init.gpa.create(zui_app.Runner(ServicesApp));
    defer init.gpa.destroy(runner);
    try runner.start(.{ .gpa = init.gpa, .io = init.io, .process = init }, .{ .title = "zui: host services", .size = .{ 760, 560 }, .visible = !checking });
    defer runner.stop();
    if (checking) {
        // A Wayland surface the compositor never shows gets no frame
        // callbacks, and a swap waits for the last frame's.
        if (builtin.os.tag == .linux) runner.renderer.draws = false;
        runner.host.fakeServices(&runner.app.service_fake);
        runner.app.check = .{ .deadline = runner.host.now().addNanoseconds(Check.deadline_ns) };
    }
    while (try runner.frame()) {}
    if (runner.app.check) |check| return check.result();
}

const ServicesApp = struct {
    pub const Host = zui_host.Host;
    pub const Renderer = SokolRenderer;
    pub const Text = zui_sokol.Text;

    sources: ServiceSources = .{},
    host: *Host = undefined,
    widgets: Widgets = .{},
    /// Asked for by declaration; the loader makes the calls.
    wanted: std.EnumSet(Action) = .initEmpty(),
    answers: std.EnumArray(Action, AnswerLine) = .initFill(.{}),
    /// In layout units from the window's top-left.
    popup_position: [2]f32 = .{ 0, 0 },
    menu_bar_shown: bool = false,
    copies: u32 = 0,
    /// Set by `--check`, which answers every service through it.
    service_fake: host_services.ServiceFake = .{},
    check: ?Check = null,

    const root_id: zui.Id = .of("root");
    const menu_bar_request: zui.ServiceRequest = .of("menu bar");

    pub fn init(app: *ServicesApp, start: zui_app.Start(ServicesApp)) !void {
        app.* = .{ .host = start.host };
    }

    pub fn zuiDeclare(app: *ServicesApp, ui: *Ui) void {
        var replies = ui.source(.replies).items();
        while (replies.next()) |reply| app.receive(reply);
        if (ui.chordPressed(copy_shortcut)) app.wanted.insert(.copy);
        if (ui.chordPressed(paste_shortcut)) app.wanted.insert(.paste);
        if (ui.chordPressed(open_shortcut)) app.wanted.insert(.pick_file);
        if (ui.chordPressed(save_shortcut)) app.wanted.insert(.save_file);
        if (ui.contextRequested(root_id)) if (ui.primaryPointer()) |pointer| {
            app.popup_position = pointer.position;
            app.wanted.insert(.popup_menu);
        };

        ui.open(.{
            .id = root_id,
            .layout = .{ .direction = .top_to_bottom, .sizing = .grow_both, .padding = .all(24), .child_gap = 10 },
            .decoration = .{ .background = .rgb(0x1c1c26) },
        });
        defer ui.close();
        ui.text("Host services", .{ .size = 24, .color = .rgb(0xf3f3f3) });
        app.widgets.label(ui, "Each button asks the host; its answer shows beside it. Right-click anywhere for the context menu.");
        for (std.enums.values(Action)) |action| {
            ui.open(.{ .layout = .{ .direction = .left_to_right, .sizing = .{ .width = .grow, .height = .fit }, .child_gap = 16, .child_alignment = .{ .y = .center } } });
            defer ui.close();
            const id = action.buttonId();
            if (app.widgets.button(ui, id, action.title(), .{ .width = .fixed(220) })) {
                if (action == .popup_menu) if (ui.rectOf(id)) |button| {
                    app.popup_position = .{ button.x, button.y + button.height };
                };
                app.wanted.insert(action);
            }
            app.widgets.label(ui, app.answers.getPtr(action).slice());
        }
    }

    fn receive(app: *ServicesApp, reply: *const ServiceReply) void {
        if (reply.request == menu_bar_request) return app.receiveMenuChoice(.toggle_menu_bar, reply);
        for (std.enums.values(Action)) |action| {
            if (reply.request != action.request()) continue;
            if (action == .popup_menu) return app.receiveMenuChoice(.popup_menu, reply);
            const line = app.answers.getPtr(action);
            switch (reply.kind) {
                .clipboard_text => line.set("pasted \"{s}\"", .{reply.text()}),
                .files_chosen => {
                    var paths = reply.paths();
                    const first = paths.next() orelse "";
                    var others: usize = 0;
                    while (paths.next()) |_| others += 1;
                    if (others == 0) line.set("{s}", .{first}) else line.set("{s} and {d} more", .{ first, others });
                },
                .notification_activated => line.set("clicked", .{}),
                .notification_dismissed => line.set("dismissed", .{}),
                .canceled => line.set("canceled", .{}),
                .failed => line.set("failed: {t}", .{reply.failure}),
                .menu_item_chosen => {},
            }
            return;
        }
    }

    fn receiveMenuChoice(app: *ServicesApp, shown_on: Action, reply: *const ServiceReply) void {
        const line = app.answers.getPtr(shown_on);
        switch (reply.kind) {
            .menu_item_chosen => {
                const chosen = Action.ofMenuItem(reply.menu_item) orelse return line.set("chose an item it does not know", .{});
                line.set("chose {s}", .{chosen.title()});
                app.wanted.insert(chosen);
            },
            .canceled => line.set("closed without a choice", .{}),
            .failed => line.set("failed: {t}", .{reply.failure}),
            else => {},
        }
    }

    pub fn zuiObserve(app: *ServicesApp, _: *const Ui, frame: *const Ui.Frame) void {
        if (app.check) |*check| check.observe(app, frame);
    }

    pub fn zuiLoader(app: *ServicesApp, _: *const Ui, _: std.Io) void {
        if (app.check) |*check| check.step(app);
        var wanted = app.wanted.iterator();
        while (wanted.next()) |action| app.call(action);
        app.wanted = .initEmpty();
    }

    fn call(app: *ServicesApp, action: Action) void {
        const line = app.answers.getPtr(action);
        app.callService(action, line) catch |err| line.set("refused: {t}", .{err});
    }

    fn callService(app: *ServicesApp, action: Action, line: *AnswerLine) zui.ServiceError!void {
        const sink: zui.ServiceSink = .of(&app.sources.replies);
        switch (action) {
            .pick_file => {
                if (!services.has_file_dialogs) return line.set("this host has no file dialogs", .{});
                try services.file_dialogs.show(app.host, .main, action.request(), .{ .title = "Pick a file", .filters = &text_filters }, sink);
                line.set("waiting for the dialog", .{});
            },
            .save_file => {
                if (!services.has_file_dialogs) return line.set("this host has no file dialogs", .{});
                try services.file_dialogs.show(app.host, .main, action.request(), .{ .kind = .save_file, .title = "Save a file", .file_name = "notes.txt", .filters = &text_filters }, sink);
                line.set("waiting for the dialog", .{});
            },
            .notify => {
                if (!services.has_notifications) return line.set("this host has no notifications", .{});
                try services.notifications.show(app.host, action.request(), .{ .title = "zui", .body = "A notification from zig build services. Click it." }, sink);
                line.set("showing", .{});
            },
            .popup_menu => {
                if (!services.has_menus) return line.set("this host has no menus", .{});
                try services.menus.popup(app.host, .main, action.request(), &popup_items, app.popup_position, sink);
                line.set("open", .{});
            },
            .toggle_menu_bar => {
                if (!services.has_menu_bar) return line.set("this host has no menu bar", .{});
                const items: []const zui.MenuItem = if (app.menu_bar_shown) &.{} else &menu_bar_items;
                try services.menus.setBar(app.host, .main, menu_bar_request, items, sink);
                app.menu_bar_shown = !app.menu_bar_shown;
                line.set("{s}", .{if (app.menu_bar_shown) "shown: File, Edit, Help" else "removed"});
            },
            .copy => {
                if (!services.has_clipboard) return line.set("this host has no clipboard", .{});
                app.copies += 1;
                var text_bytes: [64]u8 = undefined;
                const text = std.fmt.bufPrint(&text_bytes, "zui copied this ({d})", .{app.copies}) catch unreachable;
                try services.clipboard.write(app.host, text);
                line.set("copied \"{s}\"", .{text});
            },
            .paste => {
                if (!services.has_clipboard) return line.set("this host has no clipboard", .{});
                try services.clipboard.read(app.host, action.request(), sink);
                line.set("reading the clipboard", .{});
            },
            .open_url => {
                if (!services.has_open_url) return line.set("this host cannot open URLs", .{});
                try services.open_url.open(app.host, url);
                line.set("handed {s} to the system", .{url});
            },
        }
    }
};

/// `--check`: presses each button in turn, as a click would, with the
/// host's fake answering as a user might, and passes once each answer
/// shows in a frame.
const Check = struct {
    deadline: zui.Instant,
    step_index: usize = 0,
    started: bool = false,
    failure: ?Failure = null,
    done: bool = false,
    /// Pastes answered `.failed = .unavailable` because another
    /// application, such as clipboard history, still held the clipboard
    /// after the copy; each is pressed again, as a user would.
    pastes_retried: u32 = 0,

    const deadline_ns = 10 * std.time.ns_per_s;
    const picked_path = if (builtin.os.tag == .windows) "C:\\zui\\picked.zon" else "/zui/picked.zon";
    const saved_path = if (builtin.os.tag == .windows) "C:\\zui\\saved.txt" else "/zui/saved.txt";

    const Failure = enum { timed_out, url_not_opened };

    const Step = struct {
        action: Action,
        /// Shown on screen once the answer has arrived.
        shows: []const u8,
        menu_bar: enum { untouched, shown, removed } = .untouched,
        /// Chooses the bar's first item, as a click in it would, in place
        /// of pressing the button.
        chooses_from_menu_bar: bool = false,
    };

    const steps = offeredSteps(&.{
        .{ .action = .copy, .shows = "copied \"zui copied this (1)\"" },
        .{ .action = .paste, .shows = "pasted \"zui copied this (1)\"" },
        .{ .action = .pick_file, .shows = picked_path },
        .{ .action = .save_file, .shows = saved_path },
        .{ .action = .notify, .shows = "clicked" },
        .{ .action = .popup_menu, .shows = "chose Paste" },
        .{ .action = .toggle_menu_bar, .shows = "shown: File, Edit, Help", .menu_bar = .shown },
        .{ .action = .toggle_menu_bar, .shows = "chose Pick a file", .chooses_from_menu_bar = true },
        .{ .action = .toggle_menu_bar, .shows = "removed", .menu_bar = .removed },
        .{ .action = .open_url, .shows = "handed " ++ url ++ " to the system" },
    });

    fn offeredSteps(comptime all: []const Step) [offeredCount(all)]Step {
        var offered: [offeredCount(all)]Step = undefined;
        var count: usize = 0;
        for (all) |each| if (each.action.isOffered()) {
            offered[count] = each;
            count += 1;
        };
        return offered;
    }

    fn offeredCount(comptime all: []const Step) usize {
        var count: usize = 0;
        for (all) |each| count += @intFromBool(each.action.isOffered());
        return count;
    }

    fn result(self: Check) !void {
        if (self.failure) |failure| {
            std.debug.print("services: failed at \"{s}\": {t}\n", .{ steps[self.step_index].action.title(), failure });
            return error.CheckFailed;
        }
        if (!self.done) return error.WindowClosedBeforeTheCheckEnded;
        std.debug.print("services: every service answered and showed its answer; {d} pastes found the clipboard held and were pressed again\n", .{self.pastes_retried});
    }

    fn step(self: *Check, app: *ServicesApp) void {
        if (self.done or self.failure != null) return app.host.close();
        if (!app.host.now().isBefore(self.deadline)) {
            self.failure = .timed_out;
            const current = steps[self.step_index];
            std.debug.print("services: expected \"{s}\", but it shows \"{s}\"\n", .{ current.shows, app.answers.getPtr(current.action).slice() });
            return app.host.close();
        }
        if (!self.started) {
            const current = steps[self.step_index];
            if (builtin.os.tag == .windows and current.chooses_from_menu_bar) {
                const bar = win32.GetMenu(app.host.hwnd) orelse return app.host.zuiWaker().wake();
                const file_menu = win32.GetSubMenu(bar, 0) orelse return app.host.zuiWaker().wake();
                _ = win32.SendMessageW(app.host.hwnd, win32.WM_COMMAND, win32.GetMenuItemID(file_menu, 0), 0);
                self.started = true;
                return app.host.zuiWaker().wake();
            }
            self.started = true;
            const fake = &app.service_fake;
            switch (current.action) {
                .pick_file => fake.scriptFileDialog(picked_path ++ "\x00"),
                .save_file => fake.scriptFileDialog(saved_path ++ "\x00"),
                .notify => fake.scriptNotification(.activated),
                .popup_menu => if (comptime services.has_menus) fake.scriptPopupMenu(Action.menuItem(.paste)),
                else => {},
            }
            app.wanted.insert(current.action);
        }
        app.host.zuiWaker().wake();
    }

    fn observe(self: *Check, app: *ServicesApp, frame: *const Ui.Frame) void {
        if (!self.started or self.done or self.failure != null) return;
        const current = steps[self.step_index];
        if (current.action == .paste and std.mem.eql(u8, app.answers.getPtr(.paste).slice(), "failed: unavailable")) {
            self.pastes_retried += 1;
            self.started = false;
            return;
        }
        if (!shows(frame, current.shows)) return;
        if (builtin.os.tag == .windows) switch (current.menu_bar) {
            .untouched => {},
            .shown => if (win32.GetMenu(app.host.hwnd) == null) return,
            .removed => if (win32.GetMenu(app.host.hwnd) != null) return,
        };
        if (current.action == .open_url) {
            const opened = app.service_fake.openedUrl() orelse return;
            if (!std.mem.eql(u8, opened, url)) {
                self.failure = .url_not_opened;
                return;
            }
        }
        std.debug.print("services: {s}: {s}\n", .{ current.action.title(), current.shows });
        self.started = false;
        self.step_index += 1;
        if (self.step_index == steps.len) self.done = true;
    }

    fn shows(frame: *const Ui.Frame, text: []const u8) bool {
        for (frame.commands()) |command| {
            if (command.payload == .text and std.mem.indexOf(u8, command.payload.text.content, text) != null) return true;
        }
        return false;
    }
};

const SokolRenderer = struct {
    pub const zui_surfaces: zui.SurfaceKinds = zui_host.Host.zui_surfaces;
    pub const ImageHandle = zui_sokol.Renderer.ImageHandle;

    sokol: zui_sokol.Renderer,
    /// False submits nothing, for a window that is never shown.
    draws: bool = true,

    pub fn init(self: *SokolRenderer, surface: zui.Surface, text: *const zui_sokol.Text) !void {
        self.* = .{ .sokol = try .initForSurface(text, surface) };
    }

    pub fn deinit(self: *SokolRenderer) void {
        self.sokol.deinit();
    }

    pub fn zuiSubmit(self: *SokolRenderer, surface: zui.Surface, frame: anytype) !void {
        if (self.draws) try self.sokol.zuiSubmit(surface, frame);
    }
};
