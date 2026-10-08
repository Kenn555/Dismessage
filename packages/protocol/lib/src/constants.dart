/// Protocol version this code speaks, sent in `register`. Raised when a
/// change needs clients to update; 2 = IDs given and signed by the relay.
const int kProtocolVersion = 2;

/// Oldest client protocol version the relay accepts (older: refused with
/// `update_required`). Raise it to retire old clients. 2: version 1 does
/// not encrypt conversations.
const int kMinProtocolVersion = 2;

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

/// Largest conversation frame before encryption (an image plus JSON).
const int kMaxInnerFrameLength = kMaxImageDataLength + 4096;

/// Maximum base64 length of a sealed frame (its JSON encrypted, + tag).
const int kMaxSealedDataLength = (kMaxInnerFrameLength + 16 + 2) ~/ 3 * 4;

/// Maximum size of one raw WebSocket message (a sealed image).
const int kMaxFrameLength = kMaxSealedDataLength + 1024;

/// The peer's key must arrive within this delay, or the conversation is
/// closed: nothing is ever sent unencrypted.
const int kE2eHandshakeSeconds = 15;

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

// Relay rate limits (token buckets: a burst, then a sustained rate). The
// throughput ones slow a client down; the others refuse with `rate_limited`.

/// Frames one connection can send at once, then per second (live typing
/// sends one every [kDraftBatchMs]).
const int kRateFramesBurst = 300;
const int kRateFramesPerSecond = 100;

/// Characters of raw frames one connection can send at once, then per second.
const int kRateBytesBurst = 16 * 1024 * 1024;
const int kRateBytesPerSecond = 8 * 1024 * 1024;

/// Chat requests of one connection: at once, then per minute.
const int kRateRequestsBurst = 10;
const int kRateRequestsPerMinute = 10;

/// Chat requests of all connections from one IP: at once, then per minute.
const int kRateIpRequestsBurst = 30;
const int kRateIpRequestsPerMinute = 30;

/// ID registrations (reconnections included) from one IP: at once, then per
/// minute.
const int kRateIpRegistersBurst = 60;
const int kRateIpRegistersPerMinute = 60;

/// IDs unknown to the relay claimed from one IP: at once, then per hour.
const int kRateIpNewIdsBurst = 50;
const int kRateIpNewIdsPerHour = 30;

/// Presence lists sent by one connection: at once, then per minute.
const int kRateWatchesBurst = 10;
const int kRateWatchesPerMinute = 10;

/// Simultaneous connections from one IP (a whole household or office can
/// share one).
const int kMaxConnectionsPerIp = 50;

/// Minimum delay between two silent updates of the "is typing" notification.
const int kTypingNotificationMs = 1500;

/// Unread messages shown in a conversation's notification (the latest).
const int kNotificationMaxLines = 5;

/// Longest text shown per line of a notification.
const int kNotificationLineLength = 120;
