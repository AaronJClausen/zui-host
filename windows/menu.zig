const std = @import("std");
const zui = @import("zui");
const win32 = @import("win32.zig");

/// A menu copied for the window thread to build: its items in the order
/// they show, each submenu followed by its own items, and every label in
/// UTF-16 with its shortcut after a tab. Copying allocates nothing.
pub const CopiedMenu = struct {
    entries: [entry_capacity]Entry = undefined,
    entry_count: usize = 0,
    units: [unit_capacity]u16 = undefined,
    units_len: usize = 0,

    pub const entry_capacity = 256;
    pub const unit_capacity = 8 * 1024;
    /// Submenus inside submenus, counting the menu itself.
    pub const depth_capacity = 8;

    pub const Entry = struct {
        kind: Kind,
        id: zui.MenuItemId,
        label_start: usize,
        enabled: bool,
        checked: bool,
        /// How many of the entries after it are its submenu's.
        descendants: usize,

        pub const Kind = enum { item, separator, submenu };
    };

    /// `error.TooLarge` when the items, their labels or their nesting do
    /// not fit, and `error.InvalidUtf8` for a label that is not UTF-8.
    /// Nothing is kept from a menu that fails.
    pub fn copy(self: *CopiedMenu, items: []const zui.MenuItem) zui.ServiceError!void {
        self.entry_count = 0;
        self.units_len = 0;
        errdefer {
            self.entry_count = 0;
            self.units_len = 0;
        }
        try self.appendItems(items, 1);
    }

    /// The item Windows reports as `command` in a menu built from this one
    /// with `first_command`; null for none, as when the menu was closed.
    pub fn itemOfCommand(self: *const CopiedMenu, command: usize, first_command: usize) ?zui.MenuItemId {
        if (command < first_command or command - first_command >= self.entry_count) return null;
        const entry = self.entries[command - first_command];
        return if (entry.kind == .item) entry.id else null;
    }

    /// The command a menu built with `first_command` reports for `id`.
    pub fn commandOfItem(self: *const CopiedMenu, id: zui.MenuItemId, first_command: usize) ?usize {
        for (self.entries[0..self.entry_count], 0..) |entry, index| {
            if (entry.kind == .item and entry.id == id) return first_command + index;
        }
        return null;
    }

    fn label(self: *const CopiedMenu, entry: Entry) [*:0]const u16 {
        return @ptrCast(&self.units[entry.label_start]);
    }

    fn appendItems(self: *CopiedMenu, items: []const zui.MenuItem, depth: usize) zui.ServiceError!void {
        if (depth > depth_capacity) return error.TooLarge;
        for (items) |item| {
            if (self.entry_count == entry_capacity) return error.TooLarge;
            const index = self.entry_count;
            self.entry_count += 1;
            const kind: Entry.Kind = if (item.submenu.len > 0) .submenu else if (item.label.len == 0) .separator else .item;
            self.entries[index] = .{
                .kind = kind,
                .id = item.id,
                .label_start = if (kind == .separator) 0 else try self.appendLabel(item.label, if (kind == .item) item.shortcut else null),
                .enabled = item.enabled,
                .checked = item.checked orelse false,
                .descendants = 0,
            };
            if (kind == .submenu) {
                try self.appendItems(item.submenu, depth + 1);
                self.entries[index].descendants = self.entry_count - index - 1;
            }
        }
    }

    /// `&` doubled, since Windows would underline the character after one.
    fn appendLabel(self: *CopiedMenu, utf8: []const u8, shortcut: ?zui.Chord) zui.ServiceError!usize {
        const start = self.units_len;
        var codepoints = (std.unicode.Utf8View.init(utf8) catch return error.InvalidUtf8).iterator();
        while (codepoints.nextCodepoint()) |codepoint| {
            if (codepoint == '&') try self.appendAscii("&");
            try self.appendCodepoint(codepoint);
        }
        if (shortcut) |chord| if (keyName(chord.key).len > 0) {
            try self.appendAscii("\t");
            if (chord.modifiers.super) try self.appendAscii("Win+");
            if (chord.modifiers.control) try self.appendAscii("Ctrl+");
            if (chord.modifiers.alt) try self.appendAscii("Alt+");
            if (chord.modifiers.shift) try self.appendAscii("Shift+");
            try self.appendAscii(keyName(chord.key));
        };
        try self.appendAscii("\x00");
        return start;
    }

    fn appendAscii(self: *CopiedMenu, ascii: []const u8) zui.ServiceError!void {
        if (ascii.len > unit_capacity - self.units_len) return error.TooLarge;
        for (ascii, self.units[self.units_len..][0..ascii.len]) |byte, *unit| unit.* = byte;
        self.units_len += ascii.len;
    }

    fn appendCodepoint(self: *CopiedMenu, codepoint: u21) zui.ServiceError!void {
        var encoded: [2]u16 = undefined;
        const len: usize = if (codepoint < 0x10000) blk: {
            encoded[0] = @intCast(codepoint);
            break :blk 1;
        } else blk: {
            const above_plane_zero = codepoint - 0x10000;
            encoded = .{ @intCast(0xD800 + (above_plane_zero >> 10)), @intCast(0xDC00 + (above_plane_zero & 0x3FF)) };
            break :blk 2;
        };
        if (len > unit_capacity - self.units_len) return error.TooLarge;
        @memcpy(self.units[self.units_len..][0..len], encoded[0..len]);
        self.units_len += len;
    }
};

pub const MenuKind = enum { popup, bar };

/// A menu holding `copied`'s items, each numbered from `first_command` in
/// the order they were copied; null when Windows cannot make one.
/// `DestroyMenu` on it destroys its submenus too.
pub fn build(copied: *const CopiedMenu, kind: MenuKind, first_command: usize) ?win32.HMENU {
    const menu = (if (kind == .bar) win32.CreateMenu() else win32.CreatePopupMenu()) orelse return null;
    if (!appendEntries(copied, menu, 0, copied.entry_count, first_command)) {
        _ = win32.DestroyMenu(menu);
        return null;
    }
    return menu;
}

fn appendEntries(copied: *const CopiedMenu, menu: win32.HMENU, start: usize, end: usize, first_command: usize) bool {
    var index = start;
    while (index < end) : (index += 1 + copied.entries[index].descendants) {
        const entry = copied.entries[index];
        const grayed: win32.UINT = if (entry.enabled) 0 else win32.MF_GRAYED;
        const checked: win32.UINT = if (entry.checked) win32.MF_CHECKED else 0;
        const state = grayed | checked;
        switch (entry.kind) {
            .separator => if (win32.AppendMenuW(menu, win32.MF_SEPARATOR, 0, null) == 0) return false,
            .item => if (win32.AppendMenuW(menu, win32.MF_STRING | state, first_command + index, copied.label(entry)) == 0) return false,
            .submenu => {
                const submenu = win32.CreatePopupMenu() orelse return false;
                const built = appendEntries(copied, submenu, index + 1, index + 1 + entry.descendants, first_command) and
                    win32.AppendMenuW(menu, win32.MF_POPUP | state, @intFromPtr(submenu), copied.label(entry)) != 0;
                if (!built) {
                    _ = win32.DestroyMenu(submenu);
                    return false;
                }
            },
        }
    }
    return true;
}

/// How Windows' own menus spell a shortcut's key; empty for one that has
/// no name, which then shows no shortcut.
fn keyName(key: zui.Key) []const u8 {
    return switch (key) {
        inline .a, .b, .c, .d, .e, .f, .g, .h, .i, .j, .k, .l, .m, .n, .o, .p, .q, .r, .s, .t, .u, .v, .w, .x, .y, .z => |letter| comptime blk: {
            const name = @tagName(letter);
            break :blk &[_]u8{std.ascii.toUpper(name[0])};
        },
        inline .digit_0, .digit_1, .digit_2, .digit_3, .digit_4, .digit_5, .digit_6, .digit_7, .digit_8, .digit_9 => |digit| @tagName(digit)["digit_".len..],
        inline .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12 => |function_key| comptime blk: {
            const name = @tagName(function_key);
            break :blk "F" ++ name[1..];
        },
        .tab => "Tab",
        .enter => "Enter",
        .escape => "Esc",
        .space => "Space",
        .backspace => "Backspace",
        .delete => "Del",
        .insert => "Ins",
        .left => "Left",
        .right => "Right",
        .up => "Up",
        .down => "Down",
        .home => "Home",
        .end => "End",
        .page_up => "PgUp",
        .page_down => "PgDn",
        .menu => "Menu",
        .shift => "Shift",
        .control => "Ctrl",
        .alt => "Alt",
        .super => "Win",
        .caps_lock => "Caps Lock",
        .minus => "-",
        .equals => "=",
        .left_bracket => "[",
        .right_bracket => "]",
        .backslash => "\\",
        .semicolon => ";",
        .apostrophe => "'",
        .grave => "`",
        .comma => ",",
        .period => ".",
        .slash => "/",
        .unidentified => "",
    };
}

const W = std.unicode.utf8ToUtf16LeStringLiteral;

test "a menu is copied in the order it shows, each submenu followed by its items, with shortcuts after a tab and & doubled" {
    var copied: CopiedMenu = .{};
    try copied.copy(&.{
        .{ .id = @enumFromInt(1), .label = "Save & close", .shortcut = .{ .key = .s, .modifiers = .{ .control = true, .shift = true } } },
        .separator,
        .{ .label = "Recent", .submenu = &.{ .{ .id = @enumFromInt(2), .label = "dark.zon" }, .{ .id = @enumFromInt(3), .label = "😀", .enabled = false, .checked = true } } },
        .{ .id = @enumFromInt(4), .label = "Help", .shortcut = .{ .key = .f1 } },
    });
    try std.testing.expectEqual(@as(usize, 6), copied.entry_count);
    try std.testing.expectEqualSlices(u16, W("Save && close\tCtrl+Shift+S"), std.mem.span(copied.label(copied.entries[0])));
    try std.testing.expectEqual(CopiedMenu.Entry.Kind.separator, copied.entries[1].kind);
    try std.testing.expectEqual(CopiedMenu.Entry.Kind.submenu, copied.entries[2].kind);
    try std.testing.expectEqual(@as(usize, 2), copied.entries[2].descendants);
    try std.testing.expect(!copied.entries[4].enabled and copied.entries[4].checked);
    try std.testing.expectEqualSlices(u16, W("😀"), std.mem.span(copied.label(copied.entries[4])));
    try std.testing.expectEqualSlices(u16, W("Help\tF1"), std.mem.span(copied.label(copied.entries[5])));

    try std.testing.expectEqual(@as(?zui.MenuItemId, @enumFromInt(3)), copied.itemOfCommand(100 + 4, 100));
    try std.testing.expectEqual(@as(?zui.MenuItemId, null), copied.itemOfCommand(100 + 2, 100));
    try std.testing.expectEqual(@as(?zui.MenuItemId, null), copied.itemOfCommand(0, 100));
    try std.testing.expectEqual(@as(?zui.MenuItemId, null), copied.itemOfCommand(100 + 6, 100));
    try std.testing.expectEqual(@as(?usize, 100 + 5), copied.commandOfItem(@enumFromInt(4), 100));
}

test "a menu too large, too deep, or not UTF-8 is refused and nothing of it is kept" {
    var copied: CopiedMenu = .{};
    const item: zui.MenuItem = .{ .id = @enumFromInt(1), .label = "Item" };
    try std.testing.expectError(error.TooLarge, copied.copy(&([_]zui.MenuItem{item} ** (CopiedMenu.entry_capacity + 1))));
    try std.testing.expectEqual(@as(usize, 0), copied.entry_count);
    try std.testing.expectError(error.TooLarge, copied.copy(&.{.{ .label = "l" ** CopiedMenu.unit_capacity }}));
    try std.testing.expectError(error.InvalidUtf8, copied.copy(&.{.{ .label = "\xff" }}));

    var nested: [CopiedMenu.depth_capacity]zui.MenuItem = undefined;
    nested[0] = item;
    for (nested[1..], 0..) |*level, index| level.* = .{ .label = "More", .submenu = nested[index..][0..1] };
    try copied.copy(nested[CopiedMenu.depth_capacity - 1 ..]);
    const one_too_deep = [_]zui.MenuItem{.{ .label = "More", .submenu = nested[CopiedMenu.depth_capacity - 1 ..] }};
    try std.testing.expectError(error.TooLarge, copied.copy(&one_too_deep));
}
