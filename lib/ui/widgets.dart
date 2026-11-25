import 'dart:math' as math;
import 'dart:ui';

import 'package:material_ui/material_ui.dart';

import 'theme.dart';

/// Soft animated gradient orbs behind every screen.
class HDBackground extends StatefulWidget {
  const HDBackground({super.key, required this.child});
  final Widget child;
  @override
  State<HDBackground> createState() => _HDBackgroundState();
}

class _HDBackgroundState extends State<HDBackground> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(seconds: 18))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(colors: [HD.bg2, HD.bg], begin: Alignment.topCenter, end: Alignment.bottomCenter),
      ),
      child: Stack(children: [
        AnimatedBuilder(
          animation: _c,
          builder: (_, _) {
            final t = _c.value * 2 * math.pi;
            return Stack(children: [
              _orb(Alignment(-0.9 + 0.2 * math.sin(t), -0.95 + 0.1 * math.cos(t)), HD.blue, 340),
              _orb(Alignment(1.1 + 0.15 * math.cos(t), -0.3 + 0.15 * math.sin(t)), HD.cyan, 260),
              _orb(Alignment(-0.6 + 0.2 * math.cos(t), 1.1), HD.violet, 300),
            ]);
          },
        ),
        widget.child,
      ]),
    );
  }

  Widget _orb(Alignment a, Color c, double size) => Align(
        alignment: a,
        child: IgnorePointer(
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(colors: [c.withValues(alpha: 0.18), c.withValues(alpha: 0)]),
            ),
          ),
        ),
      );
}

class GlassCard extends StatelessWidget {
  const GlassCard({super.key, required this.child, this.padding = const EdgeInsets.all(18), this.radius = 22, this.onTap, this.highlight = false});
  final Widget child;
  final EdgeInsets padding;
  final double radius;
  final VoidCallback? onTap;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: Material(
          color: highlight ? HD.blue.withValues(alpha: 0.12) : HD.glass,
          child: InkWell(
            onTap: onTap,
            child: Container(
              padding: padding,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(radius),
                border: Border.all(color: highlight ? HD.cyan.withValues(alpha: 0.55) : HD.line),
              ),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

/// Large primary call-to-action with gradient, glow and press animation.
class GradientButton extends StatefulWidget {
  const GradientButton({super.key, required this.label, required this.onPressed, this.icon, this.height = 62, this.busy = false});
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final double height;
  final bool busy;

  @override
  State<GradientButton> createState() => _GradientButtonState();
}

class _GradientButtonState extends State<GradientButton> with SingleTickerProviderStateMixin {
  bool _down = false;
  late final _shine = AnimationController(vsync: this, duration: const Duration(milliseconds: 2600))..repeat();

  @override
  void dispose() {
    _shine.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null && !widget.busy;
    return GestureDetector(
      onTapDown: enabled ? (_) => setState(() => _down = true) : null,
      onTapCancel: () => setState(() => _down = false),
      onTapUp: enabled
          ? (_) {
              setState(() => _down = false);
              widget.onPressed!();
            }
          : null,
      child: AnimatedScale(
        scale: _down ? 0.97 : 1,
        duration: const Duration(milliseconds: 120),
        child: AnimatedOpacity(
          opacity: enabled || widget.busy ? 1 : 0.45,
          duration: const Duration(milliseconds: 200),
          child: Container(
            height: widget.height,
            decoration: BoxDecoration(
              gradient: HD.accent,
              borderRadius: BorderRadius.circular(widget.height / 2),
              boxShadow: [BoxShadow(color: HD.blue.withValues(alpha: 0.45), blurRadius: 28, offset: const Offset(0, 10))],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(widget.height / 2),
              child: Stack(alignment: Alignment.center, children: [
                AnimatedBuilder(
                  animation: _shine,
                  builder: (_, _) => Align(
                    alignment: Alignment(-2 + 4 * _shine.value, 0),
                    child: Transform.rotate(
                      angle: 0.3,
                      child: Container(
                        width: 60,
                        height: widget.height * 2,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(colors: [
                            Colors.white.withValues(alpha: 0),
                            Colors.white.withValues(alpha: 0.22),
                            Colors.white.withValues(alpha: 0),
                          ]),
                        ),
                      ),
                    ),
                  ),
                ),
                widget.busy
                    ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
                    : Row(mainAxisSize: MainAxisSize.min, children: [
                        if (widget.icon != null) ...[Icon(widget.icon, color: Colors.white, size: 22), const SizedBox(width: 10)],
                        Text(widget.label,
                            style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w800, letterSpacing: 1.4)),
                      ]),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

class SecondaryButton extends StatelessWidget {
  const SecondaryButton({super.key, required this.label, required this.onPressed, this.icon, this.color});
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? HD.text;
    return SizedBox(
      height: 54,
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          foregroundColor: c,
          side: const BorderSide(color: HD.line),
          backgroundColor: HD.glass,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        ),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          if (icon != null) ...[Icon(icon, size: 20, color: c), const SizedBox(width: 8)],
          Flexible(child: Text(label, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, letterSpacing: 0.6))),
        ]),
      ),
    );
  }
}

/// The HD CLEAN mark: gradient rounded square with "HD".
class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 40});
  final double size;
  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          gradient: HD.accent,
          borderRadius: BorderRadius.circular(size * 0.3),
          boxShadow: [BoxShadow(color: HD.cyan.withValues(alpha: 0.35), blurRadius: size * 0.5)],
        ),
        alignment: Alignment.center,
        child: Text('HD', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: size * 0.38, letterSpacing: 0.5)),
      );
}

class StatTile extends StatelessWidget {
  const StatTile(this.label, this.value, {super.key, this.accent = false});
  final String label;
  final String value;
  final bool accent;
  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label.toUpperCase(), style: const TextStyle(fontSize: 10.5, color: HD.muted, letterSpacing: 1.2, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        Text(value,
            style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700, color: accent ? HD.cyan : HD.text),
            maxLines: 1,
            overflow: TextOverflow.ellipsis),
      ]);
}

/// Two-column grid of [StatTile]s.
class StatGrid extends StatelessWidget {
  const StatGrid(this.items, {super.key});
  final List<(String, String)> items;
  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var i = 0; i < items.length; i += 2) {
      rows.add(Padding(
        padding: EdgeInsets.only(top: i == 0 ? 0 : 14),
        child: Row(children: [
          Expanded(child: StatTile(items[i].$1, items[i].$2)),
          Expanded(child: i + 1 < items.length ? StatTile(items[i + 1].$1, items[i + 1].$2) : const SizedBox()),
        ]),
      ));
    }
    return Column(children: rows);
  }
}

/// Animated circular progress with gradient arc and glow.
class ProgressRing extends StatefulWidget {
  const ProgressRing({super.key, required this.value, required this.child, this.size = 230, this.indeterminate = false});
  final double value; // 0..1
  final Widget child;
  final double size;
  final bool indeterminate;
  @override
  State<ProgressRing> createState() => _ProgressRingState();
}

class _ProgressRingState extends State<ProgressRing> with SingleTickerProviderStateMixin {
  late final _spin = AnimationController(vsync: this, duration: const Duration(seconds: 3))..repeat();
  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(end: widget.value.clamp(0, 1)),
      duration: const Duration(milliseconds: 450),
      curve: Curves.easeOutCubic,
      builder: (_, v, _) => AnimatedBuilder(
        animation: _spin,
        builder: (_, _) => CustomPaint(
          size: Size.square(widget.size),
          painter: _RingPainter(v, _spin.value, widget.indeterminate),
          child: SizedBox.square(dimension: widget.size, child: Center(child: widget.child)),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.v, this.spin, this.indeterminate);
  final double v, spin;
  final bool indeterminate;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2 - 14;
    final rect = Rect.fromCircle(center: c, radius: r);
    canvas.drawCircle(c, r, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 12
      ..color = HD.line);
    // Ticks
    final tick = Paint()
      ..color = HD.line
      ..strokeWidth = 1.5;
    for (var i = 0; i < 60; i++) {
      final a = i / 60 * 2 * math.pi;
      final p1 = c + Offset(math.cos(a), math.sin(a)) * (r - 18);
      final p2 = c + Offset(math.cos(a), math.sin(a)) * (r - (i % 5 == 0 ? 26 : 22));
      canvas.drawLine(p1, p2, tick);
    }
    final start = indeterminate ? spin * 2 * math.pi : -math.pi / 2;
    final sweep = indeterminate ? math.pi * 0.6 : 2 * math.pi * v;
    if (sweep <= 0) return;
    final shader = SweepGradient(
      colors: const [HD.blue, HD.cyan, HD.blue],
      transform: GradientRotation(start),
    ).createShader(rect);
    canvas.drawArc(rect, start, sweep, false, Paint()
      ..shader = shader
      ..style = PaintingStyle.stroke
      ..strokeWidth = 14
      ..strokeCap = StrokeCap.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10));
    canvas.drawArc(rect, start, sweep, false, Paint()
      ..shader = shader
      ..style = PaintingStyle.stroke
      ..strokeWidth = 12
      ..strokeCap = StrokeCap.round);
    // Leading dot
    final end = start + sweep;
    canvas.drawCircle(c + Offset(math.cos(end), math.sin(end)) * r, 5, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(_RingPainter o) => o.v != v || o.spin != spin;
}

/// Segmented selector with a sliding highlight.
class Segmented<T> extends StatelessWidget {
  const Segmented({super.key, required this.values, required this.selected, required this.label, required this.onChanged});
  final List<T> values;
  final T selected;
  final String Function(T) label;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final idx = values.indexOf(selected);
    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth / values.length;
      return Container(
        height: 46,
        decoration: BoxDecoration(color: HD.glass, borderRadius: BorderRadius.circular(14), border: Border.all(color: HD.line)),
        child: Stack(children: [
          AnimatedPositioned(
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
            left: idx * w + 3,
            top: 3,
            bottom: 3,
            width: w - 6,
            child: Container(decoration: BoxDecoration(gradient: HD.accent, borderRadius: BorderRadius.circular(11))),
          ),
          Row(children: [
            for (final v in values)
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onChanged(v),
                  child: Center(
                    child: Text(label(v),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 12.5, fontWeight: FontWeight.w700, color: v == selected ? Colors.white : HD.muted)),
                  ),
                ),
              ),
          ]),
        ]),
      );
    });
  }
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key, this.trailing});
  final String text;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 12, top: 4),
        child: Row(children: [Expanded(child: Text(text.toUpperCase(), style: kTitle)), ?trailing]),
      );
}

void showError(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Row(children: [
      const Icon(Icons.error_outline_rounded, color: HD.bad),
      const SizedBox(width: 10),
      Expanded(child: Text(message)),
    ]),
  ));
}

void showInfo(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Row(children: [
      const Icon(Icons.check_circle_rounded, color: HD.ok),
      const SizedBox(width: 10),
      Expanded(child: Text(message)),
    ]),
  ));
}

/// Fade+slide in on first build, staggered by [index].
class Reveal extends StatelessWidget {
  const Reveal({super.key, required this.child, this.index = 0});
  final Widget child;
  final int index;
  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: Duration(milliseconds: 420 + index * 70),
        curve: Curves.easeOutCubic,
        builder: (_, t, c) => Opacity(opacity: t, child: Transform.translate(offset: Offset(0, 18 * (1 - t)), child: c)),
        child: child,
      );
}
