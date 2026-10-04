#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "notifications.h"
#include "utils.h"

namespace {

// One Dismessage per session: a second copy would register the same ID and
// disconnect the first one (e.g. started at Windows startup).
constexpr const wchar_t kInstanceMutex[] = L"Local\\Dismessage.SingleInstance";

// Brings the already running window to the front.
void ActivateRunningInstance() {
  HWND window = ::FindWindow(L"FLUTTER_RUNNER_WIN32_WINDOW", L"Dismessage");
  if (window == nullptr) return;
  if (::IsIconic(window)) ::ShowWindow(window, SW_RESTORE);
  ::SetForegroundWindow(window);
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  HANDLE instance_mutex = nullptr;
#ifdef NDEBUG
  // Release only: a development build ("flutter run") may run next to the
  // installed app.
  instance_mutex = ::CreateMutex(nullptr, TRUE, kInstanceMutex);
  if (instance_mutex != nullptr && ::GetLastError() == ERROR_ALREADY_EXISTS) {
    ActivateRunningInstance();
    ::CloseHandle(instance_mutex);
    return EXIT_SUCCESS;
  }
#endif
  RegisterAppUserModelId();
  // "--minimized": launched at Windows startup, stay in the taskbar.
  const bool start_minimized =
      command_line != nullptr && ::wcsstr(command_line, L"--minimized");

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  window.SetStartMinimized(start_minimized);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"Dismessage", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  if (instance_mutex != nullptr) ::CloseHandle(instance_mutex);
  return EXIT_SUCCESS;
}
