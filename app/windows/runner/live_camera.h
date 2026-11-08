#ifndef RUNNER_LIVE_CAMERA_H_
#define RUNNER_LIVE_CAMERA_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/method_result.h>
#include <windows.h>

#include <memory>
#include <string>

// The webcam as a source of frames for the live camera view
// ("dismessage/camera" channel, LiveCamera in Dart): JPEG (WIC), or H.264
// (video_codec.h) when both sides can. Media Foundation reads it on a thread
// of its own; only a frame that was asked for is encoded, the next one to
// come, so that a slow network costs no CPU and the camera sets the pace. The
// video encoder only sees the images that leave: one skipped never breaks the
// stream.
class LiveCamera {
 public:
  LiveCamera(flutter::BinaryMessenger* messenger, HWND window);
  ~LiveCamera();

  // Returns true when [message] was the thread's answer.
  bool HandleWindowMessage(UINT message);

  // What the camera's thread shares with the platform thread.
  struct Worker;

 private:
  using Result = flutter::MethodResult<flutter::EncodableValue>;

  // [device]: the camera chosen in the settings, empty for the first one.
  void Open(int side, std::string device, std::unique_ptr<Result> result);
  void RequestFrame(const struct Wanted& wanted,
                    std::unique_ptr<Result> result);
  // Never waits for the thread: a camera that delivers nothing would freeze
  // the app. The thread ends by itself.
  void Close();

  HWND window_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::shared_ptr<Worker> worker_;
  std::unique_ptr<Result> open_result_;
  std::unique_ptr<Result> frame_result_;
};

#endif  // RUNNER_LIVE_CAMERA_H_
