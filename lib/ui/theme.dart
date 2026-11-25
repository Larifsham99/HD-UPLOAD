import 'package:material_ui/material_ui.dart';

class HD {
  static const bg = Color(0xFF060A13);
  static const bg2 = Color(0xFF0B1220);
  static const surface = Color(0xFF101A2C);
  static const line = Color(0x1FFFFFFF);
  static const glass = Color(0x0FFFFFFF);
  static const blue = Color(0xFF2E7BFF);
  static const cyan = Color(0xFF22D3EE);
  static const violet = Color(0xFF7C5CFF);
  static const text = Color(0xFFF3F6FC);
  static const muted = Color(0xFF8E9BB3);
  static const faint = Color(0xFF55627A);
  static const ok = Color(0xFF34D399);
  static const warn = Color(0xFFFBBF24);
  static const bad = Color(0xFFF87171);

  static const accent = LinearGradient(
    colors: [blue, cyan],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static ThemeData theme() {
    final base = ThemeData(
      brightness: Brightness.dark,
      useMaterial3: true,
      colorScheme: const ColorScheme.dark(
        primary: blue,
        secondary: cyan,
        surface: surface,
        onSurface: text,
        error: bad,
      ),
      scaffoldBackgroundColor: bg,
      splashFactory: InkSparkle.splashFactory,
    );
    return base.copyWith(
      textTheme: base.textTheme.apply(bodyColor: text, displayColor: text),
      sliderTheme: const SliderThemeData(
        activeTrackColor: cyan,
        inactiveTrackColor: line,
        thumbColor: Colors.white,
        overlayColor: Color(0x3322D3EE),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Colors.white : muted),
        trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? blue : line),
        trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
      ),
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: surface,
        contentTextStyle: TextStyle(color: text),
        behavior: SnackBarBehavior.floating,
      ),
      pageTransitionsTheme: const PageTransitionsTheme(builders: {
        TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.iOS: FadeForwardsPageTransitionsBuilder(),
      }),
    );
  }
}

const kTitle = TextStyle(fontSize: 13, fontWeight: FontWeight.w700, letterSpacing: 1.6, color: HD.muted);
