import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// Shared typography, surfaces, spacing, and touch targets.
abstract final class Design {
  static const ink = Color(0xFF202020);
  static const accent = Color(0xFF3B5BDB);

  /// Shared spacing scale for repeated gaps. [gutter] is the content inset.
  static const double space1 = 4;
  static const double space2 = 8;
  static const double space3 = 12;
  static const double gutter = 16;
  static const double space5 = 24;

  /// Minimum hit target for primary interactive controls.
  static const double target = 44;

  /// Corner radii: small tiles/chips, cards/panels, and message bubbles.
  static const double radiusSmall = 10;
  static const double radiusMedium = 14;
  static const double radiusLarge = 18;

  static bool dark(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark;
  static Color panel(BuildContext context) =>
      dark(context) ? const Color(0xFF202020) : const Color(0xFFF7F7F7);
  static Color sheet(BuildContext context) =>
      dark(context) ? const Color(0xFF262626) : Colors.white;
  static Color control(BuildContext context) =>
      dark(context) ? const Color(0xFF303030) : const Color(0xFFF7F7F7);
  static Color composer(BuildContext context) =>
      dark(context) ? const Color(0xFF292929) : const Color(0xFFF4F4F4);
  static Color group(BuildContext context) =>
      dark(context) ? const Color(0xFF333333) : Colors.white;
  static Color search(BuildContext context) =>
      dark(context) ? const Color(0xFF292929) : Colors.white;
  static Color line(BuildContext context, [double opacity = .13]) =>
      dark(context)
      ? Colors.white.withValues(alpha: opacity)
      : const Color(0xFFE4E4E4);
}

class DesignIcon extends StatelessWidget {
  const DesignIcon(this.name, {super.key, this.size = 21, this.color});
  final String name;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) => SvgPicture.asset(
    'assets/icons/$name.svg',
    width: size,
    height: size,
    excludeFromSemantics: true,
    colorFilter: ColorFilter.mode(
      color ??
          IconTheme.of(context).color ??
          Theme.of(context).colorScheme.onSurface,
      BlendMode.srcIn,
    ),
  );
}

class RoundAction extends StatelessWidget {
  const RoundAction({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.quiet = false,
    this.color,
  });
  final String icon;
  final String label;
  final VoidCallback? onPressed;
  final bool quiet;
  final Color? color;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: label,
    onPressed: onPressed,
    style: IconButton.styleFrom(
      minimumSize: const Size.square(44),
      maximumSize: const Size.square(44),
      padding: EdgeInsets.zero,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      backgroundColor: quiet ? Colors.transparent : Design.control(context),
      foregroundColor: color ?? Theme.of(context).colorScheme.onSurface,
    ),
    icon: DesignIcon(icon),
  );
}

class SheetHeading extends StatelessWidget {
  const SheetHeading({
    super.key,
    required this.title,
    required this.closeLabel,
  });
  final String title;
  final String closeLabel;
  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(minHeight: 48),
    child: Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
          ),
        ),
        RoundAction(
          icon: 'close',
          label: closeLabel,
          quiet: true,
          onPressed: () => Navigator.pop(context),
        ),
      ],
    ),
  );
}

/// Body of a modal bottom sheet that contains a form. It sits above the
/// keyboard and scrolls, so its confirmation button stays reachable at any
/// text size or orientation.
class KeyboardSafeSheet extends StatelessWidget {
  const KeyboardSafeSheet({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedPadding(
    duration: MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 180),
    curve: Curves.easeOut,
    padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
    child: SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          Design.gutter,
          0,
          Design.gutter,
          Design.gutter,
        ),
        child: child,
      ),
    ),
  );
}

/// One row of [showActionSheet].
class SheetAction<T> {
  const SheetAction(
    this.value,
    this.label, {
    this.enabled = true,
    this.destructive = false,
  });
  final T value;
  final String label;
  final bool enabled;
  final bool destructive;
}

/// A titled list of actions in the same style as the chat actions sheet.
/// Returns the chosen value, or null when dismissed.
Future<T?> showActionSheet<T>(
  BuildContext context, {
  required String title,
  required String closeLabel,
  required List<SheetAction<T>> actions,
}) => showModalBottomSheet<T>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: false,
  barrierColor: Design.ink.withValues(alpha: .70),
  builder: (context) => SafeArea(
    top: false,
    child: SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        Design.gutter,
        0,
        Design.gutter,
        Design.space5,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const SheetHandle(),
          SheetHeading(title: title, closeLabel: closeLabel),
          for (final action in actions)
            DecoratedBox(
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(color: Design.line(context, .12)),
                ),
              ),
              child: ListTile(
                minTileHeight: 56,
                contentPadding: EdgeInsets.zero,
                enabled: action.enabled,
                title: Text(
                  action.label,
                  style: TextStyle(
                    fontSize: 17,
                    color: action.destructive && action.enabled
                        ? Theme.of(context).colorScheme.error
                        : null,
                  ),
                ),
                onTap: () => Navigator.pop(context, action.value),
              ),
            ),
        ],
      ),
    ),
  ),
);

class SheetHandle extends StatelessWidget {
  const SheetHandle({super.key});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 12, bottom: 10),
    child: Center(
      child: Container(
        width: 38,
        height: 5,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .22),
          borderRadius: BorderRadius.circular(99),
        ),
      ),
    ),
  );
}
