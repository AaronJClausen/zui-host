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

`zui_host.Host` opens Win32 windows and gives renderers each one's `win32`
surface (the `HWND`). Its message loop runs on a thread of its own, so a
window keeps drawing while the user drags its edges or moves it. It:

- opens many windows (`zui_capabilities.windows = .many`): `init` opens
  `.main`, and `zuiOpenWindow(options)` up to `Host.max_windows - 1` more,
  each with an id never given twice, its own events, scale, requests,
  chrome regions, accessibility bridge and menu bar, polled by its id;
  `zuiCloseWindow(window)` closes any of them, `.main` included. One wait
  covers them all. A message-only window anchors the window thread and
  owns the clipboard and the notification icon, so every service keeps
  working whichever windows are open, and the console's terminate and
  low memory reach every window;

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
- offers zui's host services: the clipboard as text,
  `Host.zuiClipboard.write(host, text)` and `read(host, request, sink)`;
  `Host.zuiOpenUrl.open(host, url)`, which hands a URL to the system's
  handler for its scheme and refuses paths and `file:` URLs;
  `Host.zuiNotifications.show(host, request, notification, sink)`, a
  balloon of the window's notification-area icon, which Windows 10 and
  11 show as a toast, answering `.notification_activated` when clicked
  and `.notification_dismissed` when it times out, is closed or is
  replaced by the next; and `Host.zuiFileDialogs.show(host, window,
  request, dialog, sink)`, the shell's open, save and folder dialogs,
  owned by the window and one at a time, answering `.files_chosen` with
  the paths chosen or `.canceled`; and `Host.zuiMenus`, Windows' own
  menus: `popup(host, window, request, items, position, sink)`, a context
  menu at a position in layout units, one at a time with a file dialog,
  answering the item chosen or `.canceled`, and `setBar(host, window,
  request, items, sink)`, which replaces the window's menu bar, or
  removes it given no items, and answers each item chosen from it, or is
  `error.Unavailable` under a custom title bar, which would hide it. Labels
  show as written, with shortcuts after them (`Ctrl+Shift+S`). Each call
  returns at once; the window thread does the work and publishes every
  answer, a `zui.ServiceReply`, into a source of the application's, so
  answers never come from two threads;
- watches up to four directories, each with its subdirectories, through
  `Host.zuiFileWatch.watch(host, directory, sink)`: a thread per
  directory waits on `ReadDirectoryChangesW` and publishes each change, a
  `zui.FileChange`, into a source of the application's, waking the window
  for the first since the last frame;
- shows the system's material behind the window when it asks for one
  (`WindowOptions.material`: `.window` is Mica, `.transient` Acrylic),
  and reports whether it shows as `Environment.system_material`: false on
  Windows 10 and Windows 11 before 22H2, with transparency effects turned
  off, or for `.none`;
- opens the surface in `.scrgb_fp16` while the window's monitor runs in
  HDR, if the window was opened with it (`zui_app` passes it when the
  renderer declares it too), and in `.sdr` otherwise, and reports
  `Environment.hdr_headroom`: the monitor's peak over the SDR white that
  its SDR content brightness slider sets, or 1 in `.sdr`. Moving to
  another monitor and turning HDR on or off change both;
- bridges `Frame.semantics()` to UI Automation, through `zuiSemantics`,
  when the window was opened with room for it (`WindowOptions.semantics`,
  which `zui_app` sizes from `Config.limits` when `features.semantics` is
  on); see *Accessibility* below;
- leaves the title bar to the application for a window opened with
  `WindowOptions.title_bar = .custom`, reporting
  `Environment.custom_title_bar` and `.window_maximized`, and answers
  Windows from the frame's chrome regions, which `zui_app` hands to
  `zuiChromeRegions`; see *A custom title bar* below.

It passes zui's host suite (`zui_testing.expectHostConforms`) against
hidden windows, two of them for its many-windows steps, whose harness
sends each window the messages Windows would.

## The Linux host

On Linux, `zui_host.Host` opens a Wayland window through libwayland-client
and xdg-shell, and gives renderers its `wayland` surface (the `wl_display`
and `wl_surface`). It reads and dispatches the compositor's events on the
thread that polls it, since a Wayland client has no modal loop to escape.
So far it:

- reports the scale the compositor prefers: fractional
  (`wp_fractional_scale_v1`, in 120ths) where it also offers
  `wp_viewporter`, the buffer drawn at physical pixels and the viewport
  giving the surface its size; otherwise the integer buffer scale
  (`wl_surface.preferred_buffer_scale`). It keeps the window's size in
  layout units when the scale changes, and takes the size the compositor
  configures, such as a tiling compositor's tile;
- reports the mouse, the wheel (40 layout units a notch, a touchpad's
  distance as it is), keys through the compositor's keymap with their
  modifiers and evdev codes, typed text, and whether the window has
  focus;
- repeats a held key at the rate and after the delay the compositor
  gives (`wl_keyboard.repeat_info`), each repeat a `key_down` with
  `repeat` set and its text typed again; a modifier pressed meanwhile
  leaves it repeating;
- reports the environment the desktop gives over D-Bus: the theme, high
  contrast and reduced motion from the XDG desktop portal's settings
  (`org.freedesktop.appearance`), and power from UPower (on battery) and
  power-profiles-daemon (`power-saver` is the saver), each change as it
  is signalled. Without a session bus, a portal or either daemon, as in a
  container or under a bare compositor, those settings stay at zui's
  defaults, and `host.environmentSources()` says which answered;
- reports lifecycle events: SIGINT, SIGTERM and SIGHUP are
  `.terminate_requested`, after which the next poll reports the window
  closed, unless the application handles or ignores the signal itself (a
  second Ctrl+C ends the process); the system sleeping and waking
  (logind's `PrepareForSleep`) are `.suspend` and `.resume`;
- reports files dropped onto the window (`wl_data_device`, an offer of
  `text/uri-list` accepted for copying), each `file://` URI on this
  machine percent-decoded to its path, at the drop's position;
- closes when its close button or the compositor asks;
- sets the cursor a frame asks for, where the compositor offers
  `wp_cursor_shape_v1`;
- offers zui's host services over the session bus, the Windows host's
  shapes: `Host.zuiNotifications.show(host, request, notification,
  sink)`, a notification from the desktop's notification daemon
  (`org.freedesktop.Notifications`), one at a time and replaced by the
  next, answering `.notification_activated` when clicked and
  `.notification_dismissed` when it expires, is closed or is replaced;
  `Host.zuiFileDialogs.show(host, window, request, dialog, sink)`, the XDG
  desktop portal's open, save and folder dialogs (`FileChooser`), one at
  a time, answering `.files_chosen` with the paths chosen or `.canceled`;
  and `Host.zuiOpenUrl.open(host, url)`, which hands a URL to the
  portal's `OpenURI` and refuses paths and `file:` URLs. Each call only
  sends; the poll and the wait read the bus and publish every answer, a
  `zui.ServiceReply`, into a source of the application's. Without a
  session bus each call is `error.Unavailable`, and without a daemon or a
  portal the answer is `.failed = .unavailable`. There are no menus,
  which Wayland does not have;
- waits as `nextFrame` says: at once, until an instant, or until input,
  a key's repeat, a signal or a wake, which is sticky and works from any
  thread (an `eventfd`); the compositor's and the buses' other messages,
  such as a buffer released after each frame, do not end a wait;
- offers the clipboard as text, `Host.zuiClipboard.write(host, text)`
  and `read(host, request, sink)`, through the seat's selection: `write`
  offers up to 64 KiB of UTF-8 as `text/plain;charset=utf-8`,
  `UTF8_STRING` and `text/plain`, and `read` publishes a
  `zui.ServiceReply` once the selection's owner has written it, up to
  64 KiB with the rest counted as left out, `""` when the clipboard
  holds no text, or `.failed` after 2 s. Both directions go through
  pipes the host's wait reads and writes, so the host can paste its own
  text, and a reader that closes early does not raise SIGPIPE. The
  compositor names the selection only to the window with keyboard
  focus; until it names another, a read answers the last text written;
- watches up to four directories, each with its subdirectories, through
  `Host.zuiFileWatch.watch(host, directory, sink)`: one inotify
  descriptor, read in the host's wait, with a watch for each directory,
  added as subdirectories are created or moved in (up to 256 in all;
  past them, or past a path of 255 bytes, a `.rescan`), publishing each
  change, a `zui.FileChange`, into a source of the application's.

It links libwayland-client and libxkbcommon, and speaks D-Bus itself: a
client of its own, in `linux/dbus.zig`, reads the buses' sockets into
fixed buffers, beside the display in the same wait, so it needs no
libdbus and allocates nothing. `init` waits up to 250 ms for the desktop's
current settings, so the first frame has them. A window opened with
`visible = false` is a surface with no role, which the compositor never
shows. The services have a connection to the session bus of their own,
which reads nothing while no call waits for an answer. Low memory,
reduced transparency, the IME, a system material and X11 are still to
come.

It passes zui's host suite (`zui_testing.expectHostConforms`) against a
window the compositor never shows, whose harness delivers what a
compositor would to the host's own handlers; without a compositor to
connect to, the suite and the host's own tests are skipped with a
message. The services are answered there through the host's fake
(`Host.fakeServices`), so nothing shows. A test with
`ZUI_HOST_TEST_SHOWN_WINDOW` set shows a window for a moment, so the
compositor gives it focus, and reads text written to the clipboard back
through the compositor's own selection; without it, the clipboard's
pipes are tested with the host at both ends. The tests read no bus but
the ones named by `ZUI_HOST_TEST_SESSION_BUS`: set to a bus's address,
tests play the portal and the notification daemon on it, and check that
the settings, a notification's arguments and signals, a file chooser's
options and its answer (paths or a cancel), and `OpenURI` reach the host
or the played service, that another sender's signals do not, and that a
notification with no daemon fails without blocking.

```sh
dbus-daemon --session --nofork --address=unix:abstract=/zui-host-test --print-address
ZUI_HOST_TEST_SESSION_BUS=unix:abstract=/zui-host-test zig build test
```

## Accessibility

A window opened with `WindowOptions.semantics` answers UI Automation's
`WM_GETOBJECT` with a fragment root, whose elements are the nodes of the
last `Frame.semantics()` the host was handed: each with its label as its
name, its role as a control type, its id in hex as its AutomationId, its
bounds in screen pixels and its place in the tree, and a heading with its
level. Each offers the pattern that stands for what it does: Toggle on a
checkbox, ExpandCollapse on a dropdown or disclosure, RangeValue on a
slider, Value on a text field or dropdown, SelectionItem on an option or
radio, Selection on a list, Scroll on a scroll container, Window on a
dialog, and Invoke on what is left that clicks.

A client's requests arrive in the next record as the actions that answer
them: Invoke, Toggle, Expand, Collapse and Select as `invoke`, answered
as a click; a range's SetValue as `adjust` by whole steps; a scroll by a
notch (a wheel step), a page or to a percentage as `scroll`;
ShowContextMenu as `show_menu`; a dialog's Close as `dismiss`; and
SetFocus as `focus`, answered as Tab would be. A text field's text is
read through its Value pattern and typed from the keyboard, since zui has
no action that replaces it. Focus, structure and property changes (name,
value, toggle, expand, selection, enabled, scroll position) are raised
only while a client listens, from the window thread.

The host copies each list into one of two snapshots it allocates in
`init`, so a list past that room is cut from the end and reported, and
nothing is allocated after `init`. Without room, the window is left to
Windows' default accessibility.

`zig build accessible` shows a heading, a button, a checkbox, a slider, a
text field, a dropdown and a scrolling log, from `zui_widgets` and zui,
for trying with Narrator or Accessibility Insights; `-- --frames 30`
draws 30 frames and quits. zui-sokol's tour declares its semantics too,
so the tour on this host can be read the same way. The host's tests read
their windows through UI Automation's own client, in-process, from a
thread that owns no window: a window that was never shown is exposed
too.

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

## HDR white

`zig build hdr` shows boxes of SDR white and of two and four times it, in
`zui.ExtendedColor`, with the output format and `hdr_headroom` the window
got. On a monitor in HDR the host opens it in `.scrgb_fp16` and
zui-sokol's renderer draws into a half-float scRGB swapchain, so the
brighter boxes show brighter; elsewhere all three show as SDR white.
`-- --measure` reads the boxes back off the desktop in scRGB, where 1.0 is
80 nits, through DXGI's desktop duplication, and fails if twice SDR white
does not show brighter than SDR white:

```
output scrgb_fp16, headroom 3.81; the desktop shows, in scRGB (1.0 is 80 nits):
  SDR white  3.500 3.500 3.500, 1.00x SDR white
  2x         7.000 7.000 7.000, 2.00x SDR white
  4x         14.000 14.000 14.000, 4.00x SDR white
```

## A theme from a file

`zig build theme` draws a window in the colors of `examples/theme.zon`
and restyles it when the file changes, on Windows and on Linux. The host's file watch publishes
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
frames after the first, on Windows; on Linux under Hyprland at 60 Hz, it
came 18.7 ms after it, in the second frame.

## Host services

`zig build services` has a button for each service, with its answer
beside it: pick a file, save a file, show a notification, open a popup
menu, set or clear the menu bar, copy, paste, and open
<https://ziglang.org>. It runs on both hosts; a service the host does not
offer says so beside its button. A right click anywhere opens the context menu,
and Ctrl+C, Ctrl+V, Ctrl+O and Ctrl+S do what the menus say. Declaration
only notes what was asked for, and the loader makes the calls between
frames through `zui_app.ServicesOf`, so every answer comes back through
one source, a `zui_async.Stream(zui.ServiceReply(16 * 1024), ...)`:

```zig
const services = zui_app.ServicesOf(zui_host.Host);

pub fn zuiLoader(app: *App, _: *const Ui, _: std.Io) void {
    if (services.has_file_dialogs and app.wants_file) {
        app.wants_file = false;
        services.file_dialogs.show(app.host, .main, .of("pick a file"), .{ .title = "Pick a file" }, .of(&app.sources.replies)) catch {};
    }
}
```

```sh
zig build services                 # interactive window
zig build services -- --check      # every service against the host's fake, in a hidden window, then quit
```

`--check` hides the window and answers every service through the host's
fake (`Host.fakeServices`), so nothing opens or shows. It presses each
button in turn, chooses an item from the menu bar as Windows would
report it, and fails unless each answer shows in a frame within 10 s.
It uses the real clipboard, and so replaces what it holds. A paste right
after a copy often finds the clipboard held by clipboard history, and is
answered `.failed = .unavailable`; the check presses Paste again, as a
user would. Setting a menu bar shrinks the window's content by the bar's
height. On Linux the check presses only the buttons of the services the
host offers, the file dialogs, the notification and the URL, and draws
nothing: a surface the compositor never shows gets no frame callbacks,
which a renderer's swap waits for.

## A custom title bar

`zig build title-bar` draws its own title bar over Mica: a title, a
search field and minimize, maximize and close buttons. The application
marks each part with `Element.chrome`, behind `features.chrome_regions`,
and opens the window with `.title_bar = .custom`:

```zig
ui.open(.{ .id = .of("title bar"), .chrome = .title_bar, .layout = .{ .sizing = .{ .width = .grow, .height = .fixed(32) } } });
defer ui.close();
_ = widgets.textField(ui, .of("search"), &app.search, .{ .label = "Search" }); // interactive, so it stays the application's
if (captionButton(ui, .of("close"), .close_button, "Close")) app.host.close(); // the keyboard's or Narrator's click
```

The window keeps the system's frame on the left, right and bottom, so DWM
draws its border, rounded corners and shadow, and only the caption goes.
`WM_NCHITTEST` is answered from the system's borders first, then a resize
band the host keeps along the top, then the frame's regions, the last on
top: a title bar is `HTCAPTION`, so Windows drags the window, maximizes it
on a double click, opens the system menu on a right click and snaps it
with Win+arrows; the maximize button is `HTMAXBUTTON`, so hovering it
shows snap layouts; resize edges and grips are the `HT` code of their
edge; and the interactive elements inside the title bar stay
`HTCLIENT`. The host keeps a copy of up to 256 regions, in pixels, under a
lock the window thread takes shared.

Over the caption buttons the pointer still reaches zui, so they show
hover and press. The host works them itself when a press and its release
land on the same button, as Windows' own buttons, and ends the press with
`pointer_cancel` rather than a release, so zui reports no click. An
application acts on `clicked` only for the keyboard and Narrator, through
`Host.minimize`, `Host.toggleMaximized` and `Host.close`, so each button
is worked once. Maximized, the content starts below the edge of the
monitor.

```sh
zig build title-bar                          # interactive window
zig build title-bar -- --no-system-material  # the solid background Windows 10 shows
zig build title-bar -- --check               # hit-test each part in a hidden window, then quit
```

`--check` hides the window, draws it twice, sends `WM_NCHITTEST` at each
part as laid out, and exits 0 only when the title is `HTCAPTION`, the
search field and the content `HTCLIENT`, and the buttons `HTMINBUTTON`,
`HTMAXBUTTON` and `HTCLOSE`.

## Many windows

`zig build many-windows` runs one application in two windows through
`zui_app`: each declares its own UI in a context of its own and counts
its own clicks, and a count shared by both is published into each
window's `zui_async.Latest(u32)`. Any window opens another or closes
itself, and the run ends with the last. zui-sokol draws each through its
own swapchain on one device.

```sh
zig build many-windows                         # interactive windows
zig build many-windows -- --check              # open, click and close hidden windows, then quit
zig build many-windows -- --measure-idle       # CPU time of two idle windows over 10 s
zig build many-windows -- --measure-animation  # frame rates of one, then two, windows animating
```

`--check` opens a hidden second window, clicks its buttons through the
host, and exits 0 only when the second counts its own click, both show
the shared count, the first counted none, and the first draws on after
the second closes. On a 144 Hz monitor, two windows animating at once
each hold 143 frames a second, as one alone holds 144, and two idle
windows use no CPU.

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
| `zig build accessible` | `zui_widgets` controls for Narrator and Accessibility Insights |
| `zig build services` | every host service from buttons, each answer shown (Windows and Linux); `-- --check` runs it against the fake |
| `zig build title-bar` | a title bar the application draws, which Windows still drags, snaps and resizes; `-- --check` hit-tests it hidden |
| `zig build many-windows` | one application in two windows, each with its own UI; `-- --check` clicks and closes them hidden |
| `zig build fmt` / `fmt-check` | format, or fail if a file is not formatted |

CI checks the format, runs the tests on Windows, and on Linux under a
headless Weston with a D-Bus daemon of its own, in Debug and ReleaseSafe, and cross-compiles from Linux
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
pointer to it, as does the Linux host's signal handler. `forced_scale`,
`system_material_unavailable` (Windows) and `bus_addresses` (Linux) may
be set before `init`, which keeps them; `zui_app` starts each field at
its default. `service_fake` may be set before `init` too, or after it
with `Host.fakeServices(fake)`, before the first service call.

## License

MIT; see [LICENSE](LICENSE).
