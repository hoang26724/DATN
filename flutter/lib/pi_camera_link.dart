import 'dart:async';

import 'package:flutter/foundation.dart';

import 'pi_camera_transport.dart';

enum PiCameraStatus {
  /// Never started, or stopped on purpose.
  idle,

  /// Socket opening, or open but no frame has arrived yet.
  connecting,

  /// Frames are arriving.
  streaming,

  /// Was streaming, then went quiet. Needs the user to reconnect.
  stalled,

  /// Never managed to stream at all. Needs the user to reconnect.
  failed,
}

/// The Raspberry Pi camera as the app sees it: a JPEG stream plus the counts
/// the Pi draws on the picture.
///
/// The failure mode this class exists for is a *silently frozen* video. A phone
/// that loses Wi-Fi keeps a half-open TCP socket that never errors and never
/// delivers a byte, so nothing in the socket layer reports a problem. The only
/// honest signal is time: if no frame has arrived for [stallTimeout], the link
/// is torn down and [status] becomes [PiCameraStatus.stalled] so the panel can
/// offer a reconnect button.
class PiCameraLink extends ChangeNotifier {
  PiCameraLink(
    this._transport, {
    this.stallTimeout = const Duration(seconds: 8),
    this.statsInterval = const Duration(milliseconds: 500),
    this.watchdogInterval = const Duration(seconds: 1),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final PiCameraTransport _transport;

  /// How long the video may go without a frame before it is declared dead.
  final Duration stallTimeout;

  /// How often `/stats` is polled.
  final Duration statsInterval;

  /// How often the stall check runs.
  final Duration watchdogInterval;

  /// Injectable so tests can drive the stall watchdog. Widget tests fake timers
  /// but not the wall clock, so [DateTime.now] would never move there and the
  /// watchdog could not be exercised.
  final DateTime Function() _clock;

  /// Upper bound on how long [stop] waits for a cancel to land. Cancelling a
  /// socket that is no longer answering can take a full TCP timeout, and the
  /// reconnect button must not sit there waiting for it.
  static const Duration _cancelGrace = Duration(seconds: 2);

  StreamSubscription<Uint8List>? _frames;
  Timer? _watchdog;
  Timer? _statsTimer;

  /// In-flight cancellation of a previous connection. A reload has to wait for
  /// it: re-listening to a stream whose cancel has not landed yet throws
  /// "Stream has already been listened to".
  Future<void> _detaching = Future<void>.value();

  bool _disposed = false;

  DateTime? _lastFrameAt;
  PiCameraStatus _status = PiCameraStatus.idle;
  String _message = '';
  Uint8List? _frame;
  int _frameCount = 0;
  PiCameraStats? _stats;
  bool _statsFresh = false;

  PiCameraStatus get status => _status;

  /// Vietnamese, user-facing, empty while the link is healthy.
  String get message => _message;

  /// Newest JPEG, or null before the first frame.
  Uint8List? get frame => _frame;

  /// How many frames have arrived on this connection. Bumped on every frame, so
  /// it is also the cheapest way for a test to know something moved.
  int get frameCount => _frameCount;

  /// Counts from `/stats`, or null if they have never arrived.
  PiCameraStats? get stats => _stats;

  /// False once a stats poll has failed, so the panel can show dashes instead
  /// of numbers that are no longer true.
  bool get statsFresh => _statsFresh;

  /// True while the panel should offer a reconnect button.
  bool get needsReconnect =>
      _status == PiCameraStatus.stalled || _status == PiCameraStatus.failed;

  /// Opens the stream and starts polling. Safe to call when already running.
  Future<void> start() async {
    if (_disposed || _status != PiCameraStatus.idle) {
      return;
    }
    _setStatus(PiCameraStatus.connecting);
    _message = '';
    _lastFrameAt = _clock();
    _frameCount = 0;

    // Listen without awaiting: openStream() only starts touching the socket once
    // something subscribes, and it never completes on its own.
    _frames = _transport.openStream().listen(
      _onFrame,
      onError: _onStreamError,
      onDone: _onStreamDone,
      cancelOnError: true,
    );

    _watchdog = Timer.periodic(watchdogInterval, (_) => _checkForStall());
    _statsTimer = Timer.periodic(statsInterval, (_) => _pollStats());
    unawaited(_pollStats());
  }

  /// Tears the connection down and opens a fresh one. This is what the
  /// reconnect button calls, and it must not need a clean socket first: the
  /// whole point is that the old one is usually wedged.
  Future<void> reload() async {
    await stop();
    await start();
  }

  Future<void> stop() async {
    await _detach();
    _setStatus(PiCameraStatus.idle);
  }

  /// Cancels the timers and the stream subscription, then hands back a future
  /// for the cancellation itself. [stop] awaits it; [_fail] stores it and moves
  /// on, so the UI is never blocked on a socket that has stopped answering.
  Future<void> _detach() {
    _watchdog?.cancel();
    _watchdog = null;
    _statsTimer?.cancel();
    _statsTimer = null;
    final frames = _frames;
    _frames = null;
    final previous = _detaching;
    if (frames == null) {
      return previous;
    }
    // A socket that is no longer answering can take a full TCP timeout to
    // cancel; past the grace period it is forgotten anyway. A real Timer with
    // an explicit cancel rather than Future.timeout, so a prompt cancel leaves
    // nothing pending behind it.
    return _detaching = _cancelWithinGrace(previous, frames);
  }

  Future<void> _cancelWithinGrace(
    Future<void> previous,
    StreamSubscription<Uint8List> frames,
  ) async {
    final done = Completer<void>();
    final guard = Timer(_cancelGrace, done.complete);
    await previous;
    unawaited(
      frames.cancel().whenComplete(() {
        guard.cancel();
        if (!done.isCompleted) {
          done.complete();
        }
      }),
    );
    await done.future;
  }

  void _onFrame(Uint8List frame) {
    if (_disposed) {
      return;
    }
    _lastFrameAt = _clock();
    _frame = frame;
    _frameCount++;
    if (_status != PiCameraStatus.streaming) {
      _message = '';
      _setStatus(PiCameraStatus.streaming);
      return;
    }
    notifyListeners();
  }

  void _onStreamError(Object error) {
    // A socket that finally gave up after being half-open. Same treatment as a
    // stall: the user reconnects.
    _fail(
      _status == PiCameraStatus.connecting
          ? 'Không mở được camera Raspberry Pi.'
          : 'Mất kết nối tới Raspberry Pi.',
      PiCameraStatus.failed,
    );
  }

  void _onStreamDone() {
    if (_status == PiCameraStatus.idle) {
      return;
    }
    // The Pi closes /stream.mjpg when its camera worker stops producing frames.
    _fail('Camera Raspberry Pi đã ngắt luồng.', PiCameraStatus.stalled);
  }

  void _checkForStall() {
    if (_status != PiCameraStatus.connecting && _status != PiCameraStatus.streaming) {
      return;
    }
    final last = _lastFrameAt;
    if (last == null || _clock().difference(last) <= stallTimeout) {
      return;
    }
    _fail(
      _status == PiCameraStatus.connecting
          ? 'Camera Raspberry Pi không phản hồi.'
          : 'Hình ảnh Raspberry Pi bị đứng.',
      PiCameraStatus.stalled,
    );
  }

  void _fail(String message, PiCameraStatus status) {
    // Tear the connection down without waiting for it, but keep its
    // cancellation chained so a later reload cannot re-listen too early.
    _detaching = _detach();
    _message = message;
    _setStatus(status);
  }

  Future<void> _pollStats() async {
    if (_disposed) {
      return;
    }
    try {
      final stats = await _transport.fetchStats();
      if (_disposed || _statsTimer == null) {
        return;
      }
      _stats = stats;
      if (!_statsFresh) {
        _statsFresh = true;
      }
      notifyListeners();
    } on Object {
      if (_disposed) {
        return;
      }
      // The counts are decoration on top of the video. A failed poll only
      // makes them stale; it must not tear down a stream that is still
      // delivering frames, or a hiccup in /stats would blank a good picture.
      if (_statsFresh) {
        _statsFresh = false;
        notifyListeners();
      }
    }
  }

  void _setStatus(PiCameraStatus status) {
    if (_disposed || _status == status) {
      return;
    }
    _status = status;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_detach());
    super.dispose();
  }
}