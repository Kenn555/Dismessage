#ifndef RUNNER_NOTIFICATIONS_H_
#define RUNNER_NOTIFICATIONS_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <map>
#include <memory>
#include <string>

// Identifies Dismessage to Windows for notifications (also set on the Start
// menu shortcut by the installer). Never change it.
constexpr const wchar_t kAppUserModelId[] = L"Dismessage.Desktop";

// Registers the identity above for the current user (no admin needed), so
// notifications show even without the installer's shortcut.
void RegisterAppUserModelId();

// Conversation toasts with a reply field, over the "dismessage/notify"
// channel (same protocol as Android's NotificationHandler.kt).
class Notifications {
 public:
  Notifications(flutter::BinaryMessenger* messenger, HWND window);
  ~Notifications();

  // Toast clicks arrive on a background thread and are posted to the window
  // as this message; returns true when it was one.
  bool HandleWindowMessage(UINT message, LPARAM lparam);

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

#endif  // RUNNER_NOTIFICATIONS_H_
