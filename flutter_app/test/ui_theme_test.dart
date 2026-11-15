/// Regression tests for the UI UX Pro Max design-token pass: contrast floors,
/// complete theme roles, coherent scales and accessible icon-only controls.
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicfly/ui/controls.dart';
import 'package:musicfly/ui/theme.dart';

double _channel(double value) {
  final x = value.clamp(0.0, 1.0);
  return x <= 0.03928
      ? x / 12.92
      : math.pow((x + 0.055) / 1.055, 2.4).toDouble();
}

double _luminance(Color c) =>
    0.2126 * _channel(c.r) +
    0.7152 * _channel(c.g) +
    0.0722 * _channel(c.b);

double _contrast(Color a, Color b) {
  final la = _luminance(a);
  final lb = _luminance(b);
  final lighter = math.max(la, lb);
  final darker = math.min(la, lb);
  return (lighter + 0.05) / (darker + 0.05);
}

void main() {
  group('WCAG contrast on dark surfaces', () {
    final textTokens = <String, Color>{
      'text': Mf.text,
      'cream': Mf.cream,
      'textSoft': Mf.textSoft,
      'muted': Mf.muted,
      'accent': Mf.accent,
      'accentHover': Mf.accentHover,
      'accentLift': Mf.accentLift,
      'success': Mf.success,
      'danger': Mf.danger,
    };

    for (final entry in textTokens.entries) {
      test('${entry.key} clears 4.5:1 on bg and surface', () {
        expect(
          _contrast(entry.value, Mf.bg),
          greaterThanOrEqualTo(4.5),
          reason: '${entry.key} on Mf.bg',
        );
        expect(
          _contrast(entry.value, Mf.surface),
          greaterThanOrEqualTo(4.5),
          reason: '${entry.key} on Mf.surface',
        );
      });
    }

    test('body text stays readable on raised cards', () {
      for (final color in [Mf.text, Mf.textSoft, Mf.muted]) {
        expect(_contrast(color, Mf.surfaceAlt), greaterThanOrEqualTo(4.5));
        expect(_contrast(color, Mf.raised), greaterThanOrEqualTo(4.5));
      }
    });

    test('outlineStrong is a visible control boundary (>=3:1)', () {
      for (final bg in [Mf.bg, Mf.surface, Mf.surfaceAlt]) {
        expect(_contrast(Mf.outlineStrong, bg), greaterThanOrEqualTo(3.0));
      }
    });
  });

  group('theme roles', () {
    final theme = buildMfTheme();
    final scheme = theme.colorScheme;

    test('status colours are distinct from the brand accent', () {
      expect(scheme.error, isNot(scheme.primary));
      expect(scheme.error, Mf.danger);
      expect(scheme.onError, Mf.onDanger);
      expect(scheme.tertiary, Mf.success);
    });

    test('surface containers and focus affordance are populated', () {
      expect(scheme.surfaceContainerLow, Mf.surface);
      expect(scheme.surfaceContainer, Mf.surfaceAlt);
      expect(scheme.surfaceContainerHigh, Mf.raised);
      expect(scheme.outlineVariant, Mf.outlineStrong);
      expect(theme.focusColor, isNot(Colors.transparent));
    });

    test('text theme defines an increasing type scale', () {
      final t = theme.textTheme;
      final sizes = [
        t.labelSmall!.fontSize!,
        t.bodyMedium!.fontSize!,
        t.bodyLarge!.fontSize!,
        t.titleMedium!.fontSize!,
        t.titleLarge!.fontSize!,
        t.displaySmall!.fontSize!,
      ];
      for (var i = 1; i < sizes.length; i++) {
        expect(sizes[i], greaterThanOrEqualTo(sizes[i - 1]));
      }
      expect(t.labelSmall!.fontSize, greaterThanOrEqualTo(12));
      expect(t.bodyMedium!.fontSize, greaterThanOrEqualTo(MfType.body));
    });
  });

  group('design scales', () {
    test('motion durations are ordered and reduced motion collapses them', () {
      expect(MfMotion.fast, lessThan(MfMotion.quick));
      expect(MfMotion.quick, lessThan(MfMotion.normal));
      expect(MfMotion.normal, lessThan(MfMotion.slow));
      expect(MfMotion.slow, lessThan(MfMotion.reveal));
    });

    testWidgets('MfMotion.of returns Duration.zero with reduced motion',
        (tester) async {
      late Duration observed;
      late bool reduced;
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: MaterialApp(
            theme: buildMfTheme(),
            home: Builder(
              builder: (context) {
                observed = MfMotion.of(context, MfMotion.quick);
                reduced = MfMotion.reduced(context);
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
      expect(reduced, isTrue);
      expect(observed, Duration.zero);
    });
  });

  group('UI layer token discipline', () {
    test('no widget uses the low-contrast faint/disabled tone for text', () {
      final dir = Directory('lib/ui');
      for (final entity in dir.listSync().whereType<File>()) {
        if (!entity.path.endsWith('.dart') ||
            entity.path.endsWith('theme.dart')) {
          continue;
        }
        final source = entity.readAsStringSync();
        expect(source.contains('Mf.faint'), isFalse, reason: entity.path);
        // Mf.disabled is allowed for explicitly disabled controls only.
      }
    });

    test('no raw white/hex semantic colours leak into widgets', () {
      final dir = Directory('lib/ui');
      for (final entity in dir.listSync().whereType<File>()) {
        if (!entity.path.endsWith('.dart') ||
            entity.path.endsWith('theme.dart')) {
          continue;
        }
        final source = entity.readAsStringSync();
        expect(source.contains('Colors.white'), isFalse, reason: entity.path);
        expect(source.contains('Color(0xFF'), isFalse, reason: entity.path);
      }
    });
  });

  group('accessible controls', () {
    testWidgets('icon-only controls expose descriptive labels', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        MaterialApp(
          theme: buildMfTheme(),
          home: Scaffold(
            body: Column(
              children: [
                MfPlayButton(playing: false, onTap: () {}),
                MfIconButton(
                  icon: Icons.close,
                  semanticLabel: '清除搜索',
                  onTap: () {},
                ),
                MfPrimaryButton(label: '登录', onTap: () {}),
                const MfScrubber(fraction: 0.5),
                MfPrimaryButton(label: '禁用', enabled: false, onTap: null),
              ],
            ),
          ),
        ),
      );

      bool labelled(String label) => find
          .byWidgetPredicate(
            (w) => w is Semantics && w.properties.label == label,
          )
          .evaluate()
          .isNotEmpty;

      expect(labelled('播放'), isTrue);
      expect(labelled('清除搜索'), isTrue);
      expect(labelled('登录'), isTrue);
      expect(labelled('进度'), isTrue);
      final slider = tester.widget<Semantics>(
        find.byWidgetPredicate(
          (w) => w is Semantics && w.properties.slider == true,
        ),
      );
      expect(slider.properties.value, '50%');
      expect(slider.properties.increasedValue, '55%');
      expect(slider.properties.decreasedValue, '45%');
      handle.dispose();
    });
  });
}
