//! The Win32 declarations the Windows host uses, and nothing more.

pub const BOOL = c_int;
pub const UINT = c_uint;
pub const DWORD = u32;
pub const WORD = u16;
pub const LONG = i32;
pub const WPARAM = usize;
pub const LPARAM = isize;
pub const LRESULT = isize;
pub const ATOM = u16;
pub const HANDLE = *anyopaque;
pub const HWND = *opaque {};
pub const HINSTANCE = *opaque {};
pub const HCURSOR = *opaque {};
pub const HICON = *opaque {};
pub const HBRUSH = *opaque {};
pub const HMENU = *opaque {};
pub const HDROP = *opaque {};
pub const HIMC = *opaque {};
pub const HKEY = *opaque {};

pub const WNDPROC = *const fn (HWND, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT;
pub const HANDLER_ROUTINE = *const fn (DWORD) callconv(.winapi) BOOL;

pub const POINT = extern struct { x: LONG = 0, y: LONG = 0 };
pub const RECT = extern struct { left: LONG = 0, top: LONG = 0, right: LONG = 0, bottom: LONG = 0 };

pub const MSG = extern struct {
    hwnd: ?HWND,
    message: UINT,
    wParam: WPARAM,
    lParam: LPARAM,
    time: DWORD,
    pt: POINT,
    lPrivate: DWORD,
};

pub const WNDCLASSEXW = extern struct {
    cbSize: UINT = @sizeOf(WNDCLASSEXW),
    style: UINT = 0,
    lpfnWndProc: WNDPROC,
    cbClsExtra: c_int = 0,
    cbWndExtra: c_int = 0,
    hInstance: ?HINSTANCE,
    hIcon: ?HICON = null,
    hCursor: ?HCURSOR = null,
    hbrBackground: ?HBRUSH = null,
    lpszMenuName: ?[*:0]const u16 = null,
    lpszClassName: [*:0]const u16,
    hIconSm: ?HICON = null,
};

pub const TRACKMOUSEEVENT = extern struct {
    cbSize: DWORD = @sizeOf(TRACKMOUSEEVENT),
    dwFlags: DWORD,
    hwndTrack: HWND,
    dwHoverTime: DWORD = 0,
};

pub const COMPOSITIONFORM = extern struct {
    dwStyle: DWORD,
    ptCurrentPos: POINT = .{},
    rcArea: RECT = .{},
};

pub const CANDIDATEFORM = extern struct {
    dwIndex: DWORD = 0,
    dwStyle: DWORD,
    ptCurrentPos: POINT = .{},
    rcArea: RECT = .{},
};

pub const SYSTEM_POWER_STATUS = extern struct {
    ACLineStatus: u8,
    BatteryFlag: u8,
    BatteryLifePercent: u8,
    SystemStatusFlag: u8,
    BatteryLifeTime: DWORD,
    BatteryFullLifeTime: DWORD,
};

pub const HIGHCONTRASTW = extern struct {
    cbSize: UINT = @sizeOf(HIGHCONTRASTW),
    dwFlags: DWORD = 0,
    lpszDefaultScheme: ?[*:0]u16 = null,
};

pub const HDC = *opaque {};
pub const BLACK_BRUSH = 4;

pub const PAINTSTRUCT = extern struct {
    hdc: ?HDC,
    fErase: BOOL,
    rcPaint: RECT,
    fRestore: BOOL,
    fIncUpdate: BOOL,
    rgbReserved: [32]u8,
};

pub const SRWLOCK = extern struct { ptr: ?*anyopaque = null };

pub const WM_DESTROY = 0x0002;
pub const WM_SIZE = 0x0005;
pub const WM_SETFOCUS = 0x0007;
pub const WM_KILLFOCUS = 0x0008;
pub const WM_PAINT = 0x000F;
pub const WM_CLOSE = 0x0010;
pub const WM_QUERYENDSESSION = 0x0011;
pub const WM_ERASEBKGND = 0x0014;
pub const WM_ENDSESSION = 0x0016;
pub const WM_SETTINGCHANGE = 0x001A;
pub const WM_SETCURSOR = 0x0020;
pub const WM_THEMECHANGED = 0x031A;
pub const WM_KEYDOWN = 0x0100;
pub const WM_KEYUP = 0x0101;
pub const WM_CHAR = 0x0102;
pub const WM_SYSKEYDOWN = 0x0104;
pub const WM_SYSKEYUP = 0x0105;
pub const WM_MOUSEMOVE = 0x0200;
pub const WM_LBUTTONDOWN = 0x0201;
pub const WM_LBUTTONUP = 0x0202;
pub const WM_RBUTTONDOWN = 0x0204;
pub const WM_RBUTTONUP = 0x0205;
pub const WM_MBUTTONDOWN = 0x0207;
pub const WM_MBUTTONUP = 0x0208;
pub const WM_MOUSEWHEEL = 0x020A;
pub const WM_MOUSEHWHEEL = 0x020E;
pub const WM_POWERBROADCAST = 0x0218;
pub const WM_DROPFILES = 0x0233;
pub const WM_MOUSELEAVE = 0x02A3;
pub const WM_DPICHANGED = 0x02E0;
pub const WM_APP = 0x8000;

pub const PBT_APMPOWERSTATUSCHANGE = 0x000A;
pub const PBT_APMSUSPEND = 0x0004;
pub const PBT_APMRESUMEAUTOMATIC = 0x0012;

pub const CS_VREDRAW = 0x0001;
pub const CS_HREDRAW = 0x0002;
pub const CS_OWNDC = 0x0020;
pub const WS_OVERLAPPEDWINDOW: DWORD = 0x00CF0000;
pub const WS_THICKFRAME: DWORD = 0x00040000;
pub const WS_MAXIMIZEBOX: DWORD = 0x00010000;
pub const CW_USEDEFAULT: c_int = @bitCast(@as(u32, 0x80000000));
pub const SW_SHOWNORMAL = 1;
pub const GWLP_USERDATA = -21;
pub const SWP_NOMOVE = 0x0002;
pub const SWP_NOZORDER = 0x0004;
pub const SWP_NOACTIVATE = 0x0010;
pub const HTCLIENT = 1;
pub const TME_LEAVE = 0x00000002;
pub const MK_LBUTTON = 0x0001;
pub const USER_DEFAULT_SCREEN_DPI = 96;
pub const DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2: isize = -4;

pub const CF_UNICODETEXT = 13;
pub const GMEM_MOVEABLE = 0x0002;

pub const CFS_FORCE_POSITION = 0x0020;
pub const CFS_EXCLUDE = 0x0080;
pub const IACE_DEFAULT = 0x0010;

pub const SPI_GETHIGHCONTRAST = 0x0042;
pub const SPI_GETCLIENTAREAANIMATION = 0x1042;
pub const HCF_HIGHCONTRASTON = 0x00000001;

pub const CTRL_C_EVENT = 0;
pub const CTRL_BREAK_EVENT = 1;
pub const CTRL_CLOSE_EVENT = 2;
pub const CTRL_LOGOFF_EVENT = 5;
pub const CTRL_SHUTDOWN_EVENT = 6;

pub const WAIT_OBJECT_0 = 0;
pub const WAIT_TIMEOUT = 258;
pub const INFINITE: DWORD = 0xFFFFFFFF;
pub const CREATE_WAITABLE_TIMER_HIGH_RESOLUTION = 0x00000002;
pub const TIMER_ALL_ACCESS = 0x001F0003;

pub const HKEY_CURRENT_USER: HKEY = @ptrFromInt(0x80000001);
pub const RRF_RT_REG_DWORD = 0x00000010;

pub const DWMWA_USE_IMMERSIVE_DARK_MODE = 20;
pub const DWMWA_SYSTEMBACKDROP_TYPE = 38;
pub const DWMSBT_MAINWINDOW = 2;
pub const DWMSBT_TRANSIENTWINDOW = 3;

pub const MARGINS = extern struct { left: c_int, right: c_int, top: c_int, bottom: c_int };

pub const IDC_ARROW = 32512;
pub const IDC_IBEAM = 32513;
pub const IDC_WAIT = 32514;
pub const IDC_CROSS = 32515;
pub const IDC_SIZENWSE = 32642;
pub const IDC_SIZENESW = 32643;
pub const IDC_SIZEWE = 32644;
pub const IDC_SIZENS = 32645;
pub const IDC_SIZEALL = 32646;
pub const IDC_NO = 32648;
pub const IDC_HAND = 32649;
pub const IDC_APPSTARTING = 32650;
pub const IDC_HELP = 32651;

pub extern "user32" fn RegisterClassExW(class: *const WNDCLASSEXW) callconv(.winapi) ATOM;
pub extern "user32" fn CreateWindowExW(ex_style: DWORD, class_name: [*:0]const u16, window_name: [*:0]const u16, style: DWORD, x: c_int, y: c_int, width: c_int, height: c_int, parent: ?HWND, menu: ?HMENU, instance: ?HINSTANCE, param: ?*anyopaque) callconv(.winapi) ?HWND;
pub extern "user32" fn DestroyWindow(hwnd: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn ShowWindow(hwnd: HWND, command: c_int) callconv(.winapi) BOOL;
pub extern "user32" fn DefWindowProcW(hwnd: HWND, message: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT;
pub extern "user32" fn GetMessageW(msg: *MSG, hwnd: ?HWND, filter_min: UINT, filter_max: UINT) callconv(.winapi) BOOL;
pub extern "user32" fn TranslateMessage(msg: *const MSG) callconv(.winapi) BOOL;
pub extern "user32" fn DispatchMessageW(msg: *const MSG) callconv(.winapi) LRESULT;
pub extern "user32" fn PostMessageW(hwnd: HWND, message: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) BOOL;
pub extern "user32" fn SendMessageW(hwnd: HWND, message: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT;
pub extern "user32" fn PostQuitMessage(exit_code: c_int) callconv(.winapi) void;
pub extern "user32" fn GetClientRect(hwnd: HWND, rect: *RECT) callconv(.winapi) BOOL;
pub extern "user32" fn SetWindowPos(hwnd: HWND, after: ?HWND, x: c_int, y: c_int, cx: c_int, cy: c_int, flags: UINT) callconv(.winapi) BOOL;
pub extern "user32" fn AdjustWindowRectExForDpi(rect: *RECT, style: DWORD, menu: BOOL, ex_style: DWORD, dpi: UINT) callconv(.winapi) BOOL;
pub extern "user32" fn GetDpiForWindow(hwnd: HWND) callconv(.winapi) UINT;
pub extern "user32" fn SetProcessDpiAwarenessContext(context: isize) callconv(.winapi) BOOL;
pub extern "user32" fn SetWindowLongPtrW(hwnd: HWND, index: c_int, value: isize) callconv(.winapi) isize;
pub extern "user32" fn GetWindowLongPtrW(hwnd: HWND, index: c_int) callconv(.winapi) isize;
pub extern "user32" fn LoadCursorW(instance: ?HINSTANCE, name: usize) callconv(.winapi) ?HCURSOR;
pub extern "user32" fn SetCursor(cursor: ?HCURSOR) callconv(.winapi) ?HCURSOR;
pub extern "user32" fn TrackMouseEvent(track: *TRACKMOUSEEVENT) callconv(.winapi) BOOL;
pub extern "user32" fn SetCapture(hwnd: HWND) callconv(.winapi) ?HWND;
pub extern "user32" fn ReleaseCapture() callconv(.winapi) BOOL;
pub extern "user32" fn GetKeyState(virtual_key: c_int) callconv(.winapi) i16;
pub extern "user32" fn ScreenToClient(hwnd: HWND, point: *POINT) callconv(.winapi) BOOL;
pub extern "user32" fn BeginPaint(hwnd: HWND, paint: *PAINTSTRUCT) callconv(.winapi) ?HDC;
pub extern "user32" fn EndPaint(hwnd: HWND, paint: *const PAINTSTRUCT) callconv(.winapi) BOOL;
pub extern "user32" fn FillRect(hdc: HDC, rect: *const RECT, brush: HBRUSH) callconv(.winapi) c_int;
pub extern "gdi32" fn GetStockObject(object: c_int) callconv(.winapi) ?HBRUSH;
pub extern "user32" fn OpenClipboard(owner: ?HWND) callconv(.winapi) BOOL;
pub extern "user32" fn CloseClipboard() callconv(.winapi) BOOL;
pub extern "user32" fn EmptyClipboard() callconv(.winapi) BOOL;
pub extern "user32" fn GetClipboardData(format: UINT) callconv(.winapi) ?HANDLE;
pub extern "user32" fn SetClipboardData(format: UINT, memory: ?HANDLE) callconv(.winapi) ?HANDLE;
pub extern "user32" fn SystemParametersInfoW(action: UINT, param: UINT, value: ?*anyopaque, win_ini: UINT) callconv(.winapi) BOOL;

pub extern "kernel32" fn GetModuleHandleW(name: ?[*:0]const u16) callconv(.winapi) ?HINSTANCE;
pub extern "kernel32" fn CreateEventW(attributes: ?*anyopaque, manual_reset: BOOL, initial_state: BOOL, name: ?[*:0]const u16) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn SetEvent(event: HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn ResetEvent(event: HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn WaitForSingleObject(handle: HANDLE, milliseconds: DWORD) callconv(.winapi) DWORD;
pub extern "kernel32" fn WaitForMultipleObjects(count: DWORD, handles: [*]const HANDLE, wait_all: BOOL, milliseconds: DWORD) callconv(.winapi) DWORD;
pub extern "kernel32" fn CloseHandle(handle: HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn CreateWaitableTimerExW(attributes: ?*anyopaque, name: ?[*:0]const u16, flags: DWORD, access: DWORD) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn SetWaitableTimer(timer: HANDLE, due_time: *const i64, period: LONG, routine: ?*anyopaque, argument: ?*anyopaque, resume_system: BOOL) callconv(.winapi) BOOL;
pub extern "kernel32" fn CancelWaitableTimer(timer: HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn SetConsoleCtrlHandler(handler: ?HANDLER_ROUTINE, add: BOOL) callconv(.winapi) BOOL;
pub extern "kernel32" fn GlobalAlloc(flags: UINT, bytes: usize) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn GlobalLock(memory: HANDLE) callconv(.winapi) ?*anyopaque;
pub extern "kernel32" fn GlobalUnlock(memory: HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn GlobalFree(memory: HANDLE) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn GlobalSize(memory: HANDLE) callconv(.winapi) usize;
pub extern "kernel32" fn CreateMemoryResourceNotification(kind: c_int) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn QueryMemoryResourceNotification(notification: HANDLE, state: *BOOL) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetSystemPowerStatus(status: *SYSTEM_POWER_STATUS) callconv(.winapi) BOOL;
pub extern "kernel32" fn AcquireSRWLockExclusive(lock: *SRWLOCK) callconv(.winapi) void;
pub extern "kernel32" fn ReleaseSRWLockExclusive(lock: *SRWLOCK) callconv(.winapi) void;
pub extern "kernel32" fn GetProcessTimes(process: HANDLE, creation: *u64, exit: *u64, kernel: *u64, user: *u64) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetCurrentProcess() callconv(.winapi) HANDLE;
pub extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: DWORD, share: DWORD, security: ?*anyopaque, disposition: DWORD, flags: DWORD, template: ?HANDLE) callconv(.winapi) HANDLE;
pub extern "kernel32" fn ReadDirectoryChangesW(directory: HANDLE, buffer: *anyopaque, buffer_bytes: DWORD, watch_subtree: BOOL, filter: DWORD, bytes_returned: ?*DWORD, overlapped: ?*OVERLAPPED, completion: ?*anyopaque) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetOverlappedResult(file: HANDLE, overlapped: *OVERLAPPED, bytes: *DWORD, wait: BOOL) callconv(.winapi) BOOL;
pub extern "kernel32" fn CancelIoEx(file: HANDLE, overlapped: ?*OVERLAPPED) callconv(.winapi) BOOL;

pub extern "shell32" fn DragAcceptFiles(hwnd: HWND, accept: BOOL) callconv(.winapi) void;
pub extern "shell32" fn DragQueryFileW(drop: HDROP, index: UINT, file: ?[*]u16, capacity: UINT) callconv(.winapi) UINT;
pub extern "shell32" fn DragQueryPoint(drop: HDROP, point: *POINT) callconv(.winapi) BOOL;
pub extern "shell32" fn DragFinish(drop: HDROP) callconv(.winapi) void;

pub extern "imm32" fn ImmGetContext(hwnd: HWND) callconv(.winapi) ?HIMC;
pub extern "imm32" fn ImmReleaseContext(hwnd: HWND, context: HIMC) callconv(.winapi) BOOL;
pub extern "imm32" fn ImmSetCompositionWindow(context: HIMC, form: *const COMPOSITIONFORM) callconv(.winapi) BOOL;
pub extern "imm32" fn ImmSetCandidateWindow(context: HIMC, form: *const CANDIDATEFORM) callconv(.winapi) BOOL;
pub extern "imm32" fn ImmAssociateContextEx(hwnd: HWND, context: ?HIMC, flags: DWORD) callconv(.winapi) BOOL;

pub extern "dwmapi" fn DwmExtendFrameIntoClientArea(hwnd: HWND, margins: *const MARGINS) callconv(.winapi) i32;
pub extern "dwmapi" fn DwmSetWindowAttribute(hwnd: HWND, attribute: DWORD, value: *const anyopaque, size: DWORD) callconv(.winapi) i32;

pub extern "advapi32" fn RegGetValueW(key: HKEY, sub_key: [*:0]const u16, value: [*:0]const u16, flags: DWORD, kind: ?*DWORD, data: ?*anyopaque, size: ?*DWORD) callconv(.winapi) LONG;

pub fn loword(value: anytype) u16 {
    return @truncate(@as(usize, @bitCast(value)));
}

pub fn hiword(value: anytype) u16 {
    return @truncate(@as(usize, @bitCast(value)) >> 16);
}

/// The signed x and y packed into a mouse message's `lParam`.
pub fn pointFromLparam(lparam: LPARAM) [2]i16 {
    return .{ @bitCast(loword(lparam)), @bitCast(hiword(lparam)) };
}

pub fn lparamFromPoint(x: i16, y: i16) LPARAM {
    const packed_point: u32 = @as(u32, @as(u16, @bitCast(y))) << 16 | @as(u16, @bitCast(x));
    return @bitCast(@as(usize, packed_point));
}

pub const OVERLAPPED = extern struct {
    Internal: usize = 0,
    InternalHigh: usize = 0,
    Offset: DWORD = 0,
    OffsetHigh: DWORD = 0,
    hEvent: ?HANDLE = null,
};

/// One entry of what `ReadDirectoryChangesW` writes; `FileName` runs on
/// for `FileNameLength` bytes.
pub const FILE_NOTIFY_INFORMATION = extern struct {
    NextEntryOffset: DWORD,
    Action: DWORD,
    FileNameLength: DWORD,
    FileName: [1]u16,
};

pub const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(~@as(usize, 0));
pub const FILE_LIST_DIRECTORY = 0x0001;
pub const FILE_SHARE_READ = 0x1;
pub const FILE_SHARE_WRITE = 0x2;
pub const FILE_SHARE_DELETE = 0x4;
pub const OPEN_EXISTING = 3;
pub const FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;
pub const FILE_FLAG_OVERLAPPED = 0x40000000;
pub const FILE_NOTIFY_CHANGE_FILE_NAME = 0x01;
pub const FILE_NOTIFY_CHANGE_DIR_NAME = 0x02;
pub const FILE_NOTIFY_CHANGE_SIZE = 0x08;
pub const FILE_NOTIFY_CHANGE_LAST_WRITE = 0x10;
pub const FILE_NOTIFY_CHANGE_CREATION = 0x40;
pub const FILE_ACTION_ADDED = 1;
pub const FILE_ACTION_REMOVED = 2;
pub const FILE_ACTION_MODIFIED = 3;
pub const FILE_ACTION_RENAMED_OLD_NAME = 4;
pub const FILE_ACTION_RENAMED_NEW_NAME = 5;
