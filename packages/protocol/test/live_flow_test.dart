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

  test('the quality goes down on a slow link, at most twice a second', () {
    final flow = LiveFlow();
    flow.sent(0);
    flow.ack(1, 100);
    final start = flow.quality;
    const queued = 100 + kLiveQueueDelayMs + 1;
    flow.sent(600);
    flow.ack(2, 600 + queued);
    final lowered = flow.quality;
    expect(lowered, lessThan(start));
    flow.sent(600 + queued);
    flow.ack(3, 600 + queued * 2);
    expect(flow.quality, lowered);
  });

  group('size', () {
    /// A frame acknowledged [rtt] ms later, [gap] ms after the previous one.
    int exchange(LiveFlow flow, int n, int at, int rtt) {
      flow.sent(at);
      flow.ack(n, at + rtt);
      return at + 600;
    }

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
      at = exchange(flow, 2, at, 50 + kLiveQueueDelayMs + 10);
      expect(flow.side, lessThan(kLiveFullStartSide));
      expect(flow.quality, quality);
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
      expect(pacer.holdFor(60 * 33, 60 * 33), lessThanOrEqualTo(kLiveMaxBufferMs));
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
    for (var i = 1; i < 50; i++) {
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
