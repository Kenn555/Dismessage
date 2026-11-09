/// Protocol version this code speaks, sent in `register`. Raised when a
/// change needs clients to update; 2 = IDs given and signed by the relay;
/// 3 = conversations survive a short loss of connection (`peer_away`).
const int kProtocolVersion = 3;

/// First protocol version whose conversations are kept through a lost
/// connection: the relay only keeps those of clients that can resume them.
const int kResumableProtocolVersion = 3;

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

/// How long the relay keeps the conversations of a client whose connection
/// dropped (a tunnel, a phone changing networks…), and the client keeps them
/// too: back within this delay, nothing is lost.
const int kSessionGraceSeconds = 90;

/// What the relay keeps for a client that is away, in characters of frames
/// (a file transfer's window fits). More: the conversation ends.
const int kAwayBufferLength = 4 * 1024 * 1024;

/// What a client keeps to send once back, per conversation (characters).
const int kOutboxLength = 4 * 1024 * 1024;

/// Conversations listed in `registered` at most.
const int kMaxResumedSessions = 64;

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

/// Images sent at once (chosen together or pasted); each leaves as its own
/// `image_offer`.
const int kMaxImagesPerSend = 10;

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

/// Files sent at once (chosen together or pasted). The receiver answers for
/// all of them with a single validation.
const int kMaxFilesPerSend = 20;

/// A chosen or pasted image file larger than this goes as a plain file
/// instead of being read whole to be shown in a bubble.
const int kMaxImageFileBytes = 64 * 1024 * 1024;

// Live camera view: video or JPEG frames, encrypted like everything else. The
// camera owner's explicit agreement is needed each time.

/// Longest side of a live frame in the small view, in pixels: small, for 30
/// images per second.
const int kLiveMaxSide = 320;

/// Longest side asked for in full screen: the camera's best, within this.
const int kLiveFullSide = 1920;

/// The sizes a live view moves through as the network allows, like video
/// calls: the size gives way first, to keep the rate.
const List<int> kLiveSideSteps = [320, 480, 640, 960, 1280, 1920];

/// Where full screen starts, before the measured delay says more.
const int kLiveFullStartSide = 960;

/// Longest a received frame waits to be shown, to even out the network's
/// irregularities: images at a steady pace rather than in bursts, like the
/// playout buffer of video calls. Only used as far as the network needs it.
const int kLiveMaxBufferMs = 300;

/// Decoded frames waiting at most: beyond, the oldest are skipped.
const int kLiveMaxHeldFrames = 12;

/// What a live view aims for, in images per second.
const int kLiveTargetFps = 30;

/// Frames sent ahead of the viewer's acknowledgements, between these bounds
/// (`LiveFlow.window` follows the distance to the relay). What cannot leave is
/// skipped, not queued: the view stays current on a slow network, with fewer
/// images rather than a growing delay.
const int kLiveWindowFrames = 5;
const int kLiveMaxWindowFrames = 45;

/// JPEG quality of live frames: where it starts and between which values it
/// follows the network.
const int kLiveQualityStart = 45;
const int kLiveQualityMin = 25;
const int kLiveQualityMax = 70;

/// Delay above the lowest measured that means frames are queueing: too heavy.
/// Below [kLiveClearDelayMs] above it, the network has room to spare.
const int kLiveQueueDelayMs = 120;
const int kLiveClearDelayMs = 60;

/// Acknowledgements in a row above [kLiveQueueDelayMs] before the view gets
/// lighter: one late frame (a relay that delivers in bursts) says little.
/// [kLiveCongestedDelayMs] above the lowest delay is enough on its own.
const int kLiveSlowAcksToLower = 3;
const int kLiveCongestedDelayMs = 480;

/// No slow acknowledgement for this long before the view gets richer.
const int kLiveCalmMs = 1000;

/// The lowest delay is the lowest measured over this period: a route that
/// changed is noticed.
const int kLiveRttMemoryMs = 60000;

// Live view as video (H.264), when both sides can: only what changes from one
// image to the next is sent, for the same quality 5 to 10 times lighter than
// JPEG. The viewer offers what it can decode (`live_request.codecs`), the
// camera owner chooses (`live_accept.codec`); JPEG otherwise.

/// H.264, constrained baseline profile, Annex B access units.
const String kLiveCodecH264 = 'h264';

/// Codec names: short, lower case.
const int kMaxLiveCodecLength = 16;
const int kMaxLiveCodecs = 8;

/// Longest side of the small view as video: video affords more than JPEG.
const int kLiveVideoSmallSide = 640;

/// Where full screen starts as video.
const int kLiveVideoFullStartSide = 1280;

/// Highest bitrate of each of [kLiveSideSteps], in kbit/s. Below a third of
/// it, the size goes down.
const List<int> kLiveMaxKbpsBySide = [400, 700, 1100, 1800, 3000, 5000];

/// Bitrate at the start, small view and full screen, and the floor.
const int kLiveStartKbps = 700;
const int kLiveFullStartKbps = 2500;
const int kLiveMinKbps = 150;

/// A key frame at least this often (decoding can start from any of them);
/// the viewer also asks for one when it needs it ([kLiveKeyRequestMs] apart).
const int kLiveKeyIntervalSeconds = 10;
const int kLiveKeyRequestMs = 1000;

/// Received video frames waiting to be decoded at most: beyond, they are
/// dropped and a key frame asked for.
const int kLiveMaxQueuedFrames = 20;

/// Unacknowledged frames older than this are given up (a stalled network).
const int kLiveStallMs = 3000;

/// Largest live frame, in bytes (larger: skipped, and the quality goes down).
const int kMaxLiveFrameBytes = 384 * 1024;

/// Maximum base64 length of a live frame.
const int kMaxLiveFrameDataLength = (kMaxLiveFrameBytes + 2) ~/ 3 * 4;

/// A received frame announcing a larger image is not decoded.
const int kLiveMaxDecodedSide = 2560;

/// The viewer stops waiting for an answer after this delay.
const int kLiveRequestTimeoutSeconds = 60;

/// After a refusal, new requests are refused at once for this long: a peer
/// cannot flood the screen with prompts.
const int kLiveDeclineCooldownSeconds = 10;

/// The camera must give a frame within this delay, or the sharing stops.
const int kLiveCameraTimeoutSeconds = 5;

// Sound of a live view: the camera owner's microphone, with the camera, when
// the viewer can play it (`live_request.audio`) and the owner allows it.

/// IMA ADPCM, 16 kHz mono, 4 bits per sample: each packet stands alone
/// (it starts with the encoder's state), 64 kbit/s, a quarter of raw PCM.
const String kLiveAudioAdpcm = 'adpcm';

/// Samples per second of the sound, captured and played.
const int kLiveAudioSampleRate = 16000;

/// Sound per packet, in milliseconds: shorter adds frames, longer delay.
const int kLiveAudioPacketMs = 40;
const int kLiveAudioPacketSamples =
    kLiveAudioSampleRate * kLiveAudioPacketMs ~/ 1000;

/// Sound gathered before playing starts (again, after the network ran dry):
/// evens out the network's irregularities.
const int kLiveAudioStartMs = 120;

/// Sound waiting to be played at most: beyond, a packet is dropped, so that
/// the delay never grows.
const int kLiveAudioMaxBufferMs = 400;

/// Largest sound packet (a 40 ms ADPCM packet is 324 bytes).
const int kMaxLiveAudioBytes = 4096;
const int kMaxLiveAudioDataLength = (kMaxLiveAudioBytes + 2) ~/ 3 * 4;

// Relay rate limits (token buckets: a burst, then a sustained rate). The
// throughput ones slow a client down; the others refuse with `rate_limited`.

/// Frames one connection can send at once, then per second (live typing
/// sends one every [kDraftBatchMs], a live view [kLiveTargetFps] images and as
/// many acknowledgements).
const int kRateFramesBurst = 400;
const int kRateFramesPerSecond = 200;

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
