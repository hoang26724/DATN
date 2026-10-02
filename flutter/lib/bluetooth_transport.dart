import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// A Bluetooth device the phone has already paired with.
///
/// Only bonded devices are listed. Pairing always happens in the system
/// Bluetooth settings first; nothing here can discover or pair a device.
@immutable
class BluetoothDevice {
  const BluetoothDevice({required this.address, required this.name});

  /// MAC address as reported by the platform, e.g. `AA:BB:CC:DD:EE:FF`.
  final String address;
  final String name;

  /// Display label. Falls back to the address so a device with an empty or
  /// missing name is still selectable in the list.
  String get label => name.trim().isEmpty ? address : name.trim();

  @override
  bool operator ==(Object other) =>
      other is BluetoothDevice && other.address == address;

  @override
  int get hashCode => address.hashCode;

  @override
  String toString() => '$label ($address)';
}

/// Bluetooth is unusable right now: no adapter, switched off, permission
/// refused, or nothing paired. [message] is already written for a human, so
/// the UI can show it verbatim instead of formatting an exception.
class BluetoothUnavailable implements Exception {
  const BluetoothUnavailable(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The wire between the app and the robot: pairing, an open socket, and bytes.
///
/// This exists for two reasons. `RobotLink` (protocol, keep-alive, watchdog)
/// can then be tested against a fake instead of real hardware, and every
/// Bluetooth-specific API stays in one file instead of leaking into widgets.
///
/// Implementations must be usable from tests on any host: nothing here may
/// assume a phone.
abstract class RobotTransport {
  /// True between a successful [connect] and [disconnect] or a [linkLostReasons]
  /// event.
  bool get isConnected;

  /// Fires when the socket drops for any reason, including the robot walking
  /// out of range. Never fires for a [disconnect] the app asked for.
  Stream<String> get linkLostReasons;

  /// Text the robot sent, purely for the diagnostics line in the UI.
  Stream<String> get messages;

  /// Throws [BluetoothUnavailable] unless the radio is present, enabled, and
  /// permitted.
  Future<void> ensureReady();

  /// Devices already bonded to this phone. Empty when nothing is paired.
  Future<List<BluetoothDevice>> pairedDevices();

  /// Opens the system Bluetooth settings so the user can pair a new robot.
  Future<void> openBluetoothSettings();

  /// Opens an RFCOMM socket to [device]. Throws if the link cannot be opened.
  Future<void> connect(BluetoothDevice device);

  Future<void> disconnect();

  /// Fire-and-forget write of [data], exactly as given.
  void write(String data);
}

/// [RobotTransport] over a platform channel to the Android host.
///
/// Classic Bluetooth (RFCOMM/SPP), not BLE. The ESP32 advertises as
/// `ESP32_ROBOT` and expects PIN `1234`; both live in `bluetooth_config.h` on
/// the firmware side.
class MethodChannelTransport implements RobotTransport {
  MethodChannelTransport({
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
  })  : _method = methodChannel ?? const MethodChannel(methodChannelName),
        _events = eventChannel ?? const EventChannel(eventChannelName) {
    _events.receiveBroadcastStream().listen(
      _onEvent,
      // A broken event stream means we will never hear about a dropped link,
      // so treat it as one rather than leaving the UI showing "connected"
      // while the motors run.
      onError: (Object error) => _linkLost.add('Mất kết nối Bluetooth: $error'),
    );
  }

  static const String methodChannelName =
      'com.example.app_control_robot/bluetooth';
  static const String eventChannelName =
      'com.example.app_control_robot/bluetooth/events';

  final MethodChannel _method;
  final EventChannel _events;
  final StreamController<String> _linkLost = StreamController.broadcast();
  final StreamController<String> _messages = StreamController.broadcast();

  bool _connected = false;

  @override
  bool get isConnected => _connected;

  @override
  Stream<String> get linkLostReasons => _linkLost.stream;

  @override
  Stream<String> get messages => _messages.stream;

  @override
  Future<void> ensureReady() async {
    await _invoke('ensureReady');
  }

  @override
  Future<List<BluetoothDevice>> pairedDevices() async {
    final raw = await _invoke('pairedDevices');
    if (raw is! List) {
      return const [];
    }
    final devices = <BluetoothDevice>[];
    for (final entry in raw) {
      if (entry is! Map) {
        continue;
      }
      final address = entry['address'];
      if (address is! String || address.isEmpty) {
        continue;
      }
      final name = entry['name'];
      devices.add(
        BluetoothDevice(address: address, name: name is String ? name : ''),
      );
    }
    return devices;
  }

  @override
  Future<void> openBluetoothSettings() => _invoke('openBluetoothSettings');

  @override
  Future<void> connect(BluetoothDevice device) async {
    await disconnect();
    await _invoke('connect', {'address': device.address, 'name': device.name});
    _connected = true;
  }

  @override
  Future<void> disconnect() async {
    final wasConnected = _connected;
    _connected = false;
    if (!wasConnected) {
      return;
    }
    try {
      await _method.invokeMethod<void>('disconnect');
    } on Object {
      // The host already tore the socket down; nothing useful to do.
    }
  }

  @override
  void write(String data) {
    if (!_connected) {
      return;
    }
    _method.invokeMethod<void>('write', {'data': data}).catchError(
      (Object error) => _linkLost.add(describe(error)),
    );
  }

  Future<Object?> _invoke(String method, [Map<String, Object?>? arguments]) async {
    try {
      return await _method.invokeMethod<Object?>(method, arguments);
    } on PlatformException catch (error) {
      // The host writes these messages for the user, so pass them through
      // instead of replacing them with a code like "no_devices".
      throw BluetoothUnavailable(error.message ?? 'Lỗi Bluetooth: ${error.code}');
    }
  }

  void _onEvent(dynamic event) {
    if (event is! Map) {
      return;
    }
    final type = event['type'];
    if (type == 'message') {
      final text = event['text'];
      if (text is String && text.trim().isNotEmpty) {
        _messages.add(text.trim());
      }
    } else if (type == 'linkLost') {
      final reason = event['reason'];
      _connected = false;
      _linkLost.add(
        reason is String && reason.trim().isNotEmpty
            ? reason.trim()
            : 'Robot đã ngắt kết nối',
      );
    }
  }

  void dispose() {
    unawaited(disconnect());
    _linkLost.close();
    _messages.close();
  }

  static String describe(Object error) {
    if (error is BluetoothUnavailable) {
      return error.message;
    }
    if (error is PlatformException) {
      return error.message ?? 'Lỗi Bluetooth: ${error.code}';
    }
    if (error is TimeoutException) {
      return 'Kết nối Bluetooth quá thời gian chờ';
    }
    return error.toString();
  }
}
