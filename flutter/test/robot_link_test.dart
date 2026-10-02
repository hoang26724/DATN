import 'dart:async';

import 'package:app_control_robot/bluetooth_transport.dart';
import 'package:app_control_robot/robot_link.dart';
import 'package:flutter_test/flutter_test.dart';

/// Stand-in for the ESP32's Bluetooth stack: records the bytes the app writes
/// and can drop the link on demand.
class FakeTransport implements RobotTransport {
  FakeTransport();

  final StreamController<String> _linkLost = StreamController.broadcast();
  final StreamController<String> _messages = StreamController.broadcast();
  final List<String> written = [];
  final List<BluetoothDevice> connects = [];
  var disconnects = 0;

  /// Thrown by [ensureReady] / [connect] when set.
  Object? readyError;
  Object? connectError;
  List<BluetoothDevice> paired = const [];

  @override
  bool isConnected = false;

  @override
  Stream<String> get linkLostReasons => _linkLost.stream;

  @override
  Stream<String> get messages => _messages.stream;

  @override
  Future<void> ensureReady() async {
    final error = readyError;
    if (error != null) {
      throw error;
    }
  }

  @override
  Future<List<BluetoothDevice>> pairedDevices() async => paired;

  @override
  Future<void> openBluetoothSettings() async {}

  @override
  Future<void> connect(BluetoothDevice device) async {
    final error = connectError;
    if (error != null) {
      throw error;
    }
    connects.add(device);
    isConnected = true;
  }

  @override
  Future<void> disconnect() async {
    disconnects++;
    isConnected = false;
  }

  @override
  void write(String data) {
    if (!isConnected) {
      return;
    }
    written.add(data);
  }

  /// Every complete command received so far, in order.
  List<String> get commands => written
      .join()
      .split(RegExp(r'[\r\n]'))
      .where((line) => line.isNotEmpty)
      .toList();

  /// Simulates the robot walking out of range.
  void dropLink(String reason) {
    isConnected = false;
    _linkLost.add(reason);
  }

  void sendText(String text) => _messages.add(text);

  Future<void> close() async {
    await _linkLost.close();
    await _messages.close();
  }
}

void main() {
  const robot = BluetoothDevice(address: 'AA:BB:CC:DD:EE:FF', name: 'ESP32_ROBOT');

  late FakeTransport transport;
  late RobotLink link;

  setUp(() {
    transport = FakeTransport();
    link = RobotLink(transport);
  });

  tearDown(() async {
    link.dispose();
    await transport.close();
  });

  test('rejects a keep-alive slower than the firmware watchdog', () {
    expect(
      () => RobotLink(
        transport,
        keepAliveInterval: RobotLink.firmwareCommandTimeout,
      ),
      throwsArgumentError,
      reason: 'a held command would stop every 600 ms instead of driving',
    );
  });

  test('connect exposes the live state and remembers the robot', () async {
    await link.connect(robot);

    expect(link.isConnected, isTrue);
    expect(link.state, RobotLinkState.connected);
    expect(link.deviceName, 'ESP32_ROBOT');
    expect(link.lastError, isEmpty);
    expect(transport.connects, [robot]);
  });

  test('sends the command immediately on hold', () async {
    await link.connect(robot);

    link.hold('F');
    await Future<void>.delayed(Duration(milliseconds: 60));

    expect(transport.written.join(), 'F\n');
    expect(link.activeCommand, 'F');
  });

  test('resends the held command so the firmware watchdog stays fed',
      () async {
    // Short keep-alive so the test observes repeats quickly.
    final fastTransport = FakeTransport();
    final fastLink =
        RobotLink(fastTransport, keepAliveInterval: const Duration(milliseconds: 20));
    addTearDown(() async {
      fastLink.dispose();
      await fastTransport.close();
    });
    await fastLink.connect(robot);

    fastLink.hold('L');
    await Future<void>.delayed(Duration(milliseconds: 120));
    fastLink.release();
    await Future<void>.delayed(Duration(milliseconds: 60));

    final commands = fastTransport.commands;
    expect(commands.where((c) => c == 'L').length, greaterThan(1));
    expect(commands.last, 'S');
    expect(
      commands.every((c) => const {'L', 'S'}.contains(c)),
      isTrue,
      reason: 'no stale command may outlive the release',
    );
  });

  test('holding a second direction replaces the first', () async {
    await link.connect(robot);

    link.hold('F');
    link.hold('R');
    await Future<void>.delayed(Duration(milliseconds: 60));

    expect(transport.commands, ['F', 'R']);
    expect(link.activeCommand, 'R');
  });

  test('holding the same direction twice does not duplicate the command',
      () async {
    await link.connect(robot);

    link.hold('B');
    link.hold('B');
    await Future<void>.delayed(Duration(milliseconds: 60));

    expect(transport.commands, ['B']);
  });

  test('release always sends stop, even with nothing held', () async {
    await link.connect(robot);

    link.release();
    await Future<void>.delayed(Duration(milliseconds: 60));

    expect(transport.commands, ['S']);
    expect(link.activeCommand, isNull);
  });

  test('hold while disconnected is a no-op', () async {
    link.hold('F');
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(transport.written, isEmpty);
    expect(link.isConnected, isFalse);
  });

  test('drops to disconnected when the robot hangs up', () async {
    await link.connect(robot);
    link.hold('F');
    expect(link.isConnected, isTrue);

    transport.dropLink('Robot đã ngắt kết nối.');
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(link.isConnected, isFalse);
    expect(link.state, RobotLinkState.disconnected);
    expect(link.deviceName, isNull);
    expect(link.lastError, 'Robot đã ngắt kết nối.');
  });

  test('a hang-up mid-hold cancels the keep-alive', () async {
    await link.connect(robot);
    link.hold('F');
    await Future<void>.delayed(const Duration(milliseconds: 30));

    transport.dropLink('Mất kết nối Bluetooth.');
    await Future<void>.delayed(const Duration(milliseconds: 250));
    final afterHangUp = transport.written.length;
    await Future<void>.delayed(const Duration(milliseconds: 250));

    // Nothing is written once the socket is gone, not even the stop.
    expect(transport.written.length, afterHangUp);
    expect(link.activeCommand, isNull);
  });

  test('connect throws and stays disconnected when the robot refuses',
      () async {
    transport.connectError = const BluetoothUnavailable('Robot không phản hồi.');
    addTearDown(() => expect(link.isConnected, isFalse));

    await expectLater(
      link.connect(robot),
      throwsA(isA<BluetoothUnavailable>()),
    );

    expect(link.isConnected, isFalse);
    expect(link.state, RobotLinkState.disconnected);
    expect(link.lastError, 'Robot không phản hồi.');
  });

  test('ensureReady and the device list come straight from the transport',
      () async {
    transport.paired = [robot];

    await link.ensureReady();
    expect(await link.pairedDevices(), [robot]);
  });

  test('surfaces text sent by the robot', () async {
    await link.connect(robot);

    transport.sendText('[boot] ESP32 robot controller (Bluetooth)');
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(link.lastMessage, '[boot] ESP32 robot controller (Bluetooth)');
  });

  test('disconnect stops the motors and clears the link', () async {
    await link.connect(robot);
    link.hold('F');
    await Future<void>.delayed(const Duration(milliseconds: 30));

    await link.disconnect();
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(link.isConnected, isFalse);
    expect(transport.commands.last, 'F');
    // Nothing more is written after a clean disconnect.
    final count = transport.written.length;
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(transport.written.length, count);
  });
}
