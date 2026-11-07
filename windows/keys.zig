const std = @import("std");
const zui = @import("zui");

/// The logical key a Windows virtual-key code names. Letters and digits
/// are already the layout's, so Ctrl+S is `.s` on AZERTY too.
pub fn keyFromVirtualKey(virtual_key: usize) zui.Key {
    return switch (virtual_key) {
        0x08 => .backspace,
        0x09 => .tab,
        0x0D => .enter,
        0x10 => .shift,
        0x11 => .control,
        0x12 => .alt,
        0x14 => .caps_lock,
        0x1B => .escape,
        0x20 => .space,
        0x21 => .page_up,
        0x22 => .page_down,
        0x23 => .end,
        0x24 => .home,
        0x25 => .left,
        0x26 => .up,
        0x27 => .right,
        0x28 => .down,
        0x2D => .insert,
        0x2E => .delete,
        0x30...0x39 => @enumFromInt(@intFromEnum(zui.Key.digit_0) + (virtual_key - 0x30)),
        0x41...0x5A => @enumFromInt(@intFromEnum(zui.Key.a) + (virtual_key - 0x41)),
        0x5B, 0x5C => .super,
        0x5D => .menu,
        0x70...0x7B => @enumFromInt(@intFromEnum(zui.Key.f1) + (virtual_key - 0x70)),
        0xBA => .semicolon,
        0xBB => .equals,
        0xBC => .comma,
        0xBD => .minus,
        0xBE => .period,
        0xBF => .slash,
        0xC0 => .grave,
        0xDB => .left_bracket,
        0xDC => .backslash,
        0xDD => .right_bracket,
        0xDE => .apostrophe,
        else => .unidentified,
    };
}

pub fn virtualKeyFromKey(key: zui.Key) ?u8 {
    for (0..256) |virtual_key| {
        if (keyFromVirtualKey(virtual_key) == key) return @intCast(virtual_key);
    }
    return null;
}

test "letters, digits and function keys map in order" {
    try std.testing.expectEqual(zui.Key.a, keyFromVirtualKey('A'));
    try std.testing.expectEqual(zui.Key.z, keyFromVirtualKey('Z'));
    try std.testing.expectEqual(zui.Key.digit_7, keyFromVirtualKey('7'));
    try std.testing.expectEqual(zui.Key.f12, keyFromVirtualKey(0x7B));
    try std.testing.expectEqual(zui.Key.unidentified, keyFromVirtualKey(0xFF));
    try std.testing.expectEqual(@as(?u8, 'S'), virtualKeyFromKey(.s));
}
