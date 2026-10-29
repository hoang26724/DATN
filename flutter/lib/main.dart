import 'dart:async';

import 'package:flutter/material.dart';

import 'bluetooth_transport.dart';
import 'camera_panel.dart';
import 'gamepad_controls.dart';
import 'pi_camera_link.dart';
import 'pi_camera_transport.dart';
import 'robot_link.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Robot Controller',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        // Console look: dark shell, one accent colour, rounded everything.
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.indigo,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const ControlPage(),
    );
  }
}

class ControlPage extends StatefulWidget {
  const ControlPage({super.key, this.link, this.camera});

  /// Injected by tests so the UI can be driven against a fake radio. The app
  /// itself leaves it null and gets a real [MethodChannelTransport].
  final RobotLink? link;

  /// Injected by tests so the camera panel never opens a socket. The app itself
  /// leaves it null and gets a real [HttpPiCameraTransport] to the Pi.
  final PiCameraLink? camera;

  @override
  State<ControlPage> createState() => _ControlPageState();
}

class _ControlPageState extends State<ControlPage> with WidgetsBindingObserver {
  /// Fixed size of the control pad, scaled to fit whatever the screen gives us.
  /// A 3x3 keypad: speed keys in the corners, directions on the sides, and the
  /// suction toggle in the middle.
  static const double _dialWidth = 320;
  static const double _dialHeight = 320;
  static const double _padButtonSize = 96;
  static const double _padGap = 8;

  late final RobotLink _link =
      widget.link ?? RobotLink(MethodChannelTransport());
  late final PiCameraLink _camera =
      widget.camera ?? PiCameraLink(HttpPiCameraTransport());

  /// Only dispose what this page created. An injected one belongs to whoever
  /// made it — tests reuse it across cases.
  bool get _ownsLink => widget.link == null;
  bool get _ownsCamera => widget.camera == null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _link.addListener(_onChanged);
    _camera.addListener(_onChanged);
    unawaited(_camera.start());
  }

  @override
  void dispose() {
    _link.removeListener(_onChanged);
    _camera.removeListener(_onChanged);
    if (_ownsLink) {
      _link.dispose();
    }
    if (_ownsCamera) {
      _camera.dispose();
    }
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Backgrounding, locking the screen, or a call must never leave the
    // motors running.
    if (state != AppLifecycleState.resumed) {
      _link.release();
      _link.releaseSpeed();
      _link.setFrontModule(false);
      // An Android socket that was parked while the app was away comes back
      // wedged more often than not, and a wedged MJPEG socket looks exactly
      // like a frozen picture. Drop it and open a fresh one on resume.
      unawaited(_camera.stop());
      return;
    }
    unawaited(_camera.start());
  }

  void _onChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  void _press(String command) => _link.hold(command);

  void _release() => _link.release();

  void _holdSpeed({required bool front, required int delta}) =>
      _link.holdSpeed(front: front, delta: delta);

  void _releaseSpeed() => _link.releaseSpeed();

  void _toggleAuto() => _link.setAutoMode(!_link.autoMode);

  void _toggleFrontModule() => _link.setFrontModule(!_link.frontModuleOn);

  void _toggleRelay() => _link.setRelay(!_link.relayOn);

  Future<void> _openDevicePicker() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => _DevicePicker(
        link: _link,
        onConnected: () => Navigator.of(context).pop(),
      ),
    );
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _disconnect() async {
    await _link.disconnect();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final connected = _link.isConnected;
    final auto = _link.autoMode;

    return Scaffold(
      appBar: AppBar(
        title: const Text('ROBOT PICKLEBALL'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Row(
              children: [
                LinkLamp(state: _link.state),
                const SizedBox(width: 8),
                Text(_statusLabel, style: theme.textTheme.labelMedium),
              ],
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            _ConnectionStrip(
              connected: connected,
              connecting: _link.state == RobotLinkState.connecting,
              error: _link.lastError,
              auto: auto,
              relayOn: _link.relayOn,
              onToggleAuto: _toggleAuto,
              onToggleRelay: _toggleRelay,
              onPick: _openDevicePicker,
              onDisconnect: _disconnect,
            ),
            // Camera above the pad, both sharing the leftover height. The pad
            // keeps its own aspect inside a FittedBox, so giving the camera a
            // fixed share instead of letting it grow keeps the thumb zones at a
            // predictable size.
            Expanded(
              flex: 5,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Center(
                  child: AspectRatio(
                    aspectRatio: 4 / 3,
                    child: CameraPanel(feed: _camera),
                  ),
                ),
              ),
            ),
            // The person / pickleball counts and the speed sliders live here,
            // between the picture and the pad: legible at a glance, and clear
            // of the video itself.
            _InfoStrip(
              persons: _camera.stats?.persons,
              pickleballs: _camera.stats?.pickleballs,
              statsFresh: _camera.statsFresh,
              frontSpeed: _link.frontSpeed,
              rearSpeed: _link.rearSpeed,
              auto: auto,
            ),
            Expanded(
              flex: 5,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                // A fixed canvas scaled down to fit. The pad keeps its shape
                // and its touch targets stay predictable on any screen, instead
                // of reflowing into something thumb-unfriendly on a short one.
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: SizedBox(
                    width: _dialWidth,
                    height: _dialHeight,
                    child: _PadGrid(
                      enabled: connected,
                      auto: auto,
                      frontModuleOn: _link.frontModuleOn,
                      onPress: _press,
                      onRelease: _release,
                      onSpeed: _holdSpeed,
                      onSpeedRelease: _releaseSpeed,
                      onToggleFrontModule: _toggleFrontModule,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String get _statusLabel {
    if (_link.state == RobotLinkState.connecting) {
      return 'Đang kết nối...';
    }
    return _link.isConnected ? 'Đã kết nối' : 'Chưa kết nối';
  }
}

/// The 3x3 keypad.
///
///   1 2 3     1 suction speed down, 2 forward, 3 drive speed down
///   4 5 6     4 turn left, 5 toggle the suction brush, 6 turn right
///   7 8 9     7 suction speed up, 8 backward, 9 drive speed up
///
/// The four direction keys are hold-to-drive; the corner keys are hold-to-ramp;
/// the middle key is a tap that toggles L298N #1 (the suction brush). Auto mode
/// lives in the top strip.
class _PadGrid extends StatelessWidget {
  const _PadGrid({
    required this.enabled,
    required this.auto,
    required this.frontModuleOn,
    required this.onPress,
    required this.onRelease,
    required this.onSpeed,
    required this.onSpeedRelease,
    required this.onToggleFrontModule,
  });

  final bool enabled;
  final bool auto;
  final bool frontModuleOn;
  final ValueChanged<String> onPress;
  final VoidCallback onRelease;
  final void Function({required bool front, required int delta}) onSpeed;
  final VoidCallback onSpeedRelease;
  final VoidCallback onToggleFrontModule;

  @override
  Widget build(BuildContext context) {
    const button = _ControlPageState._padButtonSize;
    const gap = _ControlPageState._padGap;
    // Driving is impossible while the Pi holds the wheel, so those keys go
    // dead in auto mode. Speed still applies, so it stays live.
    final driveEnabled = enabled && !auto;

    Widget cell(Widget child) =>
        SizedBox(width: button, height: button, child: child);

    Widget row(List<Widget> children) => Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) const SizedBox(width: gap),
          children[i],
        ],
      ],
    );

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        row([
          cell(
            SpeedButton(
              module: 1,
              icon: Icons.add,
              label: 'Tăng tốc hút',
              enabled: enabled,
              onPressed: () => onSpeed(front: true, delta: RobotLink.speedStep),
              onReleased: onSpeedRelease,
              size: button,
            ),
          ),
          cell(
            DirectionButton(
              command: 'F',
              label: 'Tiến',
              icon: Icons.keyboard_arrow_up,
              enabled: driveEnabled,
              onPressed: onPress,
              onReleased: onRelease,
              size: button,
            ),
          ),
          cell(
            SpeedButton(
              module: 2,
              icon: Icons.add,
              label: 'Tăng tốc chạy',
              enabled: enabled,
              onPressed: () =>
                  onSpeed(front: false, delta: RobotLink.speedStep),
              onReleased: onSpeedRelease,
              size: button,
            ),
          ),
        ]),
        const SizedBox(height: gap),
        row([
          cell(
            DirectionButton(
              command: 'L',
              label: 'Sang trái',
              icon: Icons.chevron_left,
              enabled: driveEnabled,
              onPressed: onPress,
              onReleased: onRelease,
              size: button,
            ),
          ),
          cell(
            PadToggleButton(
              icon: Icons.power,
              label: 'Bật tắt hút',
              active: frontModuleOn,
              enabled: enabled,
              onPressed: onToggleFrontModule,
              size: button,
            ),
          ),
          cell(
            DirectionButton(
              command: 'R',
              label: 'Sang phải',
              icon: Icons.chevron_right,
              enabled: driveEnabled,
              onPressed: onPress,
              onReleased: onRelease,
              size: button,
            ),
          ),
        ]),
        const SizedBox(height: gap),
        row([
          cell(
            SpeedButton(
              module: 1,
              icon: Icons.remove,
              label: 'Giảm tốc hút',
              enabled: enabled,
              onPressed: () =>
                  onSpeed(front: true, delta: -RobotLink.speedStep),
              onReleased: onSpeedRelease,
              size: button,
            ),
          ),
          cell(
            DirectionButton(
              command: 'B',
              label: 'Lùi',
              icon: Icons.keyboard_arrow_down,
              enabled: driveEnabled,
              onPressed: onPress,
              onReleased: onRelease,
              size: button,
            ),
          ),
          cell(
            SpeedButton(
              module: 2,
              icon: Icons.remove,
              label: 'Giảm tốc chạy',
              enabled: enabled,
              onPressed: () =>
                  onSpeed(front: false, delta: -RobotLink.speedStep),
              onReleased: onSpeedRelease,
              size: button,
            ),
          ),
        ]),
      ],
    );
  }
}

/// Strip between the camera and the pad: person / pickleball counts on the
/// left, the two speed sliders on the right, plus an auto-mode badge.
class _InfoStrip extends StatelessWidget {
  const _InfoStrip({
    required this.persons,
    required this.pickleballs,
    required this.statsFresh,
    required this.frontSpeed,
    required this.rearSpeed,
    required this.auto,
  });

  final int? persons;
  final int? pickleballs;
  final bool statsFresh;
  final int frontSpeed;
  final int rearSpeed;
  final bool auto;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          _count(
            theme,
            label: 'Người',
            value: persons,
            fresh: statsFresh,
            dot: const Color(0xFFFF6B6B),
          ),
          const SizedBox(width: 12),
          _count(
            theme,
            label: 'Bóng',
            value: pickleballs,
            fresh: statsFresh,
            dot: const Color(0xFFFFD34E),
          ),
          const Spacer(),
          _speed(theme, 'Tốc độ hút', frontSpeed, theme.colorScheme.primary),
          const SizedBox(width: 10),
          _speed(theme, 'Tốc độ chạy', rearSpeed, theme.colorScheme.tertiary),
          if (auto) ...[
            const SizedBox(width: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: theme.colorScheme.tertiary,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                'AUTO',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onTertiary,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _count(
    ThemeData theme, {
    required String label,
    required int? value,
    required bool fresh,
    required Color dot,
  }) {
    final shown = (value == null || !fresh) ? '--' : '$value';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
        ),
        const SizedBox(width: 5),
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(width: 4),
        Text(
          shown,
          style: theme.textTheme.labelMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }

  Widget _speed(ThemeData theme, String label, int percent, Color color) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$percent%',
          style: theme.textTheme.labelMedium?.copyWith(
            color: color,
            fontWeight: FontWeight.bold,
          ),
        ),
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// Header strip: the auto, relay and connect/disconnect controls, spread evenly
/// across one row. The app bar already owns the connection status, so the strip
/// does not repeat the robot name or address.
class _ConnectionStrip extends StatelessWidget {
  const _ConnectionStrip({
    required this.connected,
    required this.connecting,
    required this.error,
    required this.auto,
    required this.relayOn,
    required this.onToggleAuto,
    required this.onToggleRelay,
    required this.onPick,
    required this.onDisconnect,
  });

  final bool connected;
  final bool connecting;
  final String error;
  final bool auto;
  final bool relayOn;
  final VoidCallback onToggleAuto;
  final VoidCallback onToggleRelay;
  final VoidCallback onPick;
  final VoidCallback onDisconnect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final stripStyle = FilledButton.styleFrom(
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      textStyle: theme.textTheme.labelSmall,
    );

    // Auto: lit while the Pi owns the wheels, inert until the robot link is up.
    final autoButton = auto
        ? FilledButton(
            onPressed: connecting || !connected ? null : onToggleAuto,
            style: stripStyle,
            child: const Text('Tự động'),
          )
        : FilledButton.tonal(
            onPressed: connecting || !connected ? null : onToggleAuto,
            style: stripStyle,
            child: const Text('Tự động'),
          );
    // Relay: lit while the GPIO-32 pin is closed, inert until the robot link is
    // up. Absolute Y1/Y0 on the wire, so the label and the pin cannot drift
    // apart after a reconnect.
    final relayButton = relayOn
        ? FilledButton(
            onPressed: connecting || !connected ? null : onToggleRelay,
            style: stripStyle,
            child: const Text('Relay bật'),
          )
        : FilledButton.tonal(
            onPressed: connecting || !connected ? null : onToggleRelay,
            style: stripStyle,
            child: const Text('Relay'),
          );
    final linkButton = FilledButton.tonalIcon(
      onPressed: connecting ? null : (connected ? onDisconnect : onPick),
      style: stripStyle,
      icon: Icon(
        connected ? Icons.bluetooth_disabled : Icons.bluetooth,
        size: 16,
      ),
      label: Text(connected ? 'Ngắt' : 'Kết nối'),
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: autoButton),
              const SizedBox(width: 8),
              Expanded(child: relayButton),
              const SizedBox(width: 8),
              Expanded(child: linkButton),
            ],
          ),
          if (error.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                error,
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
              ),
            ),
        ],
      ),
    );
  }
}

/// Bottom sheet that lists paired robots and connects to one.
///
/// Pairing is never done here: Android only lets the system settings pair a
/// device, so the sheet offers a button that jumps there.
class _DevicePicker extends StatefulWidget {
  const _DevicePicker({required this.link, required this.onConnected});

  final RobotLink link;
  final VoidCallback onConnected;

  @override
  State<_DevicePicker> createState() => _DevicePickerState();
}

class _DevicePickerState extends State<_DevicePicker> {
  List<BluetoothDevice> _devices = const [];
  String _error = '';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      await widget.link.ensureReady();
      final devices = await widget.link.pairedDevices();
      if (!mounted) {
        return;
      }
      setState(() {
        _devices = devices;
        _loading = false;
      });
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _devices = const [];
        _loading = false;
        _error = MethodChannelTransport.describe(error);
      });
    }
  }

  Future<void> _connect(BluetoothDevice device) async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      await widget.link.connect(device);
      widget.onConnected();
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _error = MethodChannelTransport.describe(error);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Robot đã ghép nối', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Chỉ robot đã ghép nối với điện thoại mới xuất hiện ở đây.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            if (_error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  _error,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_devices.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(
                  'Chưa có robot nào được ghép nối.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium,
                ),
              )
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _devices.length,
                  itemBuilder: (context, index) {
                    final device = _devices[index];
                    return ListTile(
                      leading: const Icon(Icons.bluetooth),
                      title: Text(device.label),
                      subtitle: Text(device.address),
                      onTap: _loading ? null : () => _connect(device),
                    );
                  },
                ),
              ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _loading
                        ? null
                        : widget.link.openBluetoothSettings,
                    icon: const Icon(Icons.settings),
                    label: const Text('Cài đặt BT'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _loading ? null : _load,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Quét lại'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
