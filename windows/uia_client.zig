//! A UI Automation client for the host's tests, which read the window as an
//! assistive technology does. Each call blocks until UI Automation answers,
//! so it must run on a thread that owns no window.

const std = @import("std");
const zui_host = @import("zui_host");
const win32 = zui_host.windows.win32;
const uia = zui_host.windows.uia;

const HRESULT = win32.HRESULT;

const CLSID_CUIAutomation8: win32.GUID = .{ .data1 = 0xe22ad333, .data2 = 0xb25f, .data3 = 0x460c, .data4 = .{ 0x83, 0xd0, 0x05, 0x81, 0x10, 0x73, 0x95, 0xc9 } };
const IID_IUIAutomation: win32.GUID = .{ .data1 = 0x30cbe57d, .data2 = 0xd9d0, .data3 = 0x452a, .data4 = .{ 0xab, 0x13, 0x7a, 0xc5, 0xac, 0x48, 0x25, 0xee } };
const IID_IUIAutomationInvokePattern: win32.GUID = .{ .data1 = 0xfb377fbe, .data2 = 0x8ea6, .data3 = 0x46d5, .data4 = .{ 0x9c, 0x73, 0x64, 0x99, 0x64, 0x2d, 0x30, 0x59 } };

const TreeScope_Descendants = 0x4;

/// A COM object reached through its table of methods, by index in the
/// order the SDK's header declares them.
const Object = extern struct {
    vtable: [*]const *const anyopaque,

    fn method(self: *Object, comptime index: usize, comptime Function: type) *const Function {
        return @ptrCast(self.vtable[index]);
    }

    fn release(self: *Object) void {
        _ = self.method(2, fn (*Object) callconv(.winapi) u32)(self);
    }
};

fn check(result: HRESULT) error{AutomationFailed}!void {
    if (!win32.succeeded(result)) return error.AutomationFailed;
}

pub const Client = struct {
    automation: *Object,

    /// Joins the calling thread to the multithreaded apartment, as UI
    /// Automation's clients should.
    pub fn init() !Client {
        const joined = win32.CoInitializeEx(null, win32.COINIT_MULTITHREADED);
        if (!win32.succeeded(joined)) return error.ComUnavailable;
        errdefer win32.CoUninitialize();
        var automation: ?*anyopaque = null;
        try check(win32.CoCreateInstance(&CLSID_CUIAutomation8, null, win32.CLSCTX_INPROC_SERVER, &IID_IUIAutomation, &automation));
        return .{ .automation = @ptrCast(@alignCast(automation.?)) };
    }

    pub fn deinit(self: *Client) void {
        self.automation.release();
        win32.CoUninitialize();
    }

    pub fn elementFromHandle(self: *Client, hwnd: win32.HWND) !Element {
        var found: ?*Object = null;
        try check(self.automation.method(6, fn (*Object, win32.HWND, *?*Object) callconv(.winapi) HRESULT)(self.automation, hwnd, &found));
        return .{ .object = found orelse return error.NoElement };
    }

    /// The first element under `root` whose name is `name`, or null.
    pub fn findByName(self: *Client, root: Element, name: []const u8) !?Element {
        var name_utf16: [128]u16 = undefined;
        const units = try std.unicode.utf8ToUtf16Le(&name_utf16, name);
        var value: win32.VARIANT = .{ .vt = win32.VT_BSTR, .value = .{ .string = win32.SysAllocStringLen(&name_utf16, @intCast(units)) orelse return error.OutOfMemory } };
        defer _ = win32.VariantClear(&value);
        var condition: ?*Object = null;
        try check(self.automation.method(23, fn (*Object, uia.PROPERTYID, win32.VARIANT, *?*Object) callconv(.winapi) HRESULT)(self.automation, uia.UIA_NamePropertyId, value, &condition));
        defer condition.?.release();
        var found: ?*Object = null;
        try check(root.object.method(5, fn (*Object, i32, *Object, *?*Object) callconv(.winapi) HRESULT)(root.object, TreeScope_Descendants, condition.?, &found));
        return if (found) |object| .{ .object = object } else null;
    }

    /// Walks every element, as `ProviderOptions` and views leave them.
    pub fn rawViewWalker(self: *Client) !Walker {
        var found: ?*Object = null;
        try check(self.automation.method(16, fn (*Object, *?*Object) callconv(.winapi) HRESULT)(self.automation, &found));
        return .{ .object = found.? };
    }
};

pub const Element = struct {
    object: *Object,

    pub fn release(self: Element) void {
        self.object.release();
    }

    pub fn setFocus(self: Element) !void {
        try check(self.object.method(3, fn (*Object) callconv(.winapi) HRESULT)(self.object));
    }

    /// The name in `buffer`, as UTF-8.
    pub fn name(self: Element, buffer: []u8) ![]u8 {
        return self.stringProperty(23, buffer);
    }

    pub fn automationId(self: Element, buffer: []u8) ![]u8 {
        return self.stringProperty(29, buffer);
    }

    pub fn controlType(self: Element) !uia.CONTROLTYPEID {
        var found: uia.CONTROLTYPEID = 0;
        try check(self.object.method(21, fn (*Object, *uia.CONTROLTYPEID) callconv(.winapi) HRESULT)(self.object, &found));
        return found;
    }

    /// In screen pixels.
    pub fn boundingRectangle(self: Element) !win32.RECT {
        var found: win32.RECT = .{};
        try check(self.object.method(43, fn (*Object, *win32.RECT) callconv(.winapi) HRESULT)(self.object, &found));
        return found;
    }

    /// Invokes it through its Invoke pattern, or returns false when it has
    /// none.
    pub fn invoke(self: Element) !bool {
        var pattern: ?*Object = null;
        try check(self.object.method(14, fn (*Object, uia.PATTERNID, *const win32.GUID, *?*anyopaque) callconv(.winapi) HRESULT)(self.object, uia.UIA_InvokePatternId, &IID_IUIAutomationInvokePattern, @ptrCast(&pattern)));
        const invoke_pattern = pattern orelse return false;
        defer invoke_pattern.release();
        try check(invoke_pattern.method(3, fn (*Object) callconv(.winapi) HRESULT)(invoke_pattern));
        return true;
    }

    fn stringProperty(self: Element, comptime index: usize, buffer: []u8) ![]u8 {
        var found: win32.BSTR = null;
        try check(self.object.method(index, fn (*Object, *win32.BSTR) callconv(.winapi) HRESULT)(self.object, &found));
        defer win32.SysFreeString(found);
        const units = std.mem.sliceTo(found orelse return buffer[0..0], 0);
        if (std.unicode.calcWtf8Len(units) > buffer.len) return error.NoSpaceLeft;
        return buffer[0..std.unicode.wtf16LeToWtf8(buffer, units)];
    }
};

pub const Walker = struct {
    object: *Object,

    pub fn release(self: Walker) void {
        self.object.release();
    }

    pub fn parent(self: Walker, element: Element) !?Element {
        return self.step(3, element);
    }

    pub fn firstChild(self: Walker, element: Element) !?Element {
        return self.step(4, element);
    }

    pub fn nextSibling(self: Walker, element: Element) !?Element {
        return self.step(6, element);
    }

    fn step(self: Walker, comptime index: usize, element: Element) !?Element {
        var found: ?*Object = null;
        try check(self.object.method(index, fn (*Object, *Object, *?*Object) callconv(.winapi) HRESULT)(self.object, element.object, &found));
        return if (found) |object| .{ .object = object } else null;
    }
};
