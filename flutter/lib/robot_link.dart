import 'dart:async';

import 'package:flutter/foundation.dart';

import 'bluetooth_transport.dart';

enum RobotLinkState { disconnected, connecting, connected }

/// Drives the ESP32 chassis: the command protocol, the keep-alive that feeds the
/// firmware watchdog, and link-loss detection.
///
/// Protocol: one ASCII line per command, each followed by `\n`. `F`/`B` drive
/// the main rear wheels, `L`/`R` turn, `S` stops them, `G1`/`G0` toggle the
/// L298N #1 suction brush and `f`/`r` set the two module speeds.
/// The bytes travel over a Bluetooth RFCOMM socket; nothing here knows that —
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

  /// How much one speed step moves the slider, and how fast a held speed
  /// button repeats. Holding for ~1 s crosses the full range.
  static const int speedStep = 10;
  static const Duration speedRepeatInterval = Duration(milliseconds: 150);

  static const int speedMin = 0;
  static const int speedMax = 100;

  Timer? _keepAlive;
  Timer? _frontKeepAlive;
  Timer? _speedRepeat;
  String? _heldCommand;
  String _lastError = '';
  String _lastMessage = '';
  String? _deviceName;

  int _frontSpeed = 100;
  int _rearSpeed = 50;
  bool _autoMode = false;
  bool _relayOn = false;
  bool _frontModuleOn = false;

  RobotLinkState _state = RobotLinkState.disconnected;

  RobotLinkState get state => _state;

  /// Speed of the front module (L298N #1), 0-100 %.
  int get frontSpeed => _frontSpeed;

  /// Speed of the rear module (L298N #2), 0-100 %.
  int get rearSpeed => _rearSpeed;

  /// True while the ESP32 has handed the wheels to the Raspberry Pi over UART.
  bool get autoMode => _autoMode;

  /// Last commanded state of the GPIO-32 relay. Always false while
  /// disconnected: the firmware opens the relay on link loss, so the two
  /// sides reset together.
  bool get relayOn => _relayOn;

  /// True while L298N #1 (the suction brush) is toggled on. It always runs
  /// forward and is kept alive by resending `G1`, because the firmware stops every
  /// motor after [firmwareCommandTimeout] without a command byte.
  bool get frontModuleOn => _frontModuleOn;

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
          .timeout(
            connectTimeout,
            onTimeout: () => throw TimeoutException(
              'Bluetooth connect timed out',
              connectTimeout,
            ),
          );
      _deviceName = device.label;
      _lastError = '';
      _setState(RobotLinkState.connected);
      // Push the current speed sliders to the firmware: the firmware has its
      // own boot defaults, but the value on screen is the truth.
      _write('f$_frontSpeed');
      _write('r$_rearSpeed');
    } on Object catch (error) {
      _stopKeepAlive();
      _stopFrontKeepAlive();
      _heldCommand = null;
      _frontModuleOn = false;
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
    _stopFrontKeepAlive();
    _stopSpeedRepeat();
    _heldCommand = null;
    _deviceName = null;
    _autoMode = false;
    _relayOn = false;
    _frontModuleOn = false;
    await _transport.disconnect();
    _setState(RobotLinkState.disconnected);
  }

  /// Sends [command] and keeps resending it until [release] is called.
  /// Safe to call repeatedly with the same command.
  void hold(String command) {
    if (!isConnected || _autoMode || _heldCommand == command) {
      return;
    }
    _heldCommand = command;
    _write(command);
    _keepAlive?.cancel();
    _keepAlive = Timer.periodic(keepAliveInterval, (_) => _write(command));
  }

  /// Stops the rear main drive and stops the direction keep-alive. Call this
  /// from every gesture that ends a press (lift, drag-off, cancel) and on app
  /// pause. L298N #1 keeps its own toggle state; on pause the page also calls
  /// [setFrontModule] with false.
  ///
  /// There is no STOP button on the pad, so this is the only thing that ever
  /// sends `S`: it therefore writes it unconditionally, and a release with
  /// nothing held is still a real stop rather than a no-op. Every entry point
  /// that can start a command has to end in a call to this.
  void release() {
    _stopKeepAlive();
    _heldCommand = null;
    _write('S');
  }

  /// Starts a held speed change: fires once at once, then repeats on a timer so
  /// the value ramps while the button is down. [front] picks module #1; the
  /// opposite module is untouched. No-op when disconnected or already at the
  /// limit.
  void holdSpeed({required bool front, required int delta}) {
    if (!isConnected) {
      return;
    }
    _changeSpeed(front: front, delta: delta);
    _speedRepeat?.cancel();
    _speedRepeat = Timer.periodic(
      speedRepeatInterval,
      (_) => _changeSpeed(front: front, delta: delta),
    );
  }

  /// Stops a held speed change. Safe to call when none is running.
  void releaseSpeed() => _stopSpeedRepeat();

  /// Arms or disarms the Raspberry-Pi auto driver. The firmware ignores drive
  /// commands while auto is on, so any held direction is dropped here too. The
  /// L298N #1 suction brush is left alone: it is not a drive and the operator
  /// may want it running while the Pi steers.
  void setAutoMode(bool value) {
    if (!isConnected || value == _autoMode) {
      return;
    }
    _stopKeepAlive();
    _heldCommand = null;
    _autoMode = value;
    _write(value ? 'A' : 'M');
    notifyListeners();
  }

  /// Toggles L298N #1, the suction brush. Written as an absolute `G1`/`G0`,
  /// never a toggle, and `G1` is resent on the keep-alive cadence while on so
  /// the firmware watchdog does not stop the module after 600 ms of silence.
  /// It stays available in auto mode because it is not part of the drive.
  void setFrontModule(bool on) {
    if (!isConnected || on == _frontModuleOn) {
      return;
    }
    _setFrontModule(on);
    notifyListeners();
  }

  /// Opens or closes the relay on GPIO 32. Written as an absolute `Y1`/`Y0`
  /// (never a toggle) so the button's lit state and the pin cannot drift after
  /// a reconnect. No-op when disconnected or already in the requested state.
  void setRelay(bool on) {
    if (!isConnected || on == _relayOn) {
      return;
    }
    _relayOn = on;
    _write(on ? 'Y1' : 'Y0');
    notifyListeners();
  }

  void _changeSpeed({required bool front, required int delta}) {
    final next = ((front ? _frontSpeed : _rearSpeed) + delta).clamp(
      speedMin,
      speedMax,
    );
    if (front) {
      if (next == _frontSpeed) {
        return;
      }
      _frontSpeed = next;
    } else {
      if (next == _rearSpeed) {
        return;
      }
      _rearSpeed = next;
    }
    _write('${front ? 'f' : 'r'}$next');
    notifyListeners();
  }

  void _setFrontModule(bool on) {
    _frontModuleOn = on;
    _stopFrontKeepAlive();
    _write(on ? 'G1' : 'G0');
    if (on) {
      _frontKeepAlive = Timer.periodic(keepAliveInterval, (_) => _write('G1'));
    }
  }

  void _stopSpeedRepeat() {
    _speedRepeat?.cancel();
    _speedRepeat = null;
  }

  void _stopKeepAlive() {
    _keepAlive?.cancel();
    _keepAlive = null;
  }

  void _stopFrontKeepAlive() {
    _frontKeepAlive?.cancel();
    _frontKeepAlive = null;
  }

  void _write(String command) {
    if (_transport.isConnected) {
      _transport.write('$command\n');
    }
  }

  void _handleLinkLost(String reason) {
    _stopKeepAlive();
    _stopFrontKeepAlive();
    _stopSpeedRepeat();
    _heldCommand = null;
    _deviceName = null;
    _autoMode = false;
    _relayOn = false;
    _frontModuleOn = false;
    // The status label already says "Chưa kết nối"; the raw link-loss reason
    // ("Mất kết nối Bluetooth.") is deliberately not surfaced in the UI.
    _lastError = '';
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
    _stopFrontKeepAlive();
    _stopSpeedRepeat();
    unawaited(_linkLostSub.cancel());
    unawaited(_messageSub.cancel());
    super.dispose();
  }
}
