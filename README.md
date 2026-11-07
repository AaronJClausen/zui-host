# zui-host

Native hosts for [zui](https://github.com/AaronJClausen/zui): each owns
its OS's windows and event loop, and implements zui's host contract, so
any renderer that draws into the same kind of surface can draw for it.
One directory per OS, chosen by the target. Windows is the first.

```zig
const zui_host = @import("zui_host");
const Host = zui_host.Host; // zui_host.windows.Host on Windows
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
- shows the system's material behind the window when it asks for one
  (`WindowOptions.material`: `.window` is Mica, `.transient` Acrylic),
  and reports whether it shows as `Environment.system_material`: false on
  Windows 10 and Windows 11 before 22H2, with transparency effects turned
  off, or for `.none`.

It passes zui's host suite (`zui_testing.expectHostConforms`) against a
hidden window, whose harness sends the messages Windows would.

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

## The tour on it

`zig build tour` runs [zui-sokol](https://github.com/AaronJClausen/zui-sokol)'s
tour on this host, drawn by zui-sokol's renderer, which draws into a
`win32` window through sokol_gfx with D3D11 and without sokol_app. The
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
runs of four (Windows counts CPU time in 15.6 ms ticks).

## Development

| Command | What it does |
|---|---|
| `zig build test` | the unit tests, and on Windows zui's host suite and the host's own tests against a hidden window |
| `zig build conformance` | only the host suite and the host's own tests |
| `zig build check` | compile the host, its tests and the tour; add `-Dtarget=x86_64-windows` to cross-compile |
| `zig build tour` | run the tour (Windows, Direct3D 11) |
| `zig build material` | show the system material, or its fallback |
| `zig build fmt` / `fmt-check` | format, or fail if a file is not formatted |

CI checks the format, runs the tests on Windows in Debug and ReleaseSafe,
and cross-compiles from Linux for x86-64 and ARM64 Windows. The examples
are compiled there and run on a desktop.

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
    pub const Renderer = MyRenderer; // one that draws into .win32
    // ...
};
```

The host must not move between `init` and `deinit`, since its window
thread holds a pointer to it. `forced_scale` and
`system_material_unavailable` may be set before `init`, which keeps them;
`zui_app` starts each field at its default.

## License

MIT; see [LICENSE](LICENSE).
