#ifndef RUNNER_VIDEO_CODEC_H_
#define RUNNER_VIDEO_CODEC_H_

#include <windows.h>
#include <mfidl.h>
#include <mftransform.h>
#include <strmif.h>
#include <wrl/client.h>

#include <cstdint>
#include <vector>

// H.264 for the live camera view, with the software codecs of Media
// Foundation (Windows 8 and later; absent from "N" editions without the Media
// Feature Pack, where the view stays in JPEG). Constrained baseline profile,
// Annex B access units, one image in, one out (low latency mode): no image is
// held back. Both are used on a thread of their own, COM initialized.

// Images per second the encoder is told about.
constexpr UINT32 kVideoFramesPerSecond = 30;

// A key frame at least this often (the viewer can ask for one any time).
constexpr UINT32 kVideoKeyIntervalFrames = 10 * kVideoFramesPerSecond;

// Largest image the decoder hands back (as Dart's kLiveMaxDecodedSide).
constexpr UINT32 kVideoMaxSide = 2560;

// BGRX pixels, rows from the top ([stride] bytes apart), into NV12 (BT.601,
// 16-235), the format the encoder takes. [width] and [height] are even.
void BgrxToNv12(const uint8_t* bgrx, UINT32 width, UINT32 height,
                size_t stride, std::vector<uint8_t>* nv12);

// Whether an access unit holds a key frame (IDR slice), and a sequence
// header (SPS).
bool HasNalType(const std::vector<uint8_t>& access_unit, int type);

class H264Encoder {
 public:
  // Whether this Windows has the encoder.
  static bool Available();

  HRESULT Open(UINT32 width, UINT32 height, int kbps);
  bool IsOpen(UINT32 width, UINT32 height) const {
    return transform_ && width_ == width && height_ == height;
  }
  // Takes effect from the next image, without a key frame.
  void SetBitrate(int kbps);

  // Encodes one NV12 image of the open size. S_OK with [out] (and whether it
  // is a key frame) when the encoder gave a frame, S_FALSE when not yet.
  HRESULT Encode(const std::vector<uint8_t>& nv12, bool key,
                 std::vector<uint8_t>* out, bool* is_key);

 private:
  HRESULT Drain(std::vector<uint8_t>* out);

  Microsoft::WRL::ComPtr<IMFTransform> transform_;
  Microsoft::WRL::ComPtr<ICodecAPI> codec_api_;
  UINT32 width_ = 0;
  UINT32 height_ = 0;
  int kbps_ = 0;
  LONGLONG time_ = 0;
};

class H264Decoder {
 public:
  // Whether this Windows has the decoder.
  static bool Available();

  HRESULT Open();

  // Decodes one access unit. S_OK with the image in [rgba] (rows from the
  // top, no padding) when one came out, S_FALSE when none yet.
  HRESULT Decode(const uint8_t* data, size_t size, bool key,
                 std::vector<uint8_t>* rgba, UINT32* width, UINT32* height);

 private:
  HRESULT ChooseOutput();
  HRESULT Drain(std::vector<uint8_t>* rgba, UINT32* width, UINT32* height,
                bool* produced);

  Microsoft::WRL::ComPtr<IMFTransform> transform_;
  // Size of the decoded planes, and of the picture inside them (1080 lines
  // are coded as 1088).
  UINT32 coded_width_ = 0;
  UINT32 coded_height_ = 0;
  UINT32 width_ = 0;
  UINT32 height_ = 0;
  LONG stride_ = 0;
  bool bt709_ = false;
  bool full_range_ = false;
  LONGLONG time_ = 0;
};

#endif  // RUNNER_VIDEO_CODEC_H_
