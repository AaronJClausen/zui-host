//! Reads what the desktop shows in half-float scRGB, where 1.0 is 80 nits,
//! through DXGI's desktop duplication, which sees past SDR white where GDI
//! clips at it.

const std = @import("std");
const zui_host = @import("zui_host");
const win32 = zui_host.windows.win32;

/// A COM interface, called through its vtable by each method's index.
const ComObject = extern struct {
    vtable: [*]const *const anyopaque,

    fn method(self: *ComObject, comptime index: usize, comptime Function: type) Function {
        return @ptrCast(@alignCast(self.vtable[index]));
    }

    fn queryInterface(self: *ComObject, iid: *const win32.GUID) ?*ComObject {
        var found: ?*ComObject = null;
        const query = self.method(0, *const fn (*ComObject, *const win32.GUID, *?*ComObject) callconv(.winapi) win32.HRESULT);
        return if (query(self, iid, &found) < 0) null else found;
    }

    fn release(self: *ComObject) void {
        _ = self.method(2, *const fn (*ComObject) callconv(.winapi) u32)(self);
    }
};

const Enumerate = *const fn (*ComObject, u32, *?*ComObject) callconv(.winapi) win32.HRESULT;

const factory_enum_adapters1 = 12;
const adapter_enum_outputs = 7;
const output_get_desc = 7;
const output5_duplicate_output1 = 26;
const duplication_acquire_next_frame = 8;
const duplication_release_frame = 14;
const texture_get_desc = 10;
const device_create_texture2d = 5;
const context_map = 14;
const context_unmap = 15;
const context_copy_resource = 47;

const iid_dxgi_factory1: win32.GUID = .{ .data1 = 0x770aae78, .data2 = 0xf26f, .data3 = 0x4dba, .data4 = .{ 0xa8, 0x29, 0x25, 0x3c, 0x83, 0xd1, 0xb3, 0x87 } };
const iid_dxgi_output5: win32.GUID = .{ .data1 = 0x80a07424, .data2 = 0xab52, .data3 = 0x42eb, .data4 = .{ 0x83, 0x3c, 0x0c, 0x42, 0xfd, 0x28, 0x2d, 0x98 } };
const iid_d3d11_texture2d: win32.GUID = .{ .data1 = 0x6f15aaf2, .data2 = 0xd208, .data3 = 0x4e89, .data4 = .{ 0x9a, 0xb4, 0x48, 0x95, 0x35, 0xd3, 0x4f, 0x9c } };

const dxgi_format_r16g16b16a16_float = 10;
const d3d11_sdk_version = 7;
const d3d_driver_type_unknown = 0;
const d3d11_usage_staging = 3;
const d3d11_cpu_access_read = 0x20000;
const d3d11_map_read = 1;

const OutputDescription = extern struct {
    device_name: [32]u16,
    desktop_coordinates: win32.RECT,
    attached_to_desktop: win32.BOOL,
    rotation: u32,
    monitor: ?win32.HMONITOR,
};

const FrameInfo = extern struct {
    last_present_time: i64,
    last_mouse_update_time: i64,
    accumulated_frames: u32,
    rects_coalesced: win32.BOOL,
    protected_content_masked_out: win32.BOOL,
    pointer_position: [3]i32,
    total_metadata_buffer_size: u32,
    pointer_shape_buffer_size: u32,
};

const TextureDescription = extern struct {
    width: u32,
    height: u32,
    mip_levels: u32,
    array_size: u32,
    format: u32,
    sample_count: u32,
    sample_quality: u32,
    usage: u32,
    bind_flags: u32,
    cpu_access_flags: u32,
    misc_flags: u32,
};

const MappedSubresource = extern struct {
    data: [*]const u8,
    row_pitch: u32,
    depth_pitch: u32,
};

extern "dxgi" fn CreateDXGIFactory1(riid: *const win32.GUID, factory: *?*ComObject) callconv(.winapi) win32.HRESULT;
extern "d3d11" fn D3D11CreateDevice(adapter: ?*ComObject, driver_type: u32, software: ?*anyopaque, flags: u32, levels: ?*const u32, level_count: u32, sdk_version: u32, device: *?*ComObject, level: ?*u32, context: *?*ComObject) callconv(.winapi) win32.HRESULT;
extern "user32" fn ClientToScreen(hwnd: win32.HWND, point: *win32.POINT) callconv(.winapi) win32.BOOL;

pub const Error = error{ NoOutput, NoDevice, NoDuplication, NoFrame, NoReadBack };

/// The scRGB color at each of `points`, in physical pixels from the top-left
/// of `hwnd`'s client area, as the desktop shows it now.
pub fn readScrgb(hwnd: win32.HWND, points: []const [2]i32, colors: [][4]f32) Error!void {
    var created: ?*ComObject = null;
    if (CreateDXGIFactory1(&iid_dxgi_factory1, &created) < 0) return error.NoOutput;
    const factory = created orelse return error.NoOutput;
    defer factory.release();
    const monitor = win32.MonitorFromWindow(hwnd, win32.MONITOR_DEFAULTTONEAREST);

    var adapter_index: u32 = 0;
    while (true) : (adapter_index += 1) {
        var adapter: ?*ComObject = null;
        if (factory.method(factory_enum_adapters1, Enumerate)(factory, adapter_index, &adapter) < 0) return error.NoOutput;
        defer adapter.?.release();
        var output_index: u32 = 0;
        while (true) : (output_index += 1) {
            var output: ?*ComObject = null;
            if (adapter.?.method(adapter_enum_outputs, Enumerate)(adapter.?, output_index, &output) < 0) break;
            defer output.?.release();
            var description: OutputDescription = undefined;
            if (output.?.method(output_get_desc, *const fn (*ComObject, *OutputDescription) callconv(.winapi) win32.HRESULT)(output.?, &description) < 0) continue;
            if (description.monitor != monitor) continue;
            return readFromOutput(adapter.?, output.?, description.desktop_coordinates, hwnd, points, colors);
        }
    }
}

fn readFromOutput(adapter: *ComObject, output: *ComObject, desktop: win32.RECT, hwnd: win32.HWND, points: []const [2]i32, colors: [][4]f32) Error!void {
    var device_or_null: ?*ComObject = null;
    var context_or_null: ?*ComObject = null;
    if (D3D11CreateDevice(adapter, d3d_driver_type_unknown, null, 0, null, 0, d3d11_sdk_version, &device_or_null, null, &context_or_null) < 0) return error.NoDevice;
    const device = device_or_null.?;
    defer device.release();
    const context = context_or_null.?;
    defer context.release();

    const output5 = output.queryInterface(&iid_dxgi_output5) orelse return error.NoDuplication;
    defer output5.release();
    const formats = [_]u32{dxgi_format_r16g16b16a16_float};
    var duplication_or_null: ?*ComObject = null;
    const duplicate = output5.method(output5_duplicate_output1, *const fn (*ComObject, *ComObject, u32, u32, [*]const u32, *?*ComObject) callconv(.winapi) win32.HRESULT);
    if (duplicate(output5, device, 0, formats.len, &formats, &duplication_or_null) < 0) return error.NoDuplication;
    const duplication = duplication_or_null.?;
    defer duplication.release();

    const acquire = duplication.method(duplication_acquire_next_frame, *const fn (*ComObject, u32, *FrameInfo, *?*ComObject) callconv(.winapi) win32.HRESULT);
    const releaseFrame = duplication.method(duplication_release_frame, *const fn (*ComObject) callconv(.winapi) win32.HRESULT);
    // The first frames can come before the desktop image does.
    const desktop_image = for (0..10) |_| {
        var info: FrameInfo = undefined;
        var resource: ?*ComObject = null;
        if (acquire(duplication, 500, &info, &resource) < 0) continue;
        if (info.last_present_time != 0) break resource.?;
        resource.?.release();
        _ = releaseFrame(duplication);
    } else return error.NoFrame;
    defer _ = releaseFrame(duplication);
    defer desktop_image.release();

    const texture = desktop_image.queryInterface(&iid_d3d11_texture2d) orelse return error.NoReadBack;
    defer texture.release();
    var description: TextureDescription = undefined;
    texture.method(texture_get_desc, *const fn (*ComObject, *TextureDescription) callconv(.winapi) void)(texture, &description);
    if (description.format != dxgi_format_r16g16b16a16_float) return error.NoReadBack;
    var staging_description = description;
    staging_description.usage = d3d11_usage_staging;
    staging_description.bind_flags = 0;
    staging_description.cpu_access_flags = d3d11_cpu_access_read;
    staging_description.misc_flags = 0;
    var staging_or_null: ?*ComObject = null;
    if (device.method(device_create_texture2d, *const fn (*ComObject, *const TextureDescription, ?*const anyopaque, *?*ComObject) callconv(.winapi) win32.HRESULT)(device, &staging_description, null, &staging_or_null) < 0) return error.NoReadBack;
    const staging = staging_or_null.?;
    defer staging.release();
    context.method(context_copy_resource, *const fn (*ComObject, *ComObject, *ComObject) callconv(.winapi) void)(context, staging, texture);

    var mapped: MappedSubresource = undefined;
    if (context.method(context_map, *const fn (*ComObject, *ComObject, u32, u32, u32, *MappedSubresource) callconv(.winapi) win32.HRESULT)(context, staging, 0, d3d11_map_read, 0, &mapped) < 0) return error.NoReadBack;
    defer context.method(context_unmap, *const fn (*ComObject, *ComObject, u32) callconv(.winapi) void)(context, staging, 0);

    var origin: win32.POINT = .{};
    _ = ClientToScreen(hwnd, &origin);
    for (points, colors) |point, *color| {
        const x: u32 = @intCast(std.math.clamp(origin.x - desktop.left + point[0], 0, @as(i32, @intCast(description.width)) - 1));
        const y: u32 = @intCast(std.math.clamp(origin.y - desktop.top + point[1], 0, @as(i32, @intCast(description.height)) - 1));
        const pixel = mapped.data[y * mapped.row_pitch + x * 8 ..][0..8];
        for (color, 0..) |*channel, index| channel.* = @floatCast(@as(f16, @bitCast(std.mem.readInt(u16, pixel[index * 2 ..][0..2], .little))));
    }
}
