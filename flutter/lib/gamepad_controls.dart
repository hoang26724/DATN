import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'robot_link.dart';

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
    this.size = 100,
    super.key,
  });

  /// The single ASCII command this button sends: `F`, `B`, `L` or `R`.
  final String command;

  /// Vietnamese name shown under the icon, e.g. `Tiến`.
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
    final scheme = Theme.of(context).colorScheme;
    final active = _pressed && widget.enabled;
    final fill = !widget.enabled
        ? scheme.surfaceContainerHighest
        : active
            ? scheme.primary
            : scheme.surfaceContainerHigh;
    final foreground = !widget.enabled
        ? scheme.onSurfaceVariant
        : active
            ? scheme.onPrimary
            : scheme.onSurface;

    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: widget.enabled ? (_) => _start() : null,
      onPointerUp: widget.enabled ? (_) => _end() : null,
      onPointerCancel: widget.enabled ? (_) => _end() : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 80),
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(
          color: fill,
          borderRadius: BorderRadius.circular(widget.size * 0.26),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(widget.icon, size: widget.size * 0.42, color: foreground),
            const SizedBox(height: 2),
            Text(
              widget.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: foreground,
                    fontWeight: FontWeight.bold,
                  ),
            ),
          ],
        ),
      ),
    );
  }
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
