import 'package:app_control_robot/bluetooth_transport.dart';
import 'package:app_control_robot/gamepad_controls.dart';
import 'package:app_control_robot/main.dart';
import 'package:app_control_robot/robot_link.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'robot_link_test.dart' show FakeTransport;

const robot = BluetoothDevice(address: 'AA:BB:CC:DD:EE:FF', name: 'ESP32_ROBOT');

DirectionButton _arrowFor(WidgetTester tester, String command) =>
    tester.widget(
      find.byWidgetPredicate(
        (widget) => widget is DirectionButton && widget.command == command,
      ),
    );

Future<void> _pump(WidgetTester tester, RobotLink link) => tester.pumpWidget(
      MaterialApp(home: ControlPage(link: link)),
    );

void main() {
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

  testWidgets('the pad carries all four directions plus STOP', (tester) async {
    await _pump(tester, link);

    for (final command in ['F', 'B', 'L', 'R']) {
      expect(find.byWidgetPredicate(
        (widget) => widget is DirectionButton && widget.command == command,
      ), findsOneWidget, reason: command);
    }
    expect(find.widgetWithText(GamepadActionButton, 'STOP'), findsOneWidget);
  });

  testWidgets('turning sits left of the screen and driving sits right',
      (tester) async {
    await _pump(tester, link);

    double centreOf(String command) =>
        tester.getCenter(find.byWidgetPredicate(
          (widget) => widget is DirectionButton && widget.command == command,
        )).dx;
    double centreOfWidget(Finder finder) => tester.getCenter(finder).dx;

    final left = centreOf('L');
    final right = centreOf('R');
    final forward = centreOf('F');
    final backward = centreOf('B');
    final stop = centreOfWidget(find.widgetWithText(GamepadActionButton, 'STOP'));
    final bt = centreOfWidget(find.widgetWithText(GamepadActionButton, 'BT'));
    final screen = tester.getSize(find.byType(ControlPage)).width / 2;

    // Pivot pair left of centre, drive pair right of it, with both action
    // buttons stranded in the middle so neither thumb can cover them.
    expect(left, lessThan(screen));
    expect(right, lessThan(screen));
    expect(forward, greaterThan(screen));
    expect(backward, greaterThan(screen));
    expect(stop, closeTo(screen, 24));
    expect(bt, closeTo(screen, 24));
  });

  testWidgets('movement is disabled until connected, STOP stays live',
      (tester) async {
    await _pump(tester, link);

    for (final command in ['F', 'B', 'L', 'R']) {
      expect(_arrowFor(tester, command).enabled, isFalse, reason: command);
    }

    // Stop must work with no socket: it is a safety net.
    final stop = tester.widget<GamepadActionButton>(
      find.widgetWithText(GamepadActionButton, 'STOP'),
    );
    expect(stop.onPressed, isNotNull);
  });

  testWidgets('holding an arrow reports press then release', (tester) async {
    await link.connect(robot);
    await _pump(tester, link);

    final forward = find.byWidgetPredicate(
      (widget) => widget is DirectionButton && widget.command == 'F',
    );
    final gesture = await tester.startGesture(tester.getCenter(forward));
    await tester.pump();

    expect(transport.commands, ['F']);
    expect(link.activeCommand, 'F');

    await gesture.up();
    await tester.pump();

    expect(transport.commands.last, 'S');
    expect(link.activeCommand, isNull);
  });

  testWidgets('a cancelled gesture still stops the robot', (tester) async {
    await link.connect(robot);
    await _pump(tester, link);

    final left = find.byWidgetPredicate(
      (widget) => widget is DirectionButton && widget.command == 'L',
    );
    final gesture = await tester.startGesture(tester.getCenter(left));
    await tester.pump();
    expect(transport.commands, ['L']);

    // Dragging off the arm must not leave the motors running.
    await gesture.cancel();
    await tester.pump();

    expect(transport.commands.last, 'S');
  });

  testWidgets('a disabled arrow never fires', (tester) async {
    await _pump(tester, link);

    final forward = find.byWidgetPredicate(
      (widget) => widget is DirectionButton && widget.command == 'F',
    );
    await tester.tap(forward);
    await tester.pump();

    expect(transport.written, isEmpty);
    expect(transport.commands, isEmpty);
  });

  testWidgets('the link lamp starts disconnected', (tester) async {
    await _pump(tester, link);

    expect(find.text('Chưa nối'), findsOneWidget);
    expect(find.text('Đã nối'), findsNothing);
    expect(
      tester.widget<LinkLamp>(find.byType(LinkLamp)).state,
      RobotLinkState.disconnected,
    );
  });

  testWidgets('connecting shows the robot and enables the pad', (tester) async {
    await link.connect(robot);
    await _pump(tester, link);

    expect(find.text('ESP32_ROBOT'), findsOneWidget);
    expect(find.text('Đã nối'), findsOneWidget);
    for (final command in ['F', 'B', 'L', 'R']) {
      expect(_arrowFor(tester, command).enabled, isTrue, reason: command);
    }
  });

  testWidgets('a link loss is surfaced and blocks driving again',
      (tester) async {
    await link.connect(robot);
    await _pump(tester, link);

    transport.dropLink('Robot đã ngắt kết nối.');
    await tester.pump();

    expect(find.text('Robot đã ngắt kết nối.'), findsOneWidget);
    expect(find.text('Chưa nối'), findsOneWidget);
    expect(_arrowFor(tester, 'F').enabled, isFalse);
  });

  testWidgets('the device sheet says so when nothing is paired', (tester) async {
    await _pump(tester, link);

    await tester.tap(find.widgetWithText(GamepadActionButton, 'BT'));
    await tester.pumpAndSettle();

    expect(find.text('Chưa có robot nào được ghép nối.'), findsOneWidget);
  });

  testWidgets('the device sheet lists a paired robot and connects to it',
      (tester) async {
    transport.paired = [robot];
    await _pump(tester, link);

    await tester.tap(find.widgetWithText(GamepadActionButton, 'BT'));
    await tester.pumpAndSettle();
    expect(find.text('ESP32_ROBOT'), findsOneWidget);

    await tester.tap(find.text('ESP32_ROBOT'));
    await tester.pumpAndSettle();

    expect(transport.connects, [robot]);
    expect(link.isConnected, isTrue);
    expect(find.text('ESP32_ROBOT'), findsOneWidget);
  });

  testWidgets('an unreachable robot leaves the pad locked', (tester) async {
    transport.connectError = const BluetoothUnavailable('Robot không phản hồi.');
    transport.paired = [robot];
    await _pump(tester, link);

    await tester.tap(find.widgetWithText(GamepadActionButton, 'BT'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ESP32_ROBOT'));
    await tester.pumpAndSettle();

    // The sheet keeps the device listed so it can be retried, and the strip
    // behind it carries the same message.
    expect(find.text('Robot không phản hồi.'), findsWidgets);
    expect(link.isConnected, isFalse);
    expect(_arrowFor(tester, 'F').enabled, isFalse);
  });
}
