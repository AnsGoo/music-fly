/// The MusicFly design tokens: warm near-black surfaces, a vermilion accent
/// and cream lettering.
///
/// UI UX Pro Max pass (2026-11-15): every colour used by a widget lives here
/// as a semantic token, text sizes/spacing/radii/motion have named scales, and
/// the Material theme exposes the full M3 colour + type roles. The brand
/// palette itself is unchanged — only its legibility and consistency changed.
library;

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

/// Touch devices handle volume with their hardware keys, so volume widgets
/// are hidden there.
///
/// OpenHarmony (HarmonyOS) reports its own operating system name ("ohos")
/// from dart:io, so it must be matched explicitly — isAndroid/isIOS are both
/// false there and the app would otherwise fall into the desktop layout
/// (fixed card widths, visible volume slider, 10 entries per section).
final bool isMobilePlatform =
    !kIsWeb &&
    (Platform.isAndroid || Platform.isIOS || Platform.operatingSystem == 'ohos');

class Mf {
  const Mf._();

  // Surfaces: a five-step warm ladder. Kept subtle, but the borders and
  // slider groove are now light enough to read as real control boundaries.
  static const bg = Color(0xFF131010);
  static const surface = Color(0xFF1B1715);
  static const surfaceAlt = Color(0xFF241F1B);
  static const raised = Color(0xFF2C2521);
  static const border = Color(0xFF3A312A);

  /// Slider grooves: a touch lighter than a border so a hairline still reads.
  static const track = Color(0xFF4A3E34);

  /// ≥3:1 against the background. Use for control outlines that carry meaning
  /// (focused/hovered field edges, active dividers), not for every hairline.
  static const outlineStrong = Color(0xFF7A6C5B);

  static const accent = Color(0xFFE85C3A);
  static const accentHover = Color(0xFFF26E4D);
  static const accentPressed = Color(0xFFD9502F);
  static const accentLift = Color(0xFFFA8362);
  static const accentWash = Color(0xFF3B211A);

  /// Soft warm shadow beneath the primary button. Composite with an alpha
  /// modifier when a stronger lift is needed.
  static const accentShadow = Color(0xFF2A1009);

  static const cream = Color(0xFFF6EFE3);

  // Text ladder. All three foreground steps clear 4.5:1 on bg/surface.
  static const text = Color(0xFFF4EEE4);
  static const textSoft = Color(0xFFC9BFB2);
  static const muted = Color(0xFF9A8F82);

  /// Decorative-only hint tone (≈4.9:1). Never use for body text — use
  /// [muted]. Kept as a token so disabled icons can stay quiet without
  /// dropping readable copy below the contrast floor.
  static const faint = Color(0xFF8A8074);

  /// Disabled / non-interactive foreground. Below the text threshold by
  /// design; only apply to controls that announce a disabled state.
  static const disabled = Color(0xFF6B6259);

  /// Status colours, split from the brand accent so "playing" and "error"
  /// never share a hue.
  static const success = Color(0xFF8FC08A);
  static const danger = Color(0xFFFF6F5E);
  static const onDanger = Color(0xFF1B1715);

  // Composite overlays, kept as tokens so hover states cannot drift apart
  // between the home grid, browse grid and album tiles.
  static const scrim = Color(0xB3000000);
  static const coverHoverScrim = Color(0x47131010); // bg @ 28%
  static const rowHover = Color(0xB32C2521); // raised @ 70%
  static const rowHoverSoft = Color(0x992C2521); // raised @ 60%
  static const gloss = Color(0x14FFFFFF);
  static const transparent = Color(0x00000000);

  // Canvas-only tones for the vinyl disc. Kept here so the painter does not
  // invent its own shadows/highlights.
  static const discShadow = Color(0x66000000);
  static const discShade = Color(0x2E000000);
  static const discEdge = Color(0x24000000);
  static const discGloss = Color(0x33FFFFFF);
}

/// 4/8dp spacing rhythm. Existing layouts keep their tight values where a
/// control is deliberately compact; new layout work should use these.
class MfSpace {
  const MfSpace._();

  static const double x1 = 4;
  static const double x2 = 8;
  static const double x3 = 12;
  static const double x4 = 16;
  static const double x5 = 20;
  static const double x6 = 24;
  static const double x8 = 32;
}

class MfRadius {
  const MfRadius._();

  static const double sm = 8;
  static const double md = 10;
  static const double lg = 12;
  static const double sheet = 16;
  static const double pill = 999;
}

/// Type scale. Body copy never goes below 12; the `caption` step is reserved
/// for numeric badges and tabular figures.
class MfType {
  const MfType._();

  static const double caption = 11;
  static const double label = 12;
  static const double body = 13;
  static const double bodyLarge = 14;
  static const double title = 16;
  static const double headline = 20;
  static const double display = 26;
}

/// Shared motion scale. Feedback is fast, reveals are slower, and everything
/// collapses to zero when the OS asks for reduced motion.
class MfMotion {
  const MfMotion._();

  static const Duration fast = Duration(milliseconds: 140);
  static const Duration quick = Duration(milliseconds: 180);
  static const Duration normal = Duration(milliseconds: 240);
  static const Duration slow = Duration(milliseconds: 320);
  static const Duration reveal = Duration(milliseconds: 600);
  static const Duration splashMin = Duration(milliseconds: 1200);
  static const Duration spin = Duration(milliseconds: 1800);
  static const Duration vinyl = Duration(seconds: 26);

  static const Curve enter = Curves.easeOutCubic;
  static const Curve exit = Curves.easeInCubic;

  static bool reduced(BuildContext context) =>
      MediaQuery.maybeOf(context)?.disableAnimations ?? false;

  /// Use for every AnimatedContainer / AnimatedSwitcher / animateTo.
  static Duration of(BuildContext context, Duration duration) =>
      reduced(context) ? Duration.zero : duration;
}

class MfTouch {
  const MfTouch._();

  /// iOS 44pt / Android 48dp, with 44 as the shared mobile minimum. Desktop
  /// keeps the user-requested 34dp visual controls; only the invisible hit
  /// area grows on touch platforms.
  static const double minTarget = 44;
  static const double minGap = 8;
}

ThemeData buildMfTheme() {
  final base = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: Mf.bg,
    colorScheme: const ColorScheme.dark(
      primary: Mf.accent,
      onPrimary: Mf.cream,
      primaryContainer: Mf.accentWash,
      onPrimaryContainer: Mf.accentHover,
      secondary: Mf.textSoft,
      onSecondary: Mf.bg,
      secondaryContainer: Mf.surfaceAlt,
      onSecondaryContainer: Mf.text,
      tertiary: Mf.success,
      onTertiary: Mf.bg,
      tertiaryContainer: Mf.surfaceAlt,
      onTertiaryContainer: Mf.success,
      surface: Mf.surface,
      onSurface: Mf.text,
      surfaceContainerLowest: Mf.bg,
      surfaceContainerLow: Mf.surface,
      surfaceContainer: Mf.surfaceAlt,
      surfaceContainerHigh: Mf.raised,
      surfaceContainerHighest: Mf.surfaceAlt,
      onSurfaceVariant: Mf.textSoft,
      outline: Mf.border,
      outlineVariant: Mf.outlineStrong,
      error: Mf.danger,
      onError: Mf.onDanger,
      errorContainer: Mf.accentWash,
      onErrorContainer: Mf.danger,
      inverseSurface: Mf.cream,
      onInverseSurface: Mf.bg,
      inversePrimary: Mf.accentPressed,
      shadow: Mf.bg,
      scrim: Mf.scrim,
    ),
  );

  final text = base.textTheme.apply(
    bodyColor: Mf.text,
    displayColor: Mf.text,
  );

  return base.copyWith(
    textTheme: text.copyWith(
      labelSmall: text.labelSmall?.copyWith(
        fontSize: MfType.label,
        color: Mf.muted,
        height: 1.35,
      ),
      labelMedium: text.labelMedium?.copyWith(
        fontSize: MfType.body,
        color: Mf.textSoft,
        height: 1.4,
      ),
      labelLarge: text.labelLarge?.copyWith(
        fontSize: MfType.bodyLarge,
        color: Mf.text,
        height: 1.4,
      ),
      bodySmall: text.bodySmall?.copyWith(
        fontSize: MfType.label,
        color: Mf.muted,
        height: 1.45,
      ),
      bodyMedium: text.bodyMedium?.copyWith(
        fontSize: MfType.body,
        color: Mf.text,
        height: 1.5,
      ),
      bodyLarge: text.bodyLarge?.copyWith(
        fontSize: MfType.bodyLarge,
        color: Mf.text,
        height: 1.5,
      ),
      titleSmall: text.titleSmall?.copyWith(
        fontSize: MfType.bodyLarge,
        color: Mf.text,
        fontWeight: FontWeight.w500,
      ),
      titleMedium: text.titleMedium?.copyWith(
        fontSize: MfType.title,
        color: Mf.text,
        fontWeight: FontWeight.w600,
      ),
      titleLarge: text.titleLarge?.copyWith(
        fontSize: MfType.headline,
        color: Mf.text,
        fontWeight: FontWeight.w600,
      ),
      headlineSmall: text.headlineSmall?.copyWith(
        fontSize: MfType.headline,
        color: Mf.text,
      ),
      displaySmall: text.displaySmall?.copyWith(
        fontSize: MfType.display,
        color: Mf.text,
      ),
    ),
    dividerColor: Mf.border,
    // NoSplash keeps the UI quiet, but keyboard focus still needs a visible
    // surface — accentWash is subtle enough not to read as a hint banner.
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    hoverColor: Mf.raised,
    focusColor: Mf.accentWash,
    tooltipTheme: const TooltipThemeData(
      decoration: BoxDecoration(
        color: Mf.raised,
        borderRadius: BorderRadius.all(Radius.circular(MfRadius.sm)),
      ),
      textStyle: TextStyle(color: Mf.textSoft, fontSize: MfType.label),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStatePropertyAll(Mf.border.withValues(alpha: 0.9)),
      radius: const Radius.circular(MfSpace.x1),
      thickness: const WidgetStatePropertyAll(6),
    ),
  );
}
