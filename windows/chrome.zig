const std = @import("std");
const zui = @import("zui");
const win32 = @import("win32.zig");

/// The chrome regions of a window's last frame, in client pixels, which the
/// window thread answers `WM_NCHITTEST` from while the UI thread publishes
/// the next frame's.
pub const ChromeSnapshot = struct {
    pub const capacity = 256;

    lock: win32.SRWLOCK = .{},
    regions: [capacity]PixelRegion = undefined,
    count: usize = 0,
    /// Regions the last publish cut from the end, past `capacity`.
    dropped: usize = 0,

    pub const PixelRegion = struct {
        left: i32,
        top: i32,
        right: i32,
        bottom: i32,
        kind: zui.ChromeKind,

        fn contains(self: PixelRegion, point: win32.POINT) bool {
            return point.x >= self.left and point.x < self.right and point.y >= self.top and point.y < self.bottom;
        }
    };

    /// Copies what fits of `regions`, which are valid only during the call.
    pub fn publish(self: *ChromeSnapshot, regions: []const zui.ChromeRegion, pixels_per_unit: f32) void {
        const kept = @min(regions.len, capacity);
        win32.AcquireSRWLockExclusive(&self.lock);
        defer win32.ReleaseSRWLockExclusive(&self.lock);
        for (regions[0..kept], self.regions[0..kept]) |region, *in_pixels| {
            const bounds = region.bounds;
            in_pixels.* = .{
                .left = pixel(bounds.x, pixels_per_unit),
                .top = pixel(bounds.y, pixels_per_unit),
                .right = pixel(bounds.x + bounds.width, pixels_per_unit),
                .bottom = pixel(bounds.y + bounds.height, pixels_per_unit),
                .kind = region.kind,
            };
        }
        self.count = kept;
        self.dropped = regions.len - kept;
    }

    /// The kind of the last region holding `point`, in client pixels: the
    /// one on top.
    pub fn kindAt(self: *ChromeSnapshot, point: win32.POINT) ?zui.ChromeKind {
        win32.AcquireSRWLockShared(&self.lock);
        defer win32.ReleaseSRWLockShared(&self.lock);
        var index = self.count;
        while (index > 0) {
            index -= 1;
            if (self.regions[index].contains(point)) return self.regions[index].kind;
        }
        return null;
    }

    fn pixel(units: f32, pixels_per_unit: f32) i32 {
        return std.math.lossyCast(i32, @round(units * pixels_per_unit));
    }
};

/// What `WM_NCHITTEST` answers for a region of `kind`.
pub fn hitTestCode(kind: zui.ChromeKind) win32.LRESULT {
    return switch (kind) {
        .title_bar => win32.HTCAPTION,
        .minimize_button => win32.HTMINBUTTON,
        .maximize_button => win32.HTMAXBUTTON,
        .close_button => win32.HTCLOSE,
        .resize_top => win32.HTTOP,
        .resize_bottom => win32.HTBOTTOM,
        .resize_left => win32.HTLEFT,
        .resize_right => win32.HTRIGHT,
        .resize_top_left => win32.HTTOPLEFT,
        .resize_top_right => win32.HTTOPRIGHT,
        .resize_bottom_left => win32.HTBOTTOMLEFT,
        .resize_bottom_right => win32.HTBOTTOMRIGHT,
        .client => win32.HTCLIENT,
    };
}

pub fn isResizeCode(code: win32.LRESULT) bool {
    return code >= win32.HTLEFT and code <= win32.HTBORDER;
}

pub fn isCaptionButtonCode(code: usize) bool {
    return code == win32.HTMINBUTTON or code == win32.HTMAXBUTTON or code == win32.HTCLOSE;
}

test "the region on top is the last one holding the point, and what does not fit is counted" {
    var snapshot: ChromeSnapshot = .{};
    const title_bar: zui.ChromeRegion = .{ .id = 1, .bounds = .{ .width = 400, .height = 32 }, .kind = .title_bar };
    const search: zui.ChromeRegion = .{ .id = 2, .bounds = .{ .x = 100, .y = 4, .width = 120, .height = 24 }, .kind = .client };
    snapshot.publish(&.{ title_bar, search }, 2);
    try std.testing.expectEqual(zui.ChromeKind.title_bar, snapshot.kindAt(.{ .x = 10, .y = 10 }).?);
    try std.testing.expectEqual(zui.ChromeKind.client, snapshot.kindAt(.{ .x = 250, .y = 20 }).?);
    try std.testing.expectEqual(zui.ChromeKind.title_bar, snapshot.kindAt(.{ .x = 450, .y = 20 }).?);
    try std.testing.expectEqual(@as(?zui.ChromeKind, null), snapshot.kindAt(.{ .x = 10, .y = 64 }));

    var many: [ChromeSnapshot.capacity + 3]zui.ChromeRegion = @splat(title_bar);
    snapshot.publish(&many, 1);
    try std.testing.expectEqual(@as(usize, ChromeSnapshot.capacity), snapshot.count);
    try std.testing.expectEqual(@as(usize, 3), snapshot.dropped);
}
