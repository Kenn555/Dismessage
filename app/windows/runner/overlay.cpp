#include "overlay.h"

#include <flutter/standard_method_codec.h>
#include <flutter_windows.h>

#include <algorithm>
#include <cmath>
#include <cstring>

#include "utils.h"

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;

constexpr int kHotkeyId = 0x4453;  // "DS"
constexpr int kFullscreenHotkeyId = 0x4454;
constexpr UINT_PTR kClickThroughTimer = 0x4455;
constexpr UINT kClickThroughTimerMs = 50;

// A number sent by Dart, or [fallback].
double Number(const EncodableMap& args, const char* key, double fallback) {
  const auto it = args.find(EncodableValue(key));
  if (it == args.end()) return fallback;
  if (const auto* value = std::get_if<double>(&it->second)) return *value;
  if (const auto* value = std::get_if<int32_t>(&it->second)) return *value;
  return fallback;
}

}  // namespace

Overlay::Overlay(flutter::BinaryMessenger* messenger, HWND window)
    : window_(window),
      channel_(std::make_unique<flutter::MethodChannel<EncodableValue>>(
          messenger, "dismessage/overlay",
          &flutter::StandardMethodCodec::GetInstance())) {
  // Taken by another app: the header button still works.
  hotkey_ = ::RegisterHotKey(window_, kHotkeyId,
                             MOD_CONTROL | MOD_ALT | MOD_NOREPEAT, 'D');
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    const auto* args = std::get_if<EncodableMap>(call.arguments());
    if (call.method_name() == "enter") {
      // DesktopOverlay.panelHeight and panelMargin.
      Enter(args ? Number(*args, "height", 64) : 64,
            args ? Number(*args, "margin", 12) : 12);
      result->Success();
    } else if (call.method_name() == "resize" && args) {
      Resize(Number(*args, "height", 64));
      result->Success();
    } else if (call.method_name() == "frame" && args) {
      const auto it = args->find(EncodableValue("pixels"));
      const auto* pixels =
          it == args->end() ? nullptr
                            : std::get_if<std::vector<uint8_t>>(&it->second);
      if (pixels) {
        ShowFrame(static_cast<int>(Number(*args, "width", 0)),
                  static_cast<int>(Number(*args, "height", 0)), *pixels);
      }
      result->Success();
    } else if (call.method_name() == "exit") {
      Exit();
      result->Success();
    } else if (call.method_name() == "liveView" && args) {
      SetLiveView(Number(*args, "width", 0), Number(*args, "height", 0));
      result->Success();
    } else if (call.method_name() == "fullscreen" && args) {
      SetFullscreen(Number(*args, "on", 0) != 0);
      result->Success();
    } else {
      result->NotImplemented();
    }
  });
}

Overlay::~Overlay() {
  channel_->SetMethodCallHandler(nullptr);
  if (hotkey_) ::UnregisterHotKey(window_, kHotkeyId);
  SetLiveView(0, 0);
  ReleaseFrameBitmap();
}

bool Overlay::HandleWindowMessage(UINT message, WPARAM wparam) {
  if (message == WM_TIMER && wparam == kClickThroughTimer) {
    UpdateClickThrough();
    return true;
  }
  if (message != WM_HOTKEY) return false;
  if (wparam == kFullscreenHotkeyId) {
    channel_->InvokeMethod("fullscreen", nullptr);
    return true;
  }
  if (wparam != kHotkeyId) return false;
  // The shortcut lets this app take the foreground.
  if (::GetForegroundWindow() != window_) {
    if (::IsIconic(window_)) ::ShowWindow(window_, SW_RESTORE);
    TakeKeyboard();
    // A click behind the panel took the keyboard: give it back.
    if (active_) return true;
  } else if (active_) {
    TakeKeyboard();
  }
  channel_->InvokeMethod("hotkey", nullptr);
  return true;
}

void Overlay::TakeKeyboard() {
  // Windows may refuse the foreground to a window asking for it on its own:
  // what is typed would go to the other app. Sharing the input of the window
  // in front lets it through; this only runs on the user's own action.
  HWND foreground = ::GetForegroundWindow();
  if (foreground != window_) {
    const DWORD theirs = ::GetWindowThreadProcessId(foreground, nullptr);
    const DWORD mine = ::GetCurrentThreadId();
    const bool attached = theirs != 0 && theirs != mine &&
                          ::AttachThreadInput(mine, theirs, TRUE);
    ::BringWindowToTop(window_);
    ::SetForegroundWindow(window_);
    if (attached) ::AttachThreadInput(mine, theirs, FALSE);
  }
  // Changing the window's styles can leave the keyboard on the window itself:
  // Flutter's view would no longer receive what is typed.
  if (HWND view = ::GetWindow(window_, GW_CHILD)) ::SetFocus(view);
}

void Overlay::Enter(double height, double margin) {
  if (active_) {
    TakeKeyboard();
    return;
  }
  placement_.length = sizeof(placement_);
  ::GetWindowPlacement(window_, &placement_);
  style_ = ::GetWindowLongPtr(window_, GWL_STYLE);
  ex_style_ = ::GetWindowLongPtr(window_, GWL_EXSTYLE);
  active_ = true;
  if (::IsIconic(window_) || ::IsZoomed(window_)) {
    ::ShowWindow(window_, SW_RESTORE);
  }

  ::SetWindowLongPtr(window_, GWL_STYLE,
                     (style_ & ~WS_OVERLAPPEDWINDOW) | WS_POPUP);
  // Layered + transparent: the mouse reaches the windows behind. Its
  // pixels come from ShowFrame (nothing shows until the first one).
  ::SetWindowLongPtr(window_, GWL_EXSTYLE,
                     ex_style_ | WS_EX_LAYERED | WS_EX_TRANSPARENT |
                         WS_EX_TOPMOST);

  // A third of the screen wide, [height] logical pixels high (the panel's
  // two lines), centered, [margin] below the top of the screen.
  HMONITOR screen = ::MonitorFromWindow(window_, MONITOR_DEFAULTTONEAREST);
  MONITORINFO monitor = {sizeof(monitor)};
  ::GetMonitorInfo(screen, &monitor);
  const RECT& work = monitor.rcWork;
  const double scale = FlutterDesktopGetDpiForMonitor(screen) / 96.0;
  const int width = (work.right - work.left) / 3;
  ::SetWindowPos(window_, HWND_TOPMOST,
                 work.left + (work.right - work.left - width) / 2,
                 work.top + static_cast<int>(std::lround(margin * scale)),
                 width, static_cast<int>(std::lround(height * scale)),
                 SWP_FRAMECHANGED | SWP_SHOWWINDOW);
  // The panel stays out of screenshots, like the window.
  ExcludeFromCapture(window_);
  TakeKeyboard();
}

void Overlay::Exit() {
  if (!active_) return;
  active_ = false;
  SetLiveView(0, 0);
  ReleaseFrameBitmap();
  ::SetWindowLongPtr(window_, GWL_EXSTYLE, ex_style_);
  ::SetWindowLongPtr(window_, GWL_STYLE, style_);
  ::SetWindowPos(window_, HWND_NOTOPMOST, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_FRAMECHANGED);
  // Back as it was, but on screen even if it was minimized.
  if (placement_.showCmd == SW_SHOWMINIMIZED ||
      placement_.showCmd == SW_MINIMIZE) {
    placement_.showCmd = SW_SHOWNORMAL;
  }
  ::SetWindowPlacement(window_, &placement_);
  ::RedrawWindow(window_, nullptr, nullptr,
                 RDW_INVALIDATE | RDW_FRAME | RDW_ALLCHILDREN);
  ExcludeFromCapture(window_);
  TakeKeyboard();
}

void Overlay::SetLiveView(double width, double height) {
  const bool on = width > 0 && height > 0;
  const bool was_on = live_width_ > 0;
  live_width_ = on ? width : 0;
  live_height_ = on ? height : 0;
  if (on == was_on) return;
  if (on) {
    // Only while a camera shows: the combination stays free for other apps.
    live_hotkey_ = ::RegisterHotKey(window_, kFullscreenHotkeyId,
                                    MOD_CONTROL | MOD_ALT | MOD_NOREPEAT, 'F');
    ::SetTimer(window_, kClickThroughTimer, kClickThroughTimerMs, nullptr);
  } else {
    if (live_hotkey_) ::UnregisterHotKey(window_, kFullscreenHotkeyId);
    live_hotkey_ = false;
    ::KillTimer(window_, kClickThroughTimer);
    if (active_) SetClickThrough(true);
  }
}

void Overlay::UpdateClickThrough() {
  if (!active_ || live_width_ <= 0) return;
  POINT cursor;
  RECT rect;
  if (!::GetCursorPos(&cursor) || !::GetWindowRect(window_, &rect)) return;
  HMONITOR screen = ::MonitorFromWindow(window_, MONITOR_DEFAULTTONEAREST);
  const double scale = FlutterDesktopGetDpiForMonitor(screen) / 96.0;
  const RECT view = {rect.left, rect.top,
                     rect.left + static_cast<LONG>(live_width_ * scale),
                     rect.top + static_cast<LONG>(live_height_ * scale)};
  SetClickThrough(!::PtInRect(&view, cursor));
}

void Overlay::SetClickThrough(bool through) {
  const LONG_PTR ex = ::GetWindowLongPtr(window_, GWL_EXSTYLE);
  const LONG_PTR next =
      through ? ex | WS_EX_TRANSPARENT : ex & ~static_cast<LONG_PTR>(WS_EX_TRANSPARENT);
  if (next != ex) ::SetWindowLongPtr(window_, GWL_EXSTYLE, next);
}

void Overlay::SetFullscreen(bool on) {
  if (on == fullscreen_ || active_) return;
  fullscreen_ = on;
  if (on) {
    fullscreen_placement_.length = sizeof(fullscreen_placement_);
    ::GetWindowPlacement(window_, &fullscreen_placement_);
    fullscreen_style_ = ::GetWindowLongPtr(window_, GWL_STYLE);
    if (::IsIconic(window_)) ::ShowWindow(window_, SW_RESTORE);
    ::SetWindowLongPtr(window_, GWL_STYLE,
                       (fullscreen_style_ & ~WS_OVERLAPPEDWINDOW) | WS_POPUP);
    HMONITOR screen = ::MonitorFromWindow(window_, MONITOR_DEFAULTTONEAREST);
    MONITORINFO monitor = {sizeof(monitor)};
    ::GetMonitorInfo(screen, &monitor);
    const RECT& area = monitor.rcMonitor;
    ::SetWindowPos(window_, HWND_TOP, area.left, area.top,
                   area.right - area.left, area.bottom - area.top,
                   SWP_FRAMECHANGED | SWP_SHOWWINDOW);
  } else {
    ::SetWindowLongPtr(window_, GWL_STYLE, fullscreen_style_);
    ::SetWindowPos(window_, nullptr, 0, 0, 0, 0,
                   SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_FRAMECHANGED);
    ::SetWindowPlacement(window_, &fullscreen_placement_);
  }
  ExcludeFromCapture(window_);
  TakeKeyboard();
}

void Overlay::ReleaseFrameBitmap() {
  if (frame_bitmap_ != nullptr) ::DeleteObject(frame_bitmap_);
  if (frame_dc_ != nullptr) ::DeleteDC(frame_dc_);
  frame_bitmap_ = nullptr;
  frame_dc_ = nullptr;
  frame_bits_ = nullptr;
  frame_width_ = 0;
  frame_height_ = 0;
}

void Overlay::Resize(double height) {
  if (!active_) return;
  RECT rect;
  ::GetWindowRect(window_, &rect);
  HMONITOR screen = ::MonitorFromWindow(window_, MONITOR_DEFAULTTONEAREST);
  const double scale = FlutterDesktopGetDpiForMonitor(screen) / 96.0;
  ::SetWindowPos(window_, nullptr, 0, 0, rect.right - rect.left,
                 static_cast<int>(std::lround(height * scale)),
                 SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
}

void Overlay::ShowFrame(int width, int height,
                        const std::vector<uint8_t>& rgba) {
  if (!active_ || width <= 0 || height <= 0 ||
      rgba.size() < static_cast<size_t>(width) * height * 4) {
    return;
  }
  // The frame is drawn at the window's size: UpdateLayeredWindow would
  // otherwise resize the window to the frame. A frame captured before a
  // Resize (still on its way) would then shrink the window back and cut
  // the text. So the window keeps its size; the frame is cropped or padded
  // with transparency, and the next one fits.
  RECT rect;
  ::GetWindowRect(window_, &rect);
  const int window_width = rect.right - rect.left;
  const int window_height = rect.bottom - rect.top;
  if (window_width <= 0 || window_height <= 0) return;
  HDC screen = ::GetDC(nullptr);
  if (window_width != frame_width_ || window_height != frame_height_ ||
      frame_bitmap_ == nullptr) {
    ReleaseFrameBitmap();
    BITMAPINFO info = {};
    info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    info.bmiHeader.biWidth = window_width;
    info.bmiHeader.biHeight = -window_height;  // Top-down, like Flutter's rows.
    info.bmiHeader.biPlanes = 1;
    info.bmiHeader.biBitCount = 32;
    info.bmiHeader.biCompression = BI_RGB;
    frame_dc_ = ::CreateCompatibleDC(screen);
    frame_bitmap_ = ::CreateDIBSection(frame_dc_, &info, DIB_RGB_COLORS,
                                       &frame_bits_, nullptr, 0);
    if (frame_bitmap_ == nullptr) {
      ReleaseFrameBitmap();
      ::ReleaseDC(nullptr, screen);
      return;
    }
    ::SelectObject(frame_dc_, frame_bitmap_);
    frame_width_ = window_width;
    frame_height_ = window_height;
  }
  // Flutter gives premultiplied RGBA; Windows wants premultiplied BGRA.
  auto* out = static_cast<uint8_t*>(frame_bits_);
  std::memset(out, 0, static_cast<size_t>(window_width) * window_height * 4);
  const int rows = (std::min)(height, window_height);
  const int columns = (std::min)(width, window_width);
  for (int y = 0; y < rows; y++) {
    const uint8_t* in = &rgba[static_cast<size_t>(y) * width * 4];
    uint8_t* row = out + static_cast<size_t>(y) * window_width * 4;
    for (int x = 0; x < columns; x++) {
      row[x * 4] = in[x * 4 + 2];
      row[x * 4 + 1] = in[x * 4 + 1];
      row[x * 4 + 2] = in[x * 4];
      row[x * 4 + 3] = in[x * 4 + 3];
    }
  }
  ::GdiFlush();
  POINT position = {rect.left, rect.top};
  SIZE size = {window_width, window_height};
  POINT origin = {0, 0};
  BLENDFUNCTION blend = {AC_SRC_OVER, 0, 255, AC_SRC_ALPHA};
  ::UpdateLayeredWindow(window_, screen, &position, &size, frame_dc_, &origin,
                        0, &blend, ULW_ALPHA);
  ::ReleaseDC(nullptr, screen);
}
