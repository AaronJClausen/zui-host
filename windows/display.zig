//! How the monitor a window is on shows color: whether Windows runs it in
//! HDR, how bright its peak is, and where the user's SDR white sits.

const std = @import("std");
const win32 = @import("win32.zig");

pub const DisplayColor = struct {
    /// Windows shows the monitor in HDR (Settings > Display > Use HDR).
    hdr: bool = false,
    /// The display's reported peak luminance.
    peak_nits: f32 = 80,
    /// Where Windows shows SDR content's white on this monitor, which the
    /// SDR content brightness slider sets. 80 when HDR is off.
    sdr_white_nits: f32 = 80,

    pub const sdr: DisplayColor = .{};

    /// The peak over SDR white, at least 1; 1 when HDR is off.
    pub fn headroom(self: DisplayColor) f32 {
        if (!self.hdr or self.sdr_white_nits <= 0) return 1;
        return @max(self.peak_nits / self.sdr_white_nits, 1);
    }

    /// The monitor `monitor`'s color, or `sdr` when Windows cannot say.
    pub fn read(monitor: win32.HMONITOR) DisplayColor {
        const output = readOutput(monitor) orelse return .sdr;
        if (output.color_space != color_space_hdr10) return .sdr;
        return .{
            .hdr = true,
            .peak_nits = output.max_luminance,
            .sdr_white_nits = readSdrWhiteNits(&output.device_name) orelse 80,
        };
    }
};

/// DXGI_COLOR_SPACE_RGB_FULL_G2084_NONE_P2020: the desktop's color space on
/// a monitor Windows runs in HDR.
const color_space_hdr10 = 12;

const OutputDescription = extern struct {
    device_name: [32]u16,
    desktop_coordinates: win32.RECT,
    attached_to_desktop: win32.BOOL,
    rotation: u32,
    monitor: ?win32.HMONITOR,
    bits_per_color: u32,
    color_space: u32,
    red_primary: [2]f32,
    green_primary: [2]f32,
    blue_primary: [2]f32,
    white_point: [2]f32,
    min_luminance: f32,
    max_luminance: f32,
    max_full_frame_luminance: f32,
};

/// A COM interface, called through its vtable by each method's index.
const ComObject = extern struct {
    vtable: [*]const *const anyopaque,

    const query_interface = 0;
    const release_method = 2;
    const adapter_enum_outputs = 7;
    const factory_enum_adapters1 = 12;
    const output6_get_desc1 = 27;

    fn method(self: *ComObject, comptime index: usize, comptime Argument: type) *const fn (*ComObject, Argument) callconv(.winapi) win32.HRESULT {
        return @ptrCast(@alignCast(self.vtable[index]));
    }

    fn enumerate(self: *ComObject, comptime index: usize, position: u32) ?*ComObject {
        const enumerateFn: *const fn (*ComObject, u32, *?*ComObject) callconv(.winapi) win32.HRESULT = @ptrCast(@alignCast(self.vtable[index]));
        var found: ?*ComObject = null;
        return if (enumerateFn(self, position, &found) < 0) null else found;
    }

    fn queryInterface(self: *ComObject, iid: *const win32.GUID) ?*ComObject {
        const queryFn: *const fn (*ComObject, *const win32.GUID, *?*ComObject) callconv(.winapi) win32.HRESULT = @ptrCast(@alignCast(self.vtable[query_interface]));
        var found: ?*ComObject = null;
        return if (queryFn(self, iid, &found) < 0) null else found;
    }

    fn release(self: *ComObject) void {
        const releaseFn: *const fn (*ComObject) callconv(.winapi) u32 = @ptrCast(@alignCast(self.vtable[release_method]));
        _ = releaseFn(self);
    }
};

const iid_dxgi_factory1: win32.GUID = .{ .data1 = 0x770aae78, .data2 = 0xf26f, .data3 = 0x4dba, .data4 = .{ 0xa8, 0x29, 0x25, 0x3c, 0x83, 0xd1, 0xb3, 0x87 } };
const iid_dxgi_output6: win32.GUID = .{ .data1 = 0x068346e8, .data2 = 0xaaec, .data3 = 0x4b84, .data4 = .{ 0xad, 0xd7, 0x13, 0x7f, 0x51, 0x3f, 0x77, 0xa1 } };

extern "dxgi" fn CreateDXGIFactory1(riid: *const win32.GUID, factory: *?*ComObject) callconv(.winapi) win32.HRESULT;

/// A fresh factory each time, since one made before a display change
/// keeps describing the displays as they were.
fn readOutput(monitor: win32.HMONITOR) ?OutputDescription {
    var created: ?*ComObject = null;
    if (CreateDXGIFactory1(&iid_dxgi_factory1, &created) < 0) return null;
    const factory = created orelse return null;
    defer factory.release();
    var adapter_index: u32 = 0;
    while (factory.enumerate(ComObject.factory_enum_adapters1, adapter_index)) |adapter| : (adapter_index += 1) {
        defer adapter.release();
        var output_index: u32 = 0;
        while (adapter.enumerate(ComObject.adapter_enum_outputs, output_index)) |output| : (output_index += 1) {
            defer output.release();
            const output6 = output.queryInterface(&iid_dxgi_output6) orelse continue;
            defer output6.release();
            var description: OutputDescription = undefined;
            if (output6.method(ComObject.output6_get_desc1, *OutputDescription)(output6, &description) < 0) continue;
            if (description.monitor == monitor) return description;
        }
    }
    return null;
}

/// The SDR white level of the display whose GDI name is `device_name`, from
/// the active display paths.
fn readSdrWhiteNits(device_name: *const [32]u16) ?f32 {
    var paths: [max_paths]win32.DISPLAYCONFIG_PATH_INFO = undefined;
    var modes: [2 * max_paths]win32.DISPLAYCONFIG_MODE_INFO = undefined;
    var path_count: u32 = paths.len;
    var mode_count: u32 = modes.len;
    if (win32.QueryDisplayConfig(win32.QDC_ONLY_ACTIVE_PATHS, &path_count, &paths, &mode_count, &modes, null) != 0) return null;
    for (paths[0..path_count]) |path| {
        var source_name: win32.DISPLAYCONFIG_SOURCE_DEVICE_NAME = .{ .header = .{
            .type = win32.DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME,
            .size = @sizeOf(win32.DISPLAYCONFIG_SOURCE_DEVICE_NAME),
            .adapter_id = path.source_adapter_id,
            .id = path.source_id,
        } };
        if (win32.DisplayConfigGetDeviceInfo(&source_name.header) != 0) continue;
        if (!std.mem.eql(u16, std.mem.sliceTo(&source_name.view_gdi_device_name, 0), std.mem.sliceTo(device_name, 0))) continue;
        var white: win32.DISPLAYCONFIG_SDR_WHITE_LEVEL = .{ .header = .{
            .type = win32.DISPLAYCONFIG_DEVICE_INFO_GET_SDR_WHITE_LEVEL,
            .size = @sizeOf(win32.DISPLAYCONFIG_SDR_WHITE_LEVEL),
            .adapter_id = path.target_adapter_id,
            .id = path.target_id,
        } };
        if (win32.DisplayConfigGetDeviceInfo(&white.header) != 0) return null;
        return sdrWhiteNits(white.sdr_white_level);
    }
    return null;
}

/// More displays than this are read as SDR.
const max_paths = 32;

/// Windows gives the SDR white level in thousandths of 80 nits.
fn sdrWhiteNits(level: u32) f32 {
    return @as(f32, @floatFromInt(level)) / 1000 * 80;
}

test "the headroom is the peak over SDR white, and 1 without HDR" {
    try std.testing.expectEqual(@as(f32, 1), DisplayColor.sdr.headroom());
    try std.testing.expectEqual(@as(f32, 1), (DisplayColor{ .hdr = false, .peak_nits = 1000, .sdr_white_nits = 200 }).headroom());
    try std.testing.expectEqual(@as(f32, 5), (DisplayColor{ .hdr = true, .peak_nits = 1000, .sdr_white_nits = 200 }).headroom());
    try std.testing.expectEqual(@as(f32, 1), (DisplayColor{ .hdr = true, .peak_nits = 150, .sdr_white_nits = 200 }).headroom());
    try std.testing.expectEqual(@as(f32, 240), sdrWhiteNits(3000));
}

test "the layouts Windows reads and writes" {
    try std.testing.expectEqual(72, @sizeOf(win32.DISPLAYCONFIG_PATH_INFO));
    try std.testing.expectEqual(64, @sizeOf(win32.DISPLAYCONFIG_MODE_INFO));
    try std.testing.expectEqual(84, @sizeOf(win32.DISPLAYCONFIG_SOURCE_DEVICE_NAME));
    try std.testing.expectEqual(24, @sizeOf(win32.DISPLAYCONFIG_SDR_WHITE_LEVEL));
    try std.testing.expectEqual(@as(usize, if (@sizeOf(usize) == 8) 152 else 144), @sizeOf(OutputDescription));
}
