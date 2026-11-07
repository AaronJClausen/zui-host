const std = @import("std");
const zui = @import("zui");
const win32 = @import("win32.zig");

/// The directories one host watches at once, each on a thread of its own
/// waiting on `ReadDirectoryChangesW`. Memory for every watch is part of
/// the host, so watching allocates nothing.
pub const Watches = struct {
    watches: [capacity]Watch = undefined,
    count: usize = 0,

    pub const capacity = 4;

    /// Starts watching `directory` and its subdirectories. Returns once the
    /// OS is collecting changes, so a change made after it is reported.
    pub fn start(self: *Watches, directory: []const u8, sink: zui.FileChangeSink, waker: zui.Waker) zui.FileWatchError!void {
        if (self.count == capacity) return error.TooManyWatches;
        const watch = &self.watches[self.count];
        try watch.open(directory, sink, waker);
        self.count += 1;
    }

    /// Ends every watch and waits for its thread.
    pub fn stopAll(self: *Watches) void {
        for (self.watches[0..self.count]) |*watch| watch.close();
        self.count = 0;
    }
};

const Watch = struct {
    directory: win32.HANDLE,
    stop_requested: win32.HANDLE,
    read_completed: win32.HANDLE,
    reading: win32.HANDLE,
    thread: std.Thread,
    sink: zui.FileChangeSink,
    waker: zui.Waker,
    overlapped: win32.OVERLAPPED,
    /// `ReadDirectoryChangesW` needs it aligned to a `DWORD`, and at most
    /// 64 KB for a directory on another machine.
    notifications: [16 * 1024]u8 align(@alignOf(win32.FILE_NOTIFY_INFORMATION)),

    const notify_filter = win32.FILE_NOTIFY_CHANGE_FILE_NAME | win32.FILE_NOTIFY_CHANGE_DIR_NAME |
        win32.FILE_NOTIFY_CHANGE_SIZE | win32.FILE_NOTIFY_CHANGE_LAST_WRITE | win32.FILE_NOTIFY_CHANGE_CREATION;
    const longest_directory = 4096;
    const thread_start_timeout_ms = 5 * std.time.ms_per_s;

    fn open(self: *Watch, directory: []const u8, sink: zui.FileChangeSink, waker: zui.Waker) zui.FileWatchError!void {
        var directory_utf16: [longest_directory:0]u16 = undefined;
        const directory_units = std.unicode.calcWtf16LeLen(directory) catch return error.DirectoryUnavailable;
        if (directory_units > longest_directory) return error.DirectoryUnavailable;
        const units = std.unicode.wtf8ToWtf16Le(&directory_utf16, directory) catch return error.DirectoryUnavailable;
        directory_utf16[units] = 0;
        const handle = win32.CreateFileW(
            &directory_utf16,
            win32.FILE_LIST_DIRECTORY,
            win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE | win32.FILE_SHARE_DELETE,
            null,
            win32.OPEN_EXISTING,
            win32.FILE_FLAG_BACKUP_SEMANTICS | win32.FILE_FLAG_OVERLAPPED,
            null,
        );
        if (handle == win32.INVALID_HANDLE_VALUE) return error.DirectoryUnavailable;
        errdefer _ = win32.CloseHandle(handle);
        const stop_requested = manualResetEvent() orelse return error.DirectoryUnavailable;
        errdefer _ = win32.CloseHandle(stop_requested);
        const read_completed = manualResetEvent() orelse return error.DirectoryUnavailable;
        errdefer _ = win32.CloseHandle(read_completed);
        const reading = manualResetEvent() orelse return error.DirectoryUnavailable;
        errdefer _ = win32.CloseHandle(reading);

        self.* = .{
            .directory = handle,
            .stop_requested = stop_requested,
            .read_completed = read_completed,
            .reading = reading,
            .thread = undefined,
            .sink = sink,
            .waker = waker,
            .overlapped = .{ .hEvent = read_completed },
            .notifications = undefined,
        };
        // The thread issues each read, since Windows may cancel a read when
        // the thread that issued it exits.
        self.thread = std.Thread.spawn(.{ .stack_size = 64 * 1024 }, run, .{self}) catch return error.DirectoryUnavailable;
        if (win32.WaitForSingleObject(reading, thread_start_timeout_ms) != win32.WAIT_OBJECT_0) {
            _ = win32.SetEvent(stop_requested);
            self.thread.join();
            return error.DirectoryUnavailable;
        }
    }

    fn close(self: *Watch) void {
        _ = win32.SetEvent(self.stop_requested);
        self.thread.join();
        for ([_]win32.HANDLE{ self.directory, self.stop_requested, self.read_completed, self.reading }) |handle| _ = win32.CloseHandle(handle);
    }

    fn run(self: *Watch) void {
        while (self.read()) {}
    }

    /// Waits for one batch of changes and publishes it; false once the
    /// watch is stopped or its directory can no longer be read.
    fn read(self: *Watch) bool {
        _ = win32.ResetEvent(self.read_completed);
        const started = win32.ReadDirectoryChangesW(self.directory, &self.notifications, self.notifications.len, 1, notify_filter, null, &self.overlapped, null);
        _ = win32.SetEvent(self.reading);
        if (started == 0) {
            self.publish(.{ .kind = .rescan });
            return false;
        }
        const handles = [_]win32.HANDLE{ self.read_completed, self.stop_requested };
        if (win32.WaitForMultipleObjects(handles.len, &handles, 0, win32.INFINITE) != win32.WAIT_OBJECT_0) {
            _ = win32.CancelIoEx(self.directory, &self.overlapped);
            var ignored: win32.DWORD = 0;
            _ = win32.GetOverlappedResult(self.directory, &self.overlapped, &ignored, 1);
            return false;
        }
        var bytes: win32.DWORD = 0;
        if (win32.GetOverlappedResult(self.directory, &self.overlapped, &bytes, 0) == 0) {
            // The directory was deleted, or the OS's own buffer overflowed.
            self.publish(.{ .kind = .rescan });
            return true;
        }
        if (bytes == 0) {
            self.publish(.{ .kind = .rescan });
            return true;
        }
        self.publishBatch(self.notifications[0..bytes]);
        return true;
    }

    fn publishBatch(self: *Watch, batch: []align(@alignOf(win32.FILE_NOTIFY_INFORMATION)) const u8) void {
        var offset: usize = 0;
        while (offset + @sizeOf(win32.FILE_NOTIFY_INFORMATION) <= batch.len) {
            const entry: *const win32.FILE_NOTIFY_INFORMATION = @ptrCast(@alignCast(batch[offset..].ptr));
            const name_units: [*]const u16 = &entry.FileName;
            self.publish(changeOf(entry.Action, name_units[0 .. entry.FileNameLength / 2]));
            if (entry.NextEntryOffset == 0) break;
            offset += entry.NextEntryOffset;
        }
    }

    fn publish(self: *Watch, change: zui.FileChange) void {
        self.waker.wakeIf(self.sink.publish(change));
    }

    fn manualResetEvent() ?win32.HANDLE {
        return win32.CreateEventW(null, 1, 0, null);
    }
};

/// The change Windows reported for a path relative to the watched
/// directory, with `/` between its directories.
pub fn changeOf(action: win32.DWORD, name: []const u16) zui.FileChange {
    const kind: zui.FileChange.Kind = switch (action) {
        win32.FILE_ACTION_ADDED => .added,
        win32.FILE_ACTION_REMOVED => .removed,
        win32.FILE_ACTION_MODIFIED => .modified,
        win32.FILE_ACTION_RENAMED_OLD_NAME => .renamed_from,
        win32.FILE_ACTION_RENAMED_NEW_NAME => .renamed_to,
        else => return .{ .kind = .rescan },
    };
    if (std.unicode.calcWtf8Len(name) > zui.FileChange.Path.capacity) return .{ .kind = .rescan };
    var path: [zui.FileChange.Path.capacity]u8 = undefined;
    const len = std.unicode.wtf16LeToWtf8(&path, name);
    std.mem.replaceScalar(u8, path[0..len], '\\', '/');
    return .of(kind, path[0..len]);
}

test "a change names its path with forward slashes, and asks for a rescan when the path does not fit" {
    const W = std.unicode.utf8ToUtf16LeStringLiteral;
    const nested = changeOf(win32.FILE_ACTION_RENAMED_NEW_NAME, W("themes\\dark.zon"));
    try std.testing.expectEqual(zui.FileChange.Kind.renamed_to, nested.kind);
    try std.testing.expectEqualStrings("themes/dark.zon", nested.pathBytes());
    try std.testing.expectEqual(zui.FileChange.Kind.rescan, changeOf(win32.FILE_ACTION_ADDED, W("p" ** 256)).kind);
    try std.testing.expectEqual(zui.FileChange.Kind.rescan, changeOf(99, W("a")).kind);
}
