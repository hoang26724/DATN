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

const robot = BluetoothDevice(
  address: 'AA:BB:CC:DD:EE:FF',
  name: 'ESP32_ROBOT',
);

DirectionButton _arrowFor(WidgetTester tester, String command) => tester.widget(
  find.byWidgetPredicate(
    (widget) => widget is DirectionButton && widget.command == command,
  ),
);

/// The strip's link button. The pad carries no button of its own, so this is the
/// only way into the device sheet.
final linkButton = find.widgetWithText(FilledButton, 'Kết nối');

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

  /// Finishes the device sheet's slide-in without `pumpAndSettle`.
  ///
  /// Timed pumps flush the microtasks and complete the sheet animation; they
  /// are used throughout because a fixed schedule is deterministic, while
  /// `pumpAndSettle` depends on there being no periodic timer left in the
  /// camera's stats polling.
  Future<void> settleSheet(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
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
    MaterialApp(
      home: ControlPage(link: link, camera: camera),
    ),
  );

  testPad('the pad carries four drive keys and the suction toggle', (
    tester,
  ) async {
    await pumpPage(tester);

    for (final command in ['F', 'B', 'L', 'R']) {
      expect(
        find.byWidgetPredicate(
          (widget) => widget is DirectionButton && widget.command == command,
        ),
        findsOneWidget,
        reason: command,
      );
    }
    // The stop button was pulled at the user's request; release() on pointer-up
    // is what stops the robot now. The link button went the same way: the strip
    // at the top already carries it and the auto toggle moved there too.
    expect(find.text('STOP'), findsNothing);
    expect(find.byType(GamepadActionButton), findsNothing);
    // Four corner speed keys, plus the middle key that toggles the suction.
    expect(find.byType(SpeedButton), findsNWidgets(4));
    expect(find.byType(PadToggleButton), findsOneWidget);
  });

  testPad('the pad keeps the 3x3 keypad arrangement', (tester) async {
    await pumpPage(tester);

    Offset centreOf(Finder finder) => tester.getCenter(finder);
    Finder direction(String command) => find.byWidgetPredicate(
      (widget) => widget is DirectionButton && widget.command == command,
    );
    Finder speed(int module, IconData icon) => find.byWidgetPredicate(
      (widget) =>
          widget is SpeedButton &&
          widget.module == module &&
          widget.icon == icon,
    );

    final forward = direction('F');
    final backward = direction('B');
    final turnLeft = direction('L');
    final turnRight = direction('R');
    final suctionDown = speed(1, Icons.remove);
    final suctionUp = speed(1, Icons.add);
    final driveDown = speed(2, Icons.remove);
    final driveUp = speed(2, Icons.add);
    final toggle = find.byType(PadToggleButton);

    // Row 1: suction up, forward, drive up.
    expect(centreOf(suctionUp).dy, closeTo(centreOf(forward).dy, 1));
    expect(centreOf(driveUp).dy, closeTo(centreOf(forward).dy, 1));
    expect(centreOf(suctionUp).dx, lessThan(centreOf(forward).dx));
    expect(centreOf(driveUp).dx, greaterThan(centreOf(forward).dx));
    // Row 2: left, suction toggle, right.
    expect(centreOf(turnLeft).dy, greaterThan(centreOf(forward).dy));
    expect(centreOf(toggle).dy, closeTo(centreOf(turnLeft).dy, 1));
    expect(centreOf(turnRight).dy, closeTo(centreOf(turnLeft).dy, 1));
    expect(centreOf(turnLeft).dx, lessThan(centreOf(toggle).dx));
    expect(centreOf(turnRight).dx, greaterThan(centreOf(toggle).dx));
    // Row 3: suction down, backward, drive down.
    expect(centreOf(backward).dy, greaterThan(centreOf(turnLeft).dy));
    expect(centreOf(backward).dx, closeTo(centreOf(forward).dx, 1));
    expect(centreOf(suctionDown).dy, closeTo(centreOf(backward).dy, 1));
    expect(centreOf(driveDown).dy, closeTo(centreOf(backward).dy, 1));
  });

  testPad('the direction buttons share one icon-only look', (tester) async {
    await pumpPage(tester);

    // Same widget and same size, so only the icon differs and all four read as
    // one set. The buttons are icon-only, which is what keeps them big enough
    // to hit without looking at them.
    expect(_arrowFor(tester, 'L').size, _arrowFor(tester, 'F').size);
    expect(_arrowFor(tester, 'R').size, _arrowFor(tester, 'B').size);
    expect(_arrowFor(tester, 'L').icon, Icons.chevron_left);
    expect(_arrowFor(tester, 'R').icon, Icons.chevron_right);
    expect(
      _arrowFor(tester, 'L').runtimeType,
      _arrowFor(tester, 'F').runtimeType,
    );
    for (final command in ['F', 'B', 'L', 'R']) {
      expect(
        find.descendant(
          of: find.byWidgetPredicate(
            (widget) => widget is DirectionButton && widget.command == command,
          ),
          matching: find.text(_arrowFor(tester, command).label),
        ),
        findsNothing,
        reason: command,
      );
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

    // The first two writes are the connect-time f100/r50 speed preamble.
    expect(transport.commands.sublist(2), ['F']);
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
    expect(transport.commands.sublist(2), ['L']);

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

    expect(find.text('ROBOT PICKLEBALL'), findsOneWidget);
    expect(find.text('Chưa kết nối'), findsOneWidget);
    expect(find.text('Đã kết nối'), findsNothing);
    expect(find.text('Kết nối'), findsOneWidget);
    expect(find.byIcon(Icons.bluetooth), findsOneWidget);
    expect(
      tester.widget<LinkLamp>(find.byType(LinkLamp)).state,
      RobotLinkState.disconnected,
    );
  });

  testPad('connecting shows only the status and enables the pad', (
    tester,
  ) async {
    await link.connect(robot);
    await pumpPage(tester);

    // The name and address stay in the picker; once connected the app bar is
    // the only place the state is spelled out.
    expect(find.text('ESP32_ROBOT'), findsNothing);
    expect(find.text(robot.address), findsNothing);
    expect(find.text('Đã kết nối'), findsOneWidget);
    expect(find.text('Ngắt'), findsOneWidget);
    expect(find.byIcon(Icons.bluetooth_disabled), findsOneWidget);
    for (final command in ['F', 'B', 'L', 'R']) {
      expect(_arrowFor(tester, command).enabled, isTrue, reason: command);
    }
  });

  testPad('a link loss is surfaced and blocks driving again', (tester) async {
    await link.connect(robot);
    await pumpPage(tester);

    transport.dropLink('Robot đã ngắt kết nối.');
    await tester.pump();

    // The raw link-loss reason is deliberately not shown; only the status
    // label changes.
    expect(find.text('Robot đã ngắt kết nối.'), findsNothing);
    expect(find.text('Chưa kết nối'), findsOneWidget);
    expect(_arrowFor(tester, 'F').enabled, isFalse);
  });

  testPad('the strip carries no bluetooth how-to', (tester) async {
    await pumpPage(tester);

    // Removed at the user's request: pairing instructions belong in the sheet,
    // not as permanent text under the title.
    expect(find.textContaining('ghép nối ESP32_ROBOT'), findsNothing);
    expect(find.textContaining('Mở Cài đặt Bluetooth'), findsNothing);
  });

  testPad('the auto button shares the top row with relay and Bluetooth', (
    tester,
  ) async {
    await pumpPage(tester);

    final auto = tester.getCenter(find.widgetWithText(FilledButton, 'Tự động'));
    final relay = tester.getCenter(find.widgetWithText(FilledButton, 'Relay'));
    final bluetooth = tester.getCenter(
      find.widgetWithText(FilledButton, 'Kết nối'),
    );

    expect(auto.dy, closeTo(relay.dy, 1));
    expect(auto.dy, closeTo(bluetooth.dy, 1));
    // The three buttons share the row evenly.
    expect(relay.dx - auto.dx, closeTo(bluetooth.dx - relay.dx, 1));
    // No auto key left inside the pad.
    expect(find.text('TỰ ĐỘNG'), findsNothing);
  });

  testPad('the middle key toggles the suction brush with an absolute G1/G0', (
    tester,
  ) async {
    await link.connect(robot);
    await pumpPage(tester);

    await tester.tap(find.byType(PadToggleButton));
    await tester.pump();
    expect(link.frontModuleOn, isTrue);
    expect(transport.commands.last, 'G1');

    await tester.tap(find.byType(PadToggleButton));
    await tester.pump();
    expect(link.frontModuleOn, isFalse);
    expect(transport.commands.last, 'G0');
  });

  testPad('the corner keys ramp their own module', (tester) async {
    await link.connect(robot);
    await pumpPage(tester);

    Finder speedKey(int module, IconData icon) => find.byWidgetPredicate(
      (widget) =>
          widget is SpeedButton &&
          widget.module == module &&
          widget.icon == icon,
    );

    Future<void> ramp(Finder key, String expected) async {
      final gesture = await tester.startGesture(tester.getCenter(key));
      await tester.pump();
      expect(transport.commands.last, expected);
      await gesture.up();
      await tester.pump();
    }

    await ramp(speedKey(1, Icons.remove), 'f90');
    await ramp(speedKey(2, Icons.remove), 'r40');
    await ramp(speedKey(1, Icons.add), 'f100');
    await ramp(speedKey(2, Icons.add), 'r50');

    expect(link.frontSpeed, 100);
    expect(link.rearSpeed, 50);
  });

  testPad('the device sheet says so when nothing is paired', (tester) async {
    await pumpPage(tester);

    await tester.tap(linkButton);
    await settleSheet(tester);

    expect(find.text('Chưa có robot nào được ghép nối.'), findsOneWidget);
  });

  testPad('the device sheet lists a paired robot and connects to it', (
    tester,
  ) async {
    transport.paired = [robot];
    await pumpPage(tester);

    await tester.tap(linkButton);
    await settleSheet(tester);
    expect(find.text('ESP32_ROBOT'), findsOneWidget);

    await tester.tap(find.text('ESP32_ROBOT'));
    await settleSheet(tester);

    expect(transport.connects, [robot]);
    expect(link.isConnected, isTrue);
    // The sheet closes and the strip no longer repeats the device name.
    expect(find.text('ESP32_ROBOT'), findsNothing);
  });

  testPad('an unreachable robot leaves the pad locked', (tester) async {
    transport.connectError = const BluetoothUnavailable(
      'Robot không phản hồi.',
    );
    transport.paired = [robot];
    await pumpPage(tester);

    await tester.tap(linkButton);
    await settleSheet(tester);
    await tester.tap(find.text('ESP32_ROBOT'));
    await settleSheet(tester);

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

    // FPS is the only number burned into the picture...
    expect(find.text('FPS: '), findsOneWidget);
    expect(find.text('11.5'), findsOneWidget);
    // ...while the person and pickleball counts sit below the frame, in the
    // strip between the camera and the pad.
    expect(find.text('Người'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(find.text('Bóng'), findsOneWidget);
    expect(find.text('4'), findsOneWidget);
  });

  testPad('the info strip shows both speed sliders', (tester) async {
    await pumpPage(tester);

    expect(find.text('100%'), findsOneWidget);
    expect(find.text('50%'), findsOneWidget);
    expect(find.text('Tốc độ hút'), findsOneWidget);
    expect(find.text('Tốc độ chạy'), findsOneWidget);
  });

  testPad('a stalled camera offers a reconnect button in the middle', (
    tester,
  ) async {
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
    // The label sits below the icon and message, so the tolerance allows for
    // that stack while still rejecting a corner placement.
    expect(button.center.dy, closeTo(panel.center.dy, 70));
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

  testPad('the camera carries no buttons in its corners', (tester) async {
    await pumpPage(tester);

    // The reload and relay buttons were pulled from the picture at the user's
    // request: reloading is a tap on the picture now, and the relay toggle
    // lives on the same line as the Bluetooth button in the strip.
    expect(find.byKey(const ValueKey('cameraReload')), findsNothing);
    expect(find.byKey(const ValueKey('cameraRelay')), findsNothing);
  });

  testPad('a frame that will not decode asks the link to start over', (
    tester,
  ) async {
    await pumpPage(tester);
    await tester.pump(const Duration(milliseconds: 60));
    final opensBefore = pi.opens;

    // Not a JPEG: the decoder throws, and the panel opens a fresh stream
    // instead of leaving a black rectangle with no way out.
    pi.emit([1, 2, 3]);
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(pi.opens, opensBefore + 1);
  });
}
