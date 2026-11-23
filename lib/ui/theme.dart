import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

@immutable
class XingjiColors extends ThemeExtension<XingjiColors> {
  const XingjiColors({
    required this.ink,
    required this.panel,
    required this.raised,
    required this.line,
    required this.cyan,
    required this.violet,
    required this.muted,
    required this.danger,
  });
  final Color ink, panel, raised, line, cyan, violet, muted, danger;
  static const light = XingjiColors(
    ink: Color(0xFFF3F5F9),
    panel: Color(0xFFFCFDFF),
    raised: Color(0xFFEFF3F8),
    line: Color(0xFFDCE3EC),
    cyan: Color(0xFF2563EB),
    violet: Color(0xFF6D5FC7),
    muted: Color(0xFF5D6B7E),
    danger: Color(0xFFC43D52),
  );
  static const dark = XingjiColors(
    ink: Color(0xFF0C1016),
    panel: Color(0xFF171C24),
    raised: Color(0xFF222A35),
    line: Color(0xFF303A47),
    cyan: Color(0xFF8AB8FF),
    violet: Color(0xFFC0B8FF),
    muted: Color(0xFFAAB6C6),
    danger: Color(0xFFFF9AA5),
  );
  @override
  XingjiColors copyWith() => this;
  @override
  XingjiColors lerp(covariant XingjiColors? other, double t) => other == null
      ? this
      : XingjiColors(
          ink: Color.lerp(ink, other.ink, t)!,
          panel: Color.lerp(panel, other.panel, t)!,
          raised: Color.lerp(raised, other.raised, t)!,
          line: Color.lerp(line, other.line, t)!,
          cyan: Color.lerp(cyan, other.cyan, t)!,
          violet: Color.lerp(violet, other.violet, t)!,
          muted: Color.lerp(muted, other.muted, t)!,
          danger: Color.lerp(danger, other.danger, t)!,
        );
}

XingjiColors colorsOf(BuildContext context) =>
    Theme.of(context).extension<XingjiColors>()!;

ThemeData xingjiTheme({bool dark = false}) {
  final c = dark ? XingjiColors.dark : XingjiColors.light;
  final text = dark ? const Color(0xFFF2F5F9) : const Color(0xFF17202B);
  final radius10 = BorderRadius.circular(10);
  final radius14 = BorderRadius.circular(14);
  return ThemeData(
    brightness: dark ? Brightness.dark : Brightness.light,
    useMaterial3: true,
    fontFamily: 'Microsoft YaHei UI',
    fontFamilyFallback: const [
      'Microsoft YaHei',
      'Segoe UI Variable',
      'Segoe UI',
      'PingFang SC',
      'HarmonyOS Sans SC',
      'Noto Sans CJK SC',
      'Noto Sans SC',
    ],
    extensions: [c],
    scaffoldBackgroundColor: c.ink,
    splashFactory: InkRipple.splashFactory,
    hoverColor: c.cyan.withValues(alpha: .05),
    focusColor: c.cyan.withValues(alpha: .10),
    splashColor: c.cyan.withValues(alpha: .08),
    highlightColor: c.cyan.withValues(alpha: .04),
    colorScheme:
        ColorScheme.fromSeed(
          seedColor: c.cyan,
          brightness: dark ? Brightness.dark : Brightness.light,
        ).copyWith(
          primary: c.cyan,
          onPrimary: dark ? c.ink : Colors.white,
          secondary: c.violet,
          surface: c.panel,
          onSurface: text,
          surfaceContainerHighest: c.raised,
          error: c.danger,
          outline: c.line,
          outlineVariant: c.line.withValues(alpha: .62),
        ),
    textTheme: const TextTheme(
      headlineSmall: TextStyle(
        fontSize: 28,
        height: 1.25,
        fontWeight: FontWeight.w600,
        letterSpacing: -.4,
      ),
      titleLarge: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
      titleMedium: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      bodyMedium: TextStyle(fontSize: 14, height: 1.5),
      bodyLarge: TextStyle(fontSize: 15, height: 1.6),
      labelLarge: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
    ),
    appBarTheme: AppBarTheme(
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      backgroundColor: c.panel.withValues(alpha: dark ? .82 : .86),
      foregroundColor: text,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: TextStyle(
        color: text,
        fontSize: 17,
        fontWeight: FontWeight.w600,
      ),
      shape: Border(bottom: BorderSide(color: c.line.withValues(alpha: .72))),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: c.panel,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: c.line.withValues(alpha: .72)),
      ),
    ),
    dividerTheme: DividerThemeData(
      color: c.line.withValues(alpha: .72),
      thickness: 1,
      space: 1,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: dark
          ? c.raised.withValues(alpha: .48)
          : Colors.white.withValues(alpha: .76),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      labelStyle: TextStyle(color: c.muted),
      hintStyle: TextStyle(color: c.muted),
      border: OutlineInputBorder(
        borderRadius: radius14,
        borderSide: BorderSide(color: c.line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: radius14,
        borderSide: BorderSide(color: c.line.withValues(alpha: .82)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: radius14,
        borderSide: BorderSide(color: c.cyan, width: 1.4),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: c.cyan,
        foregroundColor: dark ? c.ink : Colors.white,
        minimumSize: const Size(0, 44),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        animationDuration: const Duration(milliseconds: 140),
        shape: RoundedRectangleBorder(borderRadius: radius14),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: text,
        backgroundColor: c.panel.withValues(alpha: dark ? .36 : .58),
        minimumSize: const Size(0, 42),
        side: BorderSide(color: c.line.withValues(alpha: .9)),
        shape: RoundedRectangleBorder(borderRadius: radius14),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: c.cyan,
        shape: RoundedRectangleBorder(borderRadius: radius10),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        minimumSize: const Size(40, 40),
        shape: RoundedRectangleBorder(borderRadius: radius10),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: c.panel,
      surfaceTintColor: Colors.transparent,
      elevation: 12,
      shadowColor: const Color(0xFF334155).withValues(alpha: dark ? .4 : .16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: c.panel,
      surfaceTintColor: Colors.transparent,
      elevation: 8,
      shape: RoundedRectangleBorder(borderRadius: radius14),
    ),
    navigationBarTheme: NavigationBarThemeData(
      elevation: 0,
      backgroundColor: c.panel.withValues(alpha: dark ? .9 : .92),
      surfaceTintColor: Colors.transparent,
      indicatorColor: c.cyan.withValues(alpha: dark ? .18 : .12),
      iconTheme: WidgetStatePropertyAll(
        IconThemeData(size: 22, color: c.muted),
      ),
      labelTextStyle: const WidgetStatePropertyAll(
        TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
      ),
    ),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 400),
      decoration: BoxDecoration(
        color: dark ? c.raised : const Color(0xEE222B38),
        borderRadius: radius10,
      ),
      textStyle: const TextStyle(color: Colors.white, fontSize: 12),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: c.raised,
      selectedColor: c.cyan.withValues(alpha: .14),
      side: BorderSide.none,
      shape: RoundedRectangleBorder(borderRadius: radius10),
      labelStyle: TextStyle(fontSize: 12, color: text),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: c.muted,
      shape: RoundedRectangleBorder(borderRadius: radius14),
    ),
    expansionTileTheme: ExpansionTileThemeData(
      iconColor: c.cyan,
      collapsedIconColor: c.muted,
      textColor: text,
      collapsedTextColor: text,
      backgroundColor: Colors.transparent,
      collapsedBackgroundColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      collapsedShape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      elevation: 4,
      backgroundColor: dark ? c.raised : const Color(0xFF222B38),
      contentTextStyle: TextStyle(color: dark ? text : Colors.white),
      actionTextColor: dark ? c.cyan : const Color(0xFFA9C8FF),
      shape: RoundedRectangleBorder(borderRadius: radius14),
    ),
    tabBarTheme: TabBarThemeData(
      labelColor: c.cyan,
      unselectedLabelColor: c.muted,
      indicatorColor: c.cyan,
      dividerColor: Colors.transparent,
    ),
  );
}

/// A static, repaint-isolated light field. It has no timers or animated layers.
class AppAmbient extends StatelessWidget {
  const AppAmbient({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(
          child: RepaintBoundary(
            child: CustomPaint(
              painter: _AmbientPainter(dark: dark, base: colorsOf(context).ink),
            ),
          ),
        ),
        child,
      ],
    );
  }
}

class _AmbientPainter extends CustomPainter {
  const _AmbientPainter({required this.dark, required this.base});
  final bool dark;
  final Color base;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = base);
    final extent = math.max(size.width, size.height);
    void glow(Offset center, double radius, Color color) {
      final paint = Paint()
        ..shader = RadialGradient(colors: [color, color.withValues(alpha: 0)])
            .createShader(Rect.fromCircle(center: center, radius: radius));
      canvas.drawCircle(center, radius, paint);
    }

    glow(
      Offset(size.width * .08, -size.height * .06),
      extent * .58,
      (dark ? const Color(0xFF1B2A4A) : const Color(0xFFCFE0FF)).withValues(
        alpha: dark ? .54 : .72,
      ),
    );
    glow(
      Offset(size.width * .94, size.height * .04),
      extent * .46,
      (dark ? const Color(0xFF3A1B33) : const Color(0xFFFFE0EF)).withValues(
        alpha: dark ? .42 : .56,
      ),
    );
    glow(
      Offset(size.width * .58, size.height * 1.06),
      extent * .62,
      (dark ? const Color(0xFF10352F) : const Color(0xFFD8F5EA)).withValues(
        alpha: dark ? .42 : .54,
      ),
    );
  }

  @override
  bool shouldRepaint(_AmbientPainter oldDelegate) =>
      oldDelegate.dark != dark || oldDelegate.base != base;
}

/// Glass is reserved for floating chrome and the single welcome panel.
/// Data-dense content continues to use opaque Material surfaces.
class GlassPanel extends StatelessWidget {
  const GlassPanel({
    super.key,
    required this.child,
    this.padding,
    this.radius = 20,
    this.blur = false,
  });
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final double radius;
  final bool blur;

  @override
  Widget build(BuildContext context) {
    final c = colorsOf(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final borderRadius = BorderRadius.circular(radius);
    final panel = Container(
      padding: padding,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            c.panel.withValues(alpha: dark ? .86 : .82),
            c.panel.withValues(alpha: dark ? .76 : .68),
          ],
        ),
        borderRadius: borderRadius,
        border: Border.all(
          color: dark
              ? Colors.white.withValues(alpha: .10)
              : Colors.white.withValues(alpha: .88),
        ),
        boxShadow: [
          BoxShadow(
            color: dark
                ? Colors.black.withValues(alpha: .24)
                : const Color(0xFF64748B).withValues(alpha: .10),
            blurRadius: 24,
            offset: const Offset(0, 10),
            spreadRadius: -10,
          ),
        ],
      ),
      child: child,
    );
    if (!blur) return panel;
    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: panel,
      ),
    );
  }
}

/// Transform-only press feedback; no pointer-move work or perpetual animation.
class Pressable extends StatefulWidget {
  const Pressable({super.key, required this.child});
  final Widget child;
  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool pressed = false;
  void update(bool value) {
    if (mounted && pressed != value) setState(() => pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return widget.child;
    return Listener(
      onPointerDown: (_) => update(true),
      onPointerUp: (_) => update(false),
      onPointerCancel: (_) => update(false),
      child: AnimatedScale(
        scale: pressed ? .98 : 1,
        duration: Duration(milliseconds: pressed ? 60 : 140),
        curve: Curves.easeOutCubic,
        child: widget.child,
      ),
    );
  }
}

class StarMark extends StatelessWidget {
  const StarMark({super.key, this.size = 34});
  final double size;
  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          colorsOf(context).cyan.withValues(alpha: .18),
          colorsOf(context).violet.withValues(alpha: .08),
        ],
      ),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: colorsOf(context).panel.withValues(alpha: .72)),
    ),
    child: Icon(
      Icons.edit_note_rounded,
      color: colorsOf(context).cyan,
      size: size * .65,
    ),
  );
}

class StatusDot extends StatelessWidget {
  const StatusDot(this.text, {super.key, this.color, this.compact = false});
  final String text;
  final Color? color;
  final bool compact;
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 6,
        height: 6,
        decoration: BoxDecoration(
          color: color ?? colorsOf(context).cyan,
          shape: BoxShape.circle,
        ),
      ),
      const SizedBox(width: 8),
      Flexible(
        child: Text(
          text,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: compact ? 11 : 12,
            color: colorsOf(context).muted,
          ),
        ),
      ),
    ],
  );
}

String dateLabel(DateTime? time, {bool full = false}) {
  if (time == null) return '添加提醒';
  final t = time.toLocal(), now = DateTime.now();
  final day = DateTime(
    t.year,
    t.month,
    t.day,
  ).difference(DateTime(now.year, now.month, now.day)).inDays;
  final prefix = full
      ? '${t.year}/${t.month.toString().padLeft(2, '0')}/${t.day.toString().padLeft(2, '0')}'
      : switch (day) {
          0 => '今天',
          1 => '明天',
          -1 => '昨天',
          _ => '${t.month}月${t.day}日',
        };
  return '$prefix ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}
