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
    /// Layout units a small scroll moves, as a notch of the wheel does.
    scroll_step: f32,
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

    /// What listening clients were last told, to raise only what changed.
    const Announced = struct {
        structure: u64 = 0,
        focused_id: u64 = 0,
        summaries: [2]Summaries = .{ .{}, .{} },
        current: u1 = 0,
    };

    /// With no nodes of room, the bridge stays off and allocates nothing.
    pub fn init(self: *Bridge, capacity: zui.SemanticsCapacity, sink: ActionSink, scroll_step: f32) !void {
        self.* = .{ .sink = sink, .scroll_step = scroll_step };
        if (capacity.nodes == 0) return;
        errdefer self.deinit();
        for (&self.snapshots) |*snapshot| try snapshot.allocate(capacity);
        for (&self.announced.summaries) |*summaries| try summaries.allocate(capacity.nodes);
        self.elements = try allocator.alloc(Element, capacity.nodes);
        for (self.elements) |*element| element.* = .{ .bridge = self };
    }

    pub fn deinit(self: *Bridge) void {
        for (&self.snapshots) |*snapshot| snapshot.free();
        for (&self.announced.summaries) |*summaries| summaries.free();
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
                .level = source.level,
                .scroll = source.scroll,
                .label = back.keepText(source.label, &dropped),
                .value = switch (source.value) {
                    .none => .none,
                    .text => |content| .{ .text = back.keepText(content, &dropped) },
                    .range => |range| .{ .range = range },
                },
            };
            back.link(index);
            back.index.insert(source.id, index);
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
    /// the focus, when the window has it, the tree's shape, and each
    /// node's name, value and state. Runs on the window thread, so the UI
    /// thread never waits on a client.
    pub fn announceChanges(self: *Bridge) void {
        if (!self.answered or uia.UiaClientsAreListening() == 0) return;
        const announced = &self.announced;
        const previous = &announced.summaries[announced.current];
        const next = &announced.summaries[announced.current ^ 1];
        const snapshot = self.readFront();
        const structure = snapshot.structure;
        const focused_id: u64 = if (snapshot.focused == no_node) 0 else snapshot.nodes[snapshot.focused].id;
        next.fill(snapshot);
        self.doneReading();
        announced.current ^= 1;

        if (structure != announced.structure) {
            announced.structure = structure;
            _ = uia.UiaRaiseStructureChangedEvent(&self.root.simple, uia.StructureChangeType_ChildrenInvalidated, null, 0);
        }
        if (focused_id != announced.focused_id) {
            announced.focused_id = focused_id;
            if (focused_id != 0 and win32.GetFocus() == self.hwnd) if (self.elementFor(focused_id)) |element| {
                _ = uia.UiaRaiseAutomationEvent(&element.simple, uia.UIA_AutomationFocusChangedEventId);
                _ = element.release();
            };
        }
        for (next.items[0..next.count]) |now| {
            const before = previous.items[previous.index.find(now.id) orelse continue];
            if (!std.meta.eql(before, now)) self.raisePropertyChanges(before, now);
        }
    }

    fn raisePropertyChanges(self: *Bridge, before: Summary, now: Summary) void {
        const element = self.elementFor(now.id) orelse return;
        defer _ = element.release();
        if (before.label != now.label) self.raiseTextChange(element, uia.UIA_NamePropertyId, .label);
        if (before.value_text != now.value_text) self.raiseTextChange(element, uia.UIA_ValueValuePropertyId, .value);
        if (before.range_value_bits != now.range_value_bits) {
            raiseChange(element, uia.UIA_RangeValueValuePropertyId, .{ .vt = win32.VT_R8, .value = .{ .double = @bitCast(now.range_value_bits) } });
        }
        if (before.checked != now.checked) if (now.checked) |checked| {
            raiseChange(element, uia.UIA_ToggleToggleStatePropertyId, integer(@intFromEnum(toggleState(checked))));
        };
        if (before.expanded != now.expanded) if (now.expanded) |expanded| {
            raiseChange(element, uia.UIA_ExpandCollapseExpandCollapseStatePropertyId, integer(@intFromEnum(expandCollapseState(expanded))));
        };
        if (before.selected != now.selected) {
            raiseChange(element, uia.UIA_SelectionItemIsSelectedPropertyId, boolean(now.selected));
            if (now.selected) _ = uia.UiaRaiseAutomationEvent(&element.simple, uia.UIA_SelectionItem_ElementSelectedEventId);
        }
        if (before.disabled != now.disabled) raiseChange(element, uia.UIA_IsEnabledPropertyId, boolean(!now.disabled));
        if (before.scroll_offset_bits[0] != now.scroll_offset_bits[0]) {
            raiseChange(element, uia.UIA_ScrollHorizontalScrollPercentPropertyId, double(now.scroll_percent[0]));
        }
        if (before.scroll_offset_bits[1] != now.scroll_offset_bits[1]) {
            raiseChange(element, uia.UIA_ScrollVerticalScrollPercentPropertyId, double(now.scroll_percent[1]));
        }
    }

    /// Reads the text again, since summaries keep only its hash: from the
    /// newest front, which is what a client would read.
    fn raiseTextChange(self: *Bridge, element: *Element, property: uia.PROPERTYID, which: enum { label, value }) void {
        const snapshot = self.readFront();
        const new_value: win32.VARIANT = if (snapshot.find(element.id)) |index| text: {
            const node = &snapshot.nodes[index];
            const span = switch (which) {
                .label => node.label,
                .value => if (node.value == .text) node.value.text else TextSpan{},
            };
            break :text string(snapshot.textOf(span)) catch .{};
        } else .{};
        self.doneReading();
        raiseChange(element, property, new_value);
    }

    /// The old value is left empty, as UI Automation allows: summaries
    /// keep only what tells a change.
    fn raiseChange(element: *Element, property: uia.PROPERTYID, new_value: win32.VARIANT) void {
        var raised = new_value;
        _ = uia.UiaRaiseAutomationPropertyChangedEvent(&element.simple, property, .{}, raised);
        _ = win32.VariantClear(&raised);
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

    /// The fragment for node `index` of `snapshot`, or null for no node.
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
    level: u8 = 0,
    scroll: ?zui.SemanticScroll = null,
    label: TextSpan,
    value: Value,

    const Value = union(enum) {
        none,
        text: TextSpan,
        range: zui.SemanticRange,
    };

    fn takes(self: *const Node, action: zui.ActionKind) bool {
        return !self.state.disabled and self.actions.contains(action);
    }

    /// A radio and an option are chosen, not toggled, even when they say
    /// whether they are checked.
    fn offersToggle(self: *const Node) bool {
        return self.state.checked != null and !self.offersSelectionItem();
    }

    fn offersSelectionItem(self: *const Node) bool {
        return self.role == .option or self.role == .radio;
    }

    /// Only when no other pattern stands for the click, so a client toggles
    /// a checkbox or opens a combo box by its own pattern; a slider or a
    /// text field takes a click to focus it, which is no command.
    fn offersInvoke(self: *const Node) bool {
        const clicks_for_another_pattern = switch (self.role) {
            .combo_box, .slider, .text_field, .progress_bar => true,
            else => false,
        };
        return self.actions.contains(.invoke) and !self.offersToggle() and !self.offersSelectionItem() and !clicks_for_another_pattern;
    }

    fn offersExpandCollapse(self: *const Node) bool {
        return self.state.expanded != null;
    }

    fn offersRangeValue(self: *const Node) bool {
        return self.value == .range;
    }

    fn offersValue(self: *const Node) bool {
        return self.value == .text;
    }

    fn offersSelection(self: *const Node) bool {
        return self.role == .list_box;
    }

    fn offersScroll(self: *const Node) bool {
        return self.scroll != null;
    }

    fn offersWindow(self: *const Node) bool {
        return self.role == .dialog;
    }

    /// The axis moves: it scrolls, and its content is larger than its view.
    fn scrollsAlong(self: *const Node, axis: usize) bool {
        const scroll = self.scroll orelse return false;
        return scroll.axes[axis] and scroll.content[axis] > scroll.viewport[axis];
    }

    /// How far along its content the view is on `axis`, from 0 to 100, or
    /// `UIA_ScrollPatternNoScroll`.
    fn scrollPercent(self: *const Node, axis: usize) f64 {
        if (!self.scrollsAlong(axis)) return uia.UIA_ScrollPatternNoScroll;
        const scroll = self.scroll.?;
        return std.math.clamp(scroll.offset[axis] / (scroll.content[axis] - scroll.viewport[axis]) * 100, 0, 100);
    }

    /// How much of its content the view shows on `axis`, from 0 to 100.
    fn scrollViewSize(self: *const Node, axis: usize) f64 {
        const scroll = self.scroll orelse return 100;
        if (scroll.content[axis] <= 0) return 100;
        return std.math.clamp(scroll.viewport[axis] / scroll.content[axis] * 100, 0, 100);
    }

    fn isExpanded(self: *const Node) bool {
        return self.state.expanded == true;
    }

    fn isCollapsed(self: *const Node) bool {
        return self.state.expanded == false;
    }

    fn isSelected(self: *const Node) bool {
        return self.state.selected;
    }
};

/// Open addressing from a node's id to its index.
const IdIndex = struct {
    slots: []Slot = &.{},

    const Slot = struct {
        id: u64 = 0,
        /// 0 is an empty slot.
        index_plus_one: u32 = 0,
    };

    fn allocate(self: *IdIndex, nodes: u32) !void {
        self.slots = try Bridge.allocator.alloc(Slot, try std.math.ceilPowerOfTwo(usize, @as(usize, nodes) * 2));
        self.clear();
    }

    fn free(self: *IdIndex) void {
        Bridge.allocator.free(self.slots);
        self.slots = &.{};
    }

    fn clear(self: *IdIndex) void {
        @memset(self.slots, .{});
    }

    fn slotOf(self: *const IdIndex, id: u64) usize {
        return @as(usize, @truncate((id *% 0x9E37_79B9_7F4A_7C15) >> 32)) & (self.slots.len - 1);
    }

    /// A second index for an id already listed keeps the first.
    fn insert(self: *IdIndex, id: u64, index: u32) void {
        var slot = self.slotOf(id);
        while (self.slots[slot].index_plus_one != 0) : (slot = (slot + 1) & (self.slots.len - 1)) {
            if (self.slots[slot].id == id) return;
        }
        self.slots[slot] = .{ .id = id, .index_plus_one = index + 1 };
    }

    fn find(self: *const IdIndex, id: u64) ?u32 {
        if (self.slots.len == 0) return null;
        var slot = self.slotOf(id);
        while (self.slots[slot].index_plus_one != 0) : (slot = (slot + 1) & (self.slots.len - 1)) {
            if (self.slots[slot].id == id) return self.slots[slot].index_plus_one - 1;
        }
        return null;
    }
};

const Snapshot = struct {
    nodes: []Node = &.{},
    count: u32 = 0,
    text: []u8 = &.{},
    text_len: u32 = 0,
    index: IdIndex = .{},
    first_root: u32 = no_node,
    last_root: u32 = no_node,
    focused: u32 = no_node,
    pixels_per_unit: f32 = 1,
    structure: u64 = 0,

    fn allocate(self: *Snapshot, capacity: zui.SemanticsCapacity) !void {
        self.nodes = try Bridge.allocator.alloc(Node, capacity.nodes);
        self.text = try Bridge.allocator.alloc(u8, capacity.text_bytes);
        try self.index.allocate(capacity.nodes);
    }

    fn free(self: *Snapshot) void {
        Bridge.allocator.free(self.nodes);
        Bridge.allocator.free(self.text);
        self.index.free();
        self.* = .{};
    }

    fn clear(self: *Snapshot, pixels_per_unit: f32) void {
        self.index.clear();
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

    fn find(self: *const Snapshot, id: u64) ?u32 {
        return self.index.find(id);
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

    fn isWithin(self: *const Snapshot, index: u32, ancestor: u32) bool {
        var enclosing = self.nodes[index].parent;
        while (enclosing != no_node) : (enclosing = self.nodes[enclosing].parent) {
            if (enclosing == ancestor) return true;
        }
        return false;
    }

    /// The nearest node around `index` with `role`, or `no_node`.
    fn enclosingWith(self: *const Snapshot, index: u32, role: zui.SemanticRole) u32 {
        var enclosing = self.nodes[index].parent;
        while (enclosing != no_node) : (enclosing = self.nodes[enclosing].parent) {
            if (self.nodes[enclosing].role == role) return enclosing;
        }
        return no_node;
    }
};

/// What a node shows a client, enough to tell that it changed.
const Summary = struct {
    id: u64,
    label: u64,
    value_text: u64,
    range_value_bits: u64,
    checked: ?bool,
    expanded: ?bool,
    selected: bool,
    disabled: bool,
    scroll_offset_bits: [2]u32,
    scroll_percent: [2]f64,
};

const Summaries = struct {
    items: []Summary = &.{},
    count: u32 = 0,
    index: IdIndex = .{},

    fn allocate(self: *Summaries, nodes: u32) !void {
        self.items = try Bridge.allocator.alloc(Summary, nodes);
        try self.index.allocate(nodes);
    }

    fn free(self: *Summaries) void {
        Bridge.allocator.free(self.items);
        self.index.free();
        self.* = .{};
    }

    fn fill(self: *Summaries, snapshot: *const Snapshot) void {
        self.index.clear();
        for (snapshot.nodes[0..snapshot.count], self.items[0..snapshot.count], 0..) |*node, *summary, index| {
            summary.* = .{
                .id = node.id,
                .label = std.hash.Wyhash.hash(0, snapshot.textOf(node.label)),
                .value_text = if (node.value == .text) std.hash.Wyhash.hash(0, snapshot.textOf(node.value.text)) else 0,
                .range_value_bits = if (node.value == .range) @bitCast(node.value.range.value) else 0,
                .checked = node.state.checked,
                .expanded = node.state.expanded,
                .selected = node.state.selected,
                .disabled = node.state.disabled,
                .scroll_offset_bits = if (node.scroll) |scroll| .{ @bitCast(scroll.offset[0]), @bitCast(scroll.offset[1]) } else .{ 0, 0 },
                .scroll_percent = .{ node.scrollPercent(0), node.scrollPercent(1) },
            };
            self.index.insert(node.id, @intCast(index));
        }
        self.count = snapshot.count;
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

fn double(value: f64) win32.VARIANT {
    return .{ .vt = win32.VT_R8, .value = .{ .double = value } };
}

fn headingLevel(node: *const Node) i32 {
    if (node.role != .heading or node.level == 0 or node.level > 9) return uia.HeadingLevel_None;
    return uia.HeadingLevel1 + node.level - 1;
}

/// Layout units a scroll request moves `axis` by: a wheel notch for a small
/// step, the view's size for a large one.
fn scrollDistance(amount: uia.ScrollAmount, scroll: zui.SemanticScroll, axis: usize, step: f32) ?f32 {
    return switch (amount) {
        .no_amount => 0,
        .small_increment => step,
        .small_decrement => -step,
        .large_increment => scroll.viewport[axis],
        .large_decrement => -scroll.viewport[axis],
        _ => null,
    };
}

/// A `VT_BSTR` holding `utf8`, which OLE allocates for the caller to free.
fn string(utf8: []const u8) error{OutOfMemory}!win32.VARIANT {
    return .{ .vt = win32.VT_BSTR, .value = .{ .string = try allocateString(utf8) } };
}

fn allocateString(utf8: []const u8) error{OutOfMemory}!win32.BSTR {
    const units = std.unicode.calcUtf16LeLen(utf8) catch 0;
    const allocated = win32.SysAllocStringLen(null, @intCast(units)) orelse return error.OutOfMemory;
    if (units != 0) _ = std.unicode.utf8ToUtf16Le(allocated[0..units], utf8) catch unreachable;
    return allocated;
}

fn winBool(value: bool) win32.BOOL {
    return @intFromBool(value);
}

fn toggleState(checked: ?bool) uia.ToggleState {
    const known = checked orelse return .indeterminate;
    return if (known) .on else .off;
}

fn expandCollapseState(expanded: ?bool) uia.ExpandCollapseState {
    const known = expanded orelse return .leaf_node;
    return if (known) .expanded else .collapsed;
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

/// The steps an `adjust` moves a range by to reach `target`: whole steps
/// when it has a step, and one toward it when it moves continuously.
fn stepsToward(range: zui.SemanticRange, target: f64) i32 {
    const distance = target - range.value;
    if (range.step <= 0) return if (distance > 0) 1 else if (distance < 0) -1 else 0;
    const steps = @round(distance / range.step);
    return @intFromFloat(std.math.clamp(steps, std.math.minInt(i32), std.math.maxInt(i32)));
}

/// What one small step moves a range by, when it moves continuously.
fn smallChange(range: zui.SemanticRange) f64 {
    return if (range.step > 0) range.step else (range.max - range.min) / 100;
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
    /// Its table goes on with `ShowContextMenu`, so it is also an
    /// `IRawElementProviderSimple2`.
    simple: uia.IRawElementProviderSimple = .{ .vtable = &simple_vtable.simple },
    fragment: uia.IRawElementProviderFragment = .{ .vtable = &fragment_vtable },
    invoke: uia.IInvokeProvider = .{ .vtable = &invoke_vtable },
    toggle: uia.IToggleProvider = .{ .vtable = &toggle_vtable },
    expand_collapse: uia.IExpandCollapseProvider = .{ .vtable = &expand_collapse_vtable },
    range_value: uia.IRangeValueProvider = .{ .vtable = &range_value_vtable },
    value: uia.IValueProvider = .{ .vtable = &value_vtable },
    selection_item: uia.ISelectionItemProvider = .{ .vtable = &selection_item_vtable },
    selection: uia.ISelectionProvider = .{ .vtable = &selection_vtable },
    scroll: uia.IScrollProvider = .{ .vtable = &scroll_vtable },
    window: uia.IWindowProvider = .{ .vtable = &window_vtable },
    references: std.atomic.Value(u32) = .init(0),
    id: u64 = 0,
    bridge: *Bridge,

    const Simple = UnknownOf(Element, uia.IRawElementProviderSimple, "simple");
    const Fragment = UnknownOf(Element, uia.IRawElementProviderFragment, "fragment");
    const Invoke = UnknownOf(Element, uia.IInvokeProvider, "invoke");
    const Toggle = UnknownOf(Element, uia.IToggleProvider, "toggle");
    const ExpandCollapse = UnknownOf(Element, uia.IExpandCollapseProvider, "expand_collapse");
    const RangeValue = UnknownOf(Element, uia.IRangeValueProvider, "range_value");
    const Value = UnknownOf(Element, uia.IValueProvider, "value");
    const SelectionItem = UnknownOf(Element, uia.ISelectionItemProvider, "selection_item");
    const Selection = UnknownOf(Element, uia.ISelectionProvider, "selection");
    const Scroll = UnknownOf(Element, uia.IScrollProvider, "scroll");
    const Window = UnknownOf(Element, uia.IWindowProvider, "window");

    const simple_vtable: uia.IRawElementProviderSimple2VTable = .{
        .simple = .{
            .unknown = Simple.methods,
            .get_ProviderOptions = providerOptions,
            .GetPatternProvider = patternProvider,
            .GetPropertyValue = propertyValue,
            .get_HostRawElementProvider = hostProvider,
        },
        .ShowContextMenu = showContextMenu,
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
    const toggle_vtable: uia.IToggleProvider.VTable = .{
        .unknown = Toggle.methods,
        .Toggle = toggleNode,
        .get_ToggleState = currentToggleState,
    };
    const expand_collapse_vtable: uia.IExpandCollapseProvider.VTable = .{
        .unknown = ExpandCollapse.methods,
        .Expand = expand,
        .Collapse = collapse,
        .get_ExpandCollapseState = currentExpandCollapseState,
    };
    const range_value_vtable: uia.IRangeValueProvider.VTable = .{
        .unknown = RangeValue.methods,
        .SetValue = setRangeValue,
        .get_Value = rangeValue,
        .get_IsReadOnly = rangeIsReadOnly,
        .get_Maximum = rangeMaximum,
        .get_Minimum = rangeMinimum,
        .get_LargeChange = rangeLargeChange,
        .get_SmallChange = rangeSmallChange,
    };
    const value_vtable: uia.IValueProvider.VTable = .{
        .unknown = Value.methods,
        .SetValue = setTextValue,
        .get_Value = textValue,
        .get_IsReadOnly = textIsReadOnly,
    };
    const selection_item_vtable: uia.ISelectionItemProvider.VTable = .{
        .unknown = SelectionItem.methods,
        .Select = select,
        .AddToSelection = select,
        .RemoveFromSelection = removeFromSelection,
        .get_IsSelected = isSelected,
        .get_SelectionContainer = selectionContainer,
    };
    const selection_vtable: uia.ISelectionProvider.VTable = .{
        .unknown = Selection.methods,
        .GetSelection = currentSelection,
        .get_CanSelectMultiple = selectsOne,
        .get_IsSelectionRequired = selectsOne,
    };
    const scroll_vtable: uia.IScrollProvider.VTable = .{
        .unknown = Scroll.methods,
        .Scroll = scrollBy,
        .SetScrollPercent = setScrollPercent,
        .get_HorizontalScrollPercent = scrollAnswer(.percent, 0),
        .get_VerticalScrollPercent = scrollAnswer(.percent, 1),
        .get_HorizontalViewSize = scrollAnswer(.view_size, 0),
        .get_VerticalViewSize = scrollAnswer(.view_size, 1),
        .get_HorizontallyScrollable = scrollsAlong(0),
        .get_VerticallyScrollable = scrollsAlong(1),
    };
    const window_vtable: uia.IWindowProvider.VTable = .{
        .unknown = Window.methods,
        .SetVisualState = keepVisualState,
        .Close = closeWindow,
        .WaitForInputIdle = alreadyIdle,
        .get_CanMaximize = windowAnswersNo,
        .get_CanMinimize = windowAnswersNo,
        .get_IsModal = windowAnswersNo,
        .get_WindowVisualState = normalVisualState,
        .get_WindowInteractionState = readyForInteraction,
        .get_IsTopmost = windowAnswersNo,
    };

    fn queryInterface(self: *Element, iid: *const GUID, found: *?*anyopaque) HRESULT {
        found.* = if (sameGuid(iid, win32.IID_IUnknown) or sameGuid(iid, uia.IID_IRawElementProviderSimple) or sameGuid(iid, uia.IID_IRawElementProviderSimple2))
            &self.simple
        else if (sameGuid(iid, uia.IID_IRawElementProviderFragment))
            &self.fragment
        else if (sameGuid(iid, uia.IID_IInvokeProvider))
            &self.invoke
        else if (sameGuid(iid, uia.IID_IToggleProvider))
            &self.toggle
        else if (sameGuid(iid, uia.IID_IExpandCollapseProvider))
            &self.expand_collapse
        else if (sameGuid(iid, uia.IID_IRangeValueProvider))
            &self.range_value
        else if (sameGuid(iid, uia.IID_IValueProvider))
            &self.value
        else if (sameGuid(iid, uia.IID_ISelectionItemProvider))
            &self.selection_item
        else if (sameGuid(iid, uia.IID_ISelectionProvider))
            &self.selection
        else if (sameGuid(iid, uia.IID_IScrollProvider))
            &self.scroll
        else if (sameGuid(iid, uia.IID_IWindowProvider))
            &self.window
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

    const Reading = struct {
        snapshot: *const Snapshot,
        index: u32,

        fn node(self: Reading) *const Node {
            return &self.snapshot.nodes[self.index];
        }
    };

    /// Holds the bridge's lock shared until `doneReading`; null when the
    /// node is gone.
    fn read(self: *Element) ?Reading {
        const snapshot = self.bridge.readFront();
        const index = snapshot.find(self.id) orelse {
            self.bridge.doneReading();
            return null;
        };
        return .{ .snapshot = snapshot, .index = index };
    }

    /// Copies what `answer` gives from the node into `result`, or fails
    /// when the node is gone.
    fn answerFromNode(self: *Element, comptime Result: type, result: *Result, comptime answer: fn (*const Node) Result) HRESULT {
        const reading = self.read() orelse return uia.UIA_E_ELEMENTNOTAVAILABLE;
        defer self.bridge.doneReading();
        result.* = answer(reading.node());
        return win32.S_OK;
    }

    /// Delivers `action` when the node takes `needed` and is not already as
    /// asked, after letting go of the lock, since the host's inbox has a
    /// lock of its own.
    fn request(self: *Element, comptime needed: zui.ActionKind, action: zui.Action, comptime already_done: ?fn (*const Node) bool) HRESULT {
        const reading = self.read() orelse return uia.UIA_E_ELEMENTNOTAVAILABLE;
        const node = reading.node();
        const takes = node.takes(needed);
        const done = if (already_done) |isDone| isDone(node) else false;
        self.bridge.doneReading();
        if (!takes) return uia.UIA_E_ELEMENTNOTENABLED;
        if (!done) self.bridge.sink.deliver(.{ .target = self.id, .action = action });
        return win32.S_OK;
    }

    fn providerOptions(_: *uia.IRawElementProviderSimple, options: *i32) callconv(.winapi) HRESULT {
        options.* = uia.ProviderOptions_ServerSideProvider;
        return win32.S_OK;
    }

    fn patternProvider(simple: *uia.IRawElementProviderSimple, pattern: uia.PATTERNID, found: *?*anyopaque) callconv(.winapi) HRESULT {
        const self = Simple.object(simple);
        found.* = null;
        const reading = self.read() orelse return uia.UIA_E_ELEMENTNOTAVAILABLE;
        const node = reading.node();
        const offered: ?*anyopaque = switch (pattern) {
            uia.UIA_InvokePatternId => if (node.offersInvoke()) &self.invoke else null,
            uia.UIA_TogglePatternId => if (node.offersToggle()) &self.toggle else null,
            uia.UIA_ExpandCollapsePatternId => if (node.offersExpandCollapse()) &self.expand_collapse else null,
            uia.UIA_RangeValuePatternId => if (node.offersRangeValue()) &self.range_value else null,
            uia.UIA_ValuePatternId => if (node.offersValue()) &self.value else null,
            uia.UIA_SelectionItemPatternId => if (node.offersSelectionItem()) &self.selection_item else null,
            uia.UIA_SelectionPatternId => if (node.offersSelection()) &self.selection else null,
            uia.UIA_ScrollPatternId => if (node.offersScroll()) &self.scroll else null,
            uia.UIA_WindowPatternId => if (node.offersWindow()) &self.window else null,
            else => null,
        };
        self.bridge.doneReading();
        if (offered != null) _ = self.addRef();
        found.* = offered;
        return win32.S_OK;
    }

    fn propertyValue(simple: *uia.IRawElementProviderSimple, property: uia.PROPERTYID, value: *win32.VARIANT) callconv(.winapi) HRESULT {
        const self = Simple.object(simple);
        value.* = .{};
        const reading = self.read() orelse return uia.UIA_E_ELEMENTNOTAVAILABLE;
        defer self.bridge.doneReading();
        const node = reading.node();
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
            uia.UIA_HeadingLevelPropertyId => integer(headingLevel(node)),
            else => .{},
        };
        return win32.S_OK;
    }

    fn showContextMenu(simple: *uia.IRawElementProviderSimple) callconv(.winapi) HRESULT {
        return Simple.object(simple).request(.show_menu, .show_menu, null);
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
        const node = reading.node();
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
        const node_bounds = reading.node().bounds;
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
        return Fragment.object(fragment).request(.focus, .focus, null);
    }

    fn fragmentRoot(fragment: *uia.IRawElementProviderFragment, found: *?*uia.IRawElementProviderFragmentRoot) callconv(.winapi) HRESULT {
        const root = &Fragment.object(fragment).bridge.root;
        found.* = &root.fragment_root;
        _ = root.addRef();
        return win32.S_OK;
    }

    fn invokeNode(invoke: *uia.IInvokeProvider) callconv(.winapi) HRESULT {
        return Invoke.object(invoke).request(.invoke, .invoke, null);
    }

    fn toggleNode(toggle: *uia.IToggleProvider) callconv(.winapi) HRESULT {
        return Toggle.object(toggle).request(.invoke, .invoke, null);
    }

    fn currentToggleState(toggle: *uia.IToggleProvider, state: *uia.ToggleState) callconv(.winapi) HRESULT {
        return Toggle.object(toggle).answerFromNode(uia.ToggleState, state, struct {
            fn answer(node: *const Node) uia.ToggleState {
                return toggleState(node.state.checked);
            }
        }.answer);
    }

    fn expand(expand_collapse: *uia.IExpandCollapseProvider) callconv(.winapi) HRESULT {
        return ExpandCollapse.object(expand_collapse).request(.invoke, .invoke, Node.isExpanded);
    }

    fn collapse(expand_collapse: *uia.IExpandCollapseProvider) callconv(.winapi) HRESULT {
        return ExpandCollapse.object(expand_collapse).request(.invoke, .invoke, Node.isCollapsed);
    }

    fn currentExpandCollapseState(expand_collapse: *uia.IExpandCollapseProvider, state: *uia.ExpandCollapseState) callconv(.winapi) HRESULT {
        return ExpandCollapse.object(expand_collapse).answerFromNode(uia.ExpandCollapseState, state, struct {
            fn answer(node: *const Node) uia.ExpandCollapseState {
                return expandCollapseState(node.state.expanded);
            }
        }.answer);
    }

    fn rangeOf(node: *const Node) zui.SemanticRange {
        return if (node.value == .range) node.value.range else .{ .value = 0 };
    }

    fn setRangeValue(range_value: *uia.IRangeValueProvider, target: f64) callconv(.winapi) HRESULT {
        const self = RangeValue.object(range_value);
        const reading = self.read() orelse return uia.UIA_E_ELEMENTNOTAVAILABLE;
        const node = reading.node();
        const range = rangeOf(node);
        const takes = node.takes(.adjust);
        self.bridge.doneReading();
        if (!takes) return uia.UIA_E_ELEMENTNOTENABLED;
        if (!(target >= range.min and target <= range.max)) return win32.E_INVALIDARG;
        const steps = stepsToward(range, target);
        if (steps != 0) self.bridge.sink.deliver(.{ .target = self.id, .action = .{ .adjust = steps } });
        return win32.S_OK;
    }

    fn rangeAnswer(comptime field: enum { value, min, max, small_change, large_change }) fn (*uia.IRangeValueProvider, *f64) callconv(.winapi) HRESULT {
        return struct {
            fn answer(node: *const Node) f64 {
                const range = rangeOf(node);
                return switch (field) {
                    .value => range.value,
                    .min => range.min,
                    .max => range.max,
                    .small_change => smallChange(range),
                    .large_change => smallChange(range) * 10,
                };
            }

            fn method(range_value: *uia.IRangeValueProvider, result: *f64) callconv(.winapi) HRESULT {
                return RangeValue.object(range_value).answerFromNode(f64, result, answer);
            }
        }.method;
    }

    const rangeValue = rangeAnswer(.value);
    const rangeMinimum = rangeAnswer(.min);
    const rangeMaximum = rangeAnswer(.max);
    const rangeSmallChange = rangeAnswer(.small_change);
    const rangeLargeChange = rangeAnswer(.large_change);

    fn rangeIsReadOnly(range_value: *uia.IRangeValueProvider, read_only: *win32.BOOL) callconv(.winapi) HRESULT {
        return RangeValue.object(range_value).answerFromNode(win32.BOOL, read_only, struct {
            fn answer(node: *const Node) win32.BOOL {
                return winBool(!node.takes(.adjust));
            }
        }.answer);
    }

    /// zui has no action that replaces an element's text: a client types
    /// into a text field through the keyboard.
    fn setTextValue(value: *uia.IValueProvider, _: [*:0]const u16) callconv(.winapi) HRESULT {
        const self = Value.object(value);
        _ = self.read() orelse return uia.UIA_E_ELEMENTNOTAVAILABLE;
        self.bridge.doneReading();
        return uia.UIA_E_INVALIDOPERATION;
    }

    fn textValue(value: *uia.IValueProvider, found: *win32.BSTR) callconv(.winapi) HRESULT {
        const self = Value.object(value);
        found.* = null;
        const reading = self.read() orelse return uia.UIA_E_ELEMENTNOTAVAILABLE;
        defer self.bridge.doneReading();
        const node = reading.node();
        const span = if (node.value == .text) node.value.text else TextSpan{};
        found.* = allocateString(reading.snapshot.textOf(span)) catch return win32.E_OUTOFMEMORY;
        return win32.S_OK;
    }

    /// An enabled text field reads as editable, which it is from the
    /// keyboard; a combo box's text is its choice, changed by choosing.
    fn textIsReadOnly(value: *uia.IValueProvider, read_only: *win32.BOOL) callconv(.winapi) HRESULT {
        return Value.object(value).answerFromNode(win32.BOOL, read_only, struct {
            fn answer(node: *const Node) win32.BOOL {
                return winBool(node.role != .text_field or node.state.disabled);
            }
        }.answer);
    }

    fn select(selection_item: *uia.ISelectionItemProvider) callconv(.winapi) HRESULT {
        return SelectionItem.object(selection_item).request(.invoke, .invoke, Node.isSelected);
    }

    /// One choice is always made, so a selected one cannot be taken away.
    fn removeFromSelection(selection_item: *uia.ISelectionItemProvider) callconv(.winapi) HRESULT {
        const self = SelectionItem.object(selection_item);
        const reading = self.read() orelse return uia.UIA_E_ELEMENTNOTAVAILABLE;
        const selected = reading.node().state.selected;
        self.bridge.doneReading();
        return if (selected) uia.UIA_E_INVALIDOPERATION else win32.S_OK;
    }

    fn isSelected(selection_item: *uia.ISelectionItemProvider, selected: *win32.BOOL) callconv(.winapi) HRESULT {
        return SelectionItem.object(selection_item).answerFromNode(win32.BOOL, selected, struct {
            fn answer(node: *const Node) win32.BOOL {
                return winBool(node.state.selected);
            }
        }.answer);
    }

    /// The list around an option, or the group around a radio.
    fn selectionContainer(selection_item: *uia.ISelectionItemProvider, found: *?*uia.IRawElementProviderSimple) callconv(.winapi) HRESULT {
        const self = SelectionItem.object(selection_item);
        found.* = null;
        const reading = self.read() orelse return uia.UIA_E_ELEMENTNOTAVAILABLE;
        defer self.bridge.doneReading();
        const node = reading.node();
        const container = if (node.role == .option) reading.snapshot.enclosingWith(reading.index, .list_box) else node.parent;
        if (container == no_node) return win32.S_OK;
        const element = self.bridge.elementFor(reading.snapshot.nodes[container].id) orelse return win32.E_OUTOFMEMORY;
        found.* = &element.simple;
        return win32.S_OK;
    }

    /// The selected options inside the list, as `VT_UNKNOWN` providers.
    fn currentSelection(selection: *uia.ISelectionProvider, found: *?*win32.SAFEARRAY) callconv(.winapi) HRESULT {
        const self = Selection.object(selection);
        found.* = null;
        const reading = self.read() orelse return uia.UIA_E_ELEMENTNOTAVAILABLE;
        defer self.bridge.doneReading();
        const snapshot = reading.snapshot;
        var selected_count: u32 = 0;
        var index = reading.index + 1;
        while (index < snapshot.count and snapshot.isWithin(index, reading.index)) : (index += 1) {
            if (snapshot.nodes[index].state.selected) selected_count += 1;
        }
        const array = win32.SafeArrayCreateVector(win32.VT_UNKNOWN, 0, selected_count) orelse return win32.E_OUTOFMEMORY;
        var position: win32.LONG = 0;
        index = reading.index + 1;
        while (index < snapshot.count and snapshot.isWithin(index, reading.index)) : (index += 1) {
            if (!snapshot.nodes[index].state.selected) continue;
            const element = self.bridge.elementFor(snapshot.nodes[index].id) orelse {
                _ = win32.SafeArrayDestroy(array);
                return win32.E_OUTOFMEMORY;
            };
            // The array takes a reference of its own.
            _ = win32.SafeArrayPutElement(array, &position, &element.simple);
            _ = element.release();
            position += 1;
        }
        found.* = array;
        return win32.S_OK;
    }

    fn selectsOne(_: *uia.ISelectionProvider, answer: *win32.BOOL) callconv(.winapi) HRESULT {
        answer.* = 0;
        return win32.S_OK;
    }

    /// Delivers the `scroll` that `scroll_request.distance` works out from the
    /// node, or fails as it says: on an axis that cannot move, or past the
    /// content.
    fn requestScroll(self: *Element, scroll_request: anytype) HRESULT {
        const reading = self.read() orelse return uia.UIA_E_ELEMENTNOTAVAILABLE;
        const node = reading.node();
        const takes = node.takes(.scroll) and node.scroll != null;
        const requested = if (takes) scroll_request.distance(node, self.bridge.scroll_step) else ScrollRequest{ .delta = .{ 0, 0 } };
        self.bridge.doneReading();
        if (!takes) return uia.UIA_E_ELEMENTNOTENABLED;
        const delta = switch (requested) {
            .delta => |delta| delta,
            .fails => |result| return result,
        };
        if (delta[0] != 0 or delta[1] != 0) self.bridge.sink.deliver(.{ .target = self.id, .action = .{ .scroll = delta } });
        return win32.S_OK;
    }

    const ScrollRequest = union(enum) {
        delta: [2]f32,
        fails: HRESULT,
    };

    const ScrollByAmounts = struct {
        amounts: [2]uia.ScrollAmount,

        fn distance(self: ScrollByAmounts, node: *const Node, step: f32) ScrollRequest {
            var delta: [2]f32 = .{ 0, 0 };
            for (self.amounts, 0..) |amount, axis| {
                if (amount == .no_amount) continue;
                if (!node.scrollsAlong(axis)) return .{ .fails = uia.UIA_E_INVALIDOPERATION };
                delta[axis] = scrollDistance(amount, node.scroll.?, axis, step) orelse return .{ .fails = win32.E_INVALIDARG };
            }
            return .{ .delta = delta };
        }
    };

    const ScrollToPercents = struct {
        percents: [2]f64,

        fn distance(self: ScrollToPercents, node: *const Node, _: f32) ScrollRequest {
            const extents = node.scroll.?;
            var delta: [2]f32 = .{ 0, 0 };
            for (self.percents, 0..) |percent, axis| {
                if (percent == uia.UIA_ScrollPatternNoScroll) continue;
                if (!node.scrollsAlong(axis)) return .{ .fails = uia.UIA_E_INVALIDOPERATION };
                if (!(percent >= 0 and percent <= 100)) return .{ .fails = win32.E_INVALIDARG };
                const target: f32 = @floatCast(percent / 100 * (extents.content[axis] - extents.viewport[axis]));
                delta[axis] = target - extents.offset[axis];
            }
            return .{ .delta = delta };
        }
    };

    fn scrollBy(scroll: *uia.IScrollProvider, horizontal: uia.ScrollAmount, vertical: uia.ScrollAmount) callconv(.winapi) HRESULT {
        return Scroll.object(scroll).requestScroll(ScrollByAmounts{ .amounts = .{ horizontal, vertical } });
    }

    fn setScrollPercent(scroll: *uia.IScrollProvider, horizontal: f64, vertical: f64) callconv(.winapi) HRESULT {
        return Scroll.object(scroll).requestScroll(ScrollToPercents{ .percents = .{ horizontal, vertical } });
    }

    fn scrollAnswer(comptime measure: enum { percent, view_size }, comptime axis: usize) fn (*uia.IScrollProvider, *f64) callconv(.winapi) HRESULT {
        return struct {
            fn answer(node: *const Node) f64 {
                return switch (measure) {
                    .percent => node.scrollPercent(axis),
                    .view_size => node.scrollViewSize(axis),
                };
            }

            fn method(scroll: *uia.IScrollProvider, result: *f64) callconv(.winapi) HRESULT {
                return Scroll.object(scroll).answerFromNode(f64, result, answer);
            }
        }.method;
    }

    fn scrollsAlong(comptime axis: usize) fn (*uia.IScrollProvider, *win32.BOOL) callconv(.winapi) HRESULT {
        return struct {
            fn answer(node: *const Node) win32.BOOL {
                return winBool(node.scrollsAlong(axis));
            }

            fn method(scroll: *uia.IScrollProvider, result: *win32.BOOL) callconv(.winapi) HRESULT {
                return Scroll.object(scroll).answerFromNode(win32.BOOL, result, answer);
            }
        }.method;
    }

    fn closeWindow(window: *uia.IWindowProvider) callconv(.winapi) HRESULT {
        return Window.object(window).request(.dismiss, .dismiss, null);
    }

    /// A dialog drawn inside the window is neither maximized nor minimized.
    fn keepVisualState(_: *uia.IWindowProvider, _: uia.WindowVisualState) callconv(.winapi) HRESULT {
        return uia.UIA_E_INVALIDOPERATION;
    }

    fn alreadyIdle(_: *uia.IWindowProvider, _: i32, idle: *win32.BOOL) callconv(.winapi) HRESULT {
        idle.* = 1;
        return win32.S_OK;
    }

    fn windowAnswersNo(_: *uia.IWindowProvider, answer: *win32.BOOL) callconv(.winapi) HRESULT {
        answer.* = 0;
        return win32.S_OK;
    }

    fn normalVisualState(_: *uia.IWindowProvider, state: *uia.WindowVisualState) callconv(.winapi) HRESULT {
        state.* = .normal;
        return win32.S_OK;
    }

    fn readyForInteraction(_: *uia.IWindowProvider, state: *uia.WindowInteractionState) callconv(.winapi) HRESULT {
        state.* = .ready_for_user_interaction;
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
    try bridge.init(.{ .nodes = 4, .text_bytes = 32 }, undefined, 40);
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
    try std.testing.expect(snapshot.isWithin(2, 0));
    try std.testing.expect(!snapshot.isWithin(3, 0));
}

test "a list longer than the room keeps its start, and text that does not fit is cut at a character" {
    var bridge: Bridge = undefined;
    try bridge.init(.{ .nodes = 2, .text_bytes = 6 }, undefined, 40);
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
    try bridge.init(.{}, undefined, 40);
    defer bridge.deinit();
    const node: zui.SemanticNode = .{ .id = 1, .parent = null, .role = .button, .label = "Save", .value = .none, .bounds = .{}, .state = .{}, .actions = .initEmpty() };
    try std.testing.expect(!bridge.hasRoom());
    try std.testing.expectEqual(zui.SemanticsDropped{ .nodes = 1, .text_bytes = 4 }, bridge.publish(&.{node}, 1));
}

test "each role offers the patterns that stand for what it does" {
    const node: Node = .{ .id = 1, .parent = no_node, .role = .button, .state = .{}, .actions = .initOne(.invoke), .bounds = .{}, .label = .{}, .value = .none };
    try std.testing.expect(node.offersInvoke() and !node.offersToggle());
    var checkbox = node;
    checkbox.role = .checkbox;
    checkbox.state.checked = false;
    try std.testing.expect(checkbox.offersToggle() and !checkbox.offersInvoke());
    var option = node;
    option.role = .option;
    option.state.checked = true;
    try std.testing.expect(option.offersSelectionItem() and !option.offersToggle() and !option.offersInvoke());
    var combo_box = node;
    combo_box.role = .combo_box;
    combo_box.state.expanded = false;
    try std.testing.expect(combo_box.offersExpandCollapse() and !combo_box.offersInvoke());
    var disclosure = node;
    disclosure.state.expanded = true;
    try std.testing.expect(disclosure.offersExpandCollapse() and disclosure.offersInvoke());
    var slider = node;
    slider.role = .slider;
    try std.testing.expect(!slider.offersInvoke());
}

test "setting a range moves it by whole steps, or by one toward the target when it has none" {
    try std.testing.expectEqual(@as(i32, 3), stepsToward(.{ .value = 0.5, .step = 0.1 }, 0.8));
    try std.testing.expectEqual(@as(i32, -2), stepsToward(.{ .value = 50, .min = 0, .max = 100, .step = 5 }, 41));
    try std.testing.expectEqual(@as(i32, 1), stepsToward(.{ .value = 0.5 }, 0.9));
    try std.testing.expectEqual(@as(i32, -1), stepsToward(.{ .value = 0.5 }, 0.1));
    try std.testing.expectEqual(@as(i32, 0), stepsToward(.{ .value = 0.5 }, 0.5));
}

test "a scroll request moves by a wheel notch or a view, and a percentage is a place in the content" {
    const node: Node = .{
        .id = 1,
        .parent = no_node,
        .role = .scroll_area,
        .state = .{},
        .actions = .initOne(.scroll),
        .bounds = .{},
        .label = .{},
        .value = .none,
        .scroll = .{ .offset = .{ 0, 50 }, .content = .{ 100, 300 }, .viewport = .{ 100, 100 }, .axes = .{ false, true } },
    };
    try std.testing.expect(!node.scrollsAlong(0) and node.scrollsAlong(1));
    try std.testing.expectEqual(uia.UIA_ScrollPatternNoScroll, node.scrollPercent(0));
    try std.testing.expectEqual(@as(f64, 25), node.scrollPercent(1));
    try std.testing.expectApproxEqAbs(@as(f64, 100.0 / 3.0), node.scrollViewSize(1), 1e-4);
    try std.testing.expectEqual(@as(?f32, 40), scrollDistance(.small_increment, node.scroll.?, 1, 40));
    try std.testing.expectEqual(@as(?f32, -100), scrollDistance(.large_decrement, node.scroll.?, 1, 40));
}

test "a heading's level reads as UI Automation's, and anything else as none" {
    var node: Node = .{ .id = 1, .parent = no_node, .role = .heading, .state = .{}, .actions = .initEmpty(), .bounds = .{}, .label = .{}, .value = .none, .level = 2 };
    try std.testing.expectEqual(uia.HeadingLevel1 + 1, headingLevel(&node));
    node.level = 0;
    try std.testing.expectEqual(uia.HeadingLevel_None, headingLevel(&node));
    node.role = .label;
    node.level = 1;
    try std.testing.expectEqual(uia.HeadingLevel_None, headingLevel(&node));
}
