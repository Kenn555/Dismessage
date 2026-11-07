#include "live_camera.h"

#include <flutter/standard_method_codec.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mferror.h>
#include <mfreadwrite.h>
#include <shlwapi.h>
#include <wincodec.h>
#include <wrl/client.h>

#include <algorithm>
#include <atomic>
#include <cstdint>
#include <cstring>
#include <mutex>
#include <thread>
#include <variant>
#include <vector>

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;
using Microsoft::WRL::ComPtr;

constexpr UINT kOutcomeMessage = WM_APP + 0x42;
constexpr DWORD kVideoStream =
    static_cast<DWORD>(MF_SOURCE_READER_FIRST_VIDEO_STREAM);

int IntArgument(const flutter::EncodableValue* arguments, const char* key,
                int fallback) {
  const auto* map = std::get_if<EncodableMap>(arguments);
  if (map == nullptr) return fallback;
  const auto it = map->find(EncodableValue(key));
  if (it == map->end()) return fallback;
  if (const auto* value = std::get_if<int32_t>(&it->second)) return *value;
  return fallback;
}

std::string ToUtf8(const wchar_t* text, UINT32 length) {
  if (length == 0) return {};
  const int size = ::WideCharToMultiByte(CP_UTF8, 0, text,
                                         static_cast<int>(length), nullptr, 0,
                                         nullptr, nullptr);
  std::string utf8(size, '\0');
  ::WideCharToMultiByte(CP_UTF8, 0, text, static_cast<int>(length), utf8.data(),
                        size, nullptr, nullptr);
  return utf8;
}

std::string DeviceString(IMFActivate* device, REFGUID key) {
  WCHAR* value = nullptr;
  UINT32 length = 0;
  if (FAILED(device->GetAllocatedString(key, &value, &length))) return {};
  std::string utf8 = ToUtf8(value, length);
  ::CoTaskMemFree(value);
  return utf8;
}

HRESULT EnumerateCameras(IMFActivate*** devices, UINT32* count) {
  ComPtr<IMFAttributes> attributes;
  HRESULT hr = ::MFCreateAttributes(&attributes, 1);
  if (FAILED(hr)) return hr;
  hr = attributes->SetGUID(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE,
                           MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID);
  if (FAILED(hr)) return hr;
  return ::MFEnumDeviceSources(attributes.Get(), devices, count);
}

constexpr auto& kCameraLink =
    MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_SYMBOLIC_LINK;

// The camera chosen in the settings, else the first one (it may have been
// unplugged); the error code for the Dart side when there is none.
HRESULT OpenCamera(const std::string& wanted, ComPtr<IMFMediaSource>* source,
                   std::string* error) {
  IMFActivate** devices = nullptr;
  UINT32 count = 0;
  HRESULT hr = EnumerateCameras(&devices, &count);
  if (FAILED(hr)) return hr;
  if (count == 0) {
    *error = "no_camera";
    ::CoTaskMemFree(devices);
    return E_FAIL;
  }
  UINT32 chosen = 0;
  if (!wanted.empty()) {
    for (UINT32 i = 0; i < count; i++) {
      if (DeviceString(devices[i], kCameraLink) == wanted) chosen = i;
    }
  }
  hr = devices[chosen]->ActivateObject(IID_PPV_ARGS(source->GetAddressOf()));
  for (UINT32 i = 0; i < count; i++) devices[i]->Release();
  ::CoTaskMemFree(devices);
  return hr;
}

// In dim light a webcam lengthens its exposure and falls to 15 images per
// second, or fewer. This asks it to keep its rate, at the cost of a darker
// image; a camera that does not know this setting simply ignores it. Local
// declarations: ksproxy.h and strmiids.lib only for this would be overkill.
void KeepFrameRate(IMFMediaSource* source) {
  struct __declspec(uuid("28F54685-06FD-11D2-B27A-00A0C9223196")) KsControl
      : IUnknown {
    virtual HRESULT STDMETHODCALLTYPE KsProperty(void*, ULONG, void*, ULONG,
                                                 ULONG*) = 0;
  };
  struct {
    GUID set;
    ULONG id;
    ULONG flags;
    LONG value;
    ULONG control_flags;
    ULONG capabilities;
  } property = {};
  // PROPSETID_VIDCAP_CAMERACONTROL.
  property.set = {0xC6E13370,
                  0x30AC,
                  0x11D0,
                  {0xA1, 0x8C, 0x00, 0xA0, 0xC9, 0x11, 0x89, 0x56}};
  property.id = 19;       // KSPROPERTY_CAMERACONTROL_AUTO_EXPOSURE_PRIORITY.
  property.flags = 2;     // KSPROPERTY_TYPE_SET.
  property.value = 0;     // The rate first.
  property.control_flags = 2;  // KSPROPERTY_CAMERACONTROL_FLAGS_MANUAL.
  ComPtr<KsControl> control;
  if (FAILED(source->QueryInterface(IID_PPV_ARGS(&control)))) return;
  ULONG returned = 0;
  control->KsProperty(&property, sizeof(property), &property, sizeof(property),
                      &returned);
}

// Names and IDs of the cameras, for the settings.
flutter::EncodableList ListCameras() {
  flutter::EncodableList list;
  const HRESULT started = ::MFStartup(MF_VERSION, MFSTARTUP_LITE);
  IMFActivate** devices = nullptr;
  UINT32 count = 0;
  if (SUCCEEDED(EnumerateCameras(&devices, &count))) {
    for (UINT32 i = 0; i < count; i++) {
      EncodableMap device;
      device[EncodableValue("id")] =
          EncodableValue(DeviceString(devices[i], kCameraLink));
      device[EncodableValue("label")] = EncodableValue(
          DeviceString(devices[i], MF_DEVSOURCE_ATTRIBUTE_FRIENDLY_NAME));
      list.emplace_back(std::move(device));
      devices[i]->Release();
    }
    ::CoTaskMemFree(devices);
  }
  if (SUCCEEDED(started)) ::MFShutdown();
  return list;
}

std::string StringArgument(const flutter::EncodableValue* arguments,
                           const char* key) {
  const auto* map = std::get_if<EncodableMap>(arguments);
  if (map == nullptr) return {};
  const auto it = map->find(EncodableValue(key));
  if (it == map->end()) return {};
  const auto* value = std::get_if<std::string>(&it->second);
  return value == nullptr ? std::string() : *value;
}

// Asks for the smallest format at least [side] pixels long, in RGB32: fewer
// pixels to convert, and the same quality once reduced.
HRESULT ChooseFormat(IMFSourceReader* reader, int side, UINT32* width,
                     UINT32* height) {
  UINT32 best_width = 0, best_height = 0, best_num = 0, best_den = 0;
  bool best_fast = false;
  ComPtr<IMFMediaType> best;
  for (DWORD i = 0;; i++) {
    ComPtr<IMFMediaType> type;
    if (FAILED(reader->GetNativeMediaType(kVideoStream, i, &type))) break;
    UINT32 w = 0, h = 0, num = 0, den = 0;
    if (FAILED(::MFGetAttributeSize(type.Get(), MF_MT_FRAME_SIZE, &w, &h))) {
      continue;
    }
    ::MFGetAttributeRatio(type.Get(), MF_MT_FRAME_RATE, &num, &den);
    // Below 15 images per second, the view would look stuck.
    if (den != 0 && num / den < 15) continue;
    const bool long_enough = static_cast<int>((std::max)(w, h)) >= side;
    const bool best_long_enough =
        static_cast<int>((std::max)(best_width, best_height)) >= side;
    const uint64_t pixels = static_cast<uint64_t>(w) * h;
    const uint64_t best_pixels = static_cast<uint64_t>(best_width) * best_height;
    // Fluidity comes first: a format near 30 images per second wins over any
    // size, then the smallest one that is long enough.
    const bool fast = den != 0 && num / den >= 25;
    const bool better =
        best_width == 0 || (fast && !best_fast) ||
        (fast == best_fast &&
         ((long_enough && !best_long_enough) ||
          (long_enough == best_long_enough &&
           (long_enough ? pixels < best_pixels : pixels > best_pixels))));
    if (better) {
      best_fast = fast;
      best_width = w;
      best_height = h;
      best_num = num;
      best_den = den;
      best = type;
    }
  }
  // Pinned first: asked only for RGB32, the reader keeps the camera's own
  // default format (1280 × 720, at 16 images per second on a test webcam).
  if (best) reader->SetCurrentMediaType(kVideoStream, nullptr, best.Get());
  ComPtr<IMFMediaType> wanted;
  HRESULT hr = ::MFCreateMediaType(&wanted);
  if (FAILED(hr)) return hr;
  wanted->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  wanted->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_RGB32);
  // Rows from the top: left to itself, the converter goes from the bottom, and
  // not every buffer says so (the image came out upside down).
  if (best_width != 0) {
    wanted->SetUINT32(MF_MT_DEFAULT_STRIDE, best_width * 4);
  }
  if (best_width != 0) {
    ::MFSetAttributeSize(wanted.Get(), MF_MT_FRAME_SIZE, best_width,
                         best_height);
    if (best_den != 0) {
      ::MFSetAttributeRatio(wanted.Get(), MF_MT_FRAME_RATE, best_num, best_den);
    }
  }
  hr = reader->SetCurrentMediaType(kVideoStream, nullptr, wanted.Get());
  if (FAILED(hr)) return hr;
  ComPtr<IMFMediaType> current;
  hr = reader->GetCurrentMediaType(kVideoStream, &current);
  if (FAILED(hr)) return hr;
  return ::MFGetAttributeSize(current.Get(), MF_MT_FRAME_SIZE, width, height);
}

// The sample's pixels, rows from the top (the camera often gives them from the
// bottom).
bool CopyPixels(IMFSample* sample, UINT32 width, UINT32 height,
                std::vector<uint8_t>* pixels, int* path) {
  ComPtr<IMFMediaBuffer> buffer;
  if (FAILED(sample->ConvertToContiguousBuffer(&buffer))) return false;
  const size_t row = static_cast<size_t>(width) * 4;
  pixels->resize(row * height);
  ComPtr<IMF2DBuffer> buffer2d;
  BYTE* scan0 = nullptr;
  LONG pitch = 0;
  if (SUCCEEDED(buffer.As(&buffer2d)) &&
      SUCCEEDED(buffer2d->Lock2D(&scan0, &pitch))) {
    *path = pitch;
    for (UINT32 y = 0; y < height; y++) {
      std::memcpy(pixels->data() + row * y, scan0 + pitch * static_cast<LONG>(y),
                  row);
    }
    buffer2d->Unlock2D();
    return true;
  }
  *path = 0;
  BYTE* data = nullptr;
  DWORD length = 0;
  if (FAILED(buffer->Lock(&data, nullptr, &length))) return false;
  const bool enough = length >= pixels->size();
  // In the order asked for: rows from the top ([ChooseFormat]).
  if (enough) std::memcpy(pixels->data(), data, pixels->size());
  buffer->Unlock();
  return enough;
}

// A JPEG of [pixels], its longest side at most [side].
bool EncodeJpeg(IWICImagingFactory* factory, std::vector<uint8_t>& pixels,
                UINT32 width, UINT32 height, int side, int quality,
                std::vector<uint8_t>* jpeg) {
  ComPtr<IWICBitmap> bitmap;
  if (FAILED(factory->CreateBitmapFromMemory(
          width, height, GUID_WICPixelFormat32bppBGR, width * 4,
          static_cast<UINT>(pixels.size()), pixels.data(), &bitmap))) {
    return false;
  }
  ComPtr<IWICBitmapSource> source = bitmap;
  UINT32 out_width = width, out_height = height;
  const UINT32 longest = (std::max)(width, height);
  if (longest > static_cast<UINT32>(side)) {
    out_width = (std::max)(1u, width * side / longest);
    out_height = (std::max)(1u, height * side / longest);
    ComPtr<IWICBitmapScaler> scaler;
    if (FAILED(factory->CreateBitmapScaler(&scaler)) ||
        FAILED(scaler->Initialize(bitmap.Get(), out_width, out_height,
                                  WICBitmapInterpolationModeLinear))) {
      return false;
    }
    source = scaler;
  }
  ComPtr<IStream> stream;
  ComPtr<IWICBitmapEncoder> encoder;
  ComPtr<IWICBitmapFrameEncode> frame;
  ComPtr<IPropertyBag2> properties;
  if (FAILED(::CreateStreamOnHGlobal(nullptr, TRUE, &stream)) ||
      FAILED(factory->CreateEncoder(GUID_ContainerFormatJpeg, nullptr,
                                    &encoder)) ||
      FAILED(encoder->Initialize(stream.Get(), WICBitmapEncoderNoCache)) ||
      FAILED(encoder->CreateNewFrame(&frame, &properties))) {
    return false;
  }
  PROPBAG2 option = {};
  wchar_t name[] = L"ImageQuality";
  option.pstrName = name;
  VARIANT value;
  ::VariantInit(&value);
  value.vt = VT_R4;
  value.fltVal = static_cast<float>(quality) / 100.0f;
  properties->Write(1, &option, &value);
  WICPixelFormatGUID format = GUID_WICPixelFormat24bppBGR;
  if (FAILED(frame->Initialize(properties.Get())) ||
      FAILED(frame->SetSize(out_width, out_height)) ||
      FAILED(frame->SetPixelFormat(&format)) ||
      FAILED(frame->WriteSource(source.Get(), nullptr)) ||
      FAILED(frame->Commit()) || FAILED(encoder->Commit())) {
    return false;
  }
  STATSTG stat = {};
  if (FAILED(stream->Stat(&stat, STATFLAG_NONAME))) return false;
  const LARGE_INTEGER start = {};
  if (FAILED(stream->Seek(start, STREAM_SEEK_SET, nullptr))) return false;
  jpeg->resize(static_cast<size_t>(stat.cbSize.QuadPart));
  ULONG read = 0;
  return SUCCEEDED(stream->Read(jpeg->data(), static_cast<ULONG>(jpeg->size()),
                                &read)) &&
         read == jpeg->size();
}

}  // namespace

// What the thread hands back to the platform thread.
struct Outcome {
  bool opened = false;  // Else: a frame.
  std::string error;    // A code, in French on the Dart side.
  std::vector<uint8_t> jpeg;
};

struct LiveCamera::Worker {
  explicit Worker(HWND target) : window(target) {}

  const HWND window;
  std::atomic<bool> stop{false};
  std::atomic<bool> failed{false};
  std::atomic<int> wanted_quality{0};
  std::atomic<int> wanted_side{320};
  // Asked of the camera; 0 once done.
  std::atomic<int> capture_side{0};
  // Row step of the last image, 0 for a plain buffer.
  std::atomic<int> pitch{0};
  // Images the camera delivered, wanted or not (check_windows_camera.dart).
  std::atomic<int> samples{0};
  std::atomic<int> width{0};
  std::atomic<int> height{0};
  std::mutex mutex;
  std::vector<Outcome> outcomes;
  IMFMediaSource* source = nullptr;

  void Post(Outcome outcome) {
    {
      std::lock_guard<std::mutex> lock(mutex);
      outcomes.push_back(std::move(outcome));
    }
    ::PostMessage(window, kOutcomeMessage, 0, 0);
  }
};

namespace {

// The thread keeps its [worker] alive: it may outlast a Close().
void RunCamera(std::shared_ptr<LiveCamera::Worker> worker, int side,
               const std::string& device) {
  std::string error;
  const HRESULT com = ::CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  const HRESULT started = ::MFStartup(MF_VERSION, MFSTARTUP_LITE);
  {
    ComPtr<IWICImagingFactory> factory;
    ComPtr<IMFMediaSource> source;
    ComPtr<IMFSourceReader> reader;
    UINT32 width = 0, height = 0;
    HRESULT hr = started;
    if (SUCCEEDED(hr)) {
      hr = ::CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                              CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory));
    }
    if (SUCCEEDED(hr)) hr = OpenCamera(device, &source, &error);
    if (SUCCEEDED(hr)) {
      std::lock_guard<std::mutex> lock(worker->mutex);
      worker->source = source.Get();
    }
    if (SUCCEEDED(hr)) KeepFrameRate(source.Get());
    if (SUCCEEDED(hr)) {
      ComPtr<IMFAttributes> attributes;
      hr = ::MFCreateAttributes(&attributes, 1);
      // Converts whatever the camera gives into RGB32.
      if (SUCCEEDED(hr)) {
        hr = attributes->SetUINT32(MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING,
                                   TRUE);
      }
      if (SUCCEEDED(hr)) {
        hr = ::MFCreateSourceReaderFromMediaSource(source.Get(),
                                                   attributes.Get(), &reader);
      }
    }
    if (SUCCEEDED(hr)) hr = ChooseFormat(reader.Get(), side, &width, &height);
    worker->width = static_cast<int>(width);
    worker->height = static_cast<int>(height);
    if (FAILED(hr) && error.empty()) {
      error = hr == E_ACCESSDENIED ? "denied"
              : hr == MF_E_VIDEO_RECORDING_DEVICE_INVALIDATED ||
                      hr == HRESULT_FROM_WIN32(ERROR_SHARING_VIOLATION) ||
                      hr == HRESULT_FROM_WIN32(ERROR_DEVICE_IN_USE)
                  ? "busy"
                  : "unavailable";
    }
    Outcome opened;
    opened.opened = true;
    opened.error = error;
    if (!error.empty()) worker->failed = true;
    worker->Post(std::move(opened));

    std::vector<uint8_t> pixels;
    while (error.empty() && !worker->stop) {
      // Full screen asks for more, leaving it for less.
      const int capture = worker->capture_side.exchange(0);
      if (capture > 0) {
        reader->Flush(kVideoStream);
        UINT32 w = width, h = height;
        if (SUCCEEDED(ChooseFormat(reader.Get(), capture, &w, &h))) {
          width = w;
          height = h;
          worker->width = static_cast<int>(width);
          worker->height = static_cast<int>(height);
        }
      }
      DWORD flags = 0;
      ComPtr<IMFSample> sample;
      hr = reader->ReadSample(kVideoStream, 0, nullptr, &flags, nullptr,
                              &sample);
      if (worker->stop) break;
      if (FAILED(hr) || (flags & MF_SOURCE_READERF_ENDOFSTREAM) ||
          (flags & MF_SOURCE_READERF_ERROR)) {
        error = "stopped";
        worker->failed = true;
        Outcome ended;
        ended.error = error;
        worker->Post(std::move(ended));
        break;
      }
      if (sample == nullptr) continue;
      worker->samples++;
      // The image that just came, and only if someone wants it.
      const int quality = worker->wanted_quality.exchange(0);
      if (quality == 0) continue;
      Outcome frame;
      int pitch = 0;
      if (CopyPixels(sample.Get(), width, height, &pixels, &pitch)) {
        worker->pitch = pitch;
        EncodeJpeg(factory.Get(), pixels, width, height,
                   worker->wanted_side.load(), quality, &frame.jpeg);
      }
      worker->Post(std::move(frame));
    }
    {
      std::lock_guard<std::mutex> lock(worker->mutex);
      worker->source = nullptr;
    }
    reader.Reset();
    if (source) source->Shutdown();
  }
  if (SUCCEEDED(started)) ::MFShutdown();
  if (SUCCEEDED(com)) ::CoUninitialize();
}

}  // namespace

LiveCamera::LiveCamera(flutter::BinaryMessenger* messenger, HWND window)
    : window_(window),
      channel_(std::make_unique<flutter::MethodChannel<EncodableValue>>(
          messenger, "dismessage/camera",
          &flutter::StandardMethodCodec::GetInstance())) {
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() == "open") {
      Open(IntArgument(call.arguments(), "side", 320),
           StringArgument(call.arguments(), "device"), std::move(result));
    } else if (call.method_name() == "list") {
      result->Success(EncodableValue(ListCameras()));
    } else if (call.method_name() == "frame") {
      if (worker_) {
        worker_->wanted_side = IntArgument(call.arguments(), "side", 320);
      }
      RequestFrame(IntArgument(call.arguments(), "quality", 50),
                   std::move(result));
    } else if (call.method_name() == "capture") {
      if (worker_) {
        worker_->capture_side = IntArgument(call.arguments(), "side", 320);
      }
      result->Success();
    } else if (call.method_name() == "stats") {
      EncodableMap stats;
      stats[EncodableValue("samples")] =
          EncodableValue(worker_ ? worker_->samples.load() : 0);
      stats[EncodableValue("width")] =
          EncodableValue(worker_ ? worker_->width.load() : 0);
      stats[EncodableValue("height")] =
          EncodableValue(worker_ ? worker_->height.load() : 0);
      stats[EncodableValue("pitch")] =
          EncodableValue(worker_ ? worker_->pitch.load() : 0);
      result->Success(EncodableValue(stats));
    } else if (call.method_name() == "close") {
      Close();
      result->Success();
    } else {
      result->NotImplemented();
    }
  });
}

LiveCamera::~LiveCamera() {
  channel_->SetMethodCallHandler(nullptr);
  Close();
}

void LiveCamera::Open(int side, std::string device,
                      std::unique_ptr<Result> result) {
  Close();
  open_result_ = std::move(result);
  worker_ = std::make_shared<Worker>(window_);
  std::thread(RunCamera, worker_, side, std::move(device)).detach();
}

void LiveCamera::RequestFrame(int quality, std::unique_ptr<Result> result) {
  if (!worker_ || worker_->failed) {
    result->Error("stopped");
    return;
  }
  // Only the latest request counts.
  if (frame_result_) frame_result_->Success();
  frame_result_ = std::move(result);
  worker_->wanted_quality = (std::clamp)(quality, 1, 100);
}

void LiveCamera::Close() {
  if (worker_) {
    worker_->stop = true;
    // Unblocks the thread waiting for a sample, if the camera allows it.
    std::lock_guard<std::mutex> lock(worker_->mutex);
    if (worker_->source != nullptr) worker_->source->Shutdown();
  }
  worker_.reset();
  if (open_result_) open_result_->Error("stopped");
  open_result_.reset();
  if (frame_result_) frame_result_->Success();
  frame_result_.reset();
}

bool LiveCamera::HandleWindowMessage(UINT message) {
  if (message != kOutcomeMessage) return false;
  // Empty once closed: what a stopped thread still posts is dropped with it.
  if (!worker_) return true;
  std::vector<Outcome> outcomes;
  {
    std::lock_guard<std::mutex> lock(worker_->mutex);
    outcomes.swap(worker_->outcomes);
  }
  for (const Outcome& outcome : outcomes) {
    auto& result = outcome.opened ? open_result_ : frame_result_;
    if (!result) continue;
    if (!outcome.error.empty()) {
      result->Error(outcome.error);
    } else if (outcome.opened || outcome.jpeg.empty()) {
      result->Success();
    } else {
      result->Success(EncodableValue(outcome.jpeg));
    }
    result.reset();
  }
  return true;
}
