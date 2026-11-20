const std = @import("std");
const zui = @import("zui");
const linux = std.os.linux;

/// The directories one host watches at once, through one inotify
/// descriptor the host's wait reads on its own thread. inotify watches one
/// directory at a time, so each subdirectory has a watch of its own, added
/// when the watch starts and as each one is created or moved in. Memory for
/// every watch is part of the host, so watching allocates nothing.
pub const Watches = struct {
    /// Negative until the first watch starts.
    inotify_fd: i32 = -1,
    roots: [capacity]Root = undefined,
    root_count: usize = 0,
    directories: [directory_capacity]Directory = undefined,
    directory_count: usize = 0,
    events: [16 * 1024]u8 align(@alignOf(linux.inotify_event)) = undefined,

    /// Directories watched at once, each with its subdirectories.
    pub const capacity = 4;
    /// Directories watched over all roots, subdirectories included; one
    /// past them is not watched, and its root is told to rescan.
    pub const directory_capacity = 256;

    const longest_directory = 4096;
    const directory_events = linux.IN.CREATE | linux.IN.DELETE | linux.IN.MODIFY | linux.IN.MOVED_FROM | linux.IN.MOVED_TO |
        linux.IN.DELETE_SELF | linux.IN.MOVE_SELF | linux.IN.ONLYDIR | linux.IN.EXCL_UNLINK;

    const Root = struct {
        path: [longest_directory]u8,
        path_len: usize,
        sink: zui.FileChangeSink,
        waker: zui.Waker,

        fn publish(self: *const Root, change: zui.FileChange) void {
            self.waker.wakeIf(self.sink.publish(change));
        }
    };

    const Directory = struct {
        watch_descriptor: i32,
        root: usize,
        /// From the root, with `/` between directories; empty for the root.
        relative: zui.FileChange.Path,
    };

    /// Starts watching `directory` and its subdirectories. Returns once
    /// inotify is collecting changes, so a change made after it is
    /// reported.
    pub fn start(self: *Watches, directory: []const u8, sink: zui.FileChangeSink, waker: zui.Waker) zui.FileWatchError!void {
        if (self.root_count == capacity) return error.TooManyWatches;
        if (directory.len == 0 or directory.len >= longest_directory) return error.DirectoryUnavailable;
        if (self.inotify_fd < 0) {
            const opened = linux.inotify_init1(linux.IN.CLOEXEC | linux.IN.NONBLOCK);
            if (linux.errno(opened) != .SUCCESS) return error.DirectoryUnavailable;
            self.inotify_fd = @intCast(opened);
        }
        const root_index = self.root_count;
        const root = &self.roots[root_index];
        root.* = .{ .path = undefined, .path_len = directory.len, .sink = sink, .waker = waker };
        @memcpy(root.path[0..directory.len], directory);
        const first_directory = self.directory_count;
        if (!self.addDirectory(root_index, "")) return error.DirectoryUnavailable;
        self.root_count += 1;
        self.watchSubdirectories(first_directory, .silently);
    }

    /// Ends every watch.
    pub fn stopAll(self: *Watches) void {
        if (self.inotify_fd >= 0) _ = linux.close(self.inotify_fd);
        self.* = .{};
    }

    /// The inotify descriptor, negative while nothing is watched, which
    /// `poll` ignores.
    pub fn descriptor(self: *const Watches) i32 {
        return self.inotify_fd;
    }

    /// Reads and publishes what inotify collected, without waiting.
    pub fn receive(self: *Watches) void {
        if (self.inotify_fd < 0) return;
        while (true) {
            const result = linux.read(self.inotify_fd, &self.events, self.events.len);
            switch (linux.errno(result)) {
                .SUCCESS => self.publishBatch(self.events[0..result]),
                .INTR => continue,
                else => return,
            }
        }
    }

    fn publishBatch(self: *Watches, batch: []align(@alignOf(linux.inotify_event)) const u8) void {
        var offset: usize = 0;
        while (offset + @sizeOf(linux.inotify_event) <= batch.len) {
            const event: *const linux.inotify_event = @ptrCast(@alignCast(batch[offset..].ptr));
            const name: []const u8 = event.getName() orelse "";
            offset += @sizeOf(linux.inotify_event) + event.len;
            self.handle(event.wd, event.mask, name);
        }
    }

    fn handle(self: *Watches, watch_descriptor: i32, mask: u32, name: []const u8) void {
        if (mask & linux.IN.Q_OVERFLOW != 0) {
            for (self.roots[0..self.root_count]) |*root| root.publish(.{ .kind = .rescan });
            return;
        }
        const directory_index = self.directoryOf(watch_descriptor) orelse return;
        const directory = self.directories[directory_index];
        const root = &self.roots[directory.root];
        if (mask & linux.IN.IGNORED != 0) return self.forgetDirectory(directory_index);
        if (mask & (linux.IN.DELETE_SELF | linux.IN.MOVE_SELF) != 0) {
            if (directory.relative.len == 0) root.publish(.{ .kind = .rescan });
            return;
        }
        var path_buffer: [zui.FileChange.Path.capacity + 1]u8 = undefined;
        const path = joined(&path_buffer, directory.relative.slice(), name) orelse return root.publish(.{ .kind = .rescan });
        const kind: zui.FileChange.Kind = if (mask & linux.IN.CREATE != 0)
            .added
        else if (mask & linux.IN.DELETE != 0)
            .removed
        else if (mask & linux.IN.MODIFY != 0)
            .modified
        else if (mask & linux.IN.MOVED_FROM != 0)
            .renamed_from
        else if (mask & linux.IN.MOVED_TO != 0)
            .renamed_to
        else
            return;
        root.publish(.of(kind, path));
        if (mask & linux.IN.ISDIR == 0) return;
        switch (kind) {
            .added, .renamed_to => {
                const first_directory = self.directory_count;
                if (self.addDirectory(directory.root, path)) self.watchSubdirectories(first_directory, .reporting_each);
            },
            .renamed_from => self.forgetSubtree(directory.root, path),
            else => {},
        }
    }

    fn directoryOf(self: *const Watches, watch_descriptor: i32) ?usize {
        for (self.directories[0..self.directory_count], 0..) |directory, index| {
            if (directory.watch_descriptor == watch_descriptor) return index;
        }
        return null;
    }

    /// Adds a watch for the directory at `relative` from root `root_index`,
    /// or tells the root to rescan when there is no room for it.
    fn addDirectory(self: *Watches, root_index: usize, relative: []const u8) bool {
        const root = &self.roots[root_index];
        if (self.directory_count == directory_capacity or relative.len > zui.FileChange.Path.capacity) {
            root.publish(.{ .kind = .rescan });
            return false;
        }
        var path: [longest_directory + 1 + zui.FileChange.Path.capacity:0]u8 = undefined;
        const full = fullPath(&path, root, relative);
        const added = linux.inotify_add_watch(self.inotify_fd, full, directory_events);
        if (linux.errno(added) != .SUCCESS) return false;
        self.directories[self.directory_count] = .{ .watch_descriptor = @intCast(added), .root = root_index, .relative = zui.FileChange.of(.added, relative).path };
        self.directory_count += 1;
        return true;
    }

    const Reporting = enum { silently, reporting_each };

    /// Adds a watch for every subdirectory of the directories from
    /// `first_directory` on, the ones it adds included. A directory created
    /// before its watch was added may already hold entries, which
    /// `.reporting_each` reports as added.
    fn watchSubdirectories(self: *Watches, first_directory: usize, reporting: Reporting) void {
        var next = first_directory;
        while (next < self.directory_count) : (next += 1) {
            const directory = self.directories[next];
            const root = &self.roots[directory.root];
            var path: [longest_directory + 1 + zui.FileChange.Path.capacity:0]u8 = undefined;
            const opened = linux.openat(linux.AT.FDCWD, fullPath(&path, root, directory.relative.slice()), .{ .DIRECTORY = true, .CLOEXEC = true }, 0);
            if (linux.errno(opened) != .SUCCESS) continue;
            const listing: i32 = @intCast(opened);
            defer _ = linux.close(listing);
            var entries: [4096]u8 align(@alignOf(linux.dirent64)) = undefined;
            while (true) {
                const read = linux.getdents64(listing, &entries, entries.len);
                if (linux.errno(read) != .SUCCESS or read == 0) break;
                var offset: usize = 0;
                while (offset < read) {
                    const entry: *const linux.dirent64 = @ptrCast(@alignCast(entries[offset..].ptr));
                    offset += entry.reclen;
                    const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&entry.name)), 0);
                    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
                    var relative_buffer: [zui.FileChange.Path.capacity + 1]u8 = undefined;
                    const relative = joined(&relative_buffer, directory.relative.slice(), name) orelse {
                        root.publish(.{ .kind = .rescan });
                        continue;
                    };
                    if (reporting == .reporting_each) root.publish(.of(.added, relative));
                    // Some file systems leave every entry's type unknown;
                    // inotify refuses those that are not directories.
                    if (entry.type == linux.DT.DIR or entry.type == linux.DT.UNKNOWN) _ = self.addDirectory(directory.root, relative);
                }
            }
        }
    }

    /// Stops watching a directory moved away, and those under it.
    fn forgetSubtree(self: *Watches, root_index: usize, relative: []const u8) void {
        var index: usize = 0;
        while (index < self.directory_count) {
            const directory = self.directories[index];
            const path = directory.relative.slice();
            const inside = std.mem.startsWith(u8, path, relative) and (path.len == relative.len or path[relative.len] == '/');
            if (directory.root != root_index or !inside) {
                index += 1;
                continue;
            }
            if (!self.watchShared(index)) _ = linux.inotify_rm_watch(self.inotify_fd, directory.watch_descriptor);
            self.forgetDirectory(index);
        }
    }

    /// inotify gives a directory watched twice, as under two roots, one
    /// descriptor.
    fn watchShared(self: *const Watches, index: usize) bool {
        const watch_descriptor = self.directories[index].watch_descriptor;
        for (self.directories[0..self.directory_count], 0..) |directory, other| {
            if (other != index and directory.watch_descriptor == watch_descriptor) return true;
        }
        return false;
    }

    fn forgetDirectory(self: *Watches, index: usize) void {
        self.directory_count -= 1;
        self.directories[index] = self.directories[self.directory_count];
    }

    fn fullPath(buffer: [:0]u8, root: *const Root, relative: []const u8) [*:0]const u8 {
        var len = root.path_len;
        @memcpy(buffer[0..len], root.path[0..len]);
        if (relative.len > 0) {
            buffer[len] = '/';
            @memcpy(buffer[len + 1 ..][0..relative.len], relative);
            len += 1 + relative.len;
        }
        buffer[len] = 0;
        return buffer[0..len :0];
    }
};

/// `directory/name`, or `name` from the root; null when it is longer than
/// a change's path holds.
fn joined(buffer: *[zui.FileChange.Path.capacity + 1]u8, directory: []const u8, name: []const u8) ?[]const u8 {
    const separator: usize = if (directory.len > 0) 1 else 0;
    const len = directory.len + separator + name.len;
    if (len > zui.FileChange.Path.capacity) return null;
    @memcpy(buffer[0..directory.len], directory);
    if (separator == 1) buffer[directory.len] = '/';
    @memcpy(buffer[directory.len + separator ..][0..name.len], name);
    return buffer[0..len];
}

test "a change inside a subdirectory names it with a forward slash, and one too long to name is null" {
    var buffer: [zui.FileChange.Path.capacity + 1]u8 = undefined;
    try std.testing.expectEqualStrings("themes/dark.zon", joined(&buffer, "themes", "dark.zon").?);
    try std.testing.expectEqualStrings("theme.zon", joined(&buffer, "", "theme.zon").?);
    try std.testing.expectEqual(@as(?[]const u8, null), joined(&buffer, "d" ** 200, "n" ** 60));
}
