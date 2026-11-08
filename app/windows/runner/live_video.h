#ifndef RUNNER_LIVE_VIDEO_H_
#define RUNNER_LIVE_VIDEO_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/method_result.h>
#include <flutter_texture_registrar.h>
#include <windows.h>

#include <map>
#include <memory>

// Decodes the peer's live video ("dismessage/video" channel, LiveVideoCodecs
// in Dart): one H.264 decoder per view, each on a thread of its own, drawing
// into a Flutter texture. The image never goes through Dart: handing 1280 ×
// 720 RGBA pixels to Dart and making an image of them took 30 ms, more than
// decoding itself. Dart sends one access unit at a time and waits for its
// answer (the size of the image).
class LiveVideo {
 public:
  LiveVideo(flutter::BinaryMessenger* messenger,
            FlutterDesktopTextureRegistrarRef textures, HWND window);
  ~LiveVideo();

  // Returns true when [message] was a decoder's answer.
  bool HandleWindowMessage(UINT message);

  // What a decoder's thread shares with the platform thread.
  struct Decoding;

 private:
  using Result = flutter::MethodResult<flutter::EncodableValue>;

  void Close(int id);

  HWND window_;
  FlutterDesktopTextureRegistrarRef textures_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::map<int, std::shared_ptr<Decoding>> decoders_;
  std::map<int, std::unique_ptr<Result>> waiting_;
  int next_id_ = 1;
};

#endif  // RUNNER_LIVE_VIDEO_H_
