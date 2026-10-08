import 'package:app_control_robot/bluetooth_transport.dart';
import 'package:app_control_robot/camera_panel.dart';
import 'package:app_control_robot/gamepad_controls.dart';
import 'package:app_control_robot/main.dart';
import 'package:app_control_robot/pi_camera_link.dart';
import 'package:app_control_robot/pi_camera_transport.dart';
import 'package:app_control_robot/robot_link.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'pi_camera_test.dart' show FakePiCameraTransport;
import 'robot_link_test.dart' show FakeTransport;

const robot = BluetoothDevice(address: 'AA:BB:CC:DD:EE:FF', name: 'ESP32_ROBOT');

DirectionButton _arrowFor(WidgetTester tester, String command) =>
    tester.widget(
      find.byWidgetPredicate(
        (widget) => widget is DirectionButton && widget.command == command,
      ),
    );

/// The strip's link button. The pad carries no button of its own, so this is the
/// only way into the device sheet.
final linkButton = find.widgetWithText(FilledButton, 'Robot');

void main() {
  late FakeTransport transport;
  late RobotLink link;
  late FakePiCameraTransport pi;
  late PiCameraLink camera;

  /// Widget tests fake timers but not the wall clock, so the feed gets one it can
  /// be driven with. [advanceClock] is what makes the stall watchdog fire.
  late DateTime now;

  setUp(() {
    transport = FakeTransport();
    link = RobotLink(transport);
    pi = FakePiCameraTransport();
    now = DateTime(2026);
    camera = PiCameraLink(
      pi,
      stallTimeout: const Duration(milliseconds: 120),
      // Long intervals on purpose: a stats poll that fires every pump would
      // keep scheduling frames and pumpAndSettle would never settle.
      statsInterval: const Duration(minutes: 1),
      watchdogInterval: const Duration(minutes: 1),
      clock: () => now,
    );
  });

  tearDown(() async {
    camera.dispose();
    link.dispose();
    await pi.close();
    await transport.close();
  });

  /// Moves the injected clock forward and lets the watchdog tick over it.
  Future<void> advanceClock(WidgetTester tester, Duration by) async {
    now = now.add(by);
    await tester.pump(const Duration(minutes: 1));
    await tester.pump();
  }

  /// [testWidgets] that always parks the camera timers before the body returns:
  /// the feed is driven by periodic timers and a leftover one fails the test.
  void testPad(String description, WidgetTesterCallback body) {
    testWidgets(description, (tester) async {
      await body(tester);
      await camera.stop();
      await tester.pump();
    });
  }

  Future<void> pumpPage(WidgetTester tester) => tester.pumpWidget(
        MaterialApp(home: ControlPage(link: link, camera: camera)),
      );

  testPad('the pad carries all four directions and no centre button',
      (tester) async {
    await pumpPage(tester);

    for (final command in ['F', 'B', 'L', 'R']) {
      expect(find.byWidgetPredicate(
        (widget) => widget is DirectionButton && widget.command == command,
      ), findsOneWidget, reason: command);
    }
    // The stop button was pulled at the user's request; release() on pointer-up
    // is what stops the robot now. The link button went the same way: the strip
    // at the top already carries it, and nothing may sit in the middle of the
    // pad where a thumb holding a direction would cover it.
    expect(find.text('STOP'), findsNothing);
    expect(find.byType(GamepadActionButton), findsNothing);
  });

  testPad('turning sits left of the screen and driving sits right',
      (tester) async {
    await pumpPage(tester);

    double centreOf(String command) =>
        tester.getCenter(find.byWidgetPredicate(
          (widget) => widget is DirectionButton && widget.command == command,
        )).dx;

    final left = centreOf('L');
    final right = centreOf('R');
    final forward = centreOf('F');
    final backward = centreOf('B');
    final screen = tester.getSize(find.byType(ControlPage)).width / 2;

    // Pivot pair left of centre, drive pair right of it, so each hand owns one
    // half of the pad and neither thumb reaches across.
    expect(left, lessThan(screen));
    expect(right, lessThan(screen));
    expect(forward, greaterThan(screen));
    expect(backward, greaterThan(screen));
  });

  testPad('the pivot buttons look like the drive buttons', (tester) async {
    await pumpPage(tester);

    // Same widget and same size, so only the icon differs and all four read as
    // one set instead of two. The buttons are icon-only, which is what keeps
    // them big enough to hit without looking at them.
    expect(_arrowFor(tester, 'L').size, _arrowFor(tester, 'F').size);
    expect(_arrowFor(tester, 'R').size, _arrowFor(tester, 'B').size);
    expect(_arrowFor(tester, 'L').icon, Icons.keyboard_arrow_left);
    expect(_arrowFor(tester, 'R').icon, Icons.keyboard_arrow_right);
    expect(_arrowFor(tester, 'L').runtimeType, _arrowFor(tester, 'F').runtimeType);
    for (final command in ['F', 'B', 'L', 'R']) {
      expect(find.descendant(
        of: find.byWidgetPredicate(
          (widget) => widget is DirectionButton && widget.command == command,
        ),
        matching: find.text(_arrowFor(tester, command).label),
      ), findsNothing, reason: command);
    }
  });

  testPad('the camera panel sits above the pad', (tester) async {
    await pumpPage(tester);

    final cameraRect = tester.getRect(find.byType(CameraPanel));
    final padRect = tester.getRect(find.byType(DirectionButton).first);

    expect(cameraRect.top, lessThan(padRect.top));
    expect(cameraRect.bottom, lessThanOrEqualTo(padRect.top));
  });

  testPad('movement is disabled until connected', (tester) async {
    await pumpPage(tester);

    for (final command in ['F', 'B', 'L', 'R']) {
      expect(_arrowFor(tester, command).enabled, isFalse, reason: command);
    }
  });

  testPad('holding an arrow reports press then release', (tester) async {
    await link.connect(robot);
    await pumpPage(tester);

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

  testPad('a cancelled gesture still stops the robot', (tester) async {
    await link.connect(robot);
    await pumpPage(tester);

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

  testPad('a disabled arrow never fires', (tester) async {
    await pumpPage(tester);

    final forward = find.byWidgetPredicate(
      (widget) => widget is DirectionButton && widget.command == 'F',
    );
    await tester.tap(forward);
    await tester.pump();

    expect(transport.written, isEmpty);
    expect(transport.commands, isEmpty);
  });

  testPad('the link lamp starts disconnected', (tester) async {
    await pumpPage(tester);

    expect(find.text('Chưa nối'), findsOneWidget);
    expect(find.text('Đã nối'), findsNothing);
    expect(
      tester.widget<LinkLamp>(find.byType(LinkLamp)).state,
      RobotLinkState.disconnected,
    );
  });

  testPad('connecting shows the robot and enables the pad', (tester) async {
    await link.connect(robot);
    await pumpPage(tester);

    expect(find.text('ESP32_ROBOT'), findsOneWidget);
    expect(find.text('Đã nối'), findsOneWidget);
    for (final command in ['F', 'B', 'L', 'R']) {
      expect(_arrowFor(tester, command).enabled, isTrue, reason: command);
    }
  });

  testPad('a link loss is surfaced and blocks driving again', (tester) async {
    await link.connect(robot);
    await pumpPage(tester);

    transport.dropLink('Robot đã ngắt kết nối.');
    await tester.pump();

    expect(find.text('Robot đã ngắt kết nối.'), findsOneWidget);
    expect(find.text('Chưa nối'), findsOneWidget);
    expect(_arrowFor(tester, 'F').enabled, isFalse);
  });

  testPad('the strip carries no bluetooth how-to', (tester) async {
    await pumpPage(tester);

    // Removed at the user's request: pairing instructions belong in the sheet,
    // not as permanent text under the title.
    expect(find.textContaining('ghép nối ESP32_ROBOT'), findsNothing);
    expect(find.textContaining('Mở Cài đặt Bluetooth'), findsNothing);
  });

  testPad('the device sheet says so when nothing is paired', (tester) async {
    await pumpPage(tester);

    await tester.tap(linkButton);
    await tester.pumpAndSettle();

    expect(find.text('Chưa có robot nào được ghép nối.'), findsOneWidget);
  });

  testPad('the device sheet lists a paired robot and connects to it',
      (tester) async {
    transport.paired = [robot];
    await pumpPage(tester);

    await tester.tap(linkButton);
    await tester.pumpAndSettle();
    expect(find.text('ESP32_ROBOT'), findsOneWidget);

    await tester.tap(find.text('ESP32_ROBOT'));
    await tester.pumpAndSettle();

    expect(transport.connects, [robot]);
    expect(link.isConnected, isTrue);
    expect(find.text('ESP32_ROBOT'), findsOneWidget);
  });

  testPad('an unreachable robot leaves the pad locked', (tester) async {
    transport.connectError = const BluetoothUnavailable('Robot không phản hồi.');
    transport.paired = [robot];
    await pumpPage(tester);

    await tester.tap(linkButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('ESP32_ROBOT'));
    await tester.pumpAndSettle();

    // The sheet keeps the device listed so it can be retried, and the strip
    // behind it carries the same message.
    expect(find.text('Robot không phản hồi.'), findsWidgets);
    expect(link.isConnected, isFalse);
    expect(_arrowFor(tester, 'F').enabled, isFalse);
  });

  testPad('the panel shows the Pi counts once stats arrive', (tester) async {
    pi.stats = const PiCameraStats(persons: 2, pickleballs: 4, fps: 11.5);
    await pumpPage(tester);

    await tester.pump(const Duration(milliseconds: 60));

    // The same three numbers the web page burns into the picture.
    expect(find.text('Nguoi: '), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(find.text('Bong: '), findsOneWidget);
    expect(find.text('4'), findsOneWidget);
    expect(find.text('11.5'), findsOneWidget);
  });

  testPad('a stalled camera offers a reconnect button in the middle',
      (tester) async {
    await pumpPage(tester);
    expect(find.text('Kết nối lại'), findsNothing);

    // No frames arrive and the clock moves on: the watchdog has to turn this
    // into a visible, tappable reconnect rather than a silent black rectangle.
    await advanceClock(tester, const Duration(milliseconds: 200));

    expect(camera.needsReconnect, isTrue);
    expect(find.text('Kết nối lại'), findsOneWidget);

    final panel = tester.getRect(find.byType(CameraPanel));
    final button = tester.getRect(find.text('Kết nối lại'));
    // In the middle of the picture, not in a corner the user has to hunt for.
    expect(button.center.dy, closeTo(panel.center.dy, 40));
    expect(button.center.dx, closeTo(panel.center.dx, 40));
  });

  testPad('the reconnect button opens a fresh stream', (tester) async {
    await pumpPage(tester);
    await advanceClock(tester, const Duration(milliseconds: 200));
    final opensBefore = pi.opens;

    await tester.tap(find.text('Kết nối lại'));
    await tester.pump();

    expect(pi.opens, opensBefore + 1);
    expect(camera.status, PiCameraStatus.connecting);
    expect(find.text('Kết nối lại'), findsNothing);
  });

  testPad('the refresh button reloads the image on demand', (tester) async {
    await pumpPage(tester);
    final opensBefore = pi.opens;

    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pump();

    expect(pi.opens, opensBefore + 1);
  });
}