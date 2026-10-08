import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:app_control_robot/pi_camera_link.dart';
import 'package:app_control_robot/pi_camera_transport.dart';
import 'package:flutter_test/flutter_test.dart';

/// Builds one `multipart/x-mixed-replace` part exactly the way the Pi writes it:
/// boundary, header block, then `Content-Length` bytes of JPEG.
List<int> _part(List<int> jpeg) => <int>[
      ...ascii.encode('--FRAME\r\n'),
      ...ascii.encode('Content-Type: image/jpeg\r\n'),
      ...ascii.encode('Content-Length: ${jpeg.length}\r\n'),
      ...ascii.encode('\r\n'),
      ...jpeg,
      ...ascii.encode('\r\n'),
    ];

/// Fake Pi: hands out a fresh stream per open, exactly as a new TCP connection
/// would, and counts how many times the app asked for one.
///
/// The per-open controller matters: a single-subscription stream cannot be
/// listened to twice, so a fake that reused one controller would break every
/// reconnect test for a reason that does not exist on the real socket.
class FakePiCameraTransport implements PiCameraTransport {
  FakePiCameraTransport();

  final List<StreamController<Uint8List>> _opened = [];
  StreamController<Uint8List>? _current;
  var opens = 0;
  var statsCalls = 0;

  /// Thrown by [fetchStats] when set.
  Object? statsError;

  /// Returned by [fetchStats] when [statsError] is null.
  PiCameraStats stats = const PiCameraStats(persons: 0, pickleballs: 0, fps: 0);

  /// Set to make the next [openStream] fail.
  Object? openError;

  /// Pushes one frame onto the current connection.
  void emit(List<int> jpeg) => _current?.add(Uint8List.fromList(jpeg));

  @override
  Stream<Uint8List> openStream() {
    opens++;
    final error = openError;
    if (error != null) {
      openError = null;
      return Stream<Uint8List>.error(error);
    }
    final controller = StreamController<Uint8List>();
    _opened.add(controller);
    _current = controller;
    return controller.stream;
  }

  @override
  Future<PiCameraStats> fetchStats() async {
    statsCalls++;
    final error = statsError;
    if (error != null) {
      throw error;
    }
    return stats;
  }

  Future<void> close() async {
    for (final controller in _opened) {
      await controller.close();
    }
  }
}

void main() {
  group('MjpegSplitter', () {
    test('pulls one frame out of a single chunk', () {
      final splitter = MjpegSplitter();
      final frames = splitter.add(_part([1, 2, 3, 4, 5]));
      expect(frames, hasLength(1));
      expect(frames.single, [1, 2, 3, 4, 5]);
    });

    test('pulls every frame when several arrive in one chunk', () {
      final splitter = MjpegSplitter();
      final frames = splitter.add([
        ..._part([1, 2]),
        ..._part([3, 4]),
        ..._part([5, 6]),
      ]);
      expect(frames.map((f) => f.toList()), [
        [1, 2],
        [3, 4],
        [5, 6],
      ]);
    });

    test('reassembles a frame split across arbitrary chunks', () {
      final splitter = MjpegSplitter();
      final jpeg = List<int>.generate(64, (i) => i);
      final part = _part(jpeg);

      // One byte at a time is the worst case: boundary, headers and body all
      // straddle chunk edges.
      final frames = <Uint8List>[];
      for (final byte in part) {
        frames.addAll(splitter.add([byte]));
      }
      expect(frames, hasLength(1));
      expect(frames.single, jpeg);
    });

    test('handles a frame whose header is split from its body', () {
      final splitter = MjpegSplitter();
      final jpeg = [9, 8, 7, 6];
      final frames = <Uint8List>[];
      final part = _part(jpeg);
      for (final chunk in [
        part.sublist(0, 30),
        part.sublist(30),
      ]) {
        frames.addAll(splitter.add(chunk));
      }
      expect(frames, hasLength(1));
      expect(frames.single, jpeg);
    });

    test('emits nothing until a frame is complete', () {
      final splitter = MjpegSplitter();
      final jpeg = [1, 2, 3, 4, 5, 6, 7, 8];
      final part = _part(jpeg);

      // Hold back the trailing CRLF and one body byte, so the frame is short.
      expect(splitter.add(part.sublist(0, part.length - 3)), isEmpty);
      expect(splitter.add(part.sublist(part.length - 3)), hasLength(1));
    });

    test('skips a part with no Content-Length instead of wedging', () {
      final splitter = MjpegSplitter();
      final frames = splitter.add([
        ...ascii.encode('--FRAME\r\nContent-Type: image/jpeg\r\n\r\n'),
        ...[1, 2, 3],
        ..._part([4, 5]),
      ]);
      expect(frames.map((f) => f.toList()), [
        [4, 5],
      ]);
    });

    test('the internal buffer does not grow without bound', () {
      final splitter = MjpegSplitter();
      for (var i = 0; i < 500; i++) {
        splitter.add(_part(List<int>.filled(512, i % 256)));
      }
      // A stream that never frees consumed bytes would take the app down
      // within minutes of running.
      expect(splitter.bufferedBytes, lessThan(1024));
      expect(splitter.add(_part([1])), hasLength(1));
    });
  });

  group('PiCameraStats.tryParse', () {
    test('reads the counts the Pi serves', () {
      final stats = PiCameraStats.tryParse(
        '{"person": 2, "pickleball": 1, "fps": 11.4, "sequence": 90}',
      );
      expect(stats, isNotNull);
      expect(stats!.persons, 2);
      expect(stats.pickleballs, 1);
      expect(stats.fps, closeTo(11.4, 0.001));
    });

    test('returns null for anything that is not the expected shape', () {
      expect(PiCameraStats.tryParse('not json'), isNull);
      expect(PiCameraStats.tryParse('[]'), isNull);
      expect(PiCameraStats.tryParse('{"person": 1}'), isNull);
    });
  });

  group('PiCameraLink', () {
    late FakePiCameraTransport transport;
    late PiCameraLink link;

    setUp(() {
      transport = FakePiCameraTransport();
      link = PiCameraLink(
        transport,
        stallTimeout: const Duration(milliseconds: 120),
        statsInterval: const Duration(milliseconds: 20),
        watchdogInterval: const Duration(milliseconds: 20),
      );
    });

    tearDown(() async {
      link.dispose();
      await transport.close();
    });

    test('a frame moves the link to streaming and is exposed', () async {
      await link.start();
      transport.emit([1, 2, 3]);

      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(link.status, PiCameraStatus.streaming);
      expect(link.frame, [1, 2, 3]);
      expect(link.frameCount, 1);
      expect(link.needsReconnect, isFalse);
      expect(link.message, isEmpty);
    });

    test('stats are polled and surfaced', () async {
      transport.stats = const PiCameraStats(persons: 3, pickleballs: 2, fps: 12.5);
      await link.start();

      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(link.stats!.persons, 3);
      expect(link.stats!.pickleballs, 2);
      expect(link.stats!.fps, closeTo(12.5, 0.001));
      expect(link.statsFresh, isTrue);
      expect(transport.statsCalls, greaterThan(0));
    });

    test('a silent stream is declared stalled and asks for a reconnect',
        () async {
      await link.start();
      transport.emit([1, 2, 3]);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(link.status, PiCameraStatus.streaming);

      // The phone walks out of Wi-Fi range: no error, no more frames.
      await Future<void>.delayed(const Duration(milliseconds: 250));

      // This is the frozen-picture case the reconnect button exists for.
      expect(link.status, PiCameraStatus.stalled);
      expect(link.needsReconnect, isTrue);
      expect(link.message, isNotEmpty);
    });

    test('a stream that never delivers a frame does not hang on connecting',
        () async {
      await link.start();
      expect(link.status, PiCameraStatus.connecting);

      await Future<void>.delayed(const Duration(milliseconds: 250));

      expect(link.status, PiCameraStatus.stalled);
      expect(link.needsReconnect, isTrue);
    });

    test('reconnect opens a fresh stream even after a stall', () async {
      await link.start();
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(link.needsReconnect, isTrue);
      final opensBefore = transport.opens;

      await link.reload();
      transport.emit([7, 7, 7]);
      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(transport.opens, opensBefore + 1);
      expect(link.status, PiCameraStatus.streaming);
      expect(link.frame, [7, 7, 7]);
      expect(link.needsReconnect, isFalse);
      expect(link.message, isEmpty);
    });

    test('a socket error while connecting reads as failed, not stalled',
        () async {
      transport.openError = StateError('connection refused');
      await link.start();

      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(link.status, PiCameraStatus.failed);
      expect(link.needsReconnect, isTrue);
    });

    test('a stream that ends is a reconnectable stall', () async {
      await link.start();
      transport.emit([1]);
      await Future<void>.delayed(const Duration(milliseconds: 40));

      // The Pi hangs up when its camera worker stops producing frames.
      await transport.close();

      expect(link.status, PiCameraStatus.stalled);
      expect(link.needsReconnect, isTrue);
    });

    test('failing stats polls never tear down a working video', () async {
      transport.statsError = StateError('no route to host');
      await link.start();

      // Frames keep coming, which is the whole point: /stats is broken while
      // the video is fine.
      final ticker = Timer.periodic(
        const Duration(milliseconds: 30),
        (_) => transport.emit([1, 2, 3]),
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
      ticker.cancel();

      expect(transport.statsCalls, greaterThan(1));
      expect(link.status, PiCameraStatus.streaming);
      expect(link.statsFresh, isFalse);
      expect(link.needsReconnect, isFalse);
    });

    test('stop cancels the timers so nothing fires after it', () async {
      await link.start();
      transport.emit([1]);
      await Future<void>.delayed(const Duration(milliseconds: 40));

      await link.stop();
      final framesAtStop = transport.statsCalls;
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(link.status, PiCameraStatus.idle);
      expect(transport.statsCalls, framesAtStop);
    });
  });
}