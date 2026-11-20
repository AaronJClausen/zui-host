pub const Proxy = opaque {};
pub const Display = opaque {};

/// 24.8 fixed point.
pub const Fixed = i32;

pub fn fixedToFloat(value: Fixed) f32 {
    return @as(f32, @floatFromInt(value)) / 256;
}

pub const Array = extern struct {
    size: usize,
    alloc: usize,
    data: ?*anyopaque,
};

pub const Message = extern struct {
    name: [*:0]const u8,
    signature: [*:0]const u8,
    types: [*]const ?*const Interface,
};

pub const Interface = extern struct {
    name: [*:0]const u8,
    version: c_int,
    method_count: c_int,
    methods: ?[*]const Message,
    event_count: c_int,
    events: ?[*]const Message,
};

pub const marshal_flag_destroy: u32 = 1;

pub extern "wayland-client" fn wl_display_connect(name: ?[*:0]const u8) callconv(.c) ?*Display;
pub extern "wayland-client" fn wl_display_disconnect(display: *Display) callconv(.c) void;
pub extern "wayland-client" fn wl_display_get_fd(display: *Display) callconv(.c) c_int;
pub extern "wayland-client" fn wl_display_roundtrip(display: *Display) callconv(.c) c_int;
pub extern "wayland-client" fn wl_display_dispatch_pending(display: *Display) callconv(.c) c_int;
pub extern "wayland-client" fn wl_display_prepare_read(display: *Display) callconv(.c) c_int;
pub extern "wayland-client" fn wl_display_read_events(display: *Display) callconv(.c) c_int;
pub extern "wayland-client" fn wl_display_cancel_read(display: *Display) callconv(.c) void;
pub extern "wayland-client" fn wl_display_flush(display: *Display) callconv(.c) c_int;
pub extern "wayland-client" fn wl_proxy_marshal_flags(proxy: *Proxy, opcode: u32, interface: ?*const Interface, version: u32, flags: u32, ...) callconv(.c) ?*Proxy;
pub extern "wayland-client" fn wl_proxy_add_listener(proxy: *Proxy, implementation: *const anyopaque, data: ?*anyopaque) callconv(.c) c_int;
pub extern "wayland-client" fn wl_proxy_destroy(proxy: *Proxy) callconv(.c) void;
pub extern "wayland-client" fn wl_proxy_get_version(proxy: *Proxy) callconv(.c) u32;

pub extern "wayland-client" const wl_registry_interface: Interface;
pub extern "wayland-client" const wl_compositor_interface: Interface;
pub extern "wayland-client" const wl_surface_interface: Interface;
pub extern "wayland-client" const wl_seat_interface: Interface;
pub extern "wayland-client" const wl_pointer_interface: Interface;
pub extern "wayland-client" const wl_keyboard_interface: Interface;
pub extern "wayland-client" const wl_output_interface: Interface;
pub extern "wayland-client" const wl_data_device_manager_interface: Interface;
pub extern "wayland-client" const wl_data_device_interface: Interface;
pub extern "wayland-client" const wl_data_source_interface: Interface;
pub extern "wayland-client" const wl_data_offer_interface: Interface;

pub fn displayProxy(display: *Display) *Proxy {
    return @ptrCast(display);
}

/// A request that creates no object.
pub fn send(proxy: *Proxy, opcode: u32, arguments: anytype) void {
    _ = @call(.auto, wl_proxy_marshal_flags, .{ proxy, opcode, null, wl_proxy_get_version(proxy), 0 } ++ arguments);
}

/// A request that creates an object of `interface`, whose new id is the
/// argument left null in `arguments`.
pub fn create(proxy: *Proxy, opcode: u32, interface: *const Interface, version: u32, arguments: anytype) ?*Proxy {
    return @call(.auto, wl_proxy_marshal_flags, .{ proxy, opcode, interface, version, 0 } ++ arguments);
}

/// A destructor request, which also frees the proxy.
pub fn destroy(proxy: *Proxy, opcode: u32) void {
    _ = wl_proxy_marshal_flags(proxy, opcode, null, wl_proxy_get_version(proxy), marshal_flag_destroy);
}

pub const no_id: ?*anyopaque = null;

pub const display_get_registry = 1;
pub const registry_bind = 0;
pub const compositor_create_surface = 0;
pub const surface_destroy = 0;
pub const surface_commit = 6;
pub const surface_set_buffer_scale = 8;
pub const seat_get_pointer = 0;
pub const seat_get_keyboard = 1;
pub const seat_release = 3;
pub const pointer_release = 1;
pub const keyboard_release = 0;

pub const seat_capability_pointer = 1;
pub const seat_capability_keyboard = 2;
pub const pointer_button_pressed = 1;
pub const pointer_axis_vertical = 0;
pub const pointer_axis_horizontal = 1;
pub const keyboard_key_pressed = 1;
pub const keymap_format_xkb_v1 = 1;

pub const data_device_manager_create_data_source = 0;
pub const data_device_manager_get_data_device = 1;
pub const data_source_offer = 0;
pub const data_source_destroy = 1;
pub const data_device_set_selection = 1;
pub const data_device_release = 2;
pub const data_offer_accept = 0;
pub const data_offer_receive = 1;
pub const data_offer_destroy = 2;
pub const data_offer_finish = 3;
pub const data_offer_set_actions = 4;
pub const data_device_manager_dnd_action_copy = 1;

pub fn bind(registry: *Proxy, name: u32, interface: *const Interface, version: u32) ?*Proxy {
    return create(registry, registry_bind, interface, version, .{ name, interface.name, version, no_id });
}

/// For an argument whose object or new id needs no interface checked.
const untyped = [_]?*const Interface{ null, null, null, null };

fn message(name: [*:0]const u8, signature: [*:0]const u8, types: []const ?*const Interface) Message {
    return .{ .name = name, .signature = signature, .types = types.ptr };
}

pub const xdg_wm_base_destroy = 0;
pub const xdg_wm_base_get_xdg_surface = 2;
pub const xdg_wm_base_pong = 3;
pub const xdg_wm_base_interface: Interface = .{
    .name = "xdg_wm_base",
    .version = 1,
    .method_count = 4,
    .methods = &[_]Message{
        message("destroy", "", &untyped),
        message("create_positioner", "n", &untyped),
        message("get_xdg_surface", "no", &.{ &xdg_surface_interface, &wl_surface_interface }),
        message("pong", "u", &untyped),
    },
    .event_count = 1,
    .events = &[_]Message{message("ping", "u", &untyped)},
};

pub const xdg_surface_destroy = 0;
pub const xdg_surface_get_toplevel = 1;
pub const xdg_surface_ack_configure = 4;
pub const xdg_surface_interface: Interface = .{
    .name = "xdg_surface",
    .version = 1,
    .method_count = 5,
    .methods = &[_]Message{
        message("destroy", "", &untyped),
        message("get_toplevel", "n", &.{&xdg_toplevel_interface}),
        message("get_popup", "n?oo", &untyped),
        message("set_window_geometry", "iiii", &untyped),
        message("ack_configure", "u", &untyped),
    },
    .event_count = 1,
    .events = &[_]Message{message("configure", "u", &untyped)},
};

pub const xdg_toplevel_destroy = 0;
pub const xdg_toplevel_set_title = 2;
pub const xdg_toplevel_set_app_id = 3;
pub const xdg_toplevel_set_max_size = 7;
pub const xdg_toplevel_set_min_size = 8;
pub const xdg_toplevel_interface: Interface = .{
    .name = "xdg_toplevel",
    .version = 1,
    .method_count = 14,
    .methods = &[_]Message{
        message("destroy", "", &untyped),
        message("set_parent", "?o", &.{&xdg_toplevel_interface}),
        message("set_title", "s", &untyped),
        message("set_app_id", "s", &untyped),
        message("show_window_menu", "ouii", &.{ &wl_seat_interface, null, null, null }),
        message("move", "ou", &.{ &wl_seat_interface, null }),
        message("resize", "ouu", &.{ &wl_seat_interface, null, null }),
        message("set_max_size", "ii", &untyped),
        message("set_min_size", "ii", &untyped),
        message("set_maximized", "", &untyped),
        message("unset_maximized", "", &untyped),
        message("set_fullscreen", "?o", &.{&wl_output_interface}),
        message("unset_fullscreen", "", &untyped),
        message("set_minimized", "", &untyped),
    },
    .event_count = 2,
    .events = &[_]Message{
        message("configure", "iia", &untyped),
        message("close", "", &untyped),
    },
};

pub const cursor_shape_manager_destroy = 0;
pub const cursor_shape_manager_get_pointer = 1;
pub const cursor_shape_manager_interface: Interface = .{
    .name = "wp_cursor_shape_manager_v1",
    .version = 1,
    .method_count = 3,
    .methods = &[_]Message{
        message("destroy", "", &untyped),
        message("get_pointer", "no", &.{ &cursor_shape_device_interface, &wl_pointer_interface }),
        message("get_tablet_tool_v2", "no", &.{ &cursor_shape_device_interface, null }),
    },
    .event_count = 0,
    .events = null,
};

pub const cursor_shape_device_destroy = 0;
pub const cursor_shape_device_set_shape = 1;
pub const cursor_shape_device_interface: Interface = .{
    .name = "wp_cursor_shape_device_v1",
    .version = 1,
    .method_count = 2,
    .methods = &[_]Message{
        message("destroy", "", &untyped),
        message("set_shape", "uu", &untyped),
    },
    .event_count = 0,
    .events = null,
};

pub const viewporter_destroy = 0;
pub const viewporter_get_viewport = 1;
pub const viewporter_interface: Interface = .{
    .name = "wp_viewporter",
    .version = 1,
    .method_count = 2,
    .methods = &[_]Message{
        message("destroy", "", &untyped),
        message("get_viewport", "no", &.{ &viewport_interface, &wl_surface_interface }),
    },
    .event_count = 0,
    .events = null,
};

pub const viewport_destroy = 0;
pub const viewport_set_destination = 2;
pub const viewport_interface: Interface = .{
    .name = "wp_viewport",
    .version = 1,
    .method_count = 3,
    .methods = &[_]Message{
        message("destroy", "", &untyped),
        message("set_source", "ffff", &untyped),
        message("set_destination", "ii", &untyped),
    },
    .event_count = 0,
    .events = null,
};

pub const fractional_scale_manager_destroy = 0;
pub const fractional_scale_manager_get_fractional_scale = 1;
pub const fractional_scale_manager_interface: Interface = .{
    .name = "wp_fractional_scale_manager_v1",
    .version = 1,
    .method_count = 2,
    .methods = &[_]Message{
        message("destroy", "", &untyped),
        message("get_fractional_scale", "no", &.{ &fractional_scale_interface, &wl_surface_interface }),
    },
    .event_count = 0,
    .events = null,
};

pub const fractional_scale_destroy = 0;
pub const fractional_scale_interface: Interface = .{
    .name = "wp_fractional_scale_v1",
    .version = 1,
    .method_count = 1,
    .methods = &[_]Message{message("destroy", "", &untyped)},
    .event_count = 1,
    .events = &[_]Message{message("preferred_scale", "u", &untyped)},
};

/// `wp_fractional_scale_v1.preferred_scale` is in 120ths.
pub const fractional_scale_denominator = 120;

pub const RegistryListener = extern struct {
    global: *const fn (?*anyopaque, ?*Proxy, u32, [*:0]const u8, u32) callconv(.c) void,
    global_remove: *const fn (?*anyopaque, ?*Proxy, u32) callconv(.c) void,
};

pub const XdgWmBaseListener = extern struct {
    ping: *const fn (?*anyopaque, ?*Proxy, u32) callconv(.c) void,
};

pub const XdgSurfaceListener = extern struct {
    configure: *const fn (?*anyopaque, ?*Proxy, u32) callconv(.c) void,
};

pub const XdgToplevelListener = extern struct {
    configure: *const fn (?*anyopaque, ?*Proxy, i32, i32, ?*Array) callconv(.c) void,
    close: *const fn (?*anyopaque, ?*Proxy) callconv(.c) void,
};

/// Through version 6.
pub const SurfaceListener = extern struct {
    enter: *const fn (?*anyopaque, ?*Proxy, ?*Proxy) callconv(.c) void,
    leave: *const fn (?*anyopaque, ?*Proxy, ?*Proxy) callconv(.c) void,
    preferred_buffer_scale: *const fn (?*anyopaque, ?*Proxy, i32) callconv(.c) void,
    preferred_buffer_transform: *const fn (?*anyopaque, ?*Proxy, u32) callconv(.c) void,
};

/// Through version 5.
pub const SeatListener = extern struct {
    capabilities: *const fn (?*anyopaque, ?*Proxy, u32) callconv(.c) void,
    name: *const fn (?*anyopaque, ?*Proxy, [*:0]const u8) callconv(.c) void,
};

/// Through version 5.
pub const PointerListener = extern struct {
    enter: *const fn (?*anyopaque, ?*Proxy, u32, ?*Proxy, Fixed, Fixed) callconv(.c) void,
    leave: *const fn (?*anyopaque, ?*Proxy, u32, ?*Proxy) callconv(.c) void,
    motion: *const fn (?*anyopaque, ?*Proxy, u32, Fixed, Fixed) callconv(.c) void,
    button: *const fn (?*anyopaque, ?*Proxy, u32, u32, u32, u32) callconv(.c) void,
    axis: *const fn (?*anyopaque, ?*Proxy, u32, u32, Fixed) callconv(.c) void,
    frame: *const fn (?*anyopaque, ?*Proxy) callconv(.c) void,
    axis_source: *const fn (?*anyopaque, ?*Proxy, u32) callconv(.c) void,
    axis_stop: *const fn (?*anyopaque, ?*Proxy, u32, u32) callconv(.c) void,
    axis_discrete: *const fn (?*anyopaque, ?*Proxy, u32, i32) callconv(.c) void,
};

/// Through version 5.
pub const KeyboardListener = extern struct {
    keymap: *const fn (?*anyopaque, ?*Proxy, u32, i32, u32) callconv(.c) void,
    enter: *const fn (?*anyopaque, ?*Proxy, u32, ?*Proxy, ?*Array) callconv(.c) void,
    leave: *const fn (?*anyopaque, ?*Proxy, u32, ?*Proxy) callconv(.c) void,
    key: *const fn (?*anyopaque, ?*Proxy, u32, u32, u32, u32) callconv(.c) void,
    modifiers: *const fn (?*anyopaque, ?*Proxy, u32, u32, u32, u32, u32) callconv(.c) void,
    repeat_info: *const fn (?*anyopaque, ?*Proxy, i32, i32) callconv(.c) void,
};

pub const FractionalScaleListener = extern struct {
    preferred_scale: *const fn (?*anyopaque, ?*Proxy, u32) callconv(.c) void,
};

pub const DataDeviceListener = extern struct {
    data_offer: *const fn (?*anyopaque, ?*Proxy, ?*Proxy) callconv(.c) void,
    enter: *const fn (?*anyopaque, ?*Proxy, u32, ?*Proxy, Fixed, Fixed, ?*Proxy) callconv(.c) void,
    leave: *const fn (?*anyopaque, ?*Proxy) callconv(.c) void,
    motion: *const fn (?*anyopaque, ?*Proxy, u32, Fixed, Fixed) callconv(.c) void,
    drop: *const fn (?*anyopaque, ?*Proxy) callconv(.c) void,
    selection: *const fn (?*anyopaque, ?*Proxy, ?*Proxy) callconv(.c) void,
};

/// Through version 3.
pub const DataOfferListener = extern struct {
    offer: *const fn (?*anyopaque, ?*Proxy, [*:0]const u8) callconv(.c) void,
    source_actions: *const fn (?*anyopaque, ?*Proxy, u32) callconv(.c) void,
    action: *const fn (?*anyopaque, ?*Proxy, u32) callconv(.c) void,
};

/// Through version 3.
pub const DataSourceListener = extern struct {
    target: *const fn (?*anyopaque, ?*Proxy, ?[*:0]const u8) callconv(.c) void,
    send: *const fn (?*anyopaque, ?*Proxy, [*:0]const u8, i32) callconv(.c) void,
    cancelled: *const fn (?*anyopaque, ?*Proxy) callconv(.c) void,
    dnd_drop_performed: *const fn (?*anyopaque, ?*Proxy) callconv(.c) void,
    dnd_finished: *const fn (?*anyopaque, ?*Proxy) callconv(.c) void,
    action: *const fn (?*anyopaque, ?*Proxy, u32) callconv(.c) void,
};

pub fn addListener(proxy: *Proxy, listener: anytype, data: *anyopaque) void {
    _ = wl_proxy_add_listener(proxy, listener, data);
}
