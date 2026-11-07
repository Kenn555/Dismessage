#include "clipboard.h"

#include <flutter/standard_method_codec.h>
#include <windows.h>

#include <shellapi.h>

#include <string>
#include <vector>

namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;

std::vector<uint8_t> GlobalBytes(HANDLE handle) {
  std::vector<uint8_t> bytes;
  if (handle == nullptr) return bytes;
  const SIZE_T size = ::GlobalSize(handle);
  const void* data = ::GlobalLock(handle);
  if (data != nullptr && size > 0) {
    const auto* begin = static_cast<const uint8_t*>(data);
    bytes.assign(begin, begin + size);
  }
  if (data != nullptr) ::GlobalUnlock(handle);
  return bytes;
}

// A device-independent bitmap (CF_DIB) as a .bmp file: the same bytes
// behind a file header that locates the pixels.
std::vector<uint8_t> DibToBmp(const std::vector<uint8_t>& dib) {
  if (dib.size() < sizeof(BITMAPINFOHEADER)) return {};
  BITMAPINFOHEADER header;
  memcpy(&header, dib.data(), sizeof(header));
  size_t offset = header.biSize;
  if (header.biSize == sizeof(BITMAPINFOHEADER) &&
      header.biCompression == BI_BITFIELDS) {
    offset += 3 * sizeof(DWORD);
  }
  DWORD colors = header.biClrUsed;
  if (colors == 0 && header.biBitCount <= 8) colors = 1u << header.biBitCount;
  offset += colors * sizeof(RGBQUAD);
  if (offset >= dib.size()) return {};

  BITMAPFILEHEADER file = {};
  file.bfType = 0x4D42;  // "BM"
  file.bfSize = static_cast<DWORD>(sizeof(file) + dib.size());
  file.bfOffBits = static_cast<DWORD>(sizeof(file) + offset);
  std::vector<uint8_t> bmp(sizeof(file));
  memcpy(bmp.data(), &file, sizeof(file));
  bmp.insert(bmp.end(), dib.begin(), dib.end());
  return bmp;
}

std::string ToUtf8(const std::wstring& text) {
  if (text.empty()) return {};
  const int size = ::WideCharToMultiByte(CP_UTF8, 0, text.data(),
                                         static_cast<int>(text.size()), nullptr,
                                         0, nullptr, nullptr);
  std::string utf8(size, '\0');
  ::WideCharToMultiByte(CP_UTF8, 0, text.data(), static_cast<int>(text.size()),
                        utf8.data(), size, nullptr, nullptr);
  return utf8;
}

// Copied files of any type (Explorer): their paths, read in Dart chunk by
// chunk. Else a copied picture: PNG when the source offers it (browsers, the
// Snipping Tool), else the bitmap.
EncodableMap ReadContent() {
  EncodableList images;
  EncodableList files;
  EncodableMap content;
  if (::OpenClipboard(nullptr)) {
    const UINT png = ::RegisterClipboardFormat(L"PNG");
    if (::IsClipboardFormatAvailable(CF_HDROP)) {
      auto drop = static_cast<HDROP>(::GetClipboardData(CF_HDROP));
      const UINT count =
          drop == nullptr ? 0 : ::DragQueryFile(drop, 0xFFFFFFFF, nullptr, 0);
      for (UINT i = 0; i < count; i++) {
        const UINT length = ::DragQueryFile(drop, i, nullptr, 0);
        std::wstring path(length + 1, L'\0');
        ::DragQueryFile(drop, i, path.data(), length + 1);
        path.resize(length);
        files.emplace_back(ToUtf8(path));
      }
    } else if (png != 0 && ::IsClipboardFormatAvailable(png)) {
      auto bytes = GlobalBytes(::GetClipboardData(png));
      if (!bytes.empty()) images.emplace_back(std::move(bytes));
    } else if (::IsClipboardFormatAvailable(CF_DIB)) {
      auto bytes = DibToBmp(GlobalBytes(::GetClipboardData(CF_DIB)));
      if (!bytes.empty()) images.emplace_back(std::move(bytes));
    }
    ::CloseClipboard();
  }
  content[EncodableValue("images")] = EncodableValue(std::move(images));
  content[EncodableValue("files")] = EncodableValue(std::move(files));
  return content;
}

}  // namespace

ClipboardImages::ClipboardImages(flutter::BinaryMessenger* messenger)
    : channel_(std::make_unique<flutter::MethodChannel<EncodableValue>>(
          messenger, "dismessage/clipboard",
          &flutter::StandardMethodCodec::GetInstance())) {
  channel_->SetMethodCallHandler([](const auto& call, auto result) {
    if (call.method_name() == "read") {
      result->Success(EncodableValue(ReadContent()));
    } else {
      result->NotImplemented();
    }
  });
}

ClipboardImages::~ClipboardImages() {
  channel_->SetMethodCallHandler(nullptr);
}
