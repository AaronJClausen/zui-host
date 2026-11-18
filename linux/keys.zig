const std = @import("std");
const zui = @import("zui");

/// The logical key an XKB keysym names, from the key's first level, so
/// Shift does not change it and AZERTY's Ctrl+A is `.a`.
pub fn keyFromKeysym(keysym: u32) zui.Key {
    return switch (keysym) {
        0xFF08 => .backspace,
        0xFF09, 0xFE20 => .tab,
        0xFF0D, 0xFF8D => .enter,
        0xFF1B => .escape,
        0x20 => .space,
        0xFF50 => .home,
        0xFF51 => .left,
        0xFF52 => .up,
        0xFF53 => .right,
        0xFF54 => .down,
        0xFF55 => .page_up,
        0xFF56 => .page_down,
        0xFF57 => .end,
        0xFF63 => .insert,
        0xFF67 => .menu,
        0xFFFF => .delete,
        0xFFE1, 0xFFE2 => .shift,
        0xFFE3, 0xFFE4 => .control,
        0xFFE5 => .caps_lock,
        0xFFE9, 0xFFEA => .alt,
        0xFFEB, 0xFFEC => .super,
        0xFFBE...0xFFC9 => @enumFromInt(@intFromEnum(zui.Key.f1) + (keysym - 0xFFBE)),
        '0'...'9' => @enumFromInt(@intFromEnum(zui.Key.digit_0) + (keysym - '0')),
        'a'...'z' => @enumFromInt(@intFromEnum(zui.Key.a) + (keysym - 'a')),
        'A'...'Z' => @enumFromInt(@intFromEnum(zui.Key.a) + (keysym - 'A')),
        '-' => .minus,
        '=' => .equals,
        '[' => .left_bracket,
        ']' => .right_bracket,
        '\\' => .backslash,
        ';' => .semicolon,
        '\'' => .apostrophe,
        '`' => .grave,
        ',' => .comma,
        '.' => .period,
        '/' => .slash,
        else => .unidentified,
    };
}

/// The key at an evdev code's place on a US keyboard, for a layout whose
/// symbol there names no key, as Cyrillic letters and AZERTY's digit row do.
pub fn keyFromEvdev(code: u32) zui.Key {
    return switch (code) {
        1 => .escape,
        2...10 => @enumFromInt(@intFromEnum(zui.Key.digit_1) + (code - 2)),
        11 => .digit_0,
        12 => .minus,
        13 => .equals,
        14 => .backspace,
        15 => .tab,
        16 => .q,
        17 => .w,
        18 => .e,
        19 => .r,
        20 => .t,
        21 => .y,
        22 => .u,
        23 => .i,
        24 => .o,
        25 => .p,
        26 => .left_bracket,
        27 => .right_bracket,
        28, 96 => .enter,
        29, 97 => .control,
        30 => .a,
        31 => .s,
        32 => .d,
        33 => .f,
        34 => .g,
        35 => .h,
        36 => .j,
        37 => .k,
        38 => .l,
        39 => .semicolon,
        40 => .apostrophe,
        41 => .grave,
        42, 54 => .shift,
        43 => .backslash,
        44 => .z,
        45 => .x,
        46 => .c,
        47 => .v,
        48 => .b,
        49 => .n,
        50 => .m,
        51 => .comma,
        52 => .period,
        53 => .slash,
        56, 100 => .alt,
        57 => .space,
        58 => .caps_lock,
        59...68 => @enumFromInt(@intFromEnum(zui.Key.f1) + (code - 59)),
        87 => .f11,
        88 => .f12,
        102 => .home,
        103 => .up,
        104 => .page_up,
        105 => .left,
        106 => .right,
        107 => .end,
        108 => .down,
        109 => .page_down,
        110 => .insert,
        111 => .delete,
        125, 126 => .super,
        127 => .menu,
        else => .unidentified,
    };
}

/// The evdev mouse buttons, `BTN_LEFT` on.
pub fn buttonFromEvdev(code: u32) ?zui.Button {
    return switch (code) {
        0x110 => .primary,
        0x111 => .secondary,
        0x112 => .middle,
        else => null,
    };
}

pub const evdev_button_left = 0x110;

test "keysyms map letters case-blind, digits and function keys in order" {
    try std.testing.expectEqual(zui.Key.a, keyFromKeysym('a'));
    try std.testing.expectEqual(zui.Key.z, keyFromKeysym('Z'));
    try std.testing.expectEqual(zui.Key.digit_7, keyFromKeysym('7'));
    try std.testing.expectEqual(zui.Key.f12, keyFromKeysym(0xFFC9));
    try std.testing.expectEqual(zui.Key.unidentified, keyFromKeysym(0x6C1));
}

test "evdev codes map a US keyboard's places" {
    try std.testing.expectEqual(zui.Key.digit_1, keyFromEvdev(2));
    try std.testing.expectEqual(zui.Key.digit_0, keyFromEvdev(11));
    try std.testing.expectEqual(zui.Key.s, keyFromEvdev(31));
    try std.testing.expectEqual(zui.Key.f10, keyFromEvdev(68));
    try std.testing.expectEqual(zui.Key.unidentified, keyFromEvdev(250));
    try std.testing.expectEqual(zui.Button.primary, buttonFromEvdev(evdev_button_left).?);
}
