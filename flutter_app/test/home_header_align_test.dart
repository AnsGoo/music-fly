/// The home cards' "查看全部" action must stay on the right edge.
///
/// The header used to be a Row with two loose flex children and no element
/// owning the trailing space, so the action ended up around the middle of the
/// card. Guard the fix against future spacing/token changes.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:musicfly/audio/player.dart';
import 'package:musicfly/data/models.dart';
import 'package:musicfly/data/musicfree_client.dart';
import 'package:musicfly/state/app_model.dart';
import 'package:musicfly/ui/home_view.dart';
import 'package:musicfly/ui/theme.dart';

class _SilentPlayer extends MfPlayer {
  @override
  Future<bool> play({
    required String trackId,
    required String title,
    required String subtitle,
    String? artist,
    required String streamUrl,
    String? coverId,
    String? coverUrl,
    Duration? duration,
    bool transcoded = false,
  }) async => true;
}

class _OfflineClient extends MusicFreeClient {
  @override
  Future<Lyrics?> structuredLyrics(
    String trackId, {
    bool retryable = true,
  }) async => null;
}

AppModel _model() {
  final client = _OfflineClient()
    ..restore(
      MusicFreeSession(
        baseUrl: Uri.parse('http://127.0.0.1:1'),
        token: 'token',
        username: 'admin',
        clientSalt: 'salt',
      ),
    );
  return AppModel(client: client, player: _SilentPlayer());
}

void main() {
  testWidgets('查看全部 is right aligned in every home card', (tester) async {
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final model = _model();
    await tester.pumpWidget(
      ChangeNotifierProvider<AppModel>.value(
        value: model,
        child: MaterialApp(
          theme: buildMfTheme(),
          home: const Scaffold(body: HomeView()),
        ),
      ),
    );
    await tester.pump();

    final labels = find.text('查看全部').evaluate();
    expect(labels, isNotEmpty, reason: 'home cards should render the action');
    for (final element in labels) {
      final box = element.renderObject as RenderBox;
      final left = box.localToGlobal(Offset.zero).dx;
      // 1000dp viewport, card padding ~34dp: a right-aligned action starts
      // well past 80% of the width. The centred regression sat at ~450dp.
      expect(left, greaterThan(800), reason: '查看全部 drifted to the middle');
      expect(left + box.size.width, lessThan(1000));
    }
    expect(tester.takeException(), isNull);
  });
}
