import 'dart:async';

import 'package:flutter/material.dart';

import 'bluetooth_transport.dart';
import 'gamepad_controls.dart';
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
  const ControlPage({super.key, this.link});

  /// Injected by tests so the UI can be driven against a fake radio. The app
  /// itself leaves it null and gets a real [MethodChannelTransport].
  final RobotLink? link;

  @override
  State<ControlPage> createState() => _ControlPageState();
}

class _ControlPageState extends State<ControlPage> with WidgetsBindingObserver {
  /// Fixed size of the control pad, scaled to fit whatever the screen gives us.
  static const double _dialWidth = 300;
  static const double _dialHeight = 216;

  late final RobotLink _link = widget.link ?? RobotLink(MethodChannelTransport());

  /// Only dispose a link this page created. An injected one belongs to whoever
  /// made it — tests reuse it across cases.
  bool get _ownsLink => widget.link == null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _link.addListener(_onLinkChanged);
  }

  @override
  void dispose() {
    _link.removeListener(_onLinkChanged);
    if (_ownsLink) {
      _link.dispose();
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
    }
  }

  void _onLinkChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  void _press(String command) => _link.hold(command);

  void _release() => _link.release();

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

    return Scaffold(
      appBar: AppBar(
        title: const Text('ROBOT PANEL'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Row(
              children: [
                LinkLamp(state: _link.state),
                const SizedBox(width: 8),
                Text(
                  _statusLabel,
                  style: theme.textTheme.labelMedium,
                ),
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
              deviceName: _link.deviceName,
              error: _link.lastError,
              message: _link.lastMessage,
              onPick: _openDevicePicker,
              onDisconnect: _disconnect,
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                // A fixed canvas scaled down to fit. The pad keeps its shape
                // and its touch targets stay predictable on any screen, instead
                // of reflowing into something thumb-unfriendly on a short one.
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: SizedBox(
                    width: _dialWidth,
                    height: _dialHeight,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        // Left thumb: pivot on the spot.
                        _DirectionCluster(
                          enabled: connected,
                          onPressed: _press,
                          onReleased: _release,
                          buttons: const [
                            (command: 'L', label: 'Trái', icon: Icons.turn_left),
                            (command: 'R', label: 'Phải', icon: Icons.turn_right),
                          ],
                        ),
                        // Centre: stop and link. Kept between the two thumb
                        // zones so neither hand can cover it.
                        Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            // Always live: a stop that needs a connection is
                            // not a safety net.
                            GamepadActionButton(
                              label: 'STOP',
                              icon: Icons.stop,
                              color: theme.colorScheme.error,
                              onPressed: _release,
                            ),
                            const SizedBox(height: 24),
                            GamepadActionButton(
                              label: 'BT',
                              icon: Icons.bluetooth,
                              color: theme.colorScheme.tertiary,
                              onPressed: _openDevicePicker,
                            ),
                          ],
                        ),
                        // Right thumb: drive.
                        _DirectionCluster(
                          enabled: connected,
                          onPressed: _press,
                          onReleased: _release,
                          buttons: const [
                            (command: 'F', label: 'Tiến', icon: Icons.keyboard_arrow_up),
                            (command: 'B', label: 'Lùi', icon: Icons.keyboard_arrow_down),
                          ],
                        ),
                      ],
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
      return 'Đang nối...';
    }
    return _link.isConnected ? 'Đã nối' : 'Chưa nối';
  }
}

/// One thumb zone: two stacked [DirectionButton]s.
///
/// Used twice on the pad, so the pairs stay visually identical and the caller
/// only decides *which* two commands go here.
class _DirectionCluster extends StatelessWidget {
  const _DirectionCluster({
    required this.enabled,
    required this.onPressed,
    required this.onReleased,
    required this.buttons,
  });

  final bool enabled;
  final ValueChanged<String> onPressed;
  final VoidCallback onReleased;

  /// Command, label and icon for each button, top to bottom.
  final List<({String command, String label, IconData icon})> buttons;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < buttons.length; i++) ...[
          if (i > 0) const SizedBox(height: 12),
          DirectionButton(
            command: buttons[i].command,
            label: buttons[i].label,
            icon: buttons[i].icon,
            enabled: enabled,
            onPressed: onPressed,
            onReleased: onReleased,
          ),
        ],
      ],
    );
  }
}

/// Header strip: which robot, what went wrong, and the button that changes it.
class _ConnectionStrip extends StatelessWidget {
  const _ConnectionStrip({
    required this.connected,
    required this.connecting,
    required this.deviceName,
    required this.error,
    required this.message,
    required this.onPick,
    required this.onDisconnect,
  });

  final bool connected;
  final bool connecting;
  final String? deviceName;
  final String error;
  final String message;
  final VoidCallback onPick;
  final VoidCallback onDisconnect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final String headline;
    if (connected) {
      headline = deviceName ?? 'Robot';
    } else if (connecting) {
      headline = 'Đang ghép nối...';
    } else {
      headline = 'Chưa có robot';
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(headline, style: theme.textTheme.titleMedium),
              ),
              FilledButton.tonalIcon(
                onPressed: connecting ? null : (connected ? onDisconnect : onPick),
                icon: Icon(connected ? Icons.link_off : Icons.bluetooth_searching),
                label: Text(connected ? 'Ngắt' : 'Robot'),
              ),
            ],
          ),
          if (error.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                error,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: scheme.error),
              ),
            )
          else if (connected && message.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                message,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            )
          else if (!connected)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Mở Cài đặt Bluetooth, ghép nối ESP32_ROBOT (mã 1234), rồi bấm Robot.',
                style: theme.textTheme.bodySmall,
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
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.error),
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
                    onPressed: _loading ? null : widget.link.openBluetoothSettings,
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
