//! The shell's file dialogs, `IFileOpenDialog` and `IFileSaveDialog`: the
//! COM declarations the host uses, and a dialog's settings copied into
//! memory of the host's, so showing one allocates nothing of the process's.

const std = @import("std");
const zui = @import("zui");
const win32 = @import("win32.zig");

const GUID = win32.GUID;
const HRESULT = win32.HRESULT;
const LPCWSTR = [*:0]const u16;

pub const CLSID_FileOpenDialog: GUID = .{ .data1 = 0xdc1c5a9c, .data2 = 0xe88a, .data3 = 0x4dde, .data4 = .{ 0xa5, 0xa1, 0x60, 0xf8, 0x2a, 0x20, 0xae, 0xf7 } };
pub const CLSID_FileSaveDialog: GUID = .{ .data1 = 0xc0b4e2f3, .data2 = 0xba21, .data3 = 0x4773, .data4 = .{ 0x8d, 0xba, 0x33, 0x5e, 0xc9, 0x46, 0xeb, 0x8b } };
pub const IID_IFileDialog: GUID = .{ .data1 = 0x42f85136, .data2 = 0xdb7e, .data3 = 0x439c, .data4 = .{ 0x85, 0xf1, 0xe4, 0x07, 0x5d, 0x13, 0x5f, 0xc8 } };
pub const IID_IFileOpenDialog: GUID = .{ .data1 = 0xd57c7288, .data2 = 0xd4ad, .data3 = 0x4768, .data4 = .{ 0xbe, 0x02, 0x9d, 0x96, 0x95, 0x32, 0xd9, 0x60 } };
pub const IID_IShellItem: GUID = .{ .data1 = 0x43826d1e, .data2 = 0xe718, .data3 = 0x42ee, .data4 = .{ 0xbc, 0x55, 0xa1, 0xe2, 0x61, 0xc3, 0x7b, 0xfe } };

pub const FOS_OVERWRITEPROMPT: u32 = 0x2;
pub const FOS_NOCHANGEDIR: u32 = 0x8;
pub const FOS_PICKFOLDERS: u32 = 0x20;
pub const FOS_FORCEFILESYSTEM: u32 = 0x40;
pub const FOS_ALLOWMULTISELECT: u32 = 0x200;
pub const FOS_PATHMUSTEXIST: u32 = 0x800;
pub const FOS_FILEMUSTEXIST: u32 = 0x1000;

pub const SIGDN_FILESYSPATH: i32 = @bitCast(@as(u32, 0x80058000));
/// What `Show` returns when the user cancels: `HRESULT_FROM_WIN32(ERROR_CANCELLED)`.
pub const E_CANCELLED: HRESULT = @bitCast(@as(u32, 0x800704C7));

pub const COMDLG_FILTERSPEC = extern struct { pszName: LPCWSTR, pszSpec: LPCWSTR };

pub const IShellItem = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        unknown: win32.IUnknownMethods(IShellItem),
        BindToHandler: *const anyopaque,
        GetParent: *const anyopaque,
        GetDisplayName: *const fn (self: *IShellItem, form: i32, name: *?[*:0]u16) callconv(.winapi) HRESULT,
        GetAttributes: *const anyopaque,
        Compare: *const anyopaque,
    };

    pub fn release(self: *IShellItem) void {
        _ = self.vtable.unknown.Release(self);
    }

    /// The item's file-system path, which the caller frees with `CoTaskMemFree`.
    pub fn fileSystemPath(self: *IShellItem) ?[*:0]u16 {
        var name: ?[*:0]u16 = null;
        if (!win32.succeeded(self.vtable.GetDisplayName(self, SIGDN_FILESYSPATH, &name))) return null;
        return name;
    }
};

pub const IShellItemArray = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        unknown: win32.IUnknownMethods(IShellItemArray),
        BindToHandler: *const anyopaque,
        GetPropertyStore: *const anyopaque,
        GetPropertyDescriptionList: *const anyopaque,
        GetAttributes: *const anyopaque,
        GetCount: *const fn (self: *IShellItemArray, count: *win32.DWORD) callconv(.winapi) HRESULT,
        GetItemAt: *const fn (self: *IShellItemArray, index: win32.DWORD, item: *?*IShellItem) callconv(.winapi) HRESULT,
        EnumItems: *const anyopaque,
    };

    pub fn release(self: *IShellItemArray) void {
        _ = self.vtable.unknown.Release(self);
    }
};

/// `IFileDialog`, which both dialogs are, behind `IModalWindow`'s `Show`.
pub const IFileDialog = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        unknown: win32.IUnknownMethods(IFileDialog),
        Show: *const fn (self: *IFileDialog, owner: ?win32.HWND) callconv(.winapi) HRESULT,
        SetFileTypes: *const fn (self: *IFileDialog, count: win32.UINT, specs: [*]const COMDLG_FILTERSPEC) callconv(.winapi) HRESULT,
        SetFileTypeIndex: *const anyopaque,
        GetFileTypeIndex: *const anyopaque,
        Advise: *const anyopaque,
        Unadvise: *const anyopaque,
        SetOptions: *const fn (self: *IFileDialog, options: u32) callconv(.winapi) HRESULT,
        GetOptions: *const fn (self: *IFileDialog, options: *u32) callconv(.winapi) HRESULT,
        SetDefaultFolder: *const anyopaque,
        SetFolder: *const fn (self: *IFileDialog, folder: *IShellItem) callconv(.winapi) HRESULT,
        GetFolder: *const fn (self: *IFileDialog, folder: *?*IShellItem) callconv(.winapi) HRESULT,
        GetCurrentSelection: *const anyopaque,
        SetFileName: *const fn (self: *IFileDialog, name: LPCWSTR) callconv(.winapi) HRESULT,
        GetFileName: *const fn (self: *IFileDialog, name: *?[*:0]u16) callconv(.winapi) HRESULT,
        SetTitle: *const fn (self: *IFileDialog, title: LPCWSTR) callconv(.winapi) HRESULT,
        SetOkButtonLabel: *const anyopaque,
        SetFileNameLabel: *const anyopaque,
        GetResult: *const fn (self: *IFileDialog, item: *?*IShellItem) callconv(.winapi) HRESULT,
        AddPlace: *const anyopaque,
        SetDefaultExtension: *const fn (self: *IFileDialog, extension: LPCWSTR) callconv(.winapi) HRESULT,
        Close: *const fn (self: *IFileDialog, result: HRESULT) callconv(.winapi) HRESULT,
        SetClientGuid: *const anyopaque,
        ClearClientData: *const anyopaque,
        SetFilter: *const anyopaque,
        /// `IFileOpenDialog`'s own, valid only on an open dialog.
        GetResults: *const fn (self: *IFileDialog, items: *?*IShellItemArray) callconv(.winapi) HRESULT,
    };

    pub fn release(self: *IFileDialog) void {
        _ = self.vtable.unknown.Release(self);
    }
};

pub const IID_IOleWindow: GUID = .{ .data1 = 0x00000114, .data2 = 0x0000, .data3 = 0x0000, .data4 = .{ 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 } };

pub const IOleWindow = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        unknown: win32.IUnknownMethods(IOleWindow),
        GetWindow: *const fn (self: *IOleWindow, hwnd: *?win32.HWND) callconv(.winapi) HRESULT,
        ContextSensitiveHelp: *const anyopaque,
    };
};

/// Ends a dialog's `Show` as its Cancel button would. `IFileDialog.Close`
/// does not, unless called from the dialog's own events, so the dialog's
/// window is sent `WM_CLOSE` instead.
pub fn cancelShown(dialog: *IFileDialog) void {
    var object: ?*anyopaque = null;
    if (!win32.succeeded(dialog.vtable.unknown.QueryInterface(dialog, &IID_IOleWindow, &object))) return;
    const window: *IOleWindow = @ptrCast(@alignCast(object orelse return));
    defer _ = window.vtable.unknown.Release(window);
    var hwnd: ?win32.HWND = null;
    if (!win32.succeeded(window.vtable.GetWindow(window, &hwnd))) return;
    _ = win32.PostMessageW(hwnd orelse return, win32.WM_CLOSE, 0, 0);
}

pub extern "shell32" fn SHCreateItemFromParsingName(path: LPCWSTR, bind_context: ?*anyopaque, iid: *const GUID, item: *?*anyopaque) callconv(.winapi) HRESULT;
pub extern "ole32" fn CoTaskMemFree(memory: ?*anyopaque) callconv(.winapi) void;
extern "kernel32" fn GetFullPathNameW(name: LPCWSTR, buffer_units: win32.DWORD, buffer: [*]u16, file_part: ?*?[*:0]u16) callconv(.winapi) win32.DWORD;

/// A `zui.FileDialog` in UTF-16, its strings in one fixed buffer, with the
/// directory made absolute, since the shell takes only absolute ones.
pub const CopiedDialog = struct {
    kind: zui.FileDialog.Kind = .open_file,
    units: [unit_capacity]u16 = undefined,
    units_len: usize = 0,
    title: ?LPCWSTR = null,
    directory: ?LPCWSTR = null,
    file_name: ?LPCWSTR = null,
    /// A save dialog's first filter's first extension, added to a name typed without one.
    default_extension: ?LPCWSTR = null,
    filters: [filter_capacity]COMDLG_FILTERSPEC = undefined,
    filter_count: usize = 0,

    pub const unit_capacity = 8 * 1024;
    pub const filter_capacity = 16;

    /// `error.TooLarge` when the strings or the filters do not fit, and
    /// `error.InvalidUtf8` for a string that is not UTF-8. Nothing is kept
    /// from a dialog that fails.
    pub fn copy(self: *CopiedDialog, dialog: zui.FileDialog) zui.ServiceError!void {
        self.* = .{ .kind = dialog.kind };
        errdefer self.* = .{};
        if (dialog.filters.len > filter_capacity) return error.TooLarge;
        if (dialog.title.len > 0) self.title = try self.append(dialog.title);
        if (dialog.directory.len > 0) self.directory = try self.appendAbsolute(dialog.directory);
        if (dialog.file_name.len > 0) self.file_name = try self.append(dialog.file_name);
        for (dialog.filters, self.filters[0..dialog.filters.len]) |filter, *spec| {
            spec.* = .{ .pszName = try self.append(filter.name), .pszSpec = try self.appendPattern(filter.extensions) };
        }
        self.filter_count = dialog.filters.len;
        if (dialog.kind == .save_file and dialog.filters.len > 0 and dialog.filters[0].extensions.len > 0) {
            self.default_extension = try self.append(dialog.filters[0].extensions[0]);
        }
    }

    /// What the dialog's `SetOptions` is given, beyond the options it starts with.
    pub fn options(self: *const CopiedDialog) u32 {
        const always = FOS_FORCEFILESYSTEM | FOS_NOCHANGEDIR | FOS_PATHMUSTEXIST;
        return always | switch (self.kind) {
            .open_file => FOS_FILEMUSTEXIST,
            .open_files => FOS_FILEMUSTEXIST | FOS_ALLOWMULTISELECT,
            .save_file => FOS_OVERWRITEPROMPT,
            .choose_folder => FOS_PICKFOLDERS,
        };
    }

    pub fn filterSpecs(self: *const CopiedDialog) []const COMDLG_FILTERSPEC {
        return self.filters[0..self.filter_count];
    }

    fn append(self: *CopiedDialog, utf8: []const u8) zui.ServiceError!LPCWSTR {
        const units = std.unicode.calcUtf16LeLen(utf8) catch return error.InvalidUtf8;
        const start = try self.reserve(units + 1);
        _ = std.unicode.utf8ToUtf16Le(self.units[start..][0..units], utf8) catch unreachable;
        self.units[start + units] = 0;
        return self.units[start .. start + units :0];
    }

    /// `*.zon;*.json`, or `*.*` for a filter without extensions.
    fn appendPattern(self: *CopiedDialog, extensions: []const []const u8) zui.ServiceError!LPCWSTR {
        const start = self.units_len;
        if (extensions.len == 0) return self.append("*.*");
        for (extensions, 0..) |extension, index| {
            const separator: []const u8 = if (index == 0) "*." else ";*.";
            for ([_][]const u8{ separator, extension }) |part| {
                const units = std.unicode.calcUtf16LeLen(part) catch return error.InvalidUtf8;
                const at = try self.reserve(units);
                _ = std.unicode.utf8ToUtf16Le(self.units[at..][0..units], part) catch unreachable;
            }
        }
        const end = try self.reserve(1);
        self.units[end] = 0;
        return self.units[start..end :0];
    }

    fn appendAbsolute(self: *CopiedDialog, directory: []const u8) zui.ServiceError!LPCWSTR {
        const relative = try self.append(directory);
        const start = self.units_len;
        const room: win32.DWORD = @intCast(unit_capacity - start);
        const needed = GetFullPathNameW(relative, room, self.units[start..].ptr, null);
        if (needed == 0) return relative;
        if (needed >= room) return error.TooLarge;
        self.units_len += needed + 1;
        return self.units[start .. start + needed :0];
    }

    fn reserve(self: *CopiedDialog, units: usize) zui.ServiceError!usize {
        if (units > unit_capacity - self.units_len) return error.TooLarge;
        const start = self.units_len;
        self.units_len += units;
        return start;
    }
};

/// A dialog made with `CoCreateInstance` and given every setting of `copied`
/// that the shell accepts; null when the shell cannot make one.
pub fn create(copied: *const CopiedDialog) ?*IFileDialog {
    const class = if (copied.kind == .save_file) &CLSID_FileSaveDialog else &CLSID_FileOpenDialog;
    const interface = if (copied.kind == .save_file) &IID_IFileDialog else &IID_IFileOpenDialog;
    var object: ?*anyopaque = null;
    if (!win32.succeeded(win32.CoCreateInstance(class, null, win32.CLSCTX_INPROC_SERVER, interface, &object))) return null;
    const dialog: *IFileDialog = @ptrCast(@alignCast(object orelse return null));
    var options: u32 = 0;
    _ = dialog.vtable.GetOptions(dialog, &options);
    _ = dialog.vtable.SetOptions(dialog, options | copied.options());
    if (copied.title) |title| _ = dialog.vtable.SetTitle(dialog, title);
    if (copied.file_name) |name| _ = dialog.vtable.SetFileName(dialog, name);
    if (copied.default_extension) |extension| _ = dialog.vtable.SetDefaultExtension(dialog, extension);
    if (copied.filter_count > 0) _ = dialog.vtable.SetFileTypes(dialog, @intCast(copied.filter_count), &copied.filters);
    if (copied.directory) |directory| {
        var folder: ?*anyopaque = null;
        if (win32.succeeded(SHCreateItemFromParsingName(directory, null, &IID_IShellItem, &folder))) if (folder) |found| {
            const item: *IShellItem = @ptrCast(@alignCast(found));
            defer item.release();
            _ = dialog.vtable.SetFolder(dialog, item);
        };
    }
    return dialog;
}

/// Each path the user chose, as UTF-8 followed by a 0 byte, in `buffer`.
pub const ChosenPaths = struct {
    buffer: []u8,
    len: usize = 0,
    /// Paths that did not fit whole, counted with their 0 bytes.
    left_out_bytes: u32 = 0,

    pub fn add(self: *ChosenPaths, path: []const u16) void {
        const needed = std.unicode.calcWtf8Len(path) + 1;
        if (needed > self.buffer.len - self.len) {
            self.left_out_bytes +|= std.math.lossyCast(u32, needed);
            return;
        }
        self.len += std.unicode.wtf16LeToWtf8(self.buffer[self.len..], path);
        self.buffer[self.len] = 0;
        self.len += 1;
    }

    pub fn addUtf8(self: *ChosenPaths, path: []const u8) void {
        if (path.len + 1 > self.buffer.len - self.len) {
            self.left_out_bytes +|= std.math.lossyCast(u32, path.len + 1);
            return;
        }
        @memcpy(self.buffer[self.len..][0..path.len], path);
        self.buffer[self.len + path.len] = 0;
        self.len += path.len + 1;
    }

    pub fn addItem(self: *ChosenPaths, item: *IShellItem) void {
        const path = item.fileSystemPath() orelse return;
        defer CoTaskMemFree(@ptrCast(path));
        self.add(std.mem.span(path));
    }

    pub fn list(self: *const ChosenPaths) []const u8 {
        return self.buffer[0..self.len];
    }
};

/// What the shown dialog answers: its paths, or that the user canceled it.
pub fn collectAnswer(dialog: *IFileDialog, kind: zui.FileDialog.Kind, shown: HRESULT, paths: *ChosenPaths) zui.ServiceAnswer.Outcome {
    if (shown == E_CANCELLED) return .canceled;
    if (!win32.succeeded(shown)) return .{ .failed = .unavailable };
    if (kind == .save_file) {
        var item: ?*IShellItem = null;
        if (!win32.succeeded(dialog.vtable.GetResult(dialog, &item))) return .{ .failed = .unavailable };
        const chosen = item orelse return .{ .failed = .unavailable };
        defer chosen.release();
        paths.addItem(chosen);
    } else {
        var items: ?*IShellItemArray = null;
        if (!win32.succeeded(dialog.vtable.GetResults(dialog, &items))) return .{ .failed = .unavailable };
        const chosen = items orelse return .{ .failed = .unavailable };
        defer chosen.release();
        var count: win32.DWORD = 0;
        _ = chosen.vtable.GetCount(chosen, &count);
        for (0..count) |index| {
            var item: ?*IShellItem = null;
            if (!win32.succeeded(chosen.vtable.GetItemAt(chosen, @intCast(index), &item))) continue;
            const each = item orelse continue;
            defer each.release();
            paths.addItem(each);
        }
    }
    return .{ .files_chosen = paths.list() };
}

test "a dialog's strings are copied in UTF-16, its filters as patterns, and a save dialog takes the first extension" {
    var copied: CopiedDialog = .{};
    try copied.copy(.{
        .kind = .save_file,
        .title = "Save théme",
        .file_name = "dark.zon",
        .filters = &.{ .{ .name = "Themes", .extensions = &.{ "zon", "json" } }, .{ .name = "All files", .extensions = &.{} } },
    });
    const W = std.unicode.utf8ToUtf16LeStringLiteral;
    try std.testing.expectEqualSlices(u16, W("Save théme"), std.mem.span(copied.title.?));
    try std.testing.expectEqualSlices(u16, W("dark.zon"), std.mem.span(copied.file_name.?));
    try std.testing.expectEqualSlices(u16, W("zon"), std.mem.span(copied.default_extension.?));
    try std.testing.expectEqual(@as(usize, 2), copied.filterSpecs().len);
    try std.testing.expectEqualSlices(u16, W("*.zon;*.json"), std.mem.span(copied.filterSpecs()[0].pszSpec));
    try std.testing.expectEqualSlices(u16, W("*.*"), std.mem.span(copied.filterSpecs()[1].pszSpec));
    try std.testing.expectEqual(null, copied.directory);
    try std.testing.expect(copied.options() & FOS_OVERWRITEPROMPT != 0);
}

test "a relative directory is made absolute" {
    var copied: CopiedDialog = .{};
    try copied.copy(.{ .directory = "themes" });
    const directory = std.mem.span(copied.directory.?);
    try std.testing.expect(directory.len > "C:\\themes".len - 1);
    try std.testing.expectEqual(@as(u16, ':'), directory[1]);
    try std.testing.expect(std.mem.endsWith(u16, directory, std.unicode.utf8ToUtf16LeStringLiteral("\\themes")));
}

test "a dialog whose strings or filters do not fit, or are not UTF-8, is refused and keeps nothing" {
    var copied: CopiedDialog = .{};
    try std.testing.expectError(error.TooLarge, copied.copy(.{ .title = "t" ** (CopiedDialog.unit_capacity + 1) }));
    try std.testing.expectEqual(@as(usize, 0), copied.units_len);
    const filter: zui.FileFilter = .{ .name = "Themes", .extensions = &.{"zon"} };
    try std.testing.expectError(error.TooLarge, copied.copy(.{ .filters = &([_]zui.FileFilter{filter} ** (CopiedDialog.filter_capacity + 1)) }));
    try std.testing.expectError(error.InvalidUtf8, copied.copy(.{ .filters = &.{.{ .name = "Themes", .extensions = &.{"z\xffn"} }} }));
    try std.testing.expectEqual(null, copied.title);
}

test "chosen paths are kept whole in UTF-8, and those that do not fit are counted" {
    var buffer: [12]u8 = undefined;
    var paths: ChosenPaths = .{ .buffer = &buffer };
    const W = std.unicode.utf8ToUtf16LeStringLiteral;
    paths.add(W("C:\\é.zon"));
    paths.add(W("C:\\long.zon"));
    try std.testing.expectEqualStrings("C:\\é.zon\x00", paths.list());
    try std.testing.expectEqual(@as(u32, "C:\\long.zon".len + 1), paths.left_out_bytes);
}
