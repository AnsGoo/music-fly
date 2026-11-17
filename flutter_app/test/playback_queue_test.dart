/// Queue behaviour when the server refuses to hand over a track's file.
library;

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';

import 'package:musicfly/audio/player.dart';
import 'package:musicfly/data/models.dart';
import 'package:musicfly/data/musicfree_client.dart';
import 'package:musicfly/state/app_model.dart';

/// Never touches a platform channel: it reports the failure the way the real
/// player does (state + `onFailed`) and returns false.
class _FakePlayer extends MfPlayer {
  _FakePlayer({this.healthy = false});

  /// When true every track loads fine.
  bool healthy;
  final List<String> attempted = [];

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
  }) async {
    attempted.add(title);
    state.value = PlaybackState(
      trackId: trackId,
      title: title,
      subtitle: subtitle,
    );
    if (healthy) return true;
    onFailed?.call(trackId, '文件在服务端找不到了');
    return false;
  }
}

/// Deterministic shuffle RNG: `value % max` is always returned, so a test can
/// assert the exact row a random skip lands on.
class _FixedRandom implements Random {
  _FixedRandom(this.value);
  final int value;
  @override
  int nextInt(int max) => value % max;
  @override
  double nextDouble() => 0.5;
  @override
  bool nextBool() => true;
}

void main() {
  List<Track> queue(int count) => [
    for (var i = 0; i < count; i++)
      Track(id: 'id$i', title: '曲目${i + 1}'),
  ];

  AppModel build(_FakePlayer player, {Random? random}) {
    final client = MusicFreeClient();
    client.restore(
      MusicFreeSession(
        baseUrl: Uri.parse('http://127.0.0.1:14533'),
        token: 'token',
        username: 'admin',
        clientSalt: 'salt',
      ),
    );
    return AppModel(client: client, player: player, random: random);
  }

  test('steps over a broken track and keeps playing', () async {
    final player = _FakePlayer();
    final model = build(player);
    final tracks = queue(3);

    await model.playFrom(tracks, 0);
    await Future<void>.delayed(Duration.zero);

    // Every track fails, so the queue walks to the end and stops there.
    expect(model.queueIndex, 2);
    expect(player.attempted, ['曲目1', '曲目2', '曲目3']);
    expect(model.error, contains('文件在服务端找不到了'));
    model.dispose();
  });

  test('gives up once the whole queue looks broken', () async {
    final player = _FakePlayer();
    final model = build(player);
    final tracks = queue(20);

    await model.playFrom(tracks, 0);
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }

    expect(model.queueIndex, lessThanOrEqualTo(6));
    expect(model.error, contains('连续'));
    expect(player.attempted.length, lessThanOrEqualTo(8));
    model.dispose();
  });

  test('does not skip when the file loads', () async {
    final player = _FakePlayer(healthy: true);
    final model = build(player);
    final tracks = queue(3);

    await model.playFrom(tracks, 0);
    await Future<void>.delayed(Duration.zero);

    expect(model.queueIndex, 0);
    expect(player.attempted, ['曲目1']);
    expect(model.error, isNull);
    model.dispose();
  });

  // The HarmonyOS lock-screen panel forwards AVSession commands to these
  // methods. next()/previous() deliberately stop at the queue edge; the
  // system panel must still respond (wrap around) instead of silently doing
  // nothing — that was reported as "lock-screen next does not work".
  test('ohos system next wraps at the end of the queue', () async {
    final player = _FakePlayer(healthy: true);
    final model = build(player);

    await model.playFrom(queue(3), 2);
    await model.systemSkip(1);

    expect(model.queueIndex, 0);
    expect(player.attempted, ['曲目3', '曲目1']);
    model.dispose();
  });

  test('ohos system previous wraps to the last track', () async {
    final player = _FakePlayer(healthy: true);
    final model = build(player);

    await model.playFrom(queue(3), 0);
    await model.systemSkip(-1);

    expect(model.queueIndex, 2);
    expect(player.attempted, ['曲目1', '曲目3']);
    model.dispose();
  });

  test('ohos system skip coalesces rapid lock-screen taps', () async {
    final player = _FakePlayer(healthy: true);
    final model = build(player);

    await model.playFrom(queue(3), 0);
    final taps = [for (var i = 0; i < 4; i++) model.systemSkip(1)];
    await Future.wait(taps);

    // Net four steps around a three-track queue lands on index 1, and the
    // burst must not spawn four concurrent setUrl loads.
    expect(model.queueIndex, 1);
    expect(player.attempted.length, lessThanOrEqualTo(3));
    model.dispose();
  });

  // A headset/lock-screen "next" used to walk `index + 1` no matter what the
  // play mode was, so shuffle still played the next row in the list. It must
  // use the same shuffle picker as the in-app next button.
  test('ohos system next picks a random row in shuffle mode', () async {
    final player = _FakePlayer(healthy: true);
    // From row 0 the sequential target would be 1; the fixed RNG forces row 3.
    final model = build(player, random: _FixedRandom(3));

    await model.playFrom(queue(5), 0);
    model.setPlayMode(PlayMode.shuffle);
    await model.systemSkip(1);

    expect(model.queueIndex, 3);
    expect(player.attempted, ['曲目1', '曲目4']);
    model.dispose();
  });

  test('ohos system previous picks a random row in shuffle mode', () async {
    final player = _FakePlayer(healthy: true);
    // From row 4 the sequential target would be 3; the fixed RNG forces row 2.
    final model = build(player, random: _FixedRandom(2));

    await model.playFrom(queue(5), 4);
    model.setPlayMode(PlayMode.shuffle);
    await model.systemSkip(-1);

    expect(model.queueIndex, 2);
    expect(player.attempted, ['曲目5', '曲目3']);
    model.dispose();
  });
}
