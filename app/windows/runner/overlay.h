#ifndef RUNNER_OVERLAY_H_
#define RUNNER_OVERLAY_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <memory>
#include <vector>

// The overlay panel ("dismessage/overlay" channel, DesktopOverlay in Dart):
// the window becomes a translucent, borderless, always-on-top panel, a third
// of the screen wide and two lines high (more for a long text), near the top,
// that mouse clicks go through. It keeps the keyboard while it is the active
// window.
//
// Ctrl+Alt+D, anywhere, is sent to Dart (enter or leave the panel); after a
// click behind the panel, it first gives the panel the keyboard back.
//
// The same channel puts the window in full screen, for the peer's camera.
class Overlay {
 public:
  Overlay(flutter::BinaryMessenger* messenger, HWND window);
  ~Overlay();

  // Returns true when [message] was for the panel (shortcuts, its timer).
  bool HandleWindowMessage(UINT message, WPARAM wparam);

 private:
  // [height] and [margin] (from the top of the screen) in logical pixels.
  void Enter(double height, double margin);
  // Grows or shrinks the panel to [height] logical pixels (a long text
  // wraps), from the top.
  void Resize(double height);
  // Shows the panel as Flutter drew it (premultiplied RGBA): the window
  // draws per-pixel alpha this way, its translucent ground fading out on
  // the sides, while clicks still go through.
  void ShowFrame(int width, int height, const std::vector<uint8_t>& rgba);
  void Exit();
  // The panel shows a camera in its top left corner, of this logical size
  // (0: none): clicks there reach the panel, and Ctrl+Alt+F works.
  void SetLiveView(double width, double height);
  // While the mouse is over the camera, clicks stop going through.
  void UpdateClickThrough();
  void SetClickThrough(bool through);
  void SetFullscreen(bool on);
  // This window in front, and the keyboard in Flutter's view.
  void TakeKeyboard();
  void ReleaseFrameBitmap();

  HWND window_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  bool hotkey_ = false;
  bool active_ = false;

  double live_width_ = 0;
  double live_height_ = 0;
  bool live_hotkey_ = false;

  // The normal window, restored on exit.
  WINDOWPLACEMENT placement_ = {};
  LONG_PTR style_ = 0;
  LONG_PTR ex_style_ = 0;

  bool fullscreen_ = false;
  WINDOWPLACEMENT fullscreen_placement_ = {};
  LONG_PTR fullscreen_style_ = 0;

  // Kept between frames: creating them at each frame costs more than filling
  // them.
  HDC frame_dc_ = nullptr;
  HBITMAP frame_bitmap_ = nullptr;
  void* frame_bits_ = nullptr;
  int frame_width_ = 0;
  int frame_height_ = 0;
};

#endif  // RUNNER_OVERLAY_H_
