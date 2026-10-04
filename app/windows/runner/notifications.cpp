#include "notifications.h"

#include <flutter/standard_method_codec.h>
#include <shobjidl.h>
#include <winrt/Windows.Data.Xml.Dom.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.UI.Notifications.h>

#include <optional>
#include <vector>

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;
namespace notif = winrt::Windows::UI::Notifications;

constexpr UINT kToastActivated = WM_APP + 0x41;
constexpr const wchar_t kGroup[] = L"chat";

// What the user did with a toast, posted from the WinRT thread.
struct ToastAction {
  std::string tag;
  std::optional<std::string> reply;
  // A button ("accept", "reject"…), and whether it brings the window up.
  std::optional<std::string> button;
  bool foreground = true;
};

// A notification button, as sent by Dart.
struct ToastButton {
  std::wstring id;
  std::wstring label;
  bool foreground = false;
};

std::wstring Widen(const std::string& text) {
  if (text.empty()) return {};
  const int size = ::MultiByteToWideChar(CP_UTF8, 0, text.data(),
                                         static_cast<int>(text.size()),
                                         nullptr, 0);
  std::wstring wide(size, L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, text.data(),
                        static_cast<int>(text.size()), wide.data(), size);
  return wide;
}

std::string Narrow(const std::wstring& text) {
  if (text.empty()) return {};
  const int size = ::WideCharToMultiByte(CP_UTF8, 0, text.data(),
                                         static_cast<int>(text.size()),
                                         nullptr, 0, nullptr, nullptr);
  std::string narrow(size, '\0');
  ::WideCharToMultiByte(CP_UTF8, 0, text.data(),
                        static_cast<int>(text.size()), narrow.data(), size,
                        nullptr, nullptr);
  return narrow;
}

std::wstring ExeDirectory() {
  wchar_t path[MAX_PATH];
  const DWORD length = ::GetModuleFileName(nullptr, path, MAX_PATH);
  std::wstring dir(path, length);
  return dir.substr(0, dir.find_last_of(L'\\'));
}

template <typename T>
std::optional<T> Arg(const EncodableMap& args, const char* key) {
  const auto it = args.find(EncodableValue(key));
  if (it == args.end()) return std::nullopt;
  if (const T* value = std::get_if<T>(&it->second)) return *value;
  return std::nullopt;
}

// Title and body are bound ({title}, {body}) so a typing update can change
// them in place, without popping the toast up again.
std::wstring ToastXml(bool alert, bool reply,
                      const std::vector<ToastButton>& buttons) {
  std::wstring xml =
      L"<toast launch=\"open\">"
      L"<visual><binding template=\"ToastGeneric\">"
      L"<text>{title}</text><text>{body}</text>"
      L"</binding></visual>";
  if (reply || !buttons.empty()) {
    xml += L"<actions>";
    if (reply) {
      xml +=
          L"<input id=\"reply\" type=\"text\" placeHolderContent=\"Répondre…\"/>"
          L"<action content=\"Envoyer\" arguments=\"reply\" hint-inputId=\"reply\"/>";
    }
    // Labels and ids come from the app itself (no markup to escape).
    for (const auto& button : buttons) {
      xml += L"<action content=\"" + button.label + L"\" arguments=\"button:" +
             (button.foreground ? L"1:" : L"0:") + button.id + L"\"/>";
    }
    xml += L"</actions>";
  }
  xml += alert ? L"<audio src=\"ms-winsoundevent:Notification.IM\"/>"
               : L"<audio silent=\"true\"/>";
  xml += L"</toast>";
  return xml;
}

}  // namespace

void RegisterAppUserModelId() {
  const std::wstring key =
      std::wstring(L"Software\\Classes\\AppUserModelId\\") + kAppUserModelId;
  HKEY handle;
  if (::RegCreateKeyEx(HKEY_CURRENT_USER, key.c_str(), 0, nullptr, 0,
                       KEY_SET_VALUE, nullptr, &handle, nullptr) !=
      ERROR_SUCCESS) {
    return;
  }
  const std::wstring name = L"Dismessage";
  const std::wstring icon = ExeDirectory() + L"\\app_icon.ico";
  ::RegSetValueEx(handle, L"DisplayName", 0, REG_SZ,
                  reinterpret_cast<const BYTE*>(name.c_str()),
                  static_cast<DWORD>((name.size() + 1) * sizeof(wchar_t)));
  ::RegSetValueEx(handle, L"IconUri", 0, REG_SZ,
                  reinterpret_cast<const BYTE*>(icon.c_str()),
                  static_cast<DWORD>((icon.size() + 1) * sizeof(wchar_t)));
  ::RegCloseKey(handle);
  ::SetCurrentProcessExplicitAppUserModelID(kAppUserModelId);
}

struct Notifications::Impl {
  HWND window;
  std::unique_ptr<flutter::MethodChannel<EncodableValue>> channel;
  notif::ToastNotifier notifier{nullptr};
  // Shown toasts, kept alive so their click handler stays registered.
  std::map<std::wstring, notif::ToastNotification> toasts;
  uint32_t sequence = 0;

  notif::ToastNotifier& Notifier() {
    if (!notifier) {
      notifier =
          notif::ToastNotificationManager::CreateToastNotifier(kAppUserModelId);
    }
    return notifier;
  }

  void OnCall(const flutter::MethodCall<EncodableValue>& call,
              std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
    const auto* args = std::get_if<EncodableMap>(call.arguments());
    try {
      if (call.method_name() == "requestPermission") {
        // Windows asks nothing: tell whether notifications are on.
        result->Success(EncodableValue(Notifier().Setting() ==
                                       notif::NotificationSetting::Enabled));
      } else if (call.method_name() == "show" && args) {
        std::vector<ToastButton> buttons;
        if (auto list = Arg<flutter::EncodableList>(*args, "actions")) {
          for (const auto& item : *list) {
            const auto* map = std::get_if<EncodableMap>(&item);
            if (!map) continue;
            buttons.push_back(
                {Widen(Arg<std::string>(*map, "id").value_or("")),
                 Widen(Arg<std::string>(*map, "label").value_or("")),
                 Arg<bool>(*map, "foreground").value_or(false)});
          }
        }
        Show(Widen(Arg<std::string>(*args, "tag").value_or("")),
             Widen(Arg<std::string>(*args, "title").value_or("")),
             Widen(Arg<std::string>(*args, "body").value_or("")),
             Arg<bool>(*args, "alert").value_or(true),
             Arg<bool>(*args, "reply").value_or(false), buttons);
        result->Success();
      } else if (call.method_name() == "cancel" && args) {
        Cancel(Widen(Arg<std::string>(*args, "tag").value_or("")));
        result->Success();
      } else {
        result->NotImplemented();
      }
    } catch (const winrt::hresult_error& e) {
      result->Error("notify", Narrow(std::wstring(e.message())));
    }
  }

  void Show(const std::wstring& tag, const std::wstring& title,
            const std::wstring& body, bool alert, bool reply,
            const std::vector<ToastButton>& buttons) {
    notif::NotificationData data;
    data.Values().Insert(L"title", title);
    data.Values().Insert(L"body", body);
    data.SequenceNumber(++sequence);

    // Silent update of a toast still shown: change its text in place.
    if (!alert && toasts.count(tag) &&
        Notifier().Update(data, tag, kGroup) ==
            notif::NotificationUpdateResult::Succeeded) {
      return;
    }

    winrt::Windows::Data::Xml::Dom::XmlDocument xml;
    xml.LoadXml(ToastXml(alert, reply, buttons));
    notif::ToastNotification toast(xml);
    toast.Tag(tag);
    toast.Group(kGroup);
    toast.Data(data);
    toast.SuppressPopup(!alert);

    const HWND target = window;
    const std::string narrow_tag = Narrow(tag);
    toast.Activated([target, narrow_tag](
                        const notif::ToastNotification&,
                        const winrt::Windows::Foundation::IInspectable& args) {
      auto action = std::make_unique<ToastAction>();
      action->tag = narrow_tag;
      if (auto activated = args.try_as<notif::ToastActivatedEventArgs>()) {
        const std::wstring arguments(activated.Arguments());
        // "button:<1|0>:<id>", 1 when the button brings the window up.
        if (arguments.rfind(L"button:", 0) == 0 && arguments.size() > 9) {
          action->foreground = arguments[7] == L'1';
          action->button = Narrow(arguments.substr(9));
        }
        if (arguments == L"reply") {
          const auto input = activated.UserInput();
          if (input && input.HasKey(L"reply")) {
            action->reply = Narrow(std::wstring(
                winrt::unbox_value_or<winrt::hstring>(input.Lookup(L"reply"),
                                                      L"")));
          }
        }
      }
      // Back to the UI thread, where Flutter's channel lives.
      if (::PostMessage(target, kToastActivated, 0,
                        reinterpret_cast<LPARAM>(action.get()))) {
        action.release();
      }
    });

    Cancel(tag);
    Notifier().Show(toast);
    toasts.insert_or_assign(tag, toast);
  }

  void Cancel(const std::wstring& tag) {
    const auto it = toasts.find(tag);
    if (it == toasts.end()) return;
    try {
      notif::ToastNotificationManager::History().Remove(tag, kGroup,
                                                        kAppUserModelId);
    } catch (const winrt::hresult_error&) {
      // Already dismissed by the user.
    }
    toasts.erase(it);
  }

  void BringToFront() {
    if (::IsIconic(window)) ::ShowWindow(window, SW_RESTORE);
    ::SetForegroundWindow(window);
  }
};

Notifications::Notifications(flutter::BinaryMessenger* messenger, HWND window)
    : impl_(std::make_unique<Impl>()) {
  impl_->window = window;
  impl_->channel = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "dismessage/notify",
      &flutter::StandardMethodCodec::GetInstance());
  Impl* impl = impl_.get();
  impl_->channel->SetMethodCallHandler(
      [impl](const auto& call, auto result) {
        impl->OnCall(call, std::move(result));
      });
}

Notifications::~Notifications() {
  for (const auto& [tag, toast] : impl_->toasts) {
    try {
      notif::ToastNotificationManager::History().Remove(tag, kGroup,
                                                        kAppUserModelId);
    } catch (const winrt::hresult_error&) {
    }
  }
}

bool Notifications::HandleWindowMessage(UINT message, LPARAM lparam) {
  if (message != kToastActivated) return false;
  std::unique_ptr<ToastAction> action(reinterpret_cast<ToastAction*>(lparam));
  EncodableMap args{{EncodableValue("tag"), EncodableValue(action->tag)}};
  if (action->button) {
    args[EncodableValue("action")] = EncodableValue(*action->button);
    if (action->foreground) impl_->BringToFront();
    impl_->channel->InvokeMethod("onAction",
                                 std::make_unique<EncodableValue>(args));
  } else if (action->reply && !action->reply->empty()) {
    args[EncodableValue("text")] = EncodableValue(*action->reply);
    impl_->channel->InvokeMethod("onReply",
                                 std::make_unique<EncodableValue>(args));
  } else {
    impl_->BringToFront();
    impl_->channel->InvokeMethod("onOpen",
                                 std::make_unique<EncodableValue>(args));
  }
  return true;
}
