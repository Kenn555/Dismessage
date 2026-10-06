/// Interval at which pending draft edits are flushed to the network.
const int kDraftBatchMs = 30;

/// Inactivity delay after which the "…" typing dots are shown.
const int kPauseDotsMs = 700;

/// A full draft snapshot is sent every [kSnapshotEvery] edit operations.
const int kSnapshotEvery = 50;

/// A pending chat request is abandoned after this delay without answer.
const int kConnectRequestTimeoutSeconds = 60;

/// Max time to open the WebSocket, then to get `registered` back.
const int kConnectTimeoutSeconds = 20;

/// Upper bound of the exponential reconnection delay.
const int kMaxReconnectDelaySeconds = 30;

/// Heartbeat interval between client and server.
const int kHeartbeatSeconds = 20;

/// Maximum length (UTF-16 code units) of a draft or message.
const int kMaxTextLength = 10000;

/// Maximum length of an ID secret.
const int kMaxSecretLength = 128;

/// Longest side of a sent image, in pixels.
const int kMaxImageSide = 1280;

/// Maximum size of an encoded (JPEG) image, in bytes.
const int kMaxImageBytes = 600 * 1024;

/// Longest side of the blurred preview sent before opening.
const int kImagePreviewSide = 32;

/// Maximum base64 length of an image preview.
const int kMaxImagePreviewLength = 8 * 1024;

/// Maximum base64 length of a full image.
const int kMaxImageDataLength = (kMaxImageBytes + 2) ~/ 3 * 4;

/// Maximum size of one raw WebSocket message (an image plus JSON overhead).
const int kMaxFrameLength = kMaxImageDataLength + 4096;

/// Maximum number of IDs one client can watch for presence (its contacts).
const int kMaxPresenceWatch = 500;

/// Maximum length (UTF-16 code units) of a reaction emoji.
const int kMaxReactionLength = 16;

/// Longest voice message, in seconds.
const int kMaxVoiceSeconds = 120;

/// Voice encoder bit rate: [kMaxVoiceSeconds] must fit in [kMaxVoiceBytes].
const int kVoiceBitRate = 32000;

/// Maximum size of an encoded voice message, in bytes.
const int kMaxVoiceBytes = kMaxImageBytes;

/// Maximum base64 length of a voice message.
const int kMaxVoiceDataLength = (kMaxVoiceBytes + 2) ~/ 3 * 4;

/// Largest file that can be sent (bytes). The receiver writes it to disk as
/// it arrives (the browser keeps it in memory until the download).
const int kMaxFileBytes = 512 * 1024 * 1024;

/// Bytes per file chunk (the last one is shorter).
const int kFileChunkBytes = 192 * 1024;

/// Maximum base64 length of one file chunk.
const int kMaxFileChunkDataLength = (kFileChunkBytes + 2) ~/ 3 * 4;

/// Chunks sent ahead of the receiver's acknowledgements: bounds what the
/// relay and the sockets buffer, and keeps room for live typing.
const int kFileWindowChunks = 4;

/// Longest file name (UTF-16 code units).
const int kMaxFileNameLength = 255;

/// Minimum delay between two silent updates of the "is typing" notification.
const int kTypingNotificationMs = 1500;

/// Unread messages shown in a conversation's notification (the latest).
const int kNotificationMaxLines = 5;

/// Longest text shown per line of a notification.
const int kNotificationLineLength = 120;
