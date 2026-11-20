//! The UI Automation provider declarations the accessibility bridge uses,
//! and nothing more.

const win32 = @import("win32.zig");
const GUID = win32.GUID;
const HRESULT = win32.HRESULT;

pub const PROPERTYID = i32;
pub const PATTERNID = i32;
pub const EVENTID = i32;
pub const CONTROLTYPEID = i32;

pub const UiaRect = extern struct { left: f64 = 0, top: f64 = 0, width: f64 = 0, height: f64 = 0 };

pub const IRawElementProviderSimple = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        unknown: win32.IUnknownMethods(IRawElementProviderSimple),
        get_ProviderOptions: *const fn (self: *IRawElementProviderSimple, options: *i32) callconv(.winapi) HRESULT,
        GetPatternProvider: *const fn (self: *IRawElementProviderSimple, pattern: PATTERNID, provider: *?*anyopaque) callconv(.winapi) HRESULT,
        GetPropertyValue: *const fn (self: *IRawElementProviderSimple, property: PROPERTYID, value: *win32.VARIANT) callconv(.winapi) HRESULT,
        get_HostRawElementProvider: *const fn (self: *IRawElementProviderSimple, provider: *?*IRawElementProviderSimple) callconv(.winapi) HRESULT,
    };
};

pub const IRawElementProviderFragment = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        unknown: win32.IUnknownMethods(IRawElementProviderFragment),
        Navigate: *const fn (self: *IRawElementProviderFragment, direction: NavigateDirection, found: *?*IRawElementProviderFragment) callconv(.winapi) HRESULT,
        GetRuntimeId: *const fn (self: *IRawElementProviderFragment, runtime_id: *?*win32.SAFEARRAY) callconv(.winapi) HRESULT,
        get_BoundingRectangle: *const fn (self: *IRawElementProviderFragment, bounds: *UiaRect) callconv(.winapi) HRESULT,
        GetEmbeddedFragmentRoots: *const fn (self: *IRawElementProviderFragment, roots: *?*win32.SAFEARRAY) callconv(.winapi) HRESULT,
        SetFocus: *const fn (self: *IRawElementProviderFragment) callconv(.winapi) HRESULT,
        get_FragmentRoot: *const fn (self: *IRawElementProviderFragment, root: *?*IRawElementProviderFragmentRoot) callconv(.winapi) HRESULT,
    };
};

pub const IRawElementProviderFragmentRoot = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        unknown: win32.IUnknownMethods(IRawElementProviderFragmentRoot),
        ElementProviderFromPoint: *const fn (self: *IRawElementProviderFragmentRoot, x: f64, y: f64, found: *?*IRawElementProviderFragment) callconv(.winapi) HRESULT,
        GetFocus: *const fn (self: *IRawElementProviderFragmentRoot, found: *?*IRawElementProviderFragment) callconv(.winapi) HRESULT,
    };
};

pub const IInvokeProvider = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        unknown: win32.IUnknownMethods(IInvokeProvider),
        Invoke: *const fn (self: *IInvokeProvider) callconv(.winapi) HRESULT,
    };
};

pub const IID_IRawElementProviderSimple: GUID = .{ .data1 = 0xd6dd68d1, .data2 = 0x86fd, .data3 = 0x4332, .data4 = .{ 0x86, 0x66, 0x9a, 0xbe, 0xde, 0xa2, 0xd2, 0x4c } };
pub const IID_IRawElementProviderFragment: GUID = .{ .data1 = 0xf7063da8, .data2 = 0x8359, .data3 = 0x439c, .data4 = .{ 0x92, 0x97, 0xbb, 0xc5, 0x29, 0x9a, 0x7d, 0x87 } };
pub const IID_IRawElementProviderFragmentRoot: GUID = .{ .data1 = 0x620ce2a5, .data2 = 0xab8f, .data3 = 0x40a9, .data4 = .{ 0x86, 0xcb, 0xde, 0x3c, 0x75, 0x59, 0x9b, 0x58 } };
pub const IID_IInvokeProvider: GUID = .{ .data1 = 0x54fcb24b, .data2 = 0xe18e, .data3 = 0x47a2, .data4 = .{ 0xb4, 0xd3, 0xec, 0xcb, 0xe7, 0x75, 0x99, 0xa2 } };

pub const NavigateDirection = enum(i32) {
    parent = 0,
    next_sibling = 1,
    previous_sibling = 2,
    first_child = 3,
    last_child = 4,
    _,
};

pub const ProviderOptions_ServerSideProvider = 0x2;

pub const UiaRootObjectId: i32 = -25;
pub const UiaAppendRuntimeId: i32 = 3;
pub const StructureChangeType_ChildrenInvalidated = 2;

pub const UIA_E_ELEMENTNOTENABLED: HRESULT = @bitCast(@as(u32, 0x80040200));
pub const UIA_E_ELEMENTNOTAVAILABLE: HRESULT = @bitCast(@as(u32, 0x80040201));

pub const UIA_InvokePatternId: PATTERNID = 10000;

pub const UIA_StructureChangedEventId: EVENTID = 20002;
pub const UIA_AutomationFocusChangedEventId: EVENTID = 20005;

pub const UIA_ControlTypePropertyId: PROPERTYID = 30003;
pub const UIA_NamePropertyId: PROPERTYID = 30005;
pub const UIA_HasKeyboardFocusPropertyId: PROPERTYID = 30008;
pub const UIA_IsKeyboardFocusablePropertyId: PROPERTYID = 30009;
pub const UIA_IsEnabledPropertyId: PROPERTYID = 30010;
pub const UIA_AutomationIdPropertyId: PROPERTYID = 30011;
pub const UIA_FrameworkIdPropertyId: PROPERTYID = 30024;
pub const UIA_IsDialogPropertyId: PROPERTYID = 30174;

pub const UIA_ButtonControlTypeId: CONTROLTYPEID = 50000;
pub const UIA_CheckBoxControlTypeId: CONTROLTYPEID = 50002;
pub const UIA_ComboBoxControlTypeId: CONTROLTYPEID = 50003;
pub const UIA_EditControlTypeId: CONTROLTYPEID = 50004;
pub const UIA_HyperlinkControlTypeId: CONTROLTYPEID = 50005;
pub const UIA_ImageControlTypeId: CONTROLTYPEID = 50006;
pub const UIA_ListItemControlTypeId: CONTROLTYPEID = 50007;
pub const UIA_ListControlTypeId: CONTROLTYPEID = 50008;
pub const UIA_ProgressBarControlTypeId: CONTROLTYPEID = 50012;
pub const UIA_RadioButtonControlTypeId: CONTROLTYPEID = 50013;
pub const UIA_SliderControlTypeId: CONTROLTYPEID = 50015;
pub const UIA_TextControlTypeId: CONTROLTYPEID = 50020;
pub const UIA_GroupControlTypeId: CONTROLTYPEID = 50026;
pub const UIA_PaneControlTypeId: CONTROLTYPEID = 50033;

pub extern "uiautomationcore" fn UiaReturnRawElementProvider(hwnd: win32.HWND, wparam: win32.WPARAM, lparam: win32.LPARAM, provider: ?*IRawElementProviderSimple) callconv(.winapi) win32.LRESULT;
pub extern "uiautomationcore" fn UiaHostProviderFromHwnd(hwnd: win32.HWND, provider: *?*IRawElementProviderSimple) callconv(.winapi) HRESULT;
pub extern "uiautomationcore" fn UiaClientsAreListening() callconv(.winapi) win32.BOOL;
pub extern "uiautomationcore" fn UiaRaiseAutomationEvent(provider: *IRawElementProviderSimple, event: EVENTID) callconv(.winapi) HRESULT;
pub extern "uiautomationcore" fn UiaRaiseStructureChangedEvent(provider: *IRawElementProviderSimple, change: i32, runtime_id: ?[*]i32, runtime_id_len: i32) callconv(.winapi) HRESULT;
pub extern "uiautomationcore" fn UiaDisconnectProvider(provider: *IRawElementProviderSimple) callconv(.winapi) HRESULT;
