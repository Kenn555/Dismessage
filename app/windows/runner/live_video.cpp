#include "live_video.h"

#include <flutter/standard_method_codec.h>
#include <mfapi.h>

#include <condition_variable>
#include <cstdint>
#include <mutex>
#include <string>
#include <thread>
#include <variant>
#include <vector>

#include "video_codec.h"

namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;

constexpr UINT kDecodedMessage = WM_APP + 0x43;

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

// The images of a texture: the decoder writes the next one aside, the engine
// copies the latest to the GPU (on its raster thread) without ever waiting
// for the decoder.
struct Frames {
  std::mutex mutex;
  // What the engine reads; held from its copy until its release.
  std::vector<uint8_t> front;
  size_t front_width = 0;
  size_t front_height = 0;
  // The latest decoded image, not yet read.
  std::vector<uint8_t> pending;
  size_t pending_width = 0;
  size_t pending_height = 0;
  bool has_pending = false;
  FlutterDesktopPixelBuffer buffer = {};

  // Raster thread.
  const FlutterDesktopPixelBuffer* Copy() {
    std::lock_guard<std::mutex> lock(mutex);
    if (has_pending) {
      front.swap(pending);
      front_width = pending_width;
      front_height = pending_height;
      has_pending = false;
    }
    if (front.empty()) return nullptr;
    buffer.buffer = front.data();
    buffer.width = front_width;
    buffer.height = front_height;
    buffer.release_callback = nullptr;
    buffer.release_context = nullptr;
    return &buffer;
  }

  // Decoder thread: [image] becomes the latest, the previous one comes back
  // to be written over.
  void Publish(std::vector<uint8_t>* image, size_t width, size_t height) {
    std::lock_guard<std::mutex> lock(mutex);
    pending.swap(*image);
    pending_width = width;
    pending_height = height;
    has_pending = true;
  }
};

}  // namespace

struct LiveVideo::Decoding {
  explicit Decoding(HWND target) : window(target) {}

  const HWND window;
  std::mutex mutex;
  std::condition_variable wake;
  bool stop = false;

  // The access unit to decode.
  bool has_job = false;
  std::vector<uint8_t> data;
  bool key = false;

  // Its answer.
  bool done = false;
  bool failed = false;
  bool image = false;
  UINT32 width = 0;
  UINT32 height = 0;

  // Where it shows: its images, the texture and its ID for Dart.
  std::shared_ptr<Frames> frames = std::make_shared<Frames>();
  FlutterDesktopTextureRegistrarRef textures = nullptr;
  int64_t texture_id = -1;
};

namespace {

// The thread keeps its [decoding] alive: it may outlast a close.
void RunDecoder(std::shared_ptr<LiveVideo::Decoding> decoding) {
  const HRESULT com = ::CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  const HRESULT started = ::MFStartup(MF_VERSION, MFSTARTUP_LITE);
  {
    H264Decoder decoder;
    const bool opened = SUCCEEDED(started) && SUCCEEDED(decoder.Open());
    std::vector<uint8_t> data;
    std::vector<uint8_t> rgba;
    for (;;) {
      bool key = false;
      {
        std::unique_lock<std::mutex> lock(decoding->mutex);
        decoding->wake.wait(
            lock, [&] { return decoding->stop || decoding->has_job; });
        if (decoding->stop) break;
        decoding->has_job = false;
        data.swap(decoding->data);
        key = decoding->key;
      }
      UINT32 width = 0, height = 0;
      const HRESULT hr =
          opened ? decoder.Decode(data.data(), data.size(), key, &rgba,
                                  &width, &height)
                 : E_FAIL;
      {
        // Under the lock: a close (which sets [stop] under it) cannot
        // unregister the texture in the middle.
        std::lock_guard<std::mutex> lock(decoding->mutex);
        if (decoding->stop) break;
        if (hr == S_OK) {
          decoding->frames->Publish(&rgba, width, height);
          FlutterDesktopTextureRegistrarMarkExternalTextureFrameAvailable(
              decoding->textures, decoding->texture_id);
        }
        decoding->done = true;
        decoding->failed = FAILED(hr);
        decoding->image = hr == S_OK;
        decoding->width = width;
        decoding->height = height;
      }
      ::PostMessage(decoding->window, kDecodedMessage, 0, 0);
    }
  }
  if (SUCCEEDED(started)) ::MFShutdown();
  if (SUCCEEDED(com)) ::CoUninitialize();
}

// Whether this Windows can decode H.264, found out once.
bool CanDecode() {
  static const bool available = [] {
    const HRESULT started = ::MFStartup(MF_VERSION, MFSTARTUP_LITE);
    const bool found = SUCCEEDED(started) && H264Decoder::Available();
    if (SUCCEEDED(started)) ::MFShutdown();
    return found;
  }();
  return available;
}

}  // namespace

LiveVideo::LiveVideo(flutter::BinaryMessenger* messenger,
                     FlutterDesktopTextureRegistrarRef textures, HWND window)
    : window_(window),
      textures_(textures),
      channel_(std::make_unique<flutter::MethodChannel<EncodableValue>>(
          messenger, "dismessage/video",
          &flutter::StandardMethodCodec::GetInstance())) {
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    const std::string& method = call.method_name();
    if (method == "decoders") {
      EncodableList codecs;
      if (CanDecode() && textures_ != nullptr) {
        codecs.emplace_back(EncodableValue("h264"));
      }
      result->Success(EncodableValue(codecs));
    } else if (method == "create") {
      const auto* codec = Argument(call.arguments(), "codec");
      const auto* name =
          codec == nullptr ? nullptr : std::get_if<std::string>(codec);
      if (name == nullptr || *name != "h264" || !CanDecode() ||
          textures_ == nullptr) {
        result->Error("unsupported");
        return;
      }
      const int id = next_id_++;
      auto decoding = std::make_shared<Decoding>(window_);
      // The engine's hold on the images, until the texture is unregistered.
      FlutterDesktopTextureInfo info = {};
      info.type = kFlutterDesktopPixelBufferTexture;
      info.pixel_buffer_config.callback = [](size_t, size_t, void* frames) {
        return static_cast<Frames*>(frames)->Copy();
      };
      info.pixel_buffer_config.user_data = decoding->frames.get();
      decoding->textures = textures_;
      decoding->texture_id =
          FlutterDesktopTextureRegistrarRegisterExternalTexture(textures_,
                                                                &info);
      decoders_[id] = decoding;
      std::thread(RunDecoder, decoding).detach();
      result->Success(EncodableValue(id));
    } else if (method == "decode") {
      const int id = IntArgument(call.arguments(), "id");
      const auto it = decoders_.find(id);
      const auto* data = Argument(call.arguments(), "data");
      const auto* bytes =
          data == nullptr ? nullptr : std::get_if<std::vector<uint8_t>>(data);
      if (it == decoders_.end() || bytes == nullptr) {
        result->Error("decoder");
        return;
      }
      // One at a time: an earlier one still waiting is answered empty.
      auto& waiting = waiting_[id];
      if (waiting) waiting->Success();
      waiting = std::move(result);
      const auto* key = Argument(call.arguments(), "key");
      const auto* is_key = key == nullptr ? nullptr : std::get_if<bool>(key);
      {
        std::lock_guard<std::mutex> lock(it->second->mutex);
        it->second->data = *bytes;
        it->second->key = is_key != nullptr && *is_key;
        it->second->has_job = true;
      }
      it->second->wake.notify_one();
    } else if (method == "close") {
      Close(IntArgument(call.arguments(), "id"));
      result->Success();
    } else {
      result->NotImplemented();
    }
  });
}

void LiveVideo::Close(int id) {
  const auto it = decoders_.find(id);
  if (it != decoders_.end()) {
    std::shared_ptr<Decoding> decoding = it->second;
    decoders_.erase(it);
    {
      std::lock_guard<std::mutex> lock(decoding->mutex);
      decoding->stop = true;
    }
    decoding->wake.notify_one();
    // The images go once the engine no longer uses them; the thread keeps
    // the rest until it ends.
    auto* frames = new std::shared_ptr<Frames>(decoding->frames);
    FlutterDesktopTextureRegistrarUnregisterExternalTexture(
        textures_, decoding->texture_id,
        [](void* held) { delete static_cast<std::shared_ptr<Frames>*>(held); },
        frames);
  }
  const auto waiting = waiting_.find(id);
  if (waiting != waiting_.end()) {
    if (waiting->second) waiting->second->Success();
    waiting_.erase(waiting);
  }
}

LiveVideo::~LiveVideo() {
  channel_->SetMethodCallHandler(nullptr);
  std::vector<int> ids;
  for (const auto& [id, decoding] : decoders_) ids.push_back(id);
  for (const int id : ids) Close(id);
}

bool LiveVideo::HandleWindowMessage(UINT message) {
  if (message != kDecodedMessage) return false;
  for (auto& [id, decoding] : decoders_) {
    bool failed = false, image = false;
    UINT32 width = 0, height = 0;
    {
      std::lock_guard<std::mutex> lock(decoding->mutex);
      if (!decoding->done) continue;
      decoding->done = false;
      failed = decoding->failed;
      image = decoding->image;
      width = decoding->width;
      height = decoding->height;
    }
    const auto waiting = waiting_.find(id);
    if (waiting == waiting_.end() || !waiting->second) continue;
    auto result = std::move(waiting->second);
    waiting_.erase(waiting);
    if (failed) {
      result->Error("decoder");
    } else if (!image) {
      result->Success();
    } else {
      EncodableMap answer;
      answer[EncodableValue("w")] = EncodableValue(static_cast<int>(width));
      answer[EncodableValue("h")] = EncodableValue(static_cast<int>(height));
      answer[EncodableValue("texture")] =
          EncodableValue(static_cast<int64_t>(decoding->texture_id));
      result->Success(EncodableValue(std::move(answer)));
    }
  }
  return true;
}
