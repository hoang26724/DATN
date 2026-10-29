import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'pi_camera_link.dart';

/// The Raspberry Pi camera, shown above the gamepad.
///
/// The picture is painted straight from a decoded [ui.Image] rather than an
/// [Image] widget, because at ~12 fps rebuilding the widget tree to swap
/// [Image.memory] buffers shows up as stutter on a mid-range phone.
///
/// Three ways out of a broken feed, in the order the user reaches for them:
/// tap the picture to reload, which is the single "reload the image"
/// affordance; the reconnect button in the middle appears on its own whenever
/// the link says it needs one. The panel carries no buttons of its own — the
/// strip above it owns those (Bluetooth, relay).
class CameraPanel extends StatefulWidget {
  const CameraPanel({
    required this.feed,
    this.aspectRatio = 4 / 3,
    super.key,
  });

  final PiCameraLink feed;

  /// The Pi streams 640x480, so 4:3 letterboxes instead of stretching.
  final double aspectRatio;

  @override
  State<CameraPanel> createState() => _CameraPanelState();
}

class _CameraPanelState extends State<CameraPanel> {
  static const Duration _decodeRetryGap = Duration(seconds: 3);

  ui.Image? _image;

  /// Guards against a slow decode of an old frame landing after a newer one.
  int _decodeToken = 0;

  /// Last reload this panel asked for because a frame would not decode. Keeps a
  /// Pi that sends nothing but corrupt JPEGs from turning into a reconnect loop.
  DateTime? _decodeRetryAt;

  @override
  void initState() {
    super.initState();
    widget.feed.addListener(_onFeedChanged);
    _decode(widget.feed.frame);
  }

  @override
  void didUpdateWidget(CameraPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.feed, widget.feed)) {
      oldWidget.feed.removeListener(_onFeedChanged);
      widget.feed.addListener(_onFeedChanged);
      _decode(widget.feed.frame);
    }
  }

  @override
  void dispose() {
    widget.feed.removeListener(_onFeedChanged);
    // The feed is owned by the page, not by this widget, so only the decoded
    // image is ours to free. The stream keeps running across navigation.
    _image?.dispose();
    _image = null;
    super.dispose();
  }

  void _onFeedChanged() {
    if (!mounted) {
      return;
    }
    setState(() {});
    final frame = widget.feed.frame;
    if (frame != null) {
      _decode(frame);
    }
  }

  Future<void> _decode(Uint8List? bytes) async {
    if (bytes == null) {
      return;
    }
    final token = ++_decodeToken;
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      if (!mounted || token != _decodeToken) {
        frame.image.dispose();
        codec.dispose();
        return;
      }
      final previous = _image;
      setState(() => _image = frame.image);
      previous?.dispose();
      codec.dispose();
    } on Object {
      // A torn JPEG means the stream is desynchronised. Ask the link to start
      // over rather than leaving a half-drawn frame on screen, but rate-limit
      // it: a Pi that only ever sends garbage must not become a reconnect loop.
      final now = DateTime.now();
      final last = _decodeRetryAt;
      if (mounted && token == _decodeToken && (last == null || now.difference(last) > _decodeRetryGap)) {
        _decodeRetryAt = now;
        unawaited(widget.feed.reload());
      }
    }
  }

  void _reload() => unawaited(widget.feed.reload());

  @override
  Widget build(BuildContext context) {
    final feed = widget.feed;

    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: ColoredBox(
        color: Colors.black,
        child: Stack(
          fit: StackFit.expand,
          children: [
            _picture(feed),
            if (feed.stats != null) _statsOverlay(context, feed),
            _statusOverlay(context, feed),
          ],
        ),
      ),
    );
  }

  Widget _picture(PiCameraLink feed) {
    final image = _image;
    if (image == null) {
      return const SizedBox.shrink();
    }
    // Tap the picture to reload — the only reload affordance while the stream
    // still shows a picture. The status overlay sits above this, so taps that
    // land on it never reach here.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _reload,
      child: CustomPaint(painter: _FramePainter(image)),
    );
  }

  /// Only the FPS is drawn on the picture. The person and pickleball counts
  /// live below the frame (see the stats strip in `ControlPage`), where they
  /// stay readable without covering the video.
  Widget _statsOverlay(BuildContext context, PiCameraLink feed) {
    final theme = Theme.of(context);
    final stats = feed.stats;
    if (stats == null) {
      return const SizedBox.shrink();
    }
    final stale = !feed.statsFresh;
    final value = stale ? '--' : stats.fps.toStringAsFixed(1);

    return Positioned(
      top: 8,
      left: 8,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: const BoxDecoration(
                  color: Color(0xFF5EE7F7),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                'FPS: ',
                style: theme.textTheme.labelSmall?.copyWith(color: Colors.white70),
              ),
              Text(
                value,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Everything the user sees when there is no picture: the message from the
  /// link, and the reconnect button in the middle of the frame.
  Widget _statusOverlay(BuildContext context, PiCameraLink feed) {
    final theme = Theme.of(context);
    final connecting = feed.status == PiCameraStatus.connecting;
    if (!connecting && !feed.needsReconnect && _image != null) {
      return const SizedBox.shrink();
    }

    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.62),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                connecting ? Icons.hourglass_empty : Icons.videocam_off_outlined,
                color: Colors.white70,
                size: 34,
              ),
              const SizedBox(height: 8),
              Text(
                connecting ? 'Đang mở camera...' : feed.message,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(color: Colors.white),
              ),
              if (!connecting) ...[
                const SizedBox(height: 12),
                // Centred on purpose: this is the one control that has to be
                // reachable the moment the picture dies.
                FilledButton.icon(
                  onPressed: _reload,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Kết nối lại'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Draws one decoded frame, letterboxed inside the panel.
class _FramePainter extends CustomPainter {
  const _FramePainter(this.image);

  final ui.Image image;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      _fitInside(size, image.width, image.height),
      Paint()..filterQuality = FilterQuality.medium,
    );
  }

  static Rect _fitInside(Size size, int width, int height) {
    if (width <= 0 || height <= 0) {
      return Offset.zero & size;
    }
    final scale = (size.width / width) < (size.height / height)
        ? size.width / width
        : size.height / height;
    final drawn = Size(width * scale, height * scale);
    return Rect.fromLTWH(
      (size.width - drawn.width) / 2,
      (size.height - drawn.height) / 2,
      drawn.width,
      drawn.height,
    );
  }

  @override
  bool shouldRepaint(_FramePainter oldDelegate) =>
      !identical(oldDelegate.image, image);
}