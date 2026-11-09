#ifndef RUNNER_LIVE_AUDIO_H_
#define RUNNER_LIVE_AUDIO_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <map>
#include <memory>

// Plays the peer's sound in a live view ("dismessage/audio" channel,
// ChannelLiveSpeaker in Dart): 16-bit mono PCM chunks, each queued after the
// previous one on the default output (waveOut, which resamples). The playout
// buffer is Dart's (LiveAudioJitter): what comes is played. The microphone
// goes through the `record_windows` plugin.
class LiveAudio {
 public:
  explicit LiveAudio(flutter::BinaryMessenger* messenger);
  ~LiveAudio();

  struct Speaker;

 private:
  void Close(int id);

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::map<int, std::unique_ptr<Speaker>> speakers_;
  int next_id_ = 1;
};

#endif  // RUNNER_LIVE_AUDIO_H_
