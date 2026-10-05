import 'package:flutter/material.dart';

/// YouTube-inspired dark palette.
class YtColors {
  static const background = Color(0xFF0F0F0F);
  static const surface = Color(0xFF181818);
  static const surfaceHigh = Color(0xFF272727);
  static const divider = Color(0xFF303030);
  static const red = Color(0xFFFF0000);
  static const blue = Color(0xFF3EA6FF);
  static const textPrimary = Color(0xFFF1F1F1);
  static const textSecondary = Color(0xFFAAAAAA);
  static const success = Color(0xFF2BA640);
  static const warning = Color(0xFFFFB300);
}

ThemeData buildDarkTheme() {
  const scheme = ColorScheme.dark(
    primary: YtColors.red,
    onPrimary: Colors.white,
    secondary: YtColors.blue,
    surface: YtColors.background,
    onSurface: YtColors.textPrimary,
    surfaceContainerHighest: YtColors.surfaceHigh,
    error: Color(0xFFFF6E6E),
  );
  final border = OutlineInputBorder(
    borderRadius: BorderRadius.circular(10),
    borderSide: const BorderSide(color: YtColors.divider),
  );
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: YtColors.background,
    canvasColor: YtColors.background,
    dividerColor: YtColors.divider,
    appBarTheme: const AppBarTheme(
      backgroundColor: YtColors.background,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleTextStyle: TextStyle(
        color: YtColors.textPrimary,
        fontSize: 20,
        fontWeight: FontWeight.w700,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: YtColors.surface,
      border: border,
      enabledBorder: border,
      focusedBorder: border.copyWith(
        borderSide: const BorderSide(color: YtColors.blue, width: 1.5),
      ),
      errorBorder: border.copyWith(
        borderSide: const BorderSide(color: Color(0xFFFF6E6E)),
      ),
      focusedErrorBorder: border.copyWith(
        borderSide: const BorderSide(color: Color(0xFFFF6E6E), width: 1.5),
      ),
      labelStyle: const TextStyle(color: YtColors.textSecondary),
      hintStyle: const TextStyle(color: YtColors.textSecondary),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: YtColors.red,
        foregroundColor: Colors.white,
        minimumSize: const Size.fromHeight(48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: YtColors.blue),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: YtColors.textPrimary,
        side: const BorderSide(color: YtColors.divider),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      ),
    ),
    snackBarTheme: const SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: YtColors.surfaceHigh,
      contentTextStyle: TextStyle(color: YtColors.textPrimary),
      actionTextColor: YtColors.blue,
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: YtColors.surface,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: YtColors.surfaceHigh,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    popupMenuTheme: const PopupMenuThemeData(
      color: YtColors.surfaceHigh,
      surfaceTintColor: Colors.transparent,
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: YtColors.red,
      linearTrackColor: YtColors.surfaceHigh,
    ),
    dividerTheme: const DividerThemeData(color: YtColors.divider, space: 1),
  );
}
