/// Step 2 of the FNID flow must ask for the Music Free account — there is no
/// "just tap 登录" passwordless shortcut that would sign into a bound default.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:musicfly/audio/player.dart';
import 'package:musicfly/data/fn_connect.dart';
import 'package:musicfly/data/musicfree_client.dart';
import 'package:musicfly/state/app_model.dart';
import 'package:musicfly/ui/login_page.dart';
import 'package:musicfly/ui/theme.dart';

class _SilentPlayer extends MfPlayer {}

/// Stands in for an AppModel whose last session used Fn Connect, without
/// starting its address-probe timers inside a widget test.
class _FnTabModel extends AppModel {
  _FnTabModel({required MusicFreeClient client, required MfPlayer player})
      : super(client: client, player: player);

  @override
  bool get preferFnConnectTab => true;
}

final _gateway = Uri.parse('https://nas.example.com/app/musicfree/');

Widget _host(AppModel model) => ChangeNotifierProvider<AppModel>.value(
  value: model,
  child: MaterialApp(theme: buildMfTheme(), home: const LoginPage()),
);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    fnGatewayToken = 'fnos-tok';
  });
  tearDown(() => fnGatewayToken = null);

  testWidgets('step 2 requires the Music Free account and password',
      (tester) async {
    final requests = <http.Request>[];
    final client = MusicFreeClient(
      httpClient: MockClient((request) async {
        requests.add(request);
        return http.Response('{}', 200);
      }),
    );
    final model = AppModel(client: client, player: _SilentPlayer());
    addTearDown(model.dispose);
    model.setFnProbeForTest(
      FnProbeResult(
        best: _gateway,
        reachable: [_gateway],
        candidates: [_gateway],
      ),
      addresses: [_gateway],
    );

    await tester.pumpWidget(_host(model));
    await tester.pumpAndSettle();
    await tester.tap(find.text('飞牛快连 (FNID)'));
    await tester.pumpAndSettle();

    expect(find.textContaining('第二步 · 输入 Music Free 账号密码'), findsOneWidget);
    expect(find.text('账号'), findsOneWidget);
    expect(find.text('密码'), findsOneWidget);
    expect(find.text('登录'), findsOneWidget);
    expect(find.textContaining('点「登录」即可进入'), findsNothing);

    // Tapping the button with empty fields must not contact the backend.
    await tester.tap(find.text('登录'));
    await tester.pumpAndSettle();

    expect(find.textContaining('请填写 Music Free 账号和密码'), findsOneWidget);
    expect(requests, isEmpty);
  });

  testWidgets('a FNID session reopens the login page on the FNID tab',
      (tester) async {
    final model = _FnTabModel(
      client: MusicFreeClient(
        httpClient: MockClient((_) async => http.Response('{}', 200)),
      ),
      player: _SilentPlayer(),
    );
    addTearDown(model.dispose);

    await tester.pumpWidget(_host(model));
    await tester.pumpAndSettle();

    expect(find.text('FNID'), findsOneWidget);
    expect(find.text('服务器地址'), findsNothing);
    expect(find.text('连接 NAS'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
