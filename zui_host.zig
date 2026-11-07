const builtin = @import("builtin");

/// The zui this host is built against; import it from here so the
/// application and the host always agree on zui's types.
pub const zui = @import("zui");

/// The native host for the target's OS.
pub const Host = switch (builtin.os.tag) {
    .windows => windows.Host,
    else => @compileError("zui_host has no host for " ++ @tagName(builtin.os.tag) ++ " yet; Windows is the first"),
};

pub const windows = if (builtin.os.tag == .windows) @import("windows/host.zig") else struct {};

test {
    if (builtin.os.tag == .windows) _ = @import("windows/host.zig");
}
