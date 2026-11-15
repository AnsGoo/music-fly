/// The cast remote's transport row: play/pause is a compact icon-only button,
/// not the old filled "⏸ 暂停" pill that dwarfed the skip buttons.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicfly/ui/cast_sheet.dart';
import 'package:musicfly/ui/controls.dart';

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

CastTransportControls _controls({
  required bool playing,
  required VoidCallback onToggle,
}) =>
    CastTransportControls(
      playing: playing,
      onToggle: onToggle,
      onPrevious: () {},
      onNext: () {},
    );

void main() {
  testWidgets('play/pause carries no text label', (tester) async {
    await tester.pumpWidget(_wrap(_controls(playing: true, onToggle: () {})));

    expect(find.text('暂停'), findsNothing);
    expect(find.text('播放'), findsNothing);
    expect(find.byType(MfPlayButton), findsOneWidget);
    expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
  });

  testWidgets('play/pause matches the 34dp skip buttons', (tester) async {
    await tester.pumpWidget(_wrap(_controls(playing: true, onToggle: () {})));

    final play = find.byType(MfPlayButton);
    expect(tester.getSize(play), const Size(34, 34));
    expect(
      tester.getSize(play),
      tester.getSize(
        find.widgetWithIcon(MfIconButton, Icons.skip_previous_rounded),
      ),
    );
    expect(
      tester.getSize(play),
      tester.getSize(
        find.widgetWithIcon(MfIconButton, Icons.skip_next_rounded),
      ),
    );
  });

  testWidgets('tapping toggles playback and the icon follows state',
      (tester) async {
    var toggles = 0;
    await tester.pumpWidget(
      _wrap(_controls(playing: true, onToggle: () => toggles++)),
    );

    await tester.tap(find.byType(MfPlayButton));
    expect(toggles, 1);

    await tester.pumpWidget(
      _wrap(_controls(playing: false, onToggle: () => toggles++)),
    );
    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
    expect(find.byIcon(Icons.pause_rounded), findsNothing);
  });
}
