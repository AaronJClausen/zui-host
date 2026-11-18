# zui-host

Native hosts for [zui](https://github.com/AaronJClausen/zui): each owns
its OS's windows and event loop, and implements zui's host contract, so
any renderer that draws into the same kind of surface can draw for it.
One directory per OS, chosen by the target: Windows, and Linux on
Wayland.

```zig
const zui_host = @import("zui_host");
const Host = zui_host.Host; // zui_host.windows.Host on Windows, zui_host.linux.Host on Linux
```

## The Windows host

`zui_host.Host` opens a Win32 window and gives renderers its `win32`
surface (the `HWND`). Its message loop runs on a thread of its own, so the
window keeps drawing while the user drags its edges or moves it. It:

- reports per-monitor scale (per-monitor DPI awareness v2), keeping the
  window's size in layout units when it moves to a monitor of another DPI;
- reports the mouse, the wheel, keys with their modifiers and scan codes,
  and typed text as UTF-8, surrogate pairs joined and consecutive
  characters in one event;
- reports the environment: dark mode (also darkening the title bar), high
  contrast, animations turned off (`reduced_motion`), power (plugged, on
  battery, battery saver) and whether the window has focus;
- reports lifecycle events: Ctrl+C, Ctrl+Break, the console closing,
  logging off, shutting down and the session ending are
  `.terminate_requested`, after which the next poll reports the window
  closed; the system sleeping and waking are `.suspend` and `.resume`;
  low memory is `.low_memory`;
- reports files dropped onto the window, with their paths and where;
- sets the cursor a frame asks for, and places the IME's composition and
  candidate windows at the caret of a frame's text-input request, turning
  the IME off while no editable asks for one;
- waits as `nextFrame` says: at once, until an instant on a
  high-resolution timer, or until input or a wake, which is sticky and
  works from any thread;
- offers the clipboard as text through `Host.zuiClipboard.read(host,
  buffer)` and `write(host, text)`;
- watches up to four directories, each with its subdirectories, through
  `Host.zuiFileWatch.watch(host, directory, sink)`: a thread per
  directory waits on `ReadDirectoryChangesW` and publishes each change, a
  `zui.FileChange`, into a source of the application's, waking the window
  for the first since the last frame;
- shows the system's material behind the window when it asks for one
  (`WindowOptions.material`: `.window` is Mica, `.transient` Acrylic),
  and reports whether it shows as `Environment.system_material`: false on
  Windows 10 and Windows 11 before 22H2, with transparency effects turned
  off, or for `.none`.

It passes zui's host suite (`zui_testing.expectHostConforms`) against a
hidden window, whose harness sends the messages Windows would.

## The Linux host

On Linux, `zui_host.Host` opens a Wayland window through libwayland-client
and xdg-shell, and gives renderers its `wayland` surface (the `wl_display`
and `wl_surface`). It reads and dispatches the compositor's events on the
thread that polls it, since a Wayland client has no modal loop to escape.
So far it:

- reports the buffer scale the compositor prefers
  (`wl_surface.preferred_buffer_scale`), keeping the window's size in
  layout units when it changes, and takes the size the compositor
  configures, such as a tiling compositor's tile;
- reports the mouse, the wheel (40 layout units a notch, a touchpad's
  distance as it is), keys through the compositor's keymap with their
  modifiers and evdev codes, typed text, and whether the window has
  focus;
- closes when its close button or the compositor asks;
- sets the cursor a frame asks for, where the compositor offers
  `wp_cursor_shape_v1`;
- waits as `nextFrame` says: at once, until an instant, or until input or
  a wake, which is sticky and works from any thread (an `eventfd`); the
  compositor's other events, such as a buffer released after each frame,
  do not end a wait.

It links libwayland-client and libxkbcommon. A window opened with
`visible = false` is a surface with no role, which the compositor never
shows. Key repeat, lifecycle events, the environment beyond focus,
fractional scale, the clipboard, drops, file watching, the IME, a system
material and X11 are still to come.

It passes zui's host suite (`zui_testing.expectHostConforms`) against a
window the compositor never shows, whose harness delivers what a
compositor would to the host's own handlers; without a compositor to
connect to, the suite and the host's own tests are skipped with a
message.

## The desktop through the window

`zig build material` shows a window whose root draws no background while
`ui.environment().system_material` is true, and the theme's background
otherwise: the same code shows Mica on Windows 11 and a solid background
on Windows 10. `-- --no-system-material` makes the host behave as on
Windows 10, `-- --transient` asks for Acrylic, and `-- --screenshot
file.bmp` saves what the screen shows. The renderer clears to transparent
and must keep its alpha: zui-sokol's does, with D3D11, through a swapchain
DirectComposition composes into the window; Windows ignores the alpha of
an OpenGL window, so with `-Dgl=true` the backdrop would be added under
every pixel.

## A theme from a file

`zig build theme` draws a window in the colors of `examples/theme.zon`
and restyles it when the file changes. The host's file watch publishes
into a `zui_async.Stream(zui.FileChange, ...)` among the application's
sources; declaration sees the theme's file among the changes, and the
loader, between frames, reads and parses it into a `zui_async.Latest`
that the next frame draws with. Declaration does no I/O, so a recorded
session restyles in replay as it did live.

```zig
try Host.zuiFileWatch.watch(host, "examples", .of(&app.sources.theme_files));
```

```sh
zig build theme                          # edit examples/theme.zon while it runs
zig build theme -- --theme my/theme.zon  # watch another file
zig build theme -- --check               # rewrite a theme file, wait for the restyled frame, quit
```

`--check` writes a dark theme into `zig-out/theme-check/theme.zon`,
opens the window, and once a frame draws it, writes a light one over it;
it fails unless a frame draws the light background within 10 s. On the
reference machine the restyled frame came 2 to 4 ms after the write, two
frames after the first.

## The tour on it

`zig build tour` runs [zui-sokol](https://github.com/AaronJClausen/zui-sokol)'s
tour on this host, drawn by zui-sokol's renderer, which draws into a
`win32` window through sokol_gfx with D3D11, or into a `wayland` surface
with OpenGL through EGL, without sokol_app. The
tour's application is zui-sokol's own (its `zui_sokol_tour` module),
unchanged, and `zui_app.run` runs it: `examples/tour.zig` names this
host, zui-sokol's renderer and the tour's text contract
(`pub const Text = zui_sokol.Text`, since that renderer does not measure),
and passes each step to the tour.

```sh
zig build tour                               # interactive window
zig build tour -- --screen box_storm         # start on one screen
zig build tour -- --frames 300 --cycle 30    # visit every screen, 30 frames each, then quit
zig build tour -- --measure-idle             # report the CPU time used over 10 idle seconds
zig build tour -- --screenshot tour.bmp      # save the window after a few frames, then quit
```

Idle, it uses no CPU: on an i9-10900K in ReleaseSafe, the Layout Lab
screen used 0.0 ms of CPU over 10 s with no frames and no wakes in three
runs of four (Windows counts CPU time in 15.6 ms ticks). On Linux, under
Hyprland with an NVIDIA RTX 2060 SUPER, it used 1.2 to 4.4 ms over 10 s,
with 0 or 1 frames and no wakes, in five runs of six. `--screenshot` saves
the window on Windows only so far.

## The tour in another process

`zig build remote` runs the same tour in a second process, on
[zui_wire](https://github.com/AaronJClausen/zui)'s host and renderer,
and draws it here: a `zui_wire.Client` joins this host and zui-sokol's
renderer to it over a loopback TCP connection, sending this window's
input and drawing the frames that come back, each written as the changes
from the one before. Closing the window ends the tour's process.

```sh
zig build remote                         # the tour runs in a second process; this one draws it
zig build remote -- --check tour.bmp     # press Ctrl+2, Ctrl+4, Ctrl+9, wait for each screen, save, quit
zig build remote -- --serve 7420         # only the tour, waiting for a viewer on port 7420
zig build remote -- --connect 7420       # only the viewer, joining a tour served on port 7420
```

`--check` fails if a screen does not come back within 20 s, and when the
tour's process does not exit with 0. On the reference machine it takes
under a second: the first frame arrives about 3 ms after connecting.

## Development

| Command | What it does |
|---|---|
| `zig build test` | the unit tests, and zui's host suite and the host's own tests against a window the user never sees (on Linux, skipped without a Wayland compositor) |
| `zig build conformance` | only the host suite and the host's own tests |
| `zig build check` | compile the host, its tests and the tour; add `-Dtarget=x86_64-windows` to cross-compile |
| `zig build tour` | run the tour (Windows, Direct3D 11; Linux, OpenGL through EGL on Wayland) |
| `zig build material` | show the system material, or its fallback |
| `zig build remote` | run the tour in another process and draw it here, over `zui_wire` |
| `zig build theme` | a window styled by a theme file, restyled when it changes |
| `zig build fmt` / `fmt-check` | format, or fail if a file is not formatted |

CI checks the format, runs the tests on Windows, and on Linux under a
headless Weston, in Debug and ReleaseSafe, and cross-compiles from Linux
for x86-64 and ARM64 Windows. The examples are compiled there and run on
a desktop. On Linux the build needs `libwayland-dev libxkbcommon-dev
libegl-dev`, and for the tour sokol's `libx11-dev libxi-dev
libxcursor-dev libgl1-mesa-dev libpulse-dev`.

The repository uses LF line endings everywhere (see `.gitattributes`).

## Using it

```sh
zig fetch --save git+https://github.com/AaronJClausen/zui-host
```

```zig
// build.zig
const zui_host = b.dependency("zui_host", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zui_host", zui_host.module("zui_host"));
```

With `zui_app`, name it as the application's host:

```zig
const App = struct {
    pub const Host = zui_host.Host;
    pub const Renderer = MyRenderer; // one that draws into .win32, or .wayland on Linux
    // ...
};
```

The host must not move between `init` and `deinit`, since its window
thread (on Windows) and the compositor's listeners (on Linux) hold a
pointer to it. `forced_scale` and
`system_material_unavailable` may be set before `init`, which keeps them;
`zui_app` starts each field at its default.

## License

MIT; see [LICENSE](LICENSE).
