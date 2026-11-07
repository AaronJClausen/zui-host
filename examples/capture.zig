//! Saves what a window shows as a BMP: drawn again by the compositor, which
//! sees what OpenGL presented, or read off the screen, which also sees the
//! backdrop the compositor draws behind it.

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
const SRCCOPY = 0x00CC0020;
const CAPTUREBLT = 0x40000000;
const POINT = extern struct { x: i32 = 0, y: i32 = 0 };
const PW_RENDERFULLCONTENT = 0x2;

extern "user32" fn GetClientRect(hwnd: HWND, rect: *RECT) callconv(.winapi) c_int;
extern "user32" fn PrintWindow(hwnd: HWND, hdc: HDC, flags: u32) callconv(.winapi) c_int;
extern "user32" fn ClientToScreen(hwnd: HWND, point: *POINT) callconv(.winapi) c_int;
extern "user32" fn GetDC(hwnd: ?HWND) callconv(.winapi) ?HDC;
extern "user32" fn ReleaseDC(hwnd: ?HWND, hdc: HDC) callconv(.winapi) c_int;
extern "user32" fn SetForegroundWindow(hwnd: HWND) callconv(.winapi) c_int;
extern "gdi32" fn BitBlt(destination: HDC, x: c_int, y: c_int, width: c_int, height: c_int, source: HDC, source_x: c_int, source_y: c_int, operation: u32) callconv(.winapi) c_int;
extern "gdi32" fn CreateCompatibleDC(hdc: ?HDC) callconv(.winapi) ?HDC;
extern "gdi32" fn DeleteDC(hdc: HDC) callconv(.winapi) c_int;
extern "gdi32" fn CreateDIBSection(hdc: ?HDC, info: *const BITMAPINFOHEADER, usage: u32, bits: *?[*]u8, section: ?*anyopaque, offset: u32) callconv(.winapi) ?HGDIOBJ;
extern "gdi32" fn SelectObject(hdc: HDC, object: HGDIOBJ) callconv(.winapi) ?HGDIOBJ;
extern "gdi32" fn DeleteObject(object: HGDIOBJ) callconv(.winapi) c_int;

pub fn saveClientArea(gpa: std.mem.Allocator, io: std.Io, window: *anyopaque, path: []const u8) !void {
    const hwnd: HWND = @ptrCast(window);
    try save(gpa, io, hwnd, path, struct {
        fn draw(source: HWND, memory_dc: HDC, _: [2]i32) !void {
            if (PrintWindow(source, memory_dc, PW_CLIENTONLY | PW_RENDERFULLCONTENT) == 0) return error.CaptureFailed;
        }
    }.draw);
}

/// The window must be on top: whatever covers it is saved instead.
pub fn saveScreenArea(gpa: std.mem.Allocator, io: std.Io, window: *anyopaque, path: []const u8) !void {
    const hwnd: HWND = @ptrCast(window);
    _ = SetForegroundWindow(hwnd);
    try save(gpa, io, hwnd, path, struct {
        fn draw(source: HWND, memory_dc: HDC, size: [2]i32) !void {
            var origin: POINT = .{};
            _ = ClientToScreen(source, &origin);
            const screen = GetDC(null) orelse return error.NoDeviceContext;
            defer _ = ReleaseDC(null, screen);
            if (BitBlt(memory_dc, 0, 0, size[0], size[1], screen, origin.x, origin.y, SRCCOPY | CAPTUREBLT) == 0) return error.CaptureFailed;
        }
    }.draw);
}

fn save(gpa: std.mem.Allocator, io: std.Io, hwnd: HWND, path: []const u8, draw: fn (HWND, HDC, [2]i32) anyerror!void) !void {
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
    try draw(hwnd, memory_dc, .{ width, height });

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
