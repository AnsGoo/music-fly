/// FNID sign-ins must always use the Music Free account the user typed.
///
/// Regression: step 1 used to fire the gateway's passwordless login as soon
/// as the FNID probe succeeded, dropping the user straight into a bound
/// default account; step 2 also ignored the typed credentials on gateway
/// links. Both paths now let the user choose (and change) the account.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:musicfly/audio/player.dart';
import 'package:musicfly/data/fn_connect.dart';
import 'package:musicfly/data/models.dart';
import 'package:musicfly/data/musicfree_client.dart';
import 'package:musicfly/state/app_model.dart';

final _gateway = Uri.parse('https://nas.example.com/app/musicfree/');
final _lan = Uri.parse('http://192.168.1.10:14533/');

const _sessionReply = {
  'token': 'jwt-for-alice',
  'username': 'alice',
  'subsonicToken': 'stream-token',
};

class _SilentPlayer extends MfPlayer {}

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    fnGatewayToken = 'fnos-tok';
    fnRelayEntryToken = null;
  });
  tearDown(() {
    fnGatewayToken = null;
    fnRelayEntryToken = null;
  });

  group('client.loginFnAddress', () {
    test('gateway links sign in as the typed account, never via gateway-login',
        () async {
      final requests = <http.Request>[];
      final client = MusicFreeClient(
        httpClient: MockClient((request) async {
          requests.add(request);
          return _json(_sessionReply);
        }),
      );

      final session = await client.loginFnAddress(
        _gateway.toString(),
        'alice',
        'pw',
      );

      expect(session.username, 'alice');
      expect(session.token, 'jwt-for-alice');
      expect(requests, hasLength(1));
      expect(
        requests.single.url.path,
        '/app/musicfree/rest/api/v1/auth/gateway-bind',
      );
      expect(jsonDecode(requests.single.body), {
        'username': 'alice',
        'password': 'pw',
      });
      expect(requests.single.headers['Authorization'], 'trim fnos-tok');
      expect(requests.single.headers['X-ND-Authorization'], isNull);
    });

    test('direct and relay links use the ordinary password login', () async {
      for (final address in <String>[
        _lan.toString(),
        'https://musicfree.myid.fnos.net/',
      ]) {
        final requests = <http.Request>[];
        final client = MusicFreeClient(
          httpClient: MockClient((request) async {
            requests.add(request);
            return _json(_sessionReply);
          }),
        );

        final session = await client.loginFnAddress(address, 'alice', 'pw');

        expect(session.username, 'alice');
        expect(requests, hasLength(1));
        expect(requests.single.url.path, endsWith('/rest/api/v1/auth/login'));
        expect(jsonDecode(requests.single.body), {
          'username': 'alice',
          'password': 'pw',
        });
      }
    });

    test('missing credentials are rejected before any request is sent',
        () async {
      var calls = 0;
      final client = MusicFreeClient(
        httpClient: MockClient((request) async {
          calls++;
          return _json(_sessionReply);
        }),
      );

      for (final credentials in <(String, String)>[
        ('', 'pw'),
        ('alice', ''),
        ('   ', 'pw'),
      ]) {
        await expectLater(
          client.loginFnAddress(
            _gateway.toString(),
            credentials.$1,
            credentials.$2,
          ),
          throwsA(
            isA<MusicFreeException>().having(
              (error) => error.message,
              'message',
              contains('账号和密码'),
            ),
          ),
        );
      }
      expect(calls, 0);
    });

    test('an older backend without gateway-bind falls back to password login',
        () async {
      final paths = <String>[];
      final client = MusicFreeClient(
        httpClient: MockClient((request) async {
          paths.add(request.url.path);
          if (request.url.path.endsWith('gateway-bind')) {
            return http.Response('404 page not found', 404);
          }
          return _json(_sessionReply);
        }),
      );

      final session = await client.loginFnAddress(
        _gateway.toString(),
        'alice',
        'pw',
      );

      expect(session.username, 'alice');
      expect(paths, [
        '/app/musicfree/rest/api/v1/auth/gateway-bind',
        '/app/musicfree/rest/api/v1/auth/login',
      ]);
    });

    test('a disabled gateway (404 JSON) still signs in by password',
        () async {
      final paths = <String>[];
      final client = MusicFreeClient(
        httpClient: MockClient((request) async {
          paths.add(request.url.path);
          if (request.url.path.endsWith('gateway-bind')) {
            return _json({'error': '网关登录未启用'}, 404);
          }
          return _json(_sessionReply);
        }),
      );

      final session = await client.loginFnAddress(
        _gateway.toString(),
        'alice',
        'pw',
      );

      expect(session.username, 'alice');
      expect(paths, [
        '/app/musicfree/rest/api/v1/auth/gateway-bind',
        '/app/musicfree/rest/api/v1/auth/login',
      ]);
    });

    test('wrong credentials keep the backend message after the fallback',
        () async {
      final paths = <String>[];
      final client = MusicFreeClient(
        httpClient: MockClient((request) async {
          paths.add(request.url.path);
          return _json({'error': '用户名或密码错误'}, 401);
        }),
      );

      await expectLater(
        client.loginFnAddress(_gateway.toString(), 'alice', 'bad'),
        throwsA(
          isA<AuthException>().having(
            (error) => error.message,
            'message',
            '用户名或密码错误',
          ),
        ),
      );
      expect(paths.last, endsWith('/rest/api/v1/auth/login'));
    });
  });

  // AppModel owns a periodic address probe, so these stay plain test() —
  // mixing them into testWidgets starves the FakeAsync clock.
  group('AppModel.loginFnPrepared', () {
    (AppModel, List<http.Request>) build() {
      final requests = <http.Request>[];
      final client = MusicFreeClient(
        httpClient: MockClient((request) async {
          requests.add(request);
          if (request.url.path.endsWith('gateway-bind')) {
            return _json(_sessionReply);
          }
          if (request.url.path.endsWith('ping.view')) {
            return _json({
              'subsonic-response': {'status': 'ok', 'version': '1.16.1'},
            });
          }
          return _json({});
        }),
      );
      final model = AppModel(client: client, player: _SilentPlayer());
      model.setFnProbeForTest(
        FnProbeResult(
          best: _gateway,
          reachable: [_gateway],
          candidates: [_gateway],
        ),
        addresses: [_gateway],
      );
      return (model, requests);
    }

    test('refuses to sign in without the Music Free account', () async {
      final (model, requests) = build();
      addTearDown(model.dispose);

      await model.loginFnPrepared();

      expect(model.error, contains('请填写 Music Free 账号和密码'));
      expect(model.session, isNull);
      expect(requests, isEmpty);
    });

    test('signs in as the typed account, never via gateway-login', () async {
      final (model, requests) = build();
      addTearDown(model.dispose);

      await model.loginFnPrepared(username: 'alice', password: 'pw');

      expect(model.error, isNull);
      expect(model.session?.username, 'alice');
      expect(model.session?.fnConnect, isTrue);
      // A later logout reopens the login page on the FNID tab, which is
      // where the account can be changed.
      expect(model.preferFnConnectTab, isTrue);
      expect(
        requests.where((r) => r.url.path.contains('gateway-bind')),
        hasLength(1),
      );
      expect(
        requests.where((r) => r.url.path.contains('gateway-login')),
        isEmpty,
      );
      expect(
        jsonDecode(
          requests
              .firstWhere((r) => r.url.path.contains('gateway-bind'))
              .body,
        ),
        {'username': 'alice', 'password': 'pw'},
      );
    });

    test('a restored FNID session keeps the FNID tab preference', () async {
      SharedPreferences.setMockInitialValues({
        'musicfly.session.v1': jsonEncode(
          MusicFreeSession(
            baseUrl: _gateway,
            token: 'jwt',
            username: 'alice',
            clientSalt: 'salt',
            fnConnect: true,
          ).toJson(),
        ),
      });
      final client = MusicFreeClient(
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('ping.view')) {
            return _json({
              'subsonic-response': {'status': 'ok', 'version': '1.16.1'},
            });
          }
          return _json({});
        }),
      );
      final model = AppModel(client: client, player: _SilentPlayer());
      addTearDown(model.dispose);

      await model.restoreSession();

      expect(model.session?.fnConnect, isTrue);
      expect(model.preferFnConnectTab, isTrue);
    });
  });
}
