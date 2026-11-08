#include "video_codec.h"

#include <codecapi.h>
#include <mfapi.h>
#include <mferror.h>
#include <wmcodecdsp.h>

#include <algorithm>
#include <cstring>

namespace {

using Microsoft::WRL::ComPtr;

constexpr LONGLONG kFrameDuration = 10000000 / kVideoFramesPerSecond;

void SetCodecValue(ICodecAPI* api, const GUID& key, UINT32 value) {
  if (api == nullptr) return;
  VARIANT variant;
  ::VariantInit(&variant);
  variant.vt = VT_UI4;
  variant.ulVal = value;
  api->SetValue(&key, &variant);
}

void SetCodecFlag(ICodecAPI* api, const GUID& key, bool value) {
  if (api == nullptr) return;
  VARIANT variant;
  ::VariantInit(&variant);
  variant.vt = VT_BOOL;
  variant.boolVal = value ? VARIANT_TRUE : VARIANT_FALSE;
  api->SetValue(&key, &variant);
}

HRESULT VideoType(const GUID& subtype, UINT32 width, UINT32 height,
                  ComPtr<IMFMediaType>* type) {
  HRESULT hr = ::MFCreateMediaType(type->ReleaseAndGetAddressOf());
  if (FAILED(hr)) return hr;
  IMFMediaType* t = type->Get();
  t->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  t->SetGUID(MF_MT_SUBTYPE, subtype);
  t->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
  if (width != 0) {
    ::MFSetAttributeSize(t, MF_MT_FRAME_SIZE, width, height);
    ::MFSetAttributeRatio(t, MF_MT_FRAME_RATE, kVideoFramesPerSecond, 1);
    ::MFSetAttributeRatio(t, MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
  }
  return S_OK;
}

HRESULT MakeSample(const uint8_t* data, size_t size, LONGLONG time,
                   ComPtr<IMFSample>* sample) {
  ComPtr<IMFMediaBuffer> buffer;
  HRESULT hr =
      ::MFCreateMemoryBuffer(static_cast<DWORD>(size), buffer.GetAddressOf());
  if (FAILED(hr)) return hr;
  BYTE* target = nullptr;
  hr = buffer->Lock(&target, nullptr, nullptr);
  if (FAILED(hr)) return hr;
  std::memcpy(target, data, size);
  buffer->Unlock();
  buffer->SetCurrentLength(static_cast<DWORD>(size));
  hr = ::MFCreateSample(sample->ReleaseAndGetAddressOf());
  if (FAILED(hr)) return hr;
  (*sample)->AddBuffer(buffer.Get());
  (*sample)->SetSampleTime(time);
  (*sample)->SetSampleDuration(kFrameDuration);
  return S_OK;
}

// An empty sample for an output that the transform does not allocate.
HRESULT OutputSample(IMFTransform* transform, DWORD minimum,
                     ComPtr<IMFSample>* sample, bool* provided) {
  MFT_OUTPUT_STREAM_INFO info = {};
  HRESULT hr = transform->GetOutputStreamInfo(0, &info);
  if (FAILED(hr)) return hr;
  *provided = (info.dwFlags & (MFT_OUTPUT_STREAM_PROVIDES_SAMPLES |
                               MFT_OUTPUT_STREAM_CAN_PROVIDE_SAMPLES)) != 0;
  sample->Reset();
  if (*provided) return S_OK;
  ComPtr<IMFMediaBuffer> buffer;
  hr = ::MFCreateMemoryBuffer((std::max)(info.cbSize, minimum),
                              buffer.GetAddressOf());
  if (FAILED(hr)) return hr;
  hr = ::MFCreateSample(sample->GetAddressOf());
  if (FAILED(hr)) return hr;
  return (*sample)->AddBuffer(buffer.Get());
}

void StartStreaming(IMFTransform* transform) {
  transform->ProcessMessage(MFT_MESSAGE_COMMAND_FLUSH, 0);
  transform->ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0);
  transform->ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0);
}

uint8_t Clamp(int value) {
  return static_cast<uint8_t>(value < 0 ? 0 : value > 255 ? 255 : value);
}

}  // namespace

void BgrxToNv12(const uint8_t* bgrx, UINT32 width, UINT32 height,
                size_t stride, std::vector<uint8_t>* nv12) {
  const size_t luma = static_cast<size_t>(width) * height;
  nv12->resize(luma + luma / 2);
  uint8_t* y_plane = nv12->data();
  uint8_t* uv_plane = nv12->data() + luma;
  for (UINT32 y = 0; y < height; y += 2) {
    const uint8_t* row0 = bgrx + stride * y;
    const uint8_t* row1 = bgrx + stride * (y + 1);
    uint8_t* out0 = y_plane + static_cast<size_t>(width) * y;
    uint8_t* out1 = out0 + width;
    uint8_t* uv = uv_plane + static_cast<size_t>(width) * (y / 2);
    for (UINT32 x = 0; x < width; x += 2) {
      int sum_r = 0, sum_g = 0, sum_b = 0;
      const uint8_t* pixels[4] = {row0 + x * 4, row0 + x * 4 + 4,
                                  row1 + x * 4, row1 + x * 4 + 4};
      uint8_t* lumas[4] = {out0 + x, out0 + x + 1, out1 + x, out1 + x + 1};
      for (int i = 0; i < 4; i++) {
        const int b = pixels[i][0], g = pixels[i][1], r = pixels[i][2];
        *lumas[i] = static_cast<uint8_t>(((66 * r + 129 * g + 25 * b + 128) >> 8) + 16);
        sum_r += r;
        sum_g += g;
        sum_b += b;
      }
      const int r = sum_r / 4, g = sum_g / 4, b = sum_b / 4;
      uv[x] = Clamp(((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128);
      uv[x + 1] = Clamp(((112 * r - 94 * g - 18 * b + 128) >> 8) + 128);
    }
  }
}

bool HasNalType(const std::vector<uint8_t>& unit, int type) {
  const size_t size = unit.size();
  for (size_t i = 0; i + 3 < size; i++) {
    if (unit[i] == 0 && unit[i + 1] == 0 && unit[i + 2] == 1) {
      if ((unit[i + 3] & 0x1F) == type) return true;
      i += 2;
    }
  }
  return false;
}

// Encoder.

bool H264Encoder::Available() {
  H264Encoder probe;
  return SUCCEEDED(probe.Open(640, 480, 500));
}

HRESULT H264Encoder::Open(UINT32 width, UINT32 height, int kbps) {
  transform_.Reset();
  codec_api_.Reset();
  width_ = height_ = 0;
  HRESULT hr = ::CoCreateInstance(CLSID_CMSH264EncoderMFT, nullptr,
                                  CLSCTX_INPROC_SERVER,
                                  IID_PPV_ARGS(&transform_));
  if (FAILED(hr)) return hr;
  transform_.As(&codec_api_);
  ICodecAPI* api = codec_api_.Get();
  // Real time: one image in, one out, at a steady bitrate, no B frames.
  SetCodecFlag(api, CODECAPI_AVLowLatencyMode, true);
  SetCodecValue(api, CODECAPI_AVEncCommonRateControlMode,
                eAVEncCommonRateControlMode_CBR);
  SetCodecValue(api, CODECAPI_AVEncCommonMeanBitRate,
                static_cast<UINT32>(kbps) * 1000);
  SetCodecValue(api, CODECAPI_AVEncMPVGOPSize, kVideoKeyIntervalFrames);
  SetCodecValue(api, CODECAPI_AVEncMPVDefaultBPictureCount, 0);
  SetCodecValue(api, CODECAPI_AVEncCommonQualityVsSpeed, 50);

  ComPtr<IMFMediaType> output;
  hr = VideoType(MFVideoFormat_H264, width, height, &output);
  if (FAILED(hr)) return hr;
  output->SetUINT32(MF_MT_AVG_BITRATE, static_cast<UINT32>(kbps) * 1000);
  output->SetUINT32(MF_MT_MPEG2_PROFILE, eAVEncH264VProfile_Base);
  output->SetUINT32(MF_MT_YUV_MATRIX, MFVideoTransferMatrix_BT601);
  output->SetUINT32(MF_MT_VIDEO_NOMINAL_RANGE, MFNominalRange_16_235);
  hr = transform_->SetOutputType(0, output.Get(), 0);
  if (FAILED(hr)) return hr;
  ComPtr<IMFMediaType> input;
  hr = VideoType(MFVideoFormat_NV12, width, height, &input);
  if (FAILED(hr)) return hr;
  input->SetUINT32(MF_MT_YUV_MATRIX, MFVideoTransferMatrix_BT601);
  input->SetUINT32(MF_MT_VIDEO_NOMINAL_RANGE, MFNominalRange_16_235);
  hr = transform_->SetInputType(0, input.Get(), 0);
  if (FAILED(hr)) return hr;
  StartStreaming(transform_.Get());
  width_ = width;
  height_ = height;
  kbps_ = kbps;
  return S_OK;
}

void H264Encoder::SetBitrate(int kbps) {
  if (kbps == kbps_) return;
  kbps_ = kbps;
  SetCodecValue(codec_api_.Get(), CODECAPI_AVEncCommonMeanBitRate,
                static_cast<UINT32>(kbps) * 1000);
}

HRESULT H264Encoder::Encode(const std::vector<uint8_t>& nv12, bool key,
                            std::vector<uint8_t>* out, bool* is_key) {
  out->clear();
  *is_key = false;
  if (!transform_) return E_UNEXPECTED;
  ComPtr<IMFSample> sample;
  HRESULT hr = MakeSample(nv12.data(), nv12.size(), time_, &sample);
  if (FAILED(hr)) return hr;
  time_ += kFrameDuration;
  if (key) SetCodecValue(codec_api_.Get(), CODECAPI_AVEncVideoForceKeyFrame, 1);
  hr = transform_->ProcessInput(0, sample.Get(), 0);
  if (hr == MF_E_NOTACCEPTING) {
    // A frame still inside: take it, then this one goes in.
    hr = Drain(out);
    if (FAILED(hr)) return hr;
    hr = transform_->ProcessInput(0, sample.Get(), 0);
  }
  if (FAILED(hr)) return hr;
  std::vector<uint8_t> more;
  hr = Drain(&more);
  if (FAILED(hr)) return hr;
  out->insert(out->end(), more.begin(), more.end());
  if (out->empty()) return S_FALSE;
  *is_key = HasNalType(*out, 5);
  // A key frame carries its sequence header: decoding starts from it.
  if (*is_key && !HasNalType(*out, 7)) {
    ComPtr<IMFMediaType> type;
    UINT32 size = 0;
    if (SUCCEEDED(transform_->GetOutputCurrentType(0, &type)) &&
        SUCCEEDED(type->GetBlobSize(MF_MT_MPEG_SEQUENCE_HEADER, &size)) &&
        size > 0) {
      std::vector<uint8_t> header(size);
      if (SUCCEEDED(type->GetBlob(MF_MT_MPEG_SEQUENCE_HEADER, header.data(),
                                  size, nullptr))) {
        out->insert(out->begin(), header.begin(), header.end());
      }
    }
  }
  return S_OK;
}

HRESULT H264Encoder::Drain(std::vector<uint8_t>* out) {
  for (int round = 0; round < 8; round++) {
    ComPtr<IMFSample> sample;
    bool provided = false;
    HRESULT hr = OutputSample(transform_.Get(), width_ * height_ * 2, &sample,
                              &provided);
    if (FAILED(hr)) return hr;
    MFT_OUTPUT_DATA_BUFFER output = {};
    output.dwStreamID = 0;
    output.pSample = sample.Get();
    DWORD status = 0;
    hr = transform_->ProcessOutput(0, 1, &output, &status);
    if (output.pEvents != nullptr) output.pEvents->Release();
    if (hr == MF_E_TRANSFORM_NEED_MORE_INPUT) return S_OK;
    if (hr == MF_E_TRANSFORM_STREAM_CHANGE) {
      ComPtr<IMFMediaType> type;
      if (SUCCEEDED(transform_->GetOutputAvailableType(0, 0, &type))) {
        transform_->SetOutputType(0, type.Get(), 0);
      }
      continue;
    }
    if (FAILED(hr)) return hr;
    ComPtr<IMFSample> produced;
    if (provided) {
      produced.Attach(output.pSample);
    } else {
      produced = sample;
    }
    if (!produced) continue;
    ComPtr<IMFMediaBuffer> buffer;
    if (FAILED(produced->ConvertToContiguousBuffer(&buffer))) continue;
    BYTE* data = nullptr;
    DWORD length = 0;
    if (SUCCEEDED(buffer->Lock(&data, nullptr, &length))) {
      out->insert(out->end(), data, data + length);
      buffer->Unlock();
    }
  }
  return S_OK;
}

// Decoder.

bool H264Decoder::Available() {
  H264Decoder probe;
  return SUCCEEDED(probe.Open());
}

HRESULT H264Decoder::Open() {
  transform_.Reset();
  HRESULT hr = ::CoCreateInstance(CLSID_CMSH264DecoderMFT, nullptr,
                                  CLSCTX_INPROC_SERVER,
                                  IID_PPV_ARGS(&transform_));
  if (FAILED(hr)) return hr;
  // Each image out as soon as it is in: no reordering buffer.
  ComPtr<IMFAttributes> attributes;
  if (SUCCEEDED(transform_->GetAttributes(&attributes))) {
    attributes->SetUINT32(MF_LOW_LATENCY, TRUE);
  }
  ComPtr<ICodecAPI> api;
  if (SUCCEEDED(transform_.As(&api))) {
    SetCodecFlag(api.Get(), CODECAPI_AVLowLatencyMode, true);
  }
  // A size of its own until the first key frame says the real one: the
  // output types can then be listed.
  ComPtr<IMFMediaType> input;
  hr = VideoType(MFVideoFormat_H264, 640, 480, &input);
  if (FAILED(hr)) return hr;
  hr = transform_->SetInputType(0, input.Get(), 0);
  if (FAILED(hr)) return hr;
  hr = ChooseOutput();
  if (FAILED(hr)) return hr;
  StartStreaming(transform_.Get());
  return S_OK;
}

HRESULT H264Decoder::ChooseOutput() {
  for (DWORD i = 0;; i++) {
    ComPtr<IMFMediaType> type;
    HRESULT hr = transform_->GetOutputAvailableType(0, i, &type);
    if (FAILED(hr)) return hr;
    GUID subtype = {};
    if (FAILED(type->GetGUID(MF_MT_SUBTYPE, &subtype)) ||
        subtype != MFVideoFormat_NV12) {
      continue;
    }
    hr = transform_->SetOutputType(0, type.Get(), 0);
    if (FAILED(hr)) return hr;
    ::MFGetAttributeSize(type.Get(), MF_MT_FRAME_SIZE, &coded_width_,
                         &coded_height_);
    width_ = coded_width_;
    height_ = coded_height_;
    MFVideoArea area = {};
    if (SUCCEEDED(type->GetBlob(MF_MT_MINIMUM_DISPLAY_APERTURE,
                                reinterpret_cast<UINT8*>(&area),
                                sizeof(area), nullptr))) {
      width_ = (std::min)(coded_width_, static_cast<UINT32>(area.Area.cx));
      height_ = (std::min)(coded_height_, static_cast<UINT32>(area.Area.cy));
    }
    UINT32 stride = 0;
    stride_ = SUCCEEDED(type->GetUINT32(MF_MT_DEFAULT_STRIDE, &stride))
                  ? static_cast<LONG>(stride)
                  : static_cast<LONG>(coded_width_);
    // What the stream says, else what an encoder most likely did.
    bt709_ = ::MFGetAttributeUINT32(type.Get(), MF_MT_YUV_MATRIX,
                                    MFVideoTransferMatrix_BT601) ==
             MFVideoTransferMatrix_BT709;
    full_range_ = ::MFGetAttributeUINT32(type.Get(), MF_MT_VIDEO_NOMINAL_RANGE,
                                         MFNominalRange_16_235) ==
                  MFNominalRange_0_255;
    return S_OK;
  }
}

HRESULT H264Decoder::Decode(const uint8_t* data, size_t size, bool key,
                            std::vector<uint8_t>* rgba, UINT32* width,
                            UINT32* height) {
  if (!transform_) return E_UNEXPECTED;
  ComPtr<IMFSample> sample;
  HRESULT hr = MakeSample(data, size, time_, &sample);
  if (FAILED(hr)) return hr;
  time_ += kFrameDuration;
  if (key) sample->SetUINT32(MFSampleExtension_CleanPoint, TRUE);
  bool produced = false;
  hr = transform_->ProcessInput(0, sample.Get(), 0);
  if (hr == MF_E_NOTACCEPTING) {
    hr = Drain(rgba, width, height, &produced);
    if (FAILED(hr)) return hr;
    hr = transform_->ProcessInput(0, sample.Get(), 0);
  }
  if (FAILED(hr)) return hr;
  hr = Drain(rgba, width, height, &produced);
  if (FAILED(hr)) return hr;
  return produced ? S_OK : S_FALSE;
}

HRESULT H264Decoder::Drain(std::vector<uint8_t>* rgba, UINT32* width,
                           UINT32* height, bool* produced) {
  for (int round = 0; round < 8; round++) {
    ComPtr<IMFSample> sample;
    bool provided = false;
    HRESULT hr = OutputSample(transform_.Get(),
                              coded_width_ * coded_height_ * 3 / 2, &sample,
                              &provided);
    if (FAILED(hr)) return hr;
    MFT_OUTPUT_DATA_BUFFER output = {};
    output.dwStreamID = 0;
    output.pSample = sample.Get();
    DWORD status = 0;
    hr = transform_->ProcessOutput(0, 1, &output, &status);
    if (output.pEvents != nullptr) output.pEvents->Release();
    if (hr == MF_E_TRANSFORM_NEED_MORE_INPUT) return S_OK;
    if (hr == MF_E_TRANSFORM_STREAM_CHANGE) {
      // The real size, from the first key frame (or a new one).
      hr = ChooseOutput();
      if (FAILED(hr)) return hr;
      if (width_ > kVideoMaxSide || height_ > kVideoMaxSide) return E_FAIL;
      continue;
    }
    if (FAILED(hr)) return hr;
    ComPtr<IMFSample> image;
    if (provided) {
      image.Attach(output.pSample);
    } else {
      image = sample;
    }
    if (!image) continue;
    ComPtr<IMFMediaBuffer> buffer;
    if (FAILED(image->ConvertToContiguousBuffer(&buffer))) continue;
    if (width_ == 0 || height_ == 0 || width_ > kVideoMaxSide ||
        height_ > kVideoMaxSide) {
      return E_FAIL;
    }
    BYTE* scan0 = nullptr;
    LONG pitch = 0;
    ComPtr<IMF2DBuffer> buffer2d;
    bool locked2d = SUCCEEDED(buffer.As(&buffer2d)) &&
                    SUCCEEDED(buffer2d->Lock2D(&scan0, &pitch));
    DWORD length = 0;
    if (!locked2d) {
      if (FAILED(buffer->Lock(&scan0, nullptr, &length))) continue;
      pitch = stride_;
    }
    const size_t needed = static_cast<size_t>(pitch) * coded_height_ * 3 / 2;
    if (pitch <= 0 || (!locked2d && length < needed)) {
      if (locked2d) {
        buffer2d->Unlock2D();
      } else {
        buffer->Unlock();
      }
      return E_FAIL;
    }
    // YUV to RGB: BT.601 or BT.709, limited or full range, in fixed point.
    const double kr = bt709_ ? 0.2126 : 0.299;
    const double kb = bt709_ ? 0.0722 : 0.114;
    const double kg = 1 - kr - kb;
    const double ys = full_range_ ? 1.0 : 255.0 / 219.0;
    const double cs = full_range_ ? 1.0 : 255.0 / 224.0;
    const int y_off = full_range_ ? 0 : 16;
    const int cy = static_cast<int>(ys * 65536);
    const int crv = static_cast<int>(cs * 2 * (1 - kr) * 65536);
    const int cbu = static_cast<int>(cs * 2 * (1 - kb) * 65536);
    const int cgu = static_cast<int>(cs * 2 * (1 - kb) * kb / kg * 65536);
    const int cgv = static_cast<int>(cs * 2 * (1 - kr) * kr / kg * 65536);
    rgba->resize(static_cast<size_t>(width_) * height_ * 4);
    const uint8_t* uv_plane = scan0 + static_cast<size_t>(pitch) * coded_height_;
    for (UINT32 y = 0; y < height_; y++) {
      const uint8_t* luma = scan0 + static_cast<size_t>(pitch) * y;
      const uint8_t* uv = uv_plane + static_cast<size_t>(pitch) * (y / 2);
      uint8_t* out = rgba->data() + static_cast<size_t>(width_) * 4 * y;
      for (UINT32 x = 0; x < width_; x++) {
        const int l = (luma[x] - y_off) * cy;
        const int u = uv[x & ~1u] - 128;
        const int v = uv[(x & ~1u) + 1] - 128;
        out[0] = Clamp((l + crv * v + 32768) >> 16);
        out[1] = Clamp((l - cgu * u - cgv * v + 32768) >> 16);
        out[2] = Clamp((l + cbu * u + 32768) >> 16);
        out[3] = 255;
        out += 4;
      }
    }
    if (locked2d) {
      buffer2d->Unlock2D();
    } else {
      buffer->Unlock();
    }
    *width = width_;
    *height = height_;
    *produced = true;
  }
  return S_OK;
}
