//! Saves what a window shows as a BMP, through the compositor, so it sees
//! what OpenGL presented.

const std = @import("std");

const HWND = *opaque {};
const HDC = *opaque {};
const HGDIOBJ = *opaque {};
const RECT = extern struct { left: i32 = 0, top: i32 = 0, right: i32 = 0, bottom: i32 = 0 };

const BITMAPINFOHEADER = extern struct {
    biSize: u32 = @sizeOf(BITMAPINFOHEADER),
    biWidth: i32,
    biHeight: i32,
    biPlanes: u16 = 1,
    biBitCount: u16 = 32,
    biCompression: u32 = 0,
    biSizeImage: u32 = 0,
    biXPelsPerMeter: i32 = 0,
    biYPelsPerMeter: i32 = 0,
    biClrUsed: u32 = 0,
    biClrImportant: u32 = 0,
};

const PW_CLIENTONLY = 0x1;
const PW_RENDERFULLCONTENT = 0x2;

extern "user32" fn GetClientRect(hwnd: HWND, rect: *RECT) callconv(.winapi) c_int;
extern "user32" fn PrintWindow(hwnd: HWND, hdc: HDC, flags: u32) callconv(.winapi) c_int;
extern "gdi32" fn CreateCompatibleDC(hdc: ?HDC) callconv(.winapi) ?HDC;
extern "gdi32" fn DeleteDC(hdc: HDC) callconv(.winapi) c_int;
extern "gdi32" fn CreateDIBSection(hdc: ?HDC, info: *const BITMAPINFOHEADER, usage: u32, bits: *?[*]u8, section: ?*anyopaque, offset: u32) callconv(.winapi) ?HGDIOBJ;
extern "gdi32" fn SelectObject(hdc: HDC, object: HGDIOBJ) callconv(.winapi) ?HGDIOBJ;
extern "gdi32" fn DeleteObject(object: HGDIOBJ) callconv(.winapi) c_int;

pub fn saveClientArea(gpa: std.mem.Allocator, io: std.Io, window: *anyopaque, path: []const u8) !void {
    const hwnd: HWND = @ptrCast(window);
    var client: RECT = .{};
    _ = GetClientRect(hwnd, &client);
    const width = client.right;
    const height = client.bottom;
    const header: BITMAPINFOHEADER = .{ .biWidth = width, .biHeight = -height };
    const memory_dc = CreateCompatibleDC(null) orelse return error.NoDeviceContext;
    defer _ = DeleteDC(memory_dc);
    var bits: ?[*]u8 = null;
    const bitmap = CreateDIBSection(memory_dc, &header, 0, &bits, null, 0) orelse return error.NoBitmap;
    defer _ = DeleteObject(bitmap);
    _ = SelectObject(memory_dc, bitmap);
    if (PrintWindow(hwnd, memory_dc, PW_CLIENTONLY | PW_RENDERFULLCONTENT) == 0) return error.CaptureFailed;

    const pixel_bytes: usize = @intCast(width * height * 4);
    const file_header_size = 14;
    const file = try gpa.alloc(u8, file_header_size + @sizeOf(BITMAPINFOHEADER) + pixel_bytes);
    defer gpa.free(file);
    @memcpy(file[0..2], "BM");
    std.mem.writeInt(u32, file[2..6], @intCast(file.len), .little);
    @memset(file[6..10], 0);
    std.mem.writeInt(u32, file[10..14], file_header_size + @sizeOf(BITMAPINFOHEADER), .little);
    @memcpy(file[file_header_size..][0..@sizeOf(BITMAPINFOHEADER)], std.mem.asBytes(&header));
    @memcpy(file[file_header_size + @sizeOf(BITMAPINFOHEADER) ..], bits.?[0..pixel_bytes]);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = file });
}
