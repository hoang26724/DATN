import 'dart:async';

import 'package:flutter/foundation.dart';

import 'bluetooth_transport.dart';

enum RobotLinkState { disconnected, connecting, connected }

/// Drives the ESP32 chassis: the command protocol, the keep-alive that feeds the
/// firmware watchdog, and link-loss detection.
///
/// Protocol, unchanged from the WiFi version: one ASCII character per command,
/// `F`/`B`/`L`/`R`/`S`, each followed by `\n`. The bytes now travel over a
/// Bluetooth RFCOMM socket instead of a TCP one, but nothing here knows that —
/// the transport does.
///
/// The firmware stops the motors if no byte arrives within
/// [firmwareCommandTimeout], so a held command is resent on a timer. That makes
/// this class the only place the protocol and the watchdog have to agree.
class RobotLink extends ChangeNotifier {
  /// Must match `COMMAND_TIMEOUT_MS` in the firmware.
  static const Duration firmwareCommandTimeout = Duration(milliseconds: 600);

  /// How often a held command is resent. Must stay well below the firmware's
  /// 600 ms safety window so the motors never stop mid-hold.
  final Duration keepAliveInterval;

  /// Upper bound on one `BluetoothSocket` connect. Generous because the host
  /// blocks on an RFCOMM handshake that can take several seconds.
  final Duration connectTimeout;

  RobotLink(
    RobotTransport transport, {
    this.keepAliveInterval = const Duration(milliseconds: 200),
    this.connectTimeout = const Duration(seconds: 15),
  }) : _transport = transport {
    // The firmware stops the motors once the watchdog expires, so a keep-alive
    // slower than that window would make a held button stutter-and-stop
    // instead of driving continuously.
    if (keepAliveInterval >= firmwareCommandTimeout) {
      throw ArgumentError.value(
        keepAliveInterval,
        'keepAliveInterval',
        'must be shorter than the firmware watchdog window '
            '($firmwareCommandTimeout) or held commands will cut out',
      );
    }
    _linkLostSub = _transport.linkLostReasons.listen(_handleLinkLost);
    _messageSub = _transport.messages.listen((text) {
      _lastMessage = text;
      notifyListeners();
    });
  }

  final RobotTransport _transport;
  late final StreamSubscription<String> _linkLostSub;
  late final StreamSubscription<String> _messageSub;

  Timer? _keepAlive;
  String? _heldCommand;
  String _lastError = '';
  String _lastMessage = '';
  String? _deviceName;

  RobotLinkState _state = RobotLinkState.disconnected;

  RobotLinkState get state => _state;

  String get lastError => _lastError;

  /// Last line the robot sent over the socket, for the diagnostics strip.
  String get lastMessage => _lastMessage;

  bool get isConnected => _state == RobotLinkState.connected;

  /// The command currently being held, or null when the robot is stopped.
  ///
  /// The on-screen buttons highlight themselves from their own press state, so
  /// nothing in the UI has to read this; it is kept as the link's own answer to
  /// "what is the robot being told to do right now".
  String? get activeCommand => _heldCommand;

  String? get deviceName => _deviceName;

  /// Throws [BluetoothUnavailable] when the radio is off, unpermitted, or has
  /// nothing paired. Call before showing the device list.
  Future<void> ensureReady() => _transport.ensureReady();

  Future<List<BluetoothDevice>> pairedDevices() => _transport.pairedDevices();

  Future<void> openBluetoothSettings() => _transport.openBluetoothSettings();

  /// Opens the socket to [device]. Throws if the robot is unreachable; the
  /// caller is responsible for surfacing that to the user.
  Future<void> connect(BluetoothDevice device) async {
    await disconnect();
    _setState(RobotLinkState.connecting);
    try {
      await _transport
          .connect(device)
          .timeout(connectTimeout, onTimeout: () => throw TimeoutException(
                'Bluetooth connect timed out',
                connectTimeout,
              ));
      _deviceName = device.label;
      _lastError = '';
      _setState(RobotLinkState.connected);
    } on Object catch (error) {
      _stopKeepAlive();
      _heldCommand = null;
      _deviceName = null;
      // The host may have half-opened a socket before failing; make sure it is
      // not left dangling before the UI offers another attempt.
      await _transport.disconnect();
      _lastError = MethodChannelTransport.describe(error);
      _setState(RobotLinkState.disconnected);
      rethrow;
    }
  }

  Future<void> disconnect() async {
    _stopKeepAlive();
    _heldCommand = null;
    _deviceName = null;
    await _transport.disconnect();
    _setState(RobotLinkState.disconnected);
  }

  /// Sends [command] and keeps resending it until [release] is called.
  /// Safe to call repeatedly with the same command.
  void hold(String command) {
    if (!isConnected || _heldCommand == command) {
      return;
    }
    _heldCommand = command;
    _write(command);
    _keepAlive?.cancel();
    _keepAlive = Timer.periodic(keepAliveInterval, (_) => _write(command));
  }

  /// Stops the robot and stops the keep-alive timer. Call this from every
  /// gesture that ends a press (lift, drag-off, cancel) and on app pause.
  ///
  /// Sends `S` even when no command was held, so the emergency stop button is
  /// never a no-op while the link is up.
  void release() {
    _stopKeepAlive();
    _heldCommand = null;
    _write('S');
  }

  void _stopKeepAlive() {
    _keepAlive?.cancel();
    _keepAlive = null;
  }

  void _write(String command) {
    if (_transport.isConnected) {
      _transport.write('$command\n');
    }
  }

  void _handleLinkLost(String reason) {
    _stopKeepAlive();
    _heldCommand = null;
    _deviceName = null;
    _lastError = reason;
    _setState(RobotLinkState.disconnected);
  }

  void _setState(RobotLinkState next) {
    if (_state == next) {
      return;
    }
    _state = next;
    notifyListeners();
  }

  @override
  void dispose() {
    _stopKeepAlive();
    unawaited(_linkLostSub.cancel());
    unawaited(_messageSub.cancel());
    super.dispose();
  }
}
