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
const IID_IUIAutomationTogglePattern: win32.GUID = .{ .data1 = 0x94cf8058, .data2 = 0x9b8d, .data3 = 0x4ab9, .data4 = .{ 0x8b, 0xfd, 0x4c, 0xd0, 0xa3, 0x3c, 0x8c, 0x70 } };
const IID_IUIAutomationExpandCollapsePattern: win32.GUID = .{ .data1 = 0x619be086, .data2 = 0x1f4e, .data3 = 0x4ee4, .data4 = .{ 0xba, 0xfa, 0x21, 0x01, 0x28, 0x73, 0x87, 0x30 } };
const IID_IUIAutomationRangeValuePattern: win32.GUID = .{ .data1 = 0x59213f4f, .data2 = 0x7346, .data3 = 0x49e5, .data4 = .{ 0xb1, 0x20, 0x80, 0x55, 0x59, 0x87, 0xa1, 0x48 } };
const IID_IUIAutomationValuePattern: win32.GUID = .{ .data1 = 0xa94cd8b1, .data2 = 0x0844, .data3 = 0x4cd6, .data4 = .{ 0x9d, 0x2d, 0x64, 0x05, 0x37, 0xab, 0x39, 0xe9 } };
const IID_IUIAutomationSelectionItemPattern: win32.GUID = .{ .data1 = 0xa8efa66a, .data2 = 0x0fda, .data3 = 0x421a, .data4 = .{ 0x91, 0x94, 0x38, 0x02, 0x1f, 0x35, 0x78, 0xea } };
const IID_IUIAutomationSelectionPattern: win32.GUID = .{ .data1 = 0x5ed5202e, .data2 = 0xb2ac, .data3 = 0x47a6, .data4 = .{ 0xb6, 0x38, 0x4b, 0x0b, 0xf1, 0x40, 0xd7, 0x8e } };
const IID_IUIAutomationPropertyChangedEventHandler: win32.GUID = .{ .data1 = 0x40cd37d4, .data2 = 0xc756, .data3 = 0x4b0c, .data4 = .{ 0x8c, 0x6f, 0xbd, 0xdf, 0xee, 0xb1, 0x3b, 0x50 } };
const IID_IUIAutomationElement3: win32.GUID = .{ .data1 = 0x8471df34, .data2 = 0xaee0, .data3 = 0x4a01, .data4 = .{ 0xa7, 0xde, 0x7d, 0xb9, 0xaf, 0x12, 0xc2, 0x96 } };
const IID_IUIAutomationWindowPattern: win32.GUID = .{ .data1 = 0x0faef453, .data2 = 0x9208, .data3 = 0x43ef, .data4 = .{ 0xbb, 0xb2, 0x3b, 0x48, 0x51, 0x77, 0x86, 0x4f } };
const IID_IUIAutomationScrollPattern: win32.GUID = .{ .data1 = 0x88f4d42a, .data2 = 0xe881, .data3 = 0x459d, .data4 = .{ 0xa7, 0x7c, 0x73, 0xbb, 0xbb, 0x7e, 0x02, 0xdc } };

const TreeScope_Descendants = 0x4;
const TreeScope_Subtree = 0x7;

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

    /// Removes every handler this client added, from the thread that added
    /// them.
    pub fn stopListening(self: *Client) void {
        _ = self.automation.method(41, fn (*Object) callconv(.winapi) HRESULT)(self.automation);
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
        return self.callPattern(uia.UIA_InvokePatternId, &IID_IUIAutomationInvokePattern, 3);
    }

    /// Toggles it through its Toggle pattern, or returns false when it has
    /// none.
    pub fn toggle(self: Element) !bool {
        return self.callPattern(uia.UIA_TogglePatternId, &IID_IUIAutomationTogglePattern, 3);
    }

    pub fn toggleState(self: Element) !?uia.ToggleState {
        return self.readPattern(uia.ToggleState, uia.UIA_TogglePatternId, &IID_IUIAutomationTogglePattern, 4);
    }

    pub fn expand(self: Element) !bool {
        return self.callPattern(uia.UIA_ExpandCollapsePatternId, &IID_IUIAutomationExpandCollapsePattern, 3);
    }

    pub fn expandCollapseState(self: Element) !?uia.ExpandCollapseState {
        return self.readPattern(uia.ExpandCollapseState, uia.UIA_ExpandCollapsePatternId, &IID_IUIAutomationExpandCollapsePattern, 5);
    }

    pub const Range = struct { value: f64, min: f64, max: f64, read_only: bool };

    pub fn range(self: Element) !?Range {
        const pattern = try self.patternObject(uia.UIA_RangeValuePatternId, &IID_IUIAutomationRangeValuePattern) orelse return null;
        defer pattern.release();
        var read_only: win32.BOOL = 0;
        try check(pattern.method(5, fn (*Object, *win32.BOOL) callconv(.winapi) HRESULT)(pattern, &read_only));
        return .{
            .value = try readNumber(pattern, 4),
            .max = try readNumber(pattern, 6),
            .min = try readNumber(pattern, 7),
            .read_only = read_only != 0,
        };
    }

    pub fn setRangeValue(self: Element, value: f64) !bool {
        const pattern = try self.patternObject(uia.UIA_RangeValuePatternId, &IID_IUIAutomationRangeValuePattern) orelse return false;
        defer pattern.release();
        try check(pattern.method(3, fn (*Object, f64) callconv(.winapi) HRESULT)(pattern, value));
        return true;
    }

    /// Its Value pattern's text in `buffer`, or null when it has no Value
    /// pattern.
    pub fn valueText(self: Element, buffer: []u8) !?[]u8 {
        const pattern = try self.patternObject(uia.UIA_ValuePatternId, &IID_IUIAutomationValuePattern) orelse return null;
        defer pattern.release();
        return try readString(pattern, 4, buffer);
    }

    pub fn valueIsReadOnly(self: Element) !?bool {
        const read_only = try self.readPattern(win32.BOOL, uia.UIA_ValuePatternId, &IID_IUIAutomationValuePattern, 5) orelse return null;
        return read_only != 0;
    }

    /// Fails as the provider does when the value cannot be set.
    pub fn setValueText(self: Element, text: [*:0]const u16) !bool {
        const pattern = try self.patternObject(uia.UIA_ValuePatternId, &IID_IUIAutomationValuePattern) orelse return false;
        defer pattern.release();
        try check(pattern.method(3, fn (*Object, [*:0]const u16) callconv(.winapi) HRESULT)(pattern, text));
        return true;
    }

    pub fn select(self: Element) !bool {
        return self.callPattern(uia.UIA_SelectionItemPatternId, &IID_IUIAutomationSelectionItemPattern, 3);
    }

    pub fn isSelected(self: Element) !?bool {
        const selected = try self.readPattern(win32.BOOL, uia.UIA_SelectionItemPatternId, &IID_IUIAutomationSelectionItemPattern, 6) orelse return null;
        return selected != 0;
    }

    /// The element its SelectionItem pattern names as its container.
    pub fn selectionContainer(self: Element) !?Element {
        const pattern = try self.patternObject(uia.UIA_SelectionItemPatternId, &IID_IUIAutomationSelectionItemPattern) orelse return null;
        defer pattern.release();
        var found: ?*Object = null;
        try check(pattern.method(7, fn (*Object, *?*Object) callconv(.winapi) HRESULT)(pattern, &found));
        return if (found) |object| .{ .object = object } else null;
    }

    /// The first element its Selection pattern reports selected, and how
    /// many it reports.
    pub fn firstSelected(self: Element) !?struct { count: i32, first: ?Element } {
        const pattern = try self.patternObject(uia.UIA_SelectionPatternId, &IID_IUIAutomationSelectionPattern) orelse return null;
        defer pattern.release();
        var array: ?*Object = null;
        try check(pattern.method(3, fn (*Object, *?*Object) callconv(.winapi) HRESULT)(pattern, &array));
        defer array.?.release();
        var count: i32 = 0;
        try check(array.?.method(3, fn (*Object, *i32) callconv(.winapi) HRESULT)(array.?, &count));
        if (count == 0) return .{ .count = 0, .first = null };
        var first: ?*Object = null;
        try check(array.?.method(4, fn (*Object, i32, *?*Object) callconv(.winapi) HRESULT)(array.?, 0, &first));
        return .{ .count = count, .first = .{ .object = first.? } };
    }

    pub fn scrollBy(self: Element, horizontal: uia.ScrollAmount, vertical: uia.ScrollAmount) !bool {
        const pattern = try self.patternObject(uia.UIA_ScrollPatternId, &IID_IUIAutomationScrollPattern) orelse return false;
        defer pattern.release();
        try check(pattern.method(3, fn (*Object, uia.ScrollAmount, uia.ScrollAmount) callconv(.winapi) HRESULT)(pattern, horizontal, vertical));
        return true;
    }

    pub fn setScrollPercent(self: Element, horizontal: f64, vertical: f64) !bool {
        const pattern = try self.patternObject(uia.UIA_ScrollPatternId, &IID_IUIAutomationScrollPattern) orelse return false;
        defer pattern.release();
        try check(pattern.method(4, fn (*Object, f64, f64) callconv(.winapi) HRESULT)(pattern, horizontal, vertical));
        return true;
    }

    /// Its scroll position, and how much of its content it shows, from 0
    /// to 100, horizontally then vertically.
    pub const Scrolled = struct { percent: [2]f64, view_size: [2]f64 };

    pub fn scrolled(self: Element) !?Scrolled {
        const pattern = try self.patternObject(uia.UIA_ScrollPatternId, &IID_IUIAutomationScrollPattern) orelse return null;
        defer pattern.release();
        return .{
            .percent = .{ try readNumber(pattern, 5), try readNumber(pattern, 6) },
            .view_size = .{ try readNumber(pattern, 7), try readNumber(pattern, 8) },
        };
    }

    /// Closes it through its Window pattern, or returns false when it has
    /// none.
    pub fn closeWindow(self: Element) !bool {
        return self.callPattern(uia.UIA_WindowPatternId, &IID_IUIAutomationWindowPattern, 3);
    }

    pub fn showContextMenu(self: Element) !void {
        var element3: ?*Object = null;
        try check(self.object.method(0, fn (*Object, *const win32.GUID, *?*Object) callconv(.winapi) HRESULT)(self.object, &IID_IUIAutomationElement3, &element3));
        defer element3.?.release();
        try check(element3.?.method(91, fn (*Object) callconv(.winapi) HRESULT)(element3.?));
    }

    /// The integer value of `property`, or null when it is not one.
    pub fn integerProperty(self: Element, property: uia.PROPERTYID) !?i32 {
        var value: win32.VARIANT = .{};
        try check(self.object.method(10, fn (*Object, uia.PROPERTYID, *win32.VARIANT) callconv(.winapi) HRESULT)(self.object, property, &value));
        defer _ = win32.VariantClear(&value);
        return if (value.vt == win32.VT_I4) value.value.int else null;
    }

    pub fn hasPattern(self: Element, pattern_id: uia.PATTERNID) !bool {
        var found: ?*Object = null;
        try check(self.object.method(16, fn (*Object, uia.PATTERNID, *?*Object) callconv(.winapi) HRESULT)(self.object, pattern_id, &found));
        const pattern = found orelse return false;
        pattern.release();
        return true;
    }

    fn patternObject(self: Element, pattern_id: uia.PATTERNID, iid: *const win32.GUID) !?*Object {
        var found: ?*Object = null;
        try check(self.object.method(14, fn (*Object, uia.PATTERNID, *const win32.GUID, *?*Object) callconv(.winapi) HRESULT)(self.object, pattern_id, iid, &found));
        return found;
    }

    /// Calls the pattern's method at `index`, which takes no argument.
    fn callPattern(self: Element, pattern_id: uia.PATTERNID, iid: *const win32.GUID, comptime index: usize) !bool {
        const pattern = try self.patternObject(pattern_id, iid) orelse return false;
        defer pattern.release();
        try check(pattern.method(index, fn (*Object) callconv(.winapi) HRESULT)(pattern));
        return true;
    }

    fn readPattern(self: Element, comptime Value: type, pattern_id: uia.PATTERNID, iid: *const win32.GUID, comptime index: usize) !?Value {
        const pattern = try self.patternObject(pattern_id, iid) orelse return null;
        defer pattern.release();
        var found: Value = undefined;
        try check(pattern.method(index, fn (*Object, *Value) callconv(.winapi) HRESULT)(pattern, &found));
        return found;
    }

    fn readNumber(pattern: *Object, comptime index: usize) !f64 {
        var found: f64 = 0;
        try check(pattern.method(index, fn (*Object, *f64) callconv(.winapi) HRESULT)(pattern, &found));
        return found;
    }

    fn stringProperty(self: Element, comptime index: usize, buffer: []u8) ![]u8 {
        return readString(self.object, index, buffer);
    }
};

/// The string the getter at `index` returns, in `buffer` as UTF-8.
fn readString(object: *Object, comptime index: usize, buffer: []u8) ![]u8 {
    var found: win32.BSTR = null;
    try check(object.method(index, fn (*Object, *win32.BSTR) callconv(.winapi) HRESULT)(object, &found));
    defer win32.SysFreeString(found);
    const units = std.mem.sliceTo(found orelse return buffer[0..0], 0);
    if (std.unicode.calcWtf8Len(units) > buffer.len) return error.NoSpaceLeft;
    return buffer[0..std.unicode.wtf16LeToWtf8(buffer, units)];
}

/// Counts the property-changed events UI Automation reports for one
/// property, keeping the last integer value, from whichever thread UI
/// Automation calls it on.
pub const PropertyChanges = struct {
    handler: Object = .{ .vtable = &vtable },
    seen: std.atomic.Value(u32) = .init(0),
    last_integer: std.atomic.Value(i32) = .init(-1),

    const Handle = *const fn (*Object, *Object, uia.PROPERTYID, win32.VARIANT) callconv(.winapi) HRESULT;
    const vtable = [_]*const anyopaque{
        @ptrCast(&queryInterface),
        @ptrCast(&addRef),
        @ptrCast(&release),
        @ptrCast(@as(Handle, &handle)),
    };

    fn of(handler: *Object) *PropertyChanges {
        return @fieldParentPtr("handler", handler);
    }

    fn queryInterface(handler: *Object, iid: *const win32.GUID, found: *?*anyopaque) callconv(.winapi) HRESULT {
        if (std.meta.eql(iid.*, win32.IID_IUnknown) or std.meta.eql(iid.*, IID_IUIAutomationPropertyChangedEventHandler)) {
            found.* = handler;
            return win32.S_OK;
        }
        found.* = null;
        return win32.E_NOINTERFACE;
    }

    /// The handler lives on its test's stack, past the last call.
    fn addRef(_: *Object) callconv(.winapi) u32 {
        return 1;
    }

    fn release(_: *Object) callconv(.winapi) u32 {
        return 1;
    }

    fn handle(handler: *Object, _: *Object, _: uia.PROPERTYID, value: win32.VARIANT) callconv(.winapi) HRESULT {
        const self = of(handler);
        if (value.vt == win32.VT_I4) self.last_integer.store(value.value.int, .release);
        _ = self.seen.fetchAdd(1, .acq_rel);
        return win32.S_OK;
    }

    /// Listens for `property` on `element` and everything in it, until the
    /// client's `stopListening`.
    pub fn listen(self: *PropertyChanges, client: *Client, element: Element, property: uia.PROPERTYID) !void {
        var properties = [_]uia.PROPERTYID{property};
        try check(client.automation.method(34, fn (*Object, *Object, i32, ?*Object, *Object, [*]uia.PROPERTYID, i32) callconv(.winapi) HRESULT)(client.automation, element.object, TreeScope_Subtree, null, &self.handler, &properties, 1));
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
