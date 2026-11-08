import 'package:dismessage_protocol/dismessage_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('frames are numbered from 1', () {
    final flow = LiveFlow();
    expect(flow.sent(0), 1);
    expect(flow.sent(100), 2);
  });

  test('no frame leaves while the window is full, until an ack', () {
    final flow = LiveFlow();
    for (var i = 0; i < kLiveWindowFrames; i++) {
      flow.sent(i * 100);
    }
    expect(flow.canSend(1000), isFalse);
    expect(flow.ack(1, 1000), isTrue);
    expect(flow.inFlight, kLiveWindowFrames - 1);
    expect(flow.canSend(1000), isTrue);
  });

  test('the window follows the distance, to keep a steady flow', () {
    final flow = LiveFlow();
    expect(flow.window, kLiveWindowFrames);
    flow.sent(0);
    flow.ack(1, 800);
    // 30 per second during 800 ms, with a margin.
    expect(flow.window, 38);
    expect(flow.lowestRtt, 800);

    final near = LiveFlow();
    near.sent(0);
    near.ack(1, 5);
    expect(near.window, kLiveWindowFrames);
  });

  test('the window has a ceiling, and a queue does not widen it', () {
    final far = LiveFlow();
    far.sent(0);
    far.ack(1, 60000);
    expect(far.window, kLiveMaxWindowFrames);

    final flow = LiveFlow();
    flow.sent(0);
    flow.ack(1, 100);
    final window = flow.window;
    flow.sent(1000);
    flow.ack(2, 3000);
    expect(flow.window, window);
    expect(flow.lastRtt, 2000);
  });

  test('an ack covers the frames before it (some were skipped)', () {
    final flow = LiveFlow();
    for (var i = 0; i < kLiveWindowFrames; i++) {
      flow.sent(i);
    }
    expect(flow.ack(kLiveWindowFrames, 50), isTrue);
    expect(flow.inFlight, 0);
  });

  test('an ack for a frame never sent is refused', () {
    final flow = LiveFlow();
    flow.sent(0);
    expect(flow.ack(2, 10), isFalse);
    expect(flow.inFlight, 1);
  });

  test('a stalled network is given up, with the lightest frames', () {
    final flow = LiveFlow();
    for (var i = 0; i < kLiveWindowFrames; i++) {
      flow.sent(0);
    }
    expect(flow.canSend(kLiveStallMs - 1), isFalse);
    expect(flow.canSend(kLiveStallMs), isTrue);
    expect(flow.inFlight, 0);
    expect(flow.quality, kLiveQualityMin);
  });

  /// A frame acknowledged [rtt] ms later; the next one leaves [gap] ms after.
  int exchange(LiveFlow flow, int n, int at, int rtt, {int gap = 600}) {
    flow.sent(at);
    flow.ack(n, at + rtt);
    return at + gap;
  }

  test('one late frame changes nothing: a relay delivers in bursts', () {
    final flow = LiveFlow();
    var at = exchange(flow, 1, 0, 100);
    final start = flow.quality;
    at = exchange(flow, 2, at, 100 + kLiveQueueDelayMs + 1);
    expect(flow.quality, start);
    // Back to normal.
    at = exchange(flow, 3, at, 100);
    at = exchange(flow, 4, at, 100 + kLiveQueueDelayMs + 1);
    expect(flow.quality, start);
  });

  test('a queue that lasts lowers the quality, at most twice a second', () {
    final flow = LiveFlow();
    var at = exchange(flow, 1, 0, 100);
    final start = flow.quality;
    const queued = 100 + kLiveQueueDelayMs + 1;
    var n = 2;
    for (var i = 0; i < kLiveSlowAcksToLower; i++) {
      at = exchange(flow, n++, at, queued, gap: 33);
    }
    final lowered = flow.quality;
    expect(lowered, lessThan(start));
    // Still queueing, within half a second: no further change yet.
    for (var i = 0; i < kLiveSlowAcksToLower; i++) {
      at = exchange(flow, n++, at, queued, gap: 33);
    }
    expect(flow.quality, lowered);
  });

  test('a very late frame alone lowers the quality', () {
    final flow = LiveFlow();
    final at = exchange(flow, 1, 0, 100);
    final start = flow.quality;
    exchange(flow, 2, at, 100 + kLiveCongestedDelayMs + 1);
    expect(flow.quality, lessThan(start));
  });

  test('the lowest delay is forgotten after a while (the route changed)', () {
    final flow = LiveFlow();
    var at = exchange(flow, 1, 0, 20);
    expect(flow.lowestRtt, 20);
    var n = 2;
    while (at < kLiveRttMemoryMs + 2000) {
      at = exchange(flow, n++, at, 200);
    }
    expect(flow.lowestRtt, 200);
  });

  group('size', () {
    test('the small view stays small, whatever the network', () {
      final flow = LiveFlow();
      var at = 0;
      for (var n = 1; n < 30; n++) {
        at = exchange(flow, n, at, 10);
      }
      expect(flow.side, kLiveMaxSide);
    });

    test('full screen starts high, and climbs while the network allows', () {
      final flow = LiveFlow()..maxSide = kLiveFullSide;
      expect(flow.side, kLiveFullStartSide);
      var at = 0;
      for (var n = 1; n < 40; n++) {
        at = exchange(flow, n, at, 20);
      }
      expect(flow.side, kLiveFullSide);
    });

    test('frames queueing: the size gives way before the quality', () {
      final flow = LiveFlow()..maxSide = kLiveFullSide;
      var at = exchange(flow, 1, 0, 50);
      final quality = flow.quality;
      for (var n = 2; n < 2 + kLiveSlowAcksToLower; n++) {
        at = exchange(flow, n, at, 50 + kLiveQueueDelayMs + 10, gap: 33);
      }
      expect(flow.side, lessThan(kLiveFullStartSide));
      expect(flow.quality, quality);
    });

    test('nothing climbs during the first calm second', () {
      final flow = LiveFlow()..maxSide = kLiveFullSide;
      var at = 0;
      for (var n = 1; n < 10; n++) {
        at = exchange(flow, n, at, 20, gap: 100);
      }
      expect(flow.side, kLiveFullStartSide);
      exchange(flow, 10, at + kLiveCalmMs, 20);
      expect(flow.side, greaterThan(kLiveFullStartSide));
    });

    test('a long distance alone is not a slow network', () {
      final flow = LiveFlow()..maxSide = kLiveFullSide;
      var at = 0;
      for (var n = 1; n < 40; n++) {
        at = exchange(flow, n, at, 800);
      }
      expect(flow.side, kLiveFullSide);
    });

    test('leaving full screen comes back to the small size', () {
      final flow = LiveFlow()..maxSide = kLiveFullSide;
      flow.maxSide = kLiveMaxSide;
      expect(flow.side, kLiveMaxSide);
    });

    test('a stalled network falls back to the smallest size', () {
      final flow = LiveFlow()..maxSide = kLiveFullSide;
      for (var i = 0; i < kLiveWindowFrames; i++) {
        flow.sent(0);
      }
      expect(flow.canSend(kLiveStallMs), isTrue);
      expect(flow.side, kLiveMaxSide);
    });

    test('a frame too large lowers the size first', () {
      final flow = LiveFlow()..maxSide = kLiveFullSide;
      final quality = flow.quality;
      flow.tooLarge();
      expect(flow.side, lessThan(kLiveFullStartSide));
      expect(flow.quality, quality);
    });
  });

  group('video', () {
    test('starts larger than JPEG, at its own bitrate', () {
      final flow = LiveFlow(video: true);
      expect(flow.side, kLiveVideoSmallSide);
      expect(flow.kbps, kLiveStartKbps);
      // The viewer asks for the small size of JPEG: video keeps its own.
      flow.maxSide = kLiveMaxSide;
      expect(flow.side, kLiveVideoSmallSide);
      flow.maxSide = kLiveFullSide;
      expect(flow.side, kLiveVideoFullStartSide);
      expect(flow.kbps, kLiveFullStartKbps);
      flow.maxSide = kLiveMaxSide;
      expect(flow.side, kLiveVideoSmallSide);
      expect(flow.kbps, lessThanOrEqualTo(LiveFlow.maxKbpsFor(flow.side)));
    });

    test('a calm network raises the bitrate, then the size', () {
      final flow = LiveFlow(video: true)..maxSide = kLiveFullSide;
      var at = 0;
      for (var n = 1; n < 80; n++) {
        at = exchange(flow, n, at, 30);
      }
      expect(flow.side, kLiveFullSide);
      expect(flow.kbps, LiveFlow.maxKbpsFor(kLiveFullSide));
    });

    test('the small view keeps its size and its ceiling', () {
      final flow = LiveFlow(video: true);
      var at = 0;
      for (var n = 1; n < 80; n++) {
        at = exchange(flow, n, at, 30);
      }
      expect(flow.side, kLiveVideoSmallSide);
      expect(flow.kbps, LiveFlow.maxKbpsFor(kLiveVideoSmallSide));
    });

    test('a lasting queue lowers the bitrate, then the size', () {
      final flow = LiveFlow(video: true)..maxSide = kLiveFullSide;
      var at = exchange(flow, 1, 0, 50);
      final kbps = flow.kbps;
      var n = 2;
      void queue() {
        for (var i = 0; i < kLiveSlowAcksToLower; i++) {
          at = exchange(flow, n++, at, 50 + kLiveQueueDelayMs + 10, gap: 200);
        }
      }

      queue();
      expect(flow.kbps, lessThan(kbps));
      expect(flow.side, kLiveVideoFullStartSide);
      for (var i = 0; i < 6; i++) {
        queue();
      }
      expect(flow.side, lessThan(kLiveVideoFullStartSide));
      expect(flow.kbps, greaterThanOrEqualTo(kLiveMinKbps));
      expect(flow.kbps, greaterThanOrEqualTo(LiveFlow.minKbpsFor(flow.side)));
    });

    test('never below the floor', () {
      final flow = LiveFlow(video: true);
      var at = exchange(flow, 1, 0, 10);
      for (var n = 2; n < 100; n++) {
        at = exchange(flow, n, at, 10 + kLiveCongestedDelayMs + 1, gap: 100);
      }
      expect(flow.kbps, kLiveMinKbps);
      expect(flow.side, kLiveSideSteps.first);
    });

    test('a stalled network starts again light and small', () {
      final flow = LiveFlow(video: true)..maxSide = kLiveFullSide;
      for (var i = 0; i < kLiveWindowFrames; i++) {
        flow.sent(0);
      }
      expect(flow.canSend(kLiveStallMs), isTrue);
      expect(flow.kbps, kLiveMinKbps);
      expect(flow.side, kLiveVideoSmallSide);
    });

    test('a frame too large lowers the bitrate', () {
      final flow = LiveFlow(video: true)..maxSide = kLiveFullSide;
      final kbps = flow.kbps;
      flow.tooLarge();
      expect(flow.kbps, lessThan(kbps));
    });

    test('each size has a sensible bitrate range', () {
      for (final side in kLiveSideSteps) {
        expect(LiveFlow.minKbpsFor(side), lessThan(LiveFlow.maxKbpsFor(side)));
      }
      expect(LiveFlow.maxKbpsFor(4000), kLiveMaxKbpsBySide.last);
      expect(kLiveMaxKbpsBySide, hasLength(kLiveSideSteps.length));
    });
  });

  group('steady pace', () {
    test('a regular network adds no delay', () {
      final pacer = LivePacer();
      for (var i = 0; i < 100; i++) {
        expect(pacer.holdFor(i * 33, i * 33 + 50), 0);
      }
    });

    test('an early frame waits when the network is irregular', () {
      final pacer = LivePacer();
      for (var i = 0; i < 60; i++) {
        pacer.holdFor(i * 33, i * 33 + 50 + (i.isEven ? 0 : 30));
      }
      expect(pacer.holdFor(60 * 33, 60 * 33 + 50), greaterThan(0));
    });

    test('never more than the maximum', () {
      final pacer = LivePacer();
      for (var i = 0; i < 60; i++) {
        pacer.holdFor(i * 33, i * 33 + (i.isEven ? 0 : 1000));
      }
      expect(
        pacer.holdFor(60 * 33, 60 * 33),
        lessThanOrEqualTo(kLiveMaxBufferMs),
      );
    });

    test('a different clock on the other side changes nothing', () {
      final pacer = LivePacer();
      for (var i = 0; i < 20; i++) {
        expect(pacer.holdFor(i * 33 + 5000000, i * 33), 0);
      }
    });
  });

  test('the quality stays between its bounds', () {
    final slow = LiveFlow();
    var now = 0;
    // Within the memory of the lowest delay: past it, a lasting queue is
    // taken for the distance.
    for (var i = 1; i < 25; i++) {
      slow.sent(now);
      now += i == 1 ? 10 : 2000;
      slow.ack(i, now);
    }
    expect(slow.quality, kLiveQualityMin);

    final fast = LiveFlow();
    now = 0;
    for (var i = 1; i < 50; i++) {
      fast.sent(now);
      fast.ack(i, now + 10);
      now += 1100;
    }
    expect(fast.quality, kLiveQualityMax);
  });

  test('a frame too large lowers the quality', () {
    final flow = LiveFlow();
    final start = flow.quality;
    flow.tooLarge();
    expect(flow.quality, lessThan(start));
  });

  test('image names are recognized whatever their case', () {
    expect(FileNames.isImage('Photo.JPG'), isTrue);
    expect(FileNames.isImage('a.b.webp'), isTrue);
    expect(FileNames.isImage('rapport.pdf'), isFalse);
    expect(FileNames.isImage('png'), isFalse);
  });
}
