#ifndef RUNNER_CLIPBOARD_H_
#define RUNNER_CLIPBOARD_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <memory>

// Pictures on the clipboard, for Ctrl+V in the chat input
// ("dismessage/clipboard" channel; Flutter's clipboard only knows text).
class ClipboardImages {
 public:
  explicit ClipboardImages(flutter::BinaryMessenger* messenger);
  ~ClipboardImages();

 private:
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif  // RUNNER_CLIPBOARD_H_
