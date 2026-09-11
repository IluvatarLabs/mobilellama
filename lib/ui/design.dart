import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// Native equivalents of the v4 proposal's OKLCH colors and SVG controls.
abstract final class Design {
  static const ink = Color(0xFF2A2E3A);
  static const accent = Color(0xFF3B5BDB);
  static bool dark(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark;
  static Color panel(BuildContext context) =>
      dark(context) ? const Color(0xFF373B47) : const Color(0xFFF7F8FA);
  static Color sheet(BuildContext context) =>
      dark(context) ? const Color(0xFF424651) : Colors.white;
  static Color control(BuildContext context) =>
      dark(context) ? const Color(0xFF494D58) : const Color(0xFFF7F8FA);
  static Color composer(BuildContext context) =>
      dark(context) ? const Color(0xFF454955) : const Color(0xFFF5F6F8);
  static Color group(BuildContext context) =>
      dark(context) ? const Color(0xFF50545F) : Colors.white;
  static Color search(BuildContext context) =>
      dark(context) ? const Color(0xFF4C505C) : Colors.white;
  static Color line(BuildContext context, [double opacity = .13]) =>
      dark(context)
      ? Colors.white.withValues(alpha: opacity)
      : const Color(0xFFD6DAE4);
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
