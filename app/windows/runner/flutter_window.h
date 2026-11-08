#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>

#include <memory>

#include "clipboard.h"
#include "live_camera.h"
#include "live_video.h"
#include "notifications.h"
#include "overlay.h"
#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // Message and typing toasts ("dismessage/notify" channel).
  std::unique_ptr<Notifications> notifications_;

  // Pictures pasted with Ctrl+V ("dismessage/clipboard" channel).
  std::unique_ptr<ClipboardImages> clipboard_;

  // The overlay panel and its shortcut ("dismessage/overlay" channel).
  std::unique_ptr<Overlay> overlay_;

  // The webcam for the live view ("dismessage/camera" channel).
  std::unique_ptr<LiveCamera> live_camera_;

  // Decoders of the peer's live video ("dismessage/video" channel).
  std::unique_ptr<LiveVideo> live_video_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
