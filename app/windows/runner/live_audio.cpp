#include "live_audio.h"

#include <flutter/standard_method_codec.h>
#include <mmsystem.h>

#include <cstdint>
#include <deque>
#include <string>
#include <variant>
#include <vector>

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;

const EncodableValue* Argument(const EncodableValue* arguments,
                               const char* key) {
  const auto* map = std::get_if<EncodableMap>(arguments);
  if (map == nullptr) return nullptr;
  const auto it = map->find(EncodableValue(key));
  return it == map->end() ? nullptr : &it->second;
}

int IntArgument(const EncodableValue* arguments, const char* key) {
  const auto* value = Argument(arguments, key);
  if (value == nullptr) return 0;
  if (const auto* number = std::get_if<int32_t>(value)) return *number;
  return 0;
}

// One chunk handed to waveOut, with the bytes it plays.
struct Chunk {
  WAVEHDR header = {};
  std::vector<uint8_t> bytes;
};

}  // namespace

struct LiveAudio::Speaker {
  HWAVEOUT handle = nullptr;
  std::deque<std::unique_ptr<Chunk>> playing;

  ~Speaker() {
    if (handle == nullptr) return;
    waveOutReset(handle);
    for (auto& chunk : playing) {
      waveOutUnprepareHeader(handle, &chunk->header, sizeof(WAVEHDR));
    }
    playing.clear();
    waveOutClose(handle);
  }

  // Chunks played to the end give their memory back.
  void Release() {
    while (!playing.empty() &&
           (playing.front()->header.dwFlags & WHDR_DONE) != 0) {
      waveOutUnprepareHeader(handle, &playing.front()->header,
                             sizeof(WAVEHDR));
      playing.pop_front();
    }
  }

  bool Play(const std::vector<uint8_t>& pcm) {
    Release();
    auto chunk = std::make_unique<Chunk>();
    chunk->bytes = pcm;
    chunk->header.lpData = reinterpret_cast<LPSTR>(chunk->bytes.data());
    chunk->header.dwBufferLength = static_cast<DWORD>(chunk->bytes.size());
    if (waveOutPrepareHeader(handle, &chunk->header, sizeof(WAVEHDR)) !=
        MMSYSERR_NOERROR) {
      return false;
    }
    if (waveOutWrite(handle, &chunk->header, sizeof(WAVEHDR)) !=
        MMSYSERR_NOERROR) {
      waveOutUnprepareHeader(handle, &chunk->header, sizeof(WAVEHDR));
      return false;
    }
    playing.push_back(std::move(chunk));
    return true;
  }
};

LiveAudio::LiveAudio(flutter::BinaryMessenger* messenger) {
  channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "dismessage/audio",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    const auto& method = call.method_name();
    const auto* arguments = call.arguments();
    if (method == "speakerOpen") {
      const int rate = IntArgument(arguments, "rate");
      if (rate < 8000 || rate > 48000) {
        result->Error("bad_rate", "rate");
        return;
      }
      WAVEFORMATEX format = {};
      format.wFormatTag = WAVE_FORMAT_PCM;
      format.nChannels = 1;
      format.nSamplesPerSec = static_cast<DWORD>(rate);
      format.wBitsPerSample = 16;
      format.nBlockAlign = 2;
      format.nAvgBytesPerSec = format.nSamplesPerSec * format.nBlockAlign;
      auto speaker = std::make_unique<Speaker>();
      if (waveOutOpen(&speaker->handle, WAVE_MAPPER, &format, 0, 0,
                      CALLBACK_NULL) != MMSYSERR_NOERROR) {
        speaker->handle = nullptr;
        result->Error("no_output", "no_output");
        return;
      }
      const int id = next_id_++;
      speakers_[id] = std::move(speaker);
      result->Success(EncodableValue(id));
    } else if (method == "speakerPlay") {
      const auto it = speakers_.find(IntArgument(arguments, "id"));
      const auto* pcm = Argument(arguments, "pcm");
      const auto* bytes =
          pcm == nullptr ? nullptr : std::get_if<std::vector<uint8_t>>(pcm);
      if (it == speakers_.end() || bytes == nullptr) {
        result->Success();
        return;
      }
      if (!it->second->Play(*bytes)) {
        result->Error("play", "play");
        return;
      }
      result->Success();
    } else if (method == "speakerClose") {
      Close(IntArgument(arguments, "id"));
      result->Success();
    } else {
      result->NotImplemented();
    }
  });
}

LiveAudio::~LiveAudio() {
  channel_->SetMethodCallHandler(nullptr);
  speakers_.clear();
}

void LiveAudio::Close(int id) { speakers_.erase(id); }
