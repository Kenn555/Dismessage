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
