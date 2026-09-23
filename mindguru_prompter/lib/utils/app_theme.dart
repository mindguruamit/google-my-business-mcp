import 'package:flutter/material.dart';

import 'constants.dart';

class AppTheme {
  AppTheme._();

  /// Bundled in assets/fonts, so the app looks right fully offline.
  static const String fontFamily = 'Inter';

  static ThemeData get dark {
    final scheme = ColorScheme.fromSeed(
      seedColor: AppColors.accent,
      brightness: Brightness.dark,
    ).copyWith(
      primary: AppColors.accent,
      onPrimary: Colors.black,
      secondary: AppColors.accent,
      onSecondary: Colors.black,
      surface: AppColors.card,
      onSurface: AppColors.textPrimary,
      error: AppColors.recording,
    );

    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      fontFamily: fontFamily,
      scaffoldBackgroundColor: AppColors.background,
    );

    return base.copyWith(
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.background,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontFamily: fontFamily,
          fontSize: 22,
          fontWeight: FontWeight.w700,
          color: AppColors.textPrimary,
        ),
      ),
      cardTheme: CardThemeData(
        color: AppColors.card,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      chipTheme: base.chipTheme.copyWith(
        backgroundColor: AppColors.card,
        selectedColor: AppColors.accent,
        disabledColor: AppColors.card.withValues(alpha: 0.5),
        labelStyle: const TextStyle(
          fontFamily: fontFamily,
          color: AppColors.textPrimary,
          fontWeight: FontWeight.w600,
        ),
        secondaryLabelStyle: const TextStyle(
          fontFamily: fontFamily,
          color: Colors.black,
          fontWeight: FontWeight.w700,
        ),
        side: const BorderSide(color: Colors.white12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        showCheckmark: false,
      ),
      sliderTheme: base.sliderTheme.copyWith(
        activeTrackColor: AppColors.accent,
        thumbColor: AppColors.accent,
        inactiveTrackColor: Colors.white24,
        overlayColor: AppColors.accent.withValues(alpha: 0.15),
        valueIndicatorColor: AppColors.accent,
        valueIndicatorTextStyle: const TextStyle(color: Colors.black),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: AppColors.accent,
        foregroundColor: Colors.black,
      ),
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: AppColors.cardHigh,
        contentTextStyle: TextStyle(fontFamily: fontFamily, color: Colors.white),
        behavior: SnackBarBehavior.floating,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.card,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: AppColors.accent, width: 1.5),
        ),
        hintStyle: const TextStyle(color: AppColors.textSecondary),
      ),
      dialogTheme: const DialogThemeData(backgroundColor: AppColors.card),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: AppColors.card,
        showDragHandle: true,
      ),
    );
  }
}

String formatDuration(Duration d) {
  final minutes = d.inMinutes;
  final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  if (minutes >= 60) {
    final hours = d.inHours;
    final m = minutes.remainder(60).toString().padLeft(2, '0');
    return '$hours:$m:$seconds';
  }
  return '$minutes:$seconds';
}
