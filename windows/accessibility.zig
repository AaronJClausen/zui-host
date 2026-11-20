const std = @import("std");
const zui = @import("zui");
const win32 = @import("win32.zig");
const uia = @import("uia.zig");

const GUID = win32.GUID;
const HRESULT = win32.HRESULT;

/// Where the bridge reports what an assistive technology asks for: the
/// host's inbox, so the request arrives in the next record.
pub const ActionSink = struct {
    context: *anyopaque,
    deliverFn: *const fn (*anyopaque, zui.ActionEvent) void,

    fn deliver(self: ActionSink, event: zui.ActionEvent) void {
        self.deliverFn(self.context, event);
    }
};

/// One window's UI Automation provider: a fragment root for the window,
/// and an element for each node of the last `Frame.semantics()` it was
/// handed.
///
/// The UI thread copies each list into the back of two snapshots and swaps
/// them under `lock`; UI Automation reads the front from whatever thread it
/// calls on, holding `lock` shared. Every buffer is allocated in `init`, and
/// the bridge must not move after it, since the elements point back to it.
pub const Bridge = struct {
    hwnd: ?win32.HWND = null,
    sink: ActionSink,
    lock: win32.SRWLOCK = .{},
    snapshots: [2]Snapshot = .{ .{}, .{} },
    /// Written only by `publish`, under `lock`.
    front: u1 = 0,
    elements_lock: win32.SRWLOCK = .{},
    elements: []Element = &.{},
    root: Root = .{},
    /// Only the window thread reads and writes these.
    announced: Announced = .{},
    /// The window thread handed UI Automation the root.
    answered: bool = false,

    const allocator = std.heap.page_allocator;

    const Announced = struct {
        structure: u64 = 0,
        focused_id: u64 = 0,
    };

    /// With no nodes of room, the bridge stays off and allocates nothing.
    pub fn init(self: *Bridge, capacity: zui.SemanticsCapacity, sink: ActionSink) !void {
        self.* = .{ .sink = sink };
        if (capacity.nodes == 0) return;
        errdefer self.deinit();
        for (&self.snapshots) |*snapshot| try snapshot.allocate(capacity);
        self.elements = try allocator.alloc(Element, capacity.nodes);
        for (self.elements) |*element| element.* = .{ .bridge = self };
    }

    pub fn deinit(self: *Bridge) void {
        for (&self.snapshots) |*snapshot| snapshot.free();
        allocator.free(self.elements);
        self.elements = &.{};
    }

    pub fn hasRoom(self: *const Bridge) bool {
        return self.elements.len != 0;
    }

    /// Copies what fits of `nodes` into the back snapshot and makes it the
    /// front. Runs on the UI thread, the only one that writes snapshots.
    pub fn publish(self: *Bridge, nodes: []const zui.SemanticNode, pixels_per_unit: f32) zui.SemanticsDropped {
        var dropped: zui.SemanticsDropped = .{};
        const back = &self.snapshots[self.front ^ 1];
        const kept = @min(nodes.len, back.nodes.len);
        dropped.nodes = @intCast(nodes.len - kept);
        for (nodes[kept..]) |unkept| dropped.text_bytes +|= @intCast(unkept.label.len + valueText(unkept.value).len);
        if (!self.hasRoom()) return dropped;

        back.clear(pixels_per_unit);
        var structure: std.hash.Wyhash = .init(0);
        for (nodes[0..kept], 0..) |source, position| {
            const index: u32 = @intCast(position);
            const parent: u32 = if (source.parent) |enclosing| if (enclosing < index) enclosing else no_node else no_node;
            back.nodes[index] = .{
                .id = source.id,
                .parent = parent,
                .role = source.role,
                .state = source.state,
                .actions = source.actions,
                .bounds = source.bounds,
                .label = back.keepText(source.label, &dropped),
                .value = switch (source.value) {
                    .none => .none,
                    .text => |content| .{ .text = back.keepText(content, &dropped) },
                    .range => |range| .{ .range = range },
                },
            };
            back.link(index);
            back.insertIndex(source.id, index);
            if (source.state.focused and back.focused == no_node) back.focused = index;
            structure.update(std.mem.asBytes(&source.id));
            structure.update(std.mem.asBytes(&parent));
        }
        back.count = @intCast(kept);
        back.structure = structure.final();

        win32.AcquireSRWLockExclusive(&self.lock);
        self.front ^= 1;
        win32.ReleaseSRWLockExclusive(&self.lock);
        return dropped;
    }

    fn valueText(value: zui.SemanticValue) []const u8 {
        return switch (value) {
            .text => |content| content,
            else => "",
        };
    }

    /// The provider for `WM_GETOBJECT`, or null to leave the message to
    /// Windows: for a window opened without room, or for an object other
    /// than UI Automation's root.
    pub fn answerGetObject(self: *Bridge, hwnd: win32.HWND, wparam: win32.WPARAM, lparam: win32.LPARAM) ?win32.LRESULT {
        if (!self.hasRoom()) return null;
        if (@as(i32, @truncate(lparam)) != uia.UiaRootObjectId) return null;
        self.hwnd = hwnd;
        self.answered = true;
        return uia.UiaReturnRawElementProvider(hwnd, wparam, lparam, &self.root.simple);
    }

    /// Raises what changed since the last call, while a client listens:
    /// the focus, when the window has it, and the tree's shape. Runs on the
    /// window thread, so the UI thread never waits on a client.
    pub fn announceChanges(self: *Bridge) void {
        if (!self.answered or uia.UiaClientsAreListening() == 0) return;
        const snapshot = self.readFront();
        const structure = snapshot.structure;
        const focused_id: u64 = if (snapshot.focused == no_node) 0 else snapshot.nodes[snapshot.focused].id;
        self.doneReading();

        if (structure != self.announced.structure) {
            self.announced.structure = structure;
            _ = uia.UiaRaiseStructureChangedEvent(&self.root.simple, uia.StructureChangeType_ChildrenInvalidated, null, 0);
        }
        if (focused_id != self.announced.focused_id) {
            self.announced.focused_id = focused_id;
            if (focused_id != 0 and win32.GetFocus() == self.hwnd) if (self.elementFor(focused_id)) |element| {
                _ = uia.UiaRaiseAutomationEvent(&element.simple, uia.UIA_AutomationFocusChangedEventId);
                _ = element.release();
            };
        }
    }

    /// Tells UI Automation the window is going, so clients drop what they
    /// hold before the bridge's memory does. Runs on the window thread, at
    /// `WM_DESTROY`.
    pub fn disconnect(self: *Bridge, hwnd: win32.HWND) void {
        if (!self.answered) return;
        self.answered = false;
        _ = uia.UiaReturnRawElementProvider(hwnd, 0, 0, null);
        _ = uia.UiaDisconnectProvider(&self.root.simple);
        for (self.elements) |*element| {
            if (element.references.load(.acquire) != 0) _ = uia.UiaDisconnectProvider(&element.simple);
        }
    }

    fn readFront(self: *Bridge) *const Snapshot {
        win32.AcquireSRWLockShared(&self.lock);
        return &self.snapshots[self.front];
    }

    fn doneReading(self: *Bridge) void {
        win32.ReleaseSRWLockShared(&self.lock);
    }

    /// The element for `id`, with a reference taken for the caller: the one
    /// a client already holds, so a node keeps its identity from frame to
    /// frame, or a free one. Null when every element is held.
    fn elementFor(self: *Bridge, id: u64) ?*Element {
        win32.AcquireSRWLockExclusive(&self.elements_lock);
        defer win32.ReleaseSRWLockExclusive(&self.elements_lock);
        var free: ?*Element = null;
        for (self.elements) |*element| {
            const references = element.references.load(.acquire);
            if (references != 0 and element.id == id) {
                _ = element.references.fetchAdd(1, .acq_rel);
                return element;
            }
            if (references == 0 and free == null) free = element;
        }
        const element = free orelse return null;
        element.id = id;
        element.references.store(1, .release);
        return element;
    }

    fn clientOrigin(self: *const Bridge) [2]f64 {
        var origin: win32.POINT = .{};
        if (self.hwnd) |hwnd| _ = win32.ClientToScreen(hwnd, &origin);
        return .{ @floatFromInt(origin.x), @floatFromInt(origin.y) };
    }

    /// The fragment for node `index` of `snapshot`, or for the root when it
    /// has no node.
    fn fragmentOf(self: *Bridge, snapshot: *const Snapshot, index: u32, found: *?*uia.IRawElementProviderFragment) HRESULT {
        if (index == no_node) {
            found.* = null;
            return win32.S_OK;
        }
        const element = self.elementFor(snapshot.nodes[index].id) orelse return win32.E_OUTOFMEMORY;
        found.* = &element.fragment;
        return win32.S_OK;
    }
};

const no_node = std.math.maxInt(u32);

const TextSpan = struct {
    start: u32 = 0,
    len: u32 = 0,
};

const Node = struct {
    id: u64,
    parent: u32,
    first_child: u32 = no_node,
    last_child: u32 = no_node,
    previous_sibling: u32 = no_node,
    next_sibling: u32 = no_node,
    role: zui.SemanticRole,
    state: zui.SemanticState,
    actions: zui.Actions,
    bounds: zui.Rect,
    label: TextSpan,
    value: Value,

    const Value = union(enum) {
        none,
        text: TextSpan,
        range: zui.SemanticRange,
    };
};

const Snapshot = struct {
    nodes: []Node = &.{},
    count: u32 = 0,
    text: []u8 = &.{},
    text_len: u32 = 0,
    /// Open addressing from a node's id to its index plus one; 0 is empty.
    index_slots: []u32 = &.{},
    first_root: u32 = no_node,
    last_root: u32 = no_node,
    focused: u32 = no_node,
    pixels_per_unit: f32 = 1,
    structure: u64 = 0,

    fn allocate(self: *Snapshot, capacity: zui.SemanticsCapacity) !void {
        self.nodes = try Bridge.allocator.alloc(Node, capacity.nodes);
        self.text = try Bridge.allocator.alloc(u8, capacity.text_bytes);
        self.index_slots = try Bridge.allocator.alloc(u32, try std.math.ceilPowerOfTwo(usize, @as(usize, capacity.nodes) * 2));
        @memset(self.index_slots, 0);
    }

    fn free(self: *Snapshot) void {
        Bridge.allocator.free(self.nodes);
        Bridge.allocator.free(self.text);
        Bridge.allocator.free(self.index_slots);
        self.* = .{};
    }

    fn clear(self: *Snapshot, pixels_per_unit: f32) void {
        @memset(self.index_slots, 0);
        self.count = 0;
        self.text_len = 0;
        self.first_root = no_node;
        self.last_root = no_node;
        self.focused = no_node;
        self.pixels_per_unit = pixels_per_unit;
    }

    /// Copies what fits of `content`, cut at a character boundary.
    fn keepText(self: *Snapshot, content: []const u8, dropped: *zui.SemanticsDropped) TextSpan {
        var kept = @min(content.len, self.text.len - self.text_len);
        if (kept < content.len) {
            while (kept > 0 and content[kept] & 0b1100_0000 == 0b1000_0000) kept -= 1;
            dropped.text_bytes +|= @intCast(content.len - kept);
        }
        const span: TextSpan = .{ .start = self.text_len, .len = @intCast(kept) };
        @memcpy(self.text[self.text_len..][0..kept], content[0..kept]);
        self.text_len += @intCast(kept);
        return span;
    }

    fn textOf(self: *const Snapshot, span: TextSpan) []const u8 {
        return self.text[span.start..][0..span.len];
    }

    /// Appends node `index` to its parent's children, or to the roots.
    fn link(self: *Snapshot, index: u32) void {
        const node = &self.nodes[index];
        if (node.parent == no_node) {
            node.previous_sibling = self.last_root;
            if (self.last_root == no_node) self.first_root = index else self.nodes[self.last_root].next_sibling = index;
            self.last_root = index;
            return;
        }
        const parent = &self.nodes[node.parent];
        node.previous_sibling = parent.last_child;
        if (parent.last_child == no_node) parent.first_child = index else self.nodes[parent.last_child].next_sibling = index;
        parent.last_child = index;
    }

    fn slotOf(self: *const Snapshot, id: u64) usize {
        return @as(usize, @truncate((id *% 0x9E37_79B9_7F4A_7C15) >> 32)) & (self.index_slots.len - 1);
    }

    /// A second node with an id already listed keeps the first's.
    fn insertIndex(self: *Snapshot, id: u64, index: u32) void {
        var slot = self.slotOf(id);
        while (self.index_slots[slot] != 0) : (slot = (slot + 1) & (self.index_slots.len - 1)) {
            if (self.nodes[self.index_slots[slot] - 1].id == id) return;
        }
        self.index_slots[slot] = index + 1;
    }

    fn find(self: *const Snapshot, id: u64) ?u32 {
        if (self.index_slots.len == 0) return null;
        var slot = self.slotOf(id);
        while (self.index_slots[slot] != 0) : (slot = (slot + 1) & (self.index_slots.len - 1)) {
            const index = self.index_slots[slot] - 1;
            if (self.nodes[index].id == id) return index;
        }
        return null;
    }

    /// The last node, in tree order, whose bounds hold `point`: the
    /// innermost, or the one drawn over the others.
    fn nodeAt(self: *const Snapshot, point: [2]f32) u32 {
        var index = self.count;
        while (index > 0) {
            index -= 1;
            const bounds = self.nodes[index].bounds;
            if (point[0] >= bounds.x and point[0] < bounds.x + bounds.width and point[1] >= bounds.y and point[1] < bounds.y + bounds.height) return index;
        }
        return no_node;
    }
};

fn sameGuid(a: *const GUID, b: GUID) bool {
    return std.meta.eql(a.*, b);
}

fn boolean(value: bool) win32.VARIANT {
    return .{ .vt = win32.VT_BOOL, .value = .{ .boolean = if (value) win32.VARIANT_TRUE else win32.VARIANT_FALSE } };
}

fn integer(value: i32) win32.VARIANT {
    return .{ .vt = win32.VT_I4, .value = .{ .int = value } };
}

/// A `VT_BSTR` holding `utf8`, which OLE allocates for the caller to free.
fn string(utf8: []const u8) error{OutOfMemory}!win32.VARIANT {
    const units = std.unicode.calcUtf16LeLen(utf8) catch 0;
    const allocated = win32.SysAllocStringLen(null, @intCast(units)) orelse return error.OutOfMemory;
    if (units != 0) _ = std.unicode.utf8ToUtf16Le(allocated[0..units], utf8) catch unreachable;
    return .{ .vt = win32.VT_BSTR, .value = .{ .string = allocated } };
}

fn controlType(role: zui.SemanticRole) uia.CONTROLTYPEID {
    return switch (role) {
        .group => uia.UIA_GroupControlTypeId,
        .button, .toggle => uia.UIA_ButtonControlTypeId,
        .link => uia.UIA_HyperlinkControlTypeId,
        .checkbox => uia.UIA_CheckBoxControlTypeId,
        .radio => uia.UIA_RadioButtonControlTypeId,
        .slider => uia.UIA_SliderControlTypeId,
        .progress_bar => uia.UIA_ProgressBarControlTypeId,
        .text_field => uia.UIA_EditControlTypeId,
        .combo_box => uia.UIA_ComboBoxControlTypeId,
        .list_box => uia.UIA_ListControlTypeId,
        .option => uia.UIA_ListItemControlTypeId,
        .label, .heading => uia.UIA_TextControlTypeId,
        .image => uia.UIA_ImageControlTypeId,
        .dialog, .scroll_area => uia.UIA_PaneControlTypeId,
    };
}

/// The `IUnknown` methods of `Object`'s interface in its field `field`,
/// each passed on to `Object`'s own.
fn UnknownOf(comptime Object: type, comptime Interface: type, comptime field: []const u8) type {
    return struct {
        fn object(self: *Interface) *Object {
            return @fieldParentPtr(field, self);
        }

        fn queryInterface(self: *Interface, iid: *const GUID, found: *?*anyopaque) callconv(.winapi) HRESULT {
            return object(self).queryInterface(iid, found);
        }

        fn addRef(self: *Interface) callconv(.winapi) u32 {
            return object(self).addRef();
        }

        fn release(self: *Interface) callconv(.winapi) u32 {
            return object(self).release();
        }

        const methods: win32.IUnknownMethods(Interface) = .{ .QueryInterface = queryInterface, .AddRef = addRef, .Release = release };
    };
}

/// One node, found by its id in the front snapshot on every call, so it
/// reads as the latest frame declared it, and as gone once no frame does.
const Element = struct {
    simple: uia.IRawElementProviderSimple = .{ .vtable = &simple_vtable },
    fragment: uia.IRawElementProviderFragment = .{ .vtable = &fragment_vtable },
    invoke: uia.IInvokeProvider = .{ .vtable = &invoke_vtable },
    references: std.atomic.Value(u32) = .init(0),
    id: u64 = 0,
    bridge: *Bridge,

    const Simple = UnknownOf(Element, uia.IRawElementProviderSimple, "simple");
    const Fragment = UnknownOf(Element, uia.IRawElementProviderFragment, "fragment");
    const Invoke = UnknownOf(Element, uia.IInvokeProvider, "invoke");

    const simple_vtable: uia.IRawElementProviderSimple.VTable = .{
        .unknown = Simple.methods,
        .get_ProviderOptions = providerOptions,
        .GetPatternProvider = patternProvider,
        .GetPropertyValue = propertyValue,
        .get_HostRawElementProvider = hostProvider,
    };
    const fragment_vtable: uia.IRawElementProviderFragment.VTable = .{
        .unknown = Fragment.methods,
        .Navigate = navigate,
        .GetRuntimeId = runtimeId,
        .get_BoundingRectangle = boundingRectangle,
        .GetEmbeddedFragmentRoots = noEmbeddedRoots,
        .SetFocus = setFocus,
        .get_FragmentRoot = fragmentRoot,
    };
    const invoke_vtable: uia.IInvokeProvider.VTable = .{
        .unknown = Invoke.methods,
        .Invoke = invokeNode,
    };

    fn queryInterface(self: *Element, iid: *const GUID, found: *?*anyopaque) HRESULT {
        found.* = if (sameGuid(iid, win32.IID_IUnknown) or sameGuid(iid, uia.IID_IRawElementProviderSimple))
            &self.simple
        else if (sameGuid(iid, uia.IID_IRawElementProviderFragment))
            &self.fragment
        else if (sameGuid(iid, uia.IID_IInvokeProvider))
            &self.invoke
        else
            return noInterface(found);
        _ = self.addRef();
        return win32.S_OK;
    }

    fn addRef(self: *Element) u32 {
        return self.references.fetchAdd(1, .acq_rel) + 1;
    }

    fn release(self: *Element) u32 {
        return self.references.fetchSub(1, .acq_rel) - 1;
    }

    /// Holds the bridge's lock shared until `doneReading`; null when the
    /// node is gone.
    fn read(self: *Element) ?struct { snapshot: *const Snapshot, index: u32 } {
        const snapshot = self.bridge.readFront();
        const index = snapshot.find(self.id) orelse {
            self.bridge.doneReading();
            return null;
        };
        return .{ .snapshot = snapshot, .index = index };
    }

    fn providerOptions(_: *uia.IRawElementProviderSimple, options: *i32) callconv(.winapi) HRESULT {
        options.* = uia.ProviderOptions_ServerSideProvider;
        return win32.S_OK;
    }

    fn patternProvider(simple: *uia.IRawElementProviderSimple, pattern: uia.PATTERNID, found: *?*anyopaque) callconv(.winapi) HRESULT {
        const self = Simple.object(simple);
        found.* = null;
        const reading = self.read() orelse return uia.UIA_E_ELEMENTNOTAVAILABLE;
        const actions = reading.snapshot.nodes[reading.index].actions;
        self.bridge.doneReading();
        if (pattern == uia.UIA_InvokePatternId and actions.contains(.invoke)) {
            found.* = &self.invoke;
            _ = self.addRef();
        }
        return win32.S_OK;
    }

    fn propertyValue(simple: *uia.IRawElementProviderSimple, property: uia.PROPERTYID, value: *win32.VARIANT) callconv(.winapi) HRESULT {
        const self = Simple.object(simple);
        value.* = .{};
        const reading = self.read() orelse return uia.UIA_E_ELEMENTNOTAVAILABLE;
        defer self.bridge.doneReading();
        const node = &reading.snapshot.nodes[reading.index];
        value.* = switch (property) {
            uia.UIA_ControlTypePropertyId => integer(controlType(node.role)),
            uia.UIA_NamePropertyId => string(reading.snapshot.textOf(node.label)) catch return win32.E_OUTOFMEMORY,
            uia.UIA_AutomationIdPropertyId => automationId: {
                var digits: [16]u8 = undefined;
                break :automationId string(std.fmt.bufPrint(&digits, "{x:0>16}", .{node.id}) catch unreachable) catch return win32.E_OUTOFMEMORY;
            },
            uia.UIA_FrameworkIdPropertyId => string("zui") catch return win32.E_OUTOFMEMORY,
            uia.UIA_IsEnabledPropertyId => boolean(!node.state.disabled),
            uia.UIA_IsKeyboardFocusablePropertyId => boolean(node.actions.contains(.focus)),
            uia.UIA_HasKeyboardFocusPropertyId => boolean(node.state.focused),
            uia.UIA_IsDialogPropertyId => boolean(node.role == .dialog),
            else => .{},
        };
        return win32.S_OK;
    }

    fn hostProvider(_: *uia.IRawElementProviderSimple, found: *?*uia.IRawElementProviderSimple) callconv(.winapi) HRESULT {
        found.* = null;
        return win32.S_OK;
    }

    fn navigate(fragment: *uia.IRawElementProviderFragment, direction: uia.NavigateDirection, found: *?*uia.IRawElementProviderFragment) callconv(.winapi) HRESULT {
        const self = Fragment.object(fragment);
        found.* = null;
        const reading = self.read() orelse return uia.UIA_E_ELEMENTNOTAVAILABLE;
        defer self.bridge.doneReading();
        const node = &reading.snapshot.nodes[reading.index];
        const target = switch (direction) {
            .parent => {
                if (node.parent == no_node) {
                    found.* = &self.bridge.root.fragment;
                    _ = self.bridge.root.addRef();
                    return win32.S_OK;
                }
                return self.bridge.fragmentOf(reading.snapshot, node.parent, found);
            },
            .next_sibling => node.next_sibling,
            .previous_sibling => node.previous_sibling,
            .first_child => node.first_child,
            .last_child => node.last_child,
            _ => return win32.E_INVALIDARG,
        };
        return self.bridge.fragmentOf(reading.snapshot, target, found);
    }

    /// `[UiaAppendRuntimeId, low, high]`, so the whole 64-bit id
    /// round-trips.
    fn runtimeId(fragment: *uia.IRawElementProviderFragment, found: *?*win32.SAFEARRAY) callconv(.winapi) HRESULT {
        const self = Fragment.object(fragment);
        found.* = null;
        const array = win32.SafeArrayCreateVector(win32.VT_I4, 0, 3) orelse return win32.E_OUTOFMEMORY;
        var data: ?*anyopaque = null;
        if (!win32.succeeded(win32.SafeArrayAccessData(array, &data))) {
            _ = win32.SafeArrayDestroy(array);
            return win32.E_FAIL;
        }
        const parts: *[3]i32 = @ptrCast(@alignCast(data.?));
        parts.* = .{ uia.UiaAppendRuntimeId, @bitCast(@as(u32, @truncate(self.id))), @bitCast(@as(u32, @truncate(self.id >> 32))) };
        _ = win32.SafeArrayUnaccessData(array);
        found.* = array;
        return win32.S_OK;
    }

    fn boundingRectangle(fragment: *uia.IRawElementProviderFragment, bounds: *uia.UiaRect) callconv(.winapi) HRESULT {
        const self = Fragment.object(fragment);
        bounds.* = .{};
        const reading = self.read() orelse return uia.UIA_E_ELEMENTNOTAVAILABLE;
        const node_bounds = reading.snapshot.nodes[reading.index].bounds;
        const scale: f64 = reading.snapshot.pixels_per_unit;
        self.bridge.doneReading();
        const origin = self.bridge.clientOrigin();
        bounds.* = .{
            .left = origin[0] + node_bounds.x * scale,
            .top = origin[1] + node_bounds.y * scale,
            .width = node_bounds.width * scale,
            .height = node_bounds.height * scale,
        };
        return win32.S_OK;
    }

    fn setFocus(fragment: *uia.IRawElementProviderFragment) callconv(.winapi) HRESULT {
        return Fragment.object(fragment).request(.focus, .focus);
    }

    fn fragmentRoot(fragment: *uia.IRawElementProviderFragment, found: *?*uia.IRawElementProviderFragmentRoot) callconv(.winapi) HRESULT {
        const root = &Fragment.object(fragment).bridge.root;
        found.* = &root.fragment_root;
        _ = root.addRef();
        return win32.S_OK;
    }

    fn invokeNode(invoke: *uia.IInvokeProvider) callconv(.winapi) HRESULT {
        return Invoke.object(invoke).request(.invoke, .invoke);
    }

    /// Delivers `action` when the node takes `needed`, after letting go of
    /// the lock, since the host's inbox has a lock of its own.
    fn request(self: *Element, comptime needed: zui.ActionKind, action: zui.Action) HRESULT {
        const reading = self.read() orelse return uia.UIA_E_ELEMENTNOTAVAILABLE;
        const node = &reading.snapshot.nodes[reading.index];
        const takes = !node.state.disabled and node.actions.contains(needed);
        self.bridge.doneReading();
        if (!takes) return uia.UIA_E_ELEMENTNOTENABLED;
        self.bridge.sink.deliver(.{ .target = self.id, .action = action });
        return win32.S_OK;
    }
};

/// The window's fragment root: Windows' own provider for the window names
/// it and places it, and its children are the nodes with no node around
/// them. It lives as long as the bridge, so its count only tracks holders.
const Root = struct {
    simple: uia.IRawElementProviderSimple = .{ .vtable = &simple_vtable },
    fragment: uia.IRawElementProviderFragment = .{ .vtable = &fragment_vtable },
    fragment_root: uia.IRawElementProviderFragmentRoot = .{ .vtable = &fragment_root_vtable },
    references: std.atomic.Value(u32) = .init(0),

    const Simple = UnknownOf(Root, uia.IRawElementProviderSimple, "simple");
    const Fragment = UnknownOf(Root, uia.IRawElementProviderFragment, "fragment");
    const FragmentRoot = UnknownOf(Root, uia.IRawElementProviderFragmentRoot, "fragment_root");

    const simple_vtable: uia.IRawElementProviderSimple.VTable = .{
        .unknown = Simple.methods,
        .get_ProviderOptions = Element.providerOptions,
        .GetPatternProvider = noPattern,
        .GetPropertyValue = noProperty,
        .get_HostRawElementProvider = hostProvider,
    };
    const fragment_vtable: uia.IRawElementProviderFragment.VTable = .{
        .unknown = Fragment.methods,
        .Navigate = navigate,
        .GetRuntimeId = noRuntimeId,
        .get_BoundingRectangle = noBounds,
        .GetEmbeddedFragmentRoots = noEmbeddedRoots,
        .SetFocus = noFocus,
        .get_FragmentRoot = itself,
    };
    const fragment_root_vtable: uia.IRawElementProviderFragmentRoot.VTable = .{
        .unknown = FragmentRoot.methods,
        .ElementProviderFromPoint = elementAt,
        .GetFocus = focusedElement,
    };

    fn bridge(self: *Root) *Bridge {
        return @fieldParentPtr("root", self);
    }

    fn queryInterface(self: *Root, iid: *const GUID, found: *?*anyopaque) HRESULT {
        found.* = if (sameGuid(iid, win32.IID_IUnknown) or sameGuid(iid, uia.IID_IRawElementProviderSimple))
            &self.simple
        else if (sameGuid(iid, uia.IID_IRawElementProviderFragment))
            &self.fragment
        else if (sameGuid(iid, uia.IID_IRawElementProviderFragmentRoot))
            &self.fragment_root
        else
            return noInterface(found);
        _ = self.addRef();
        return win32.S_OK;
    }

    fn addRef(self: *Root) u32 {
        return self.references.fetchAdd(1, .acq_rel) + 1;
    }

    fn release(self: *Root) u32 {
        return self.references.fetchSub(1, .acq_rel) - 1;
    }

    fn noPattern(_: *uia.IRawElementProviderSimple, _: uia.PATTERNID, found: *?*anyopaque) callconv(.winapi) HRESULT {
        found.* = null;
        return win32.S_OK;
    }

    fn noProperty(_: *uia.IRawElementProviderSimple, _: uia.PROPERTYID, value: *win32.VARIANT) callconv(.winapi) HRESULT {
        value.* = .{};
        return win32.S_OK;
    }

    fn hostProvider(simple: *uia.IRawElementProviderSimple, found: *?*uia.IRawElementProviderSimple) callconv(.winapi) HRESULT {
        found.* = null;
        const hwnd = Simple.object(simple).bridge().hwnd orelse return uia.UIA_E_ELEMENTNOTAVAILABLE;
        return uia.UiaHostProviderFromHwnd(hwnd, found);
    }

    fn navigate(fragment: *uia.IRawElementProviderFragment, direction: uia.NavigateDirection, found: *?*uia.IRawElementProviderFragment) callconv(.winapi) HRESULT {
        const owner = Fragment.object(fragment).bridge();
        found.* = null;
        const snapshot = owner.readFront();
        defer owner.doneReading();
        return switch (direction) {
            .first_child => owner.fragmentOf(snapshot, snapshot.first_root, found),
            .last_child => owner.fragmentOf(snapshot, snapshot.last_root, found),
            else => win32.S_OK,
        };
    }

    fn noRuntimeId(_: *uia.IRawElementProviderFragment, found: *?*win32.SAFEARRAY) callconv(.winapi) HRESULT {
        found.* = null;
        return win32.S_OK;
    }

    fn noBounds(_: *uia.IRawElementProviderFragment, bounds: *uia.UiaRect) callconv(.winapi) HRESULT {
        bounds.* = .{};
        return win32.S_OK;
    }

    fn noFocus(_: *uia.IRawElementProviderFragment) callconv(.winapi) HRESULT {
        return win32.S_OK;
    }

    fn itself(fragment: *uia.IRawElementProviderFragment, found: *?*uia.IRawElementProviderFragmentRoot) callconv(.winapi) HRESULT {
        const self = Fragment.object(fragment);
        found.* = &self.fragment_root;
        _ = self.addRef();
        return win32.S_OK;
    }

    fn elementAt(fragment_root: *uia.IRawElementProviderFragmentRoot, x: f64, y: f64, found: *?*uia.IRawElementProviderFragment) callconv(.winapi) HRESULT {
        const owner = FragmentRoot.object(fragment_root).bridge();
        const origin = owner.clientOrigin();
        const snapshot = owner.readFront();
        defer owner.doneReading();
        const scale: f64 = snapshot.pixels_per_unit;
        const point: [2]f32 = .{ @floatCast((x - origin[0]) / scale), @floatCast((y - origin[1]) / scale) };
        return owner.fragmentOf(snapshot, snapshot.nodeAt(point), found);
    }

    fn focusedElement(fragment_root: *uia.IRawElementProviderFragmentRoot, found: *?*uia.IRawElementProviderFragment) callconv(.winapi) HRESULT {
        const owner = FragmentRoot.object(fragment_root).bridge();
        const snapshot = owner.readFront();
        defer owner.doneReading();
        return owner.fragmentOf(snapshot, snapshot.focused, found);
    }
};

fn noEmbeddedRoots(_: *uia.IRawElementProviderFragment, found: *?*win32.SAFEARRAY) callconv(.winapi) HRESULT {
    found.* = null;
    return win32.S_OK;
}

fn noInterface(found: *?*anyopaque) HRESULT {
    found.* = null;
    return win32.E_NOINTERFACE;
}

test "a snapshot links each node to its parent and siblings, and finds it by id" {
    var bridge: Bridge = undefined;
    try bridge.init(.{ .nodes = 4, .text_bytes = 32 }, undefined);
    defer bridge.deinit();
    const group: zui.SemanticNode = .{ .id = 1, .parent = null, .role = .group, .label = "Tools", .value = .none, .bounds = .{}, .state = .{}, .actions = .initEmpty() };
    var save = group;
    save.id = 2;
    save.parent = 0;
    save.role = .button;
    save.label = "Save";
    var open = save;
    open.id = 3;
    open.label = "Open";
    var status = group;
    status.id = 4;
    status.label = "Ready";
    try std.testing.expectEqual(zui.SemanticsDropped{}, bridge.publish(&.{ group, save, open, status }, 1));

    const snapshot = bridge.readFront();
    defer bridge.doneReading();
    try std.testing.expectEqual(@as(?u32, 2), snapshot.find(3));
    try std.testing.expectEqual(@as(?u32, null), snapshot.find(5));
    try std.testing.expectEqual(@as(u32, 0), snapshot.first_root);
    try std.testing.expectEqual(@as(u32, 3), snapshot.last_root);
    try std.testing.expectEqual(@as(u32, 1), snapshot.nodes[0].first_child);
    try std.testing.expectEqual(@as(u32, 2), snapshot.nodes[1].next_sibling);
    try std.testing.expectEqual(@as(u32, 1), snapshot.nodes[2].previous_sibling);
    try std.testing.expectEqual(@as(u32, 3), snapshot.nodes[0].next_sibling);
    try std.testing.expectEqualStrings("Open", snapshot.textOf(snapshot.nodes[2].label));
}

test "a list longer than the room keeps its start, and text that does not fit is cut at a character" {
    var bridge: Bridge = undefined;
    try bridge.init(.{ .nodes = 2, .text_bytes = 6 }, undefined);
    defer bridge.deinit();
    const node: zui.SemanticNode = .{ .id = 1, .parent = null, .role = .button, .label = "Save", .value = .none, .bounds = .{}, .state = .{}, .actions = .initEmpty() };
    var accented = node;
    accented.id = 2;
    accented.label = "Éé";
    var unkept = node;
    unkept.id = 3;
    unkept.label = "Quit";
    try std.testing.expectEqual(zui.SemanticsDropped{ .nodes = 1, .text_bytes = 2 + 4 }, bridge.publish(&.{ node, accented, unkept }, 1));
    const snapshot = bridge.readFront();
    defer bridge.doneReading();
    try std.testing.expectEqual(@as(u32, 2), snapshot.count);
    try std.testing.expectEqualStrings("É", snapshot.textOf(snapshot.nodes[1].label));
}

test "a bridge without room keeps nothing and allocates nothing" {
    var bridge: Bridge = undefined;
    try bridge.init(.{}, undefined);
    defer bridge.deinit();
    const node: zui.SemanticNode = .{ .id = 1, .parent = null, .role = .button, .label = "Save", .value = .none, .bounds = .{}, .state = .{}, .actions = .initEmpty() };
    try std.testing.expect(!bridge.hasRoom());
    try std.testing.expectEqual(zui.SemanticsDropped{ .nodes = 1, .text_bytes = 4 }, bridge.publish(&.{node}, 1));
}
