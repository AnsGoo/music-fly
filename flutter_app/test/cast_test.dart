/// Casting: control forwarding, queue advance and session teardown.
library;

import 'dart:io';

import 'package:dart_cast/dart_cast.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:musicfly/audio/player.dart';
import 'package:musicfly/data/models.dart';
import 'package:musicfly/data/musicfree_client.dart';
import 'package:musicfly/state/app_model.dart';
import 'package:musicfly/state/cast_audio_session.dart';

/// Records every control call without touching any network.
class _FakeSession extends CastSession {
  _FakeSession(super.device);

  final List<CastMedia> loaded = [];
  final List<Duration> seeked = [];
  final List<double> volumes = [];
  int plays = 0;
  int pauses = 0;

  @override
  Future<void> loadMedia(CastMedia media) async {
    loaded.add(media);
    stateMachine.transitionTo(SessionState.loading);
    stateMachine.transitionTo(SessionState.playing);
  }

  @override
  Future<void> play() async => plays++;
  @override
  Future<void> pause() async => pauses++;
  @override
  Future<void> stop() async {}
  @override
  Future<void> seek(Duration position) async => seeked.add(position);
  @override
  Future<void> setVolume(double volume) async => volumes.add(volume);
  @override
  Future<void> setSubtitle(CastSubtitle? subtitle) async {}
  @override
  Future<void> disconnect() async {
    stateMachine.transitionTo(SessionState.disconnected);
  }
}

/// Same shape as the queue tests' fake: never touches a platform channel.
class _FakePlayer extends MfPlayer {
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
    return true;
  }
}

void main() {
  List<Track> queue(int count, {String? format}) => [
    for (var i = 0; i < count; i++)
      Track(
        id: 'id$i',
        title: '曲目${i + 1}',
        durationSeconds: 180,
        format: format,
        coverId: 'cover$i',
      ),
  ];

  Future<(AppModel, _FakeSession)> build({
    List<Track>? tracks,
    MusicFreeSession? restoredSession,
  }) async {
    final client = MusicFreeClient();
    client.restore(
      restoredSession ??
          MusicFreeSession(
            baseUrl: Uri.parse('http://127.0.0.1:14533'),
            token: 'token',
            username: 'admin',
            subsonicToken: 'subtoken',
            clientSalt: 'salt',
          ),
    );
    final player = _FakePlayer();
    late final _FakeSession session;
    final model = AppModel(
      client: client,
      player: player,
      castSessionFactory: (device) => session = _FakeSession(device),
    );
    final device = CastDevice(
      id: 'uuid:test',
      name: '客厅音箱',
      protocol: CastProtocol.dlna,
      address: InternetAddress('192.168.1.50'),
      port: 49152,
    );
    await model.playFrom(tracks ?? queue(3), 0);
    await model.connectCast(device);
    return (model, session);
  }

  test('connecting pushes the current track to the renderer', () async {
    final (model, session) = await build();

    expect(model.casting, isTrue);
    expect(model.castDevice?.name, '客厅音箱');
    expect(session.loaded, hasLength(1));
    // The renderer gets the server's own stream URL with token auth, so it
    // needs nothing from this machine.
    final castUrl = session.loaded.single.url;
    expect(castUrl, contains('/rest/stream'));
    expect(castUrl, contains('id=id0'));
    expect(castUrl, contains('t='));
    expect(castUrl, contains('s=salt'));
    expect(session.loaded.single.title, '曲目1');
    // The local player must not have been reloaded by connecting.
    expect(model.player.state.value.playing, isFalse);
    model.dispose();
  });

  test('a non-MP3 track is cast through the DLNA transcode direct link', () async {
    final (model, session) = await build(
      tracks: queue(3, format: 'flac'),
    );

    final castUrl = session.loaded.single.url;
    expect(castUrl, contains('/rest/stream'));
    expect(castUrl, contains('format=mp3'));
    expect(castUrl, contains('dlna=true'));
    expect(castUrl, contains('estimateContentLength=true'));
    expect(castUrl, contains('id=id0'));
    // Auth still travels in the URL: the TV cannot send our headers.
    expect(castUrl, contains('t='));
    expect(castUrl, contains('s=salt'));
    model.dispose();
  });

  test('an MP3 track keeps the raw, untranscoded direct link', () async {
    final (model, session) = await build(tracks: queue(3, format: 'mp3'));

    final castUrl = session.loaded.single.url;
    expect(castUrl, contains('/rest/stream'));
    expect(castUrl, isNot(contains('format=mp3')));
    expect(castUrl, isNot(contains('dlna=')));
    expect(castUrl, isNot(contains('estimateContentLength=')));
    model.dispose();
  });

  test('the renderer gets a LAN link even when the app sits on a gateway', () async {
    final gateway = Uri.parse('https://myid.fnos.net/app/musicfree/');
    final lan = Uri.parse('http://192.168.1.10:14533/');
    final (model, session) = await build(
      restoredSession: MusicFreeSession(
        baseUrl: gateway,
        token: 'token',
        username: 'admin',
        subsonicToken: 'subtoken',
        clientSalt: 'salt',
        addresses: [gateway, lan],
        fnConnect: true,
      ),
    );

    final castUrl = Uri.parse(session.loaded.single.url);
    expect(castUrl.host, '192.168.1.10');
    expect(castUrl.port, 14533);
    expect(castUrl.path, '/rest/stream');
    expect(castUrl.queryParameters['t'], isNotEmpty);
    expect(session.loaded.single.imageUrl, contains('192.168.1.10'));
    model.dispose();
  });

  test('transport controls are forwarded while casting', () async {
    final (model, session) = await build();

    model.togglePlay();
    await Future<void>.delayed(Duration.zero);
    expect(session.pauses, 1);

    session.stateMachine.transitionTo(SessionState.paused);
    model.togglePlay();
    await Future<void>.delayed(Duration.zero);
    expect(session.plays, 1);

    await model.seek(const Duration(seconds: 42));
    expect(session.seeked, [const Duration(seconds: 42)]);

    model.setVolume(0.4);
    expect(session.volumes, [0.4]);
    expect(model.volume, 0.4);
    model.dispose();
  });

  test('next and previous stay on the renderer', () async {
    final (model, session) = await build();

    await model.next();
    expect(session.loaded, hasLength(2));
    expect(session.loaded.last.title, '曲目2');
    expect(model.currentTrack?.id, 'id1');
    // The local player only ever saw the first track (before connecting).
    expect(model.player.state.value.trackId, 'id0');

    await model.previous();
    expect(session.loaded.last.title, '曲目1');
    model.dispose();
  });

  test('a renderer stop near the end advances the queue', () async {
    final (model, session) = await build();

    // The renderer plays to the last seconds and stops itself.
    session.updateDuration(const Duration(minutes: 3));
    session.updatePosition(const Duration(minutes: 3) - const Duration(seconds: 2));
    session.stateMachine.transitionTo(SessionState.idle);
    // The cast path fetches lyrics before pushing the next track, so the
    // queue advance now spans more than one microtask.
    for (var i = 0; i < 50 && session.loaded.length < 2; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    expect(session.loaded, hasLength(2));
    expect(session.loaded.last.title, '曲目2');
    model.dispose();
  });

  test('a renderer stop mid-track does not advance', () async {
    final (model, session) = await build();

    session.updateDuration(const Duration(minutes: 3));
    session.updatePosition(const Duration(seconds: 30));
    session.stateMachine.transitionTo(SessionState.idle);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(session.loaded, hasLength(1));
    expect(model.castState, SessionState.idle);
    model.dispose();
  });

  test('disconnecting hands playback back to the local player', () async {
    final (model, session) = await build();

    await model.next();
    expect(session.loaded.last.title, '曲目2');
    await model.disconnectCast();

    expect(model.casting, isFalse);
    expect(model.castDevice, isNull);
    // The track that was on the renderer now plays locally.
    expect(model.player.state.value.trackId, 'id1');
    expect(model.playback.value.trackId, 'id1');
    model.dispose();
  });

  test('the UI playback snapshot follows the renderer, so lyrics scroll', () async {
    final (model, session) = await build();
    await Future<void>.delayed(const Duration(milliseconds: 5));

    expect(model.playback.value.trackId, 'id0');
    expect(model.playback.value.title, '曲目1');
    expect(model.playback.value.playing, isTrue);
    // The pre-cast lyrics fetch must always settle, even when the endpoint
    // (stubbed to 400 in widget tests) has no lyrics for the track.
    expect(model.lyricsLoading, isFalse);

    session.updateDuration(const Duration(minutes: 3));
    session.updatePosition(const Duration(seconds: 42));
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(model.playback.value.position, const Duration(seconds: 42));
    expect(model.playback.value.duration, const Duration(minutes: 3));

    session.stateMachine.transitionTo(SessionState.paused);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(model.playback.value.playing, isFalse);

    await model.next();
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(model.playback.value.trackId, 'id1');
    expect(model.playback.value.title, '曲目2');
    model.dispose();
  });

  test('a DLNA renderer receives the library artist and album tags', () async {
    final bodies = <String>[];
    final soap = DlnaHttpClient(
      client: MockClient((request) async {
        bodies.add(request.body);
        return http.Response(
          '<?xml version="1.0"?>'
          '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">'
          '<s:Body/></s:Envelope>',
          200,
          headers: {'content-type': 'text/xml'},
        );
      }),
    );
    final client = MusicFreeClient();
    client.restore(
      MusicFreeSession(
        baseUrl: Uri.parse('http://127.0.0.1:14533'),
        token: 'token',
        username: 'admin',
        subsonicToken: 'subtoken',
        clientSalt: 'salt',
      ),
    );
    final model = AppModel(
      client: client,
      player: _FakePlayer(),
      castSessionFactory: (device) => AudioDlnaSession(
        device: device,
        description: DlnaDeviceDescription(
          friendlyName: '客厅电视',
          udn: device.id,
          avTransportControlUrl:
              'http://192.168.1.50:49152/AVTransport/control',
          locationUrl: 'http://192.168.1.50:49152/description.xml',
        ),
        httpClient: soap,
      ),
    );
    final device = CastDevice(
      id: 'uuid:tv',
      name: '客厅电视',
      protocol: CastProtocol.dlna,
      address: InternetAddress('192.168.1.50'),
      port: 49152,
    );
    await model.playFrom(
      [
        Track(
          id: 'song-1',
          title: '夜曲',
          artists: const [Artist(id: 'a1', name: '周杰伦')],
          album: const Album(id: 'al1', name: '十一月的萧邦'),
          durationSeconds: 200,
          format: 'flac',
          coverId: 'c1',
        ),
      ],
      0,
    );
    await model.connectCast(device);

    final body = bodies.firstWhere((b) => b.contains('SetAVTransportURI'));
    expect(body, contains('&lt;dc:creator&gt;周杰伦&lt;/dc:creator&gt;'));
    expect(body, contains('&lt;upnp:artist role=&quot;Performer&quot;&gt;'));
    expect(
      body,
      contains('&lt;upnp:album&gt;十一月的萧邦&lt;/upnp:album&gt;'),
    );
    expect(body, contains('getCoverArt'));
    expect(body, contains('object.item.audioItem.musicTrack'));
    // Disconnect stops the session's polling timer before the test ends.
    await model.disconnectCast();
    model.dispose();
  });
}
