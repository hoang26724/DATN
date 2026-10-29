import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'robot_link.dart';

/// How far a button sinks and how much shadow it drops when held, so a press
/// reads as a physical key going down rather than just a colour change.
const double _pressSink = 4;
const Duration _pressAnimation = Duration(milliseconds: 80);

/// One hold-to-move direction button.
///
/// [onPressed] fires as soon as the finger lands. [onReleased] fires when it
/// lifts, drags off, or the gesture is otherwise cancelled — every one of those
/// paths stops the robot, so releasing can never leave the motors running.
///
/// Uses [Listener] rather than [InkWell] because pointer-up is delivered even
/// when the finger moves off the button. That is the behavior we want here. Do
/// not "simplify" this to an [InkWell] or a gesture recognizer.
class DirectionButton extends StatefulWidget {
  const DirectionButton({
    required this.command,
    required this.label,
    required this.icon,
    required this.enabled,
    required this.onPressed,
    required this.onReleased,
    this.size = 128,
    super.key,
  });

  /// The single ASCII command this button sends: `F`, `B`, `L`, `R`, `X` or `Z`.
  final String command;

  /// Vietnamese name of the command, e.g. `Tiến`. The button shows an icon
  /// only — the arrow already says which way it goes — so this is handed to
  /// accessibility services instead of being painted.
  final String label;

  final IconData icon;

  final bool enabled;
  final ValueChanged<String> onPressed;
  final VoidCallback onReleased;

  /// Width and height of the button.
  final double size;

  @override
  State<DirectionButton> createState() => _DirectionButtonState();
}

class _DirectionButtonState extends State<DirectionButton> {
  bool _pressed = false;

  void _start() {
    if (!widget.enabled || _pressed) {
      return;
    }
    setState(() => _pressed = true);
    HapticFeedback.selectionClick();
    widget.onPressed(widget.command);
  }

  void _end() {
    if (!_pressed) {
      return;
    }
    setState(() => _pressed = false);
    widget.onReleased();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: widget.label,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: widget.enabled ? (_) => _start() : null,
        onPointerUp: widget.enabled ? (_) => _end() : null,
        onPointerCancel: widget.enabled ? (_) => _end() : null,
        child: _PadSurface(
          size: widget.size,
          pressed: _pressed && widget.enabled,
          enabled: widget.enabled,
          child: Icon(
            widget.icon,
            size: widget.size * 0.5,
            color: _foreground(
              context,
              _pressed && widget.enabled,
              widget.enabled,
            ),
          ),
        ),
      ),
    );
  }
}

/// A held speed button: press-and-hold ramps the value up or down.
///
/// Shows what the module drives (`Hút` for the L298N #1 suction brush, `Chạy`
/// for the L298N #2 wheels) so the two pairs on the pad are never confused.
class SpeedButton extends StatefulWidget {
  const SpeedButton({
    required this.module,
    required this.icon,
    required this.label,
    required this.enabled,
    required this.onPressed,
    required this.onReleased,
    this.size = 100,
    super.key,
  });

  /// Module shown on the button: `1` = front (L298N #1), `2` = rear.
  final int module;

  final IconData icon;
  final String label;
  final bool enabled;
  final VoidCallback onPressed;
  final VoidCallback onReleased;

  final double size;

  @override
  State<SpeedButton> createState() => _SpeedButtonState();
}

class _SpeedButtonState extends State<SpeedButton> {
  bool _pressed = false;

  void _start() {
    if (!widget.enabled || _pressed) {
      return;
    }
    setState(() => _pressed = true);
    HapticFeedback.selectionClick();
    widget.onPressed();
  }

  void _end() {
    if (!_pressed) {
      return;
    }
    setState(() => _pressed = false);
    widget.onReleased();
  }

  @override
  Widget build(BuildContext context) {
    final foreground = _foreground(
      context,
      _pressed && widget.enabled,
      widget.enabled,
    );
    return Semantics(
      button: true,
      label: widget.label,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: widget.enabled ? (_) => _start() : null,
        onPointerUp: widget.enabled ? (_) => _end() : null,
        onPointerCancel: widget.enabled ? (_) => _end() : null,
        child: _PadSurface(
          size: widget.size,
          pressed: _pressed && widget.enabled,
          enabled: widget.enabled,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(widget.icon, size: widget.size * 0.32, color: foreground),
              const SizedBox(height: 2),
              Text(
                widget.module == 1 ? 'Hút' : 'Chạy',
                style: Theme.of(context).textTheme.labelSmall
                    ?.copyWith(color: foreground, fontWeight: FontWeight.bold),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A tap-to-toggle pad key. Unlike the direction keys this does not send a
/// held command: it flips an absolute state on the robot (the middle key
/// toggles the L298N #1 suction brush) and stays lit while that state is on.
class PadToggleButton extends StatelessWidget {
  const PadToggleButton({
    required this.icon,
    required this.label,
    required this.active,
    required this.enabled,
    required this.onPressed,
    this.size = 100,
    super.key,
  });

  final IconData icon;
  final String label;
  final bool active;
  final bool enabled;
  final VoidCallback onPressed;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fill = !enabled
        ? scheme.surfaceContainerHighest
        : active
        ? scheme.tertiary
        : scheme.surfaceContainerHigh;
    final foreground = !enabled
        ? scheme.onSurfaceVariant
        : active
        ? scheme.onTertiary
        : scheme.onSurface;

    return Semantics(
      button: true,
      toggled: active,
      label: label,
      child: Material(
        color: fill,
        borderRadius: BorderRadius.circular(size * 0.26),
        child: InkWell(
          borderRadius: BorderRadius.circular(size * 0.26),
          onTap: enabled ? onPressed : null,
          child: SizedBox(
            width: size,
            height: size,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: size * 0.34, color: foreground),
                const SizedBox(height: 2),
                Text(
                  'Hút',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: foreground,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.5,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The round, sunk-when-pressed surface shared by the pad buttons.
class _PadSurface extends StatelessWidget {
  const _PadSurface({
    required this.size,
    required this.pressed,
    required this.enabled,
    required this.child,
  });

  final double size;
  final bool pressed;
  final bool enabled;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final raised = enabled && !pressed;
    // Press feedback is a gentle lighten of the accent, not a full colour
    // flip: the key still reads as the same button, just lit from within while
    // it is down. The 4 px sink above does the rest of the work.
    final fill = !enabled
        ? scheme.surfaceContainerHighest
        : pressed
        ? Color.lerp(scheme.primary, Colors.white, 0.18)!
        : scheme.surfaceContainerHigh;

    return AnimatedContainer(
      duration: _pressAnimation,
      transform: Matrix4.translationValues(0, pressed ? _pressSink : 0, 0),
      transformAlignment: Alignment.center,
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(size * 0.26),
        boxShadow: raised
            ? [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.5),
                  blurRadius: 8,
                  offset: const Offset(0, 4),
                ),
              ]
            : null,
      ),
      alignment: Alignment.center,
      child: child,
    );
  }
}

Color _foreground(BuildContext context, bool pressed, bool enabled) {
  final scheme = Theme.of(context).colorScheme;
  if (!enabled) {
    return scheme.onSurfaceVariant;
  }
  return pressed ? scheme.onPrimary : scheme.onSurface;
}

/// A round console button that fires once per tap. Used for STOP and for
/// opening the device picker, where there is no "hold" to speak of.
class GamepadActionButton extends StatelessWidget {
  const GamepadActionButton({
    required this.label,
    required this.color,
    required this.onPressed,
    this.icon,
    this.size = 76,
    super.key,
  });

  final String label;
  final Color color;
  final VoidCallback onPressed;
  final IconData? icon;
  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Derived from the fill rather than hardcoded to onError, so a button of
    // any colour (STOP is the error colour, BT is not) gets a label that stays
    // readable on top of it.
    final foreground = theme.colorScheme.contrastOn(color);

    return Semantics(
      button: true,
      label: label,
      child: Material(
        color: color,
        shape: const CircleBorder(),
        child: InkWell(
          // A tap, not a hold: STOP must work even if the finger lands and
          // immediately lifts, so this deliberately does not use Listener.
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: SizedBox(
            width: size,
            height: size,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (icon != null)
                  Icon(icon, size: size * 0.34, color: foreground),
                Text(
                  label,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: foreground,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Picks black or white text for [fill] so a label always stays legible,
/// whatever colour the caller picked.
extension on ColorScheme {
  Color contrastOn(Color fill) =>
      fill.computeLuminance() > 0.5 ? Colors.black87 : Colors.white;
}

/// Status LED: green while connected, amber while connecting, red otherwise.
class LinkLamp extends StatelessWidget {
  const LinkLamp({required this.state, super.key});

  final RobotLinkState state;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = switch (state) {
      RobotLinkState.connected => scheme.primary,
      RobotLinkState.connecting => scheme.tertiary,
      RobotLinkState.disconnected => scheme.error,
    };
    return Container(
      width: 12,
      height: 12,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(color: color.withValues(alpha: 0.6), blurRadius: 8),
        ],
      ),
    );
  }
}
