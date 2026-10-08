import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;

/// Address of the Raspberry Pi that serves the camera dashboard.
///
/// The phone and the Pi have to be on the same network for any of this to work.
/// Nothing here discovers the Pi: the address is fixed in the firmware brief.
const String kPiCameraHost = '10.193.56.100';

/// Port the dashboard in `raspberry/pickleball.py` listens on.
const int kPiCameraPort = 8000;

/// The counts the Pi draws onto the picture, as served by `/stats`.
///
/// The web page reads them out of the pixels; the app shows them as text, so
/// both read the same numbers from the same place rather than from two
/// different code paths.
class PiCameraStats {
  const PiCameraStats({
    required this.persons,
    required this.pickleballs,
    required this.fps,
  });

  final int persons;
  final int pickleballs;
  final double fps;

  /// Parses `/stats`. Returns null when the body is not the shape we expect, so
  /// a future or broken Pi build degrades to "no numbers" instead of throwing
  /// on every poll.
  static PiCameraStats? tryParse(String body) {
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      return null;
    }
    if (decoded is! Map<String, dynamic>) {
      return null;
    }
    final persons = _asInt(decoded['person']);
    final pickleballs = _asInt(decoded['pickleball']);
    final fps = _asDouble(decoded['fps']);
    if (persons == null || pickleballs == null || fps == null) {
      return null;
    }
    return PiCameraStats(
      persons: persons,
      pickleballs: pickleballs,
      fps: fps,
    );
  }

  static int? _asInt(Object? value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.round();
    }
    return null;
  }

  static double? _asDouble(Object? value) {
    if (value is num) {
      return value.toDouble();
    }
    return null;
  }
}

/// The camera side of the robot, as a stream of JPEGs plus a stats poll.
///
/// An interface for the same reason [RobotTransport] is one: the widget and the
/// link must be testable without a Raspberry Pi on the network.
abstract class PiCameraTransport {
  /// Frames of the MJPEG stream, in order. Closes when the stream ends.
  Stream<Uint8List> openStream();

  /// Reads `/stats`. Throws when the Pi is unreachable.
  Future<PiCameraStats> fetchStats();
}

/// Real transport: two plain HTTP requests against the Pi dashboard.
class HttpPiCameraTransport implements PiCameraTransport {
  HttpPiCameraTransport({
    this.host = kPiCameraHost,
    this.port = kPiCameraPort,
    HttpClient? client,
    this.connectTimeout = const Duration(seconds: 6),
  }) : _client = client ?? HttpClient();

  final String host;
  final int port;
  final HttpClient _client;
  final Duration connectTimeout;

  Uri _uri(String path) => Uri.parse('http://$host:$port$path');

  @override
  Stream<Uint8List> openStream() async* {
    // The stream never ends on its own, so it must not be a broadcast stream
    // and must not be awaited to completion anywhere.
    final request = await _client
        .getUrl(_uri('/stream.mjpg'))
        .timeout(connectTimeout);
    request.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException(
        'Camera trả về HTTP ${response.statusCode}',
        uri: _uri('/stream.mjpg'),
      );
    }
    final splitter = MjpegSplitter();
    await for (final chunk in response) {
      for (final frame in splitter.add(chunk)) {
        yield frame;
      }
    }
  }

  @override
  Future<PiCameraStats> fetchStats() async {
    final request = await _client.getUrl(_uri('/stats')).timeout(connectTimeout);
    request.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
    final response = await request.close().timeout(connectTimeout);
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException(
        'Máy chủ trả về HTTP ${response.statusCode}',
        uri: _uri('/stats'),
      );
    }
    final stats = PiCameraStats.tryParse(body);
    if (stats == null) {
      throw const FormatException('Nội dung /stats không đúng định dạng');
    }
    return stats;
  }
}

/// Splits a `multipart/x-mixed-replace` byte stream into whole JPEG frames.
///
/// The Pi writes each part as a boundary line, a header block, then exactly
/// `Content-Length` bytes of JPEG, so the length in the headers is the only
/// thing trusted. Bytes arriving in arbitrary chunk sizes are fine: a frame
/// split across three chunks, or three frames inside one chunk, both come out
/// whole.
class MjpegSplitter {
  MjpegSplitter({String boundary = 'FRAME'})
      : _marker = ascii.encode('--$boundary'),
        _headerEnd = ascii.encode('\r\n\r\n');

  final List<int> _marker;
  final List<int> _headerEnd;

  /// Bytes received but not yet emitted or discarded.
  final List<int> _buffer = <int>[];

  /// Absolute stream position of `_buffer[0]`. Every cursor below is absolute,
  /// which is what keeps a truncated buffer from invalidating them.
  int _base = 0;

  /// Absolute index the next boundary search may start at.
  int _markerFrom = 0;

  /// Absolute index of the first body byte, or -1 while reading headers.
  int _bodyAt = -1;
  int _contentLength = 0;

  /// Bytes currently held back waiting for the rest of a frame.
  ///
  /// Exposed for the test that proves the buffer is released as it goes: a
  /// stream that never drops consumed bytes takes the app down within minutes.
  @visibleForTesting
  int get bufferedBytes => _buffer.length;

  /// Feeds [chunk] in and returns every frame it completed.
  List<Uint8List> add(List<int> chunk) {
    _buffer.addAll(chunk);
    final frames = <Uint8List>[];

    while (true) {
      if (_bodyAt < 0) {
        final markerAt = _indexOf(_marker, _markerFrom);
        if (markerAt < 0) {
          // Keep just enough tail for a boundary that straddles two chunks.
          final earliest = _base + _buffer.length - _marker.length + 1;
          _markerFrom = earliest > _base ? earliest : _base;
          break;
        }
        final headersAt = _indexOf(_headerEnd, markerAt + _marker.length);
        if (headersAt < 0) {
          _markerFrom = markerAt;
          break;
        }
        final length = _contentLengthOf(markerAt + _marker.length, headersAt);
        if (length < 0) {
          // Malformed part: skip it rather than wedge on its headers forever.
          _markerFrom = headersAt + _headerEnd.length;
          continue;
        }
        _contentLength = length;
        _bodyAt = headersAt + _headerEnd.length;
      }

      final end = _bodyAt + _contentLength;
      if (_buffer.length + _base < end) {
        break;
      }
      final from = _bodyAt - _base;
      frames.add(Uint8List.fromList(_buffer.sublist(from, from + _contentLength)));
      _bodyAt = -1;
      _markerFrom = end;
    }

    // Everything before the oldest cursor is already accounted for: either a
    // whole frame was emitted, or it is garbage we will never look at again.
    final keepFrom = _bodyAt >= 0 ? _bodyAt : _markerFrom;
    final discard = keepFrom - _base;
    if (discard > 0) {
      _buffer.removeRange(0, discard);
      _base = keepFrom;
    }
    return frames;
  }

  /// Searches [_buffer] for [needle] from the absolute offset [from].
  int _indexOf(List<int> needle, int from) {
    var i = from - _base;
    if (i < 0) {
      i = 0;
    }
    final limit = _buffer.length - needle.length;
    for (; i <= limit; i++) {
      var matched = true;
      for (var j = 0; j < needle.length; j++) {
        if (_buffer[i + j] != needle[j]) {
          matched = false;
          break;
        }
      }
      if (matched) {
        return _base + i;
      }
    }
    return -1;
  }

  /// Reads `Content-Length` out of the header block between the absolute
  /// offsets [from] and [to]. Returns -1 when it is absent or unusable.
  int _contentLengthOf(int from, int to) {
    if (to <= from) {
      return -1;
    }
    final headers = latin1.decode(
      _buffer.sublist(from - _base, to - _base),
      allowInvalid: true,
    );
    for (final line in headers.split('\r\n')) {
      final separator = line.indexOf(':');
      if (separator < 0) {
        continue;
      }
      final name = line.substring(0, separator).trim().toLowerCase();
      if (name != 'content-length') {
        continue;
      }
      final value = int.tryParse(line.substring(separator + 1).trim());
      if (value == null || value < 0) {
        return -1;
      }
      return value;
    }
    return -1;
  }
}