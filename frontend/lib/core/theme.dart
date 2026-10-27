import 'package:flutter/material.dart';

/// Colours from the Figma "YouTube UI Clone" mockups (dark theme). Pages and
/// widgets use these, never raw hex values.
class YtColors {
  /// Browse pages (home grid, channel, search, your videos).
  static const background = Color(0xFF000000);

  /// The watch page sits on a lighter black than the grids.
  static const watchBackground = Color(0xFF181818);

  /// Masthead, sidebar, chip bar.
  static const surface = Color(0xFF212121);

  /// Selected sidebar item, unselected chip, search button, hover.
  static const surfaceHigh = Color(0xFF303030);

  /// The search field's well.
  static const field = Color(0xFF121212);

  static const divider = Color(0xFF2E2E2E);
  static const outline = Color(0xFF3D3D3D);
  static const red = Color(0xFFFF0000);
  static const blue = Color(0xFF3EA6FF);
  static const textPrimary = Color(0xFFFFFFFF);
  static const textSecondary = Color(0xFFAAAAAA);
  static const icon = Color(0xFFFFFFFF);
  static const error = Color(0xFFFF6E6E);
  static const success = Color(0xFF2BA640);
  static const warning = Color(0xFFFFB300);

  /// The duration badge on thumbnails.
  static const badge = Color(0xCC000000);

  /// Behind the red "watched" bar on thumbnails.
  static const watchedTrack = Color(0x99717171);
}

/// Layout metrics from the mockups.
class YtSizes {
  static const mastheadHeight = 56.0;
  static const sidebarWidth = 240.0;
  static const miniSidebarWidth = 72.0;
  static const chipBarHeight = 56.0;
  static const chipHeight = 32.0;
  static const gridGap = 16.0;
  static const gridMinTileWidth = 250.0;
  static const avatar = 36.0;
  static const watchedBarHeight = 3.0;

  /// Full sidebar at and above this width, the mini rail above [rail].
  static const wide = 1312.0;
  static const rail = 792.0;
}

ThemeData buildDarkTheme() {
  const scheme = ColorScheme.dark(
    primary: YtColors.blue,
    onPrimary: Colors.black,
    secondary: YtColors.red,
    surface: YtColors.background,
    onSurface: YtColors.textPrimary,
    surfaceContainerHighest: YtColors.surfaceHigh,
    error: YtColors.error,
  );
  final border = OutlineInputBorder(
    borderRadius: BorderRadius.circular(4),
    borderSide: const BorderSide(color: YtColors.outline),
  );
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: YtColors.background,
    canvasColor: YtColors.surface,
    dividerColor: YtColors.divider,
    hoverColor: Colors.white.withValues(alpha: 0.08),
    splashFactory: NoSplash.splashFactory,
    iconTheme: const IconThemeData(color: YtColors.icon, size: 24),
    appBarTheme: const AppBarTheme(
      backgroundColor: YtColors.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
    ),
    textTheme: const TextTheme(
      titleLarge: TextStyle(fontSize: 20, fontWeight: FontWeight.w400),
      titleMedium: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
      bodyMedium: TextStyle(fontSize: 14),
      bodySmall: TextStyle(fontSize: 13, color: YtColors.textSecondary),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: YtColors.field,
      border: border,
      enabledBorder: border,
      focusedBorder: border.copyWith(
        borderSide: const BorderSide(color: YtColors.blue, width: 1.5),
      ),
      errorBorder: border.copyWith(
        borderSide: const BorderSide(color: YtColors.error),
      ),
      focusedErrorBorder: border.copyWith(
        borderSide: const BorderSide(color: YtColors.error, width: 1.5),
      ),
      labelStyle: const TextStyle(color: YtColors.textSecondary),
      hintStyle: const TextStyle(color: YtColors.textSecondary),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: YtColors.blue,
        foregroundColor: Colors.black,
        disabledBackgroundColor: YtColors.surfaceHigh,
        minimumSize: const Size(64, 40),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(2)),
        textStyle: const TextStyle(
          fontWeight: FontWeight.w500,
          fontSize: 14,
          letterSpacing: 0.5,
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: YtColors.blue,
        textStyle: const TextStyle(fontWeight: FontWeight.w500),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: YtColors.blue,
        side: const BorderSide(color: YtColors.outline),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(2)),
        textStyle: const TextStyle(
          fontWeight: FontWeight.w500,
          letterSpacing: 0.5,
        ),
      ),
    ),
    tooltipTheme: const TooltipThemeData(
      decoration: BoxDecoration(
        color: Color(0xE6616161),
        borderRadius: BorderRadius.all(Radius.circular(2)),
      ),
      textStyle: TextStyle(fontSize: 12, color: Colors.white),
      waitDuration: Duration(milliseconds: 500),
    ),
    snackBarTheme: const SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: YtColors.surfaceHigh,
      contentTextStyle: TextStyle(color: YtColors.textPrimary),
      actionTextColor: YtColors.blue,
      width: 480,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: YtColors.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
    ),
    popupMenuTheme: const PopupMenuThemeData(
      color: YtColors.surfaceHigh,
      surfaceTintColor: Colors.transparent,
    ),
    menuTheme: const MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(YtColors.surfaceHigh),
        surfaceTintColor: WidgetStatePropertyAll(Colors.transparent),
      ),
    ),
    drawerTheme: const DrawerThemeData(
      backgroundColor: YtColors.surface,
      surfaceTintColor: Colors.transparent,
      width: YtSizes.sidebarWidth,
      shape: RoundedRectangleBorder(),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: YtColors.red,
      linearTrackColor: YtColors.surfaceHigh,
    ),
    dividerTheme: const DividerThemeData(color: YtColors.divider, space: 1),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStatePropertyAll(Colors.white.withValues(alpha: 0.3)),
    ),
  );
}
