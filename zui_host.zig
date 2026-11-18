const builtin = @import("builtin");

/// The zui this host is built against; import it from here so the
/// application and the host always agree on zui's types.
pub const zui = @import("zui");

/// The native host for the target's OS: Win32 on Windows, Wayland on Linux.
pub const Host = switch (builtin.os.tag) {
    .windows => windows.Host,
    .linux => linux.Host,
    else => @compileError("zui_host has no host for " ++ @tagName(builtin.os.tag) ++ " yet; Windows and Linux are the first"),
};

pub const windows = if (builtin.os.tag == .windows) @import("windows/host.zig") else struct {};
pub const linux = if (builtin.os.tag == .linux) @import("linux/host.zig") else struct {};

test {
    if (builtin.os.tag == .windows) _ = @import("windows/host.zig");
    if (builtin.os.tag == .linux) _ = @import("linux/host.zig");
}
