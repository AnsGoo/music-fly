/// DLNA audio metadata sent to a TV renderer.
///
/// A recording HTTP client stands in for the TV's AVTransport control endpoint
/// so the exact SetAVTransportURI SOAP body can be inspected without any real
/// network traffic. dart_cast's own builder labels everything a `videoItem`;
/// this file guards the audio-only metadata that keeps TV renderers out of
/// their video pipeline.
library;

import 'dart:io';

import 'package:dart_cast/dart_cast.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:musicfly/state/cast_audio_session.dart';

class _Renderer {
  _Renderer(this.client, this.bodies);

  final DlnaHttpClient client;
  final List<String> bodies;

  factory _Renderer.record() {
    final bodies = <String>[];
    final client = DlnaHttpClient(
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
    return _Renderer(client, bodies);
  }
}

AudioDlnaSession _sessionFor(_Renderer renderer) => AudioDlnaSession(
  device: CastDevice(
    id: 'uuid:tv',
    name: '客厅电视',
    protocol: CastProtocol.dlna,
    address: InternetAddress('192.168.1.50'),
    port: 49152,
  ),
  description: DlnaDeviceDescription(
    friendlyName: '客厅电视',
    udn: 'uuid:tv',
    avTransportControlUrl: 'http://192.168.1.50:49152/AVTransport/control',
    locationUrl: 'http://192.168.1.50:49152/description.xml',
  ),
  httpClient: renderer.client,
);

const _transcodeUrl =
    'http://192.168.1.10:14533/rest/stream'
    '?id=song-1&format=mp3&estimateContentLength=true&dlna=true'
    '&u=admin&t=abc123&s=salt';
const _rawMp3Url =
    'http://192.168.1.10:14533/rest/stream?id=song-2&u=admin&t=abc123&s=salt';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a transcoded stream is announced as an audio track', () async {
    final renderer = _Renderer.record();
    final session = _sessionFor(renderer);
    addTearDown(session.dispose);
    await session.connect();

    await session.loadMedia(
      CastMedia(
        url: _transcodeUrl,
        type: CastMediaType.mp4,
        title: 'A & B <live>',
        imageUrl:
            'http://192.168.1.10:14533/rest/getCoverArt?id=cover-1&size=320',
        duration: const Duration(minutes: 3, seconds: 25),
      ),
    );

    final body = renderer.bodies.firstWhere(
      (body) => body.contains('SetAVTransportURI'),
    );
    // The whole point: never route music through the TV's video pipeline.
    expect(body, contains('object.item.audioItem.musicTrack'));
    expect(body, isNot(contains('videoItem')));
    expect(body, contains('http-get:*:audio/mpeg:DLNA.ORG_PN=MP3'));
    // A generated stream is conversion-flagged, like the backend's DIDL.
    expect(body, contains('DLNA.ORG_OP=00;DLNA.ORG_CI=1'));
    expect(body, contains('duration=&quot;00:03:25&quot;'));
    expect(body, contains('&lt;upnp:albumArtURI&gt;'));
    expect(body, contains('getCoverArt'));

    // CurrentURI is SOAP text (one escape), the DIDL inside
    // CurrentURIMetaData is XML-as-text (two escapes).
    expect(
      body,
      contains(
        '<CurrentURI>http://192.168.1.10:14533/rest/stream'
        '?id=song-1&amp;format=mp3&amp;estimateContentLength=true'
        '&amp;dlna=true&amp;u=admin&amp;t=abc123&amp;s=salt</CurrentURI>',
      ),
    );
    expect(body, contains('&lt;DIDL-Lite'));
    expect(body, contains('A &amp;amp; B &amp;lt;live&amp;gt;'));
  });

  test('a raw MP3 advertises byte seek and no conversion', () async {
    final renderer = _Renderer.record();
    final session = _sessionFor(renderer);
    addTearDown(session.dispose);
    await session.connect();

    await session.loadMedia(
      CastMedia(
        url: _rawMp3Url,
        type: CastMediaType.mp4,
        title: '曲目 2',
        duration: const Duration(minutes: 4),
      ),
    );

    final body = renderer.bodies.firstWhere(
      (body) => body.contains('SetAVTransportURI'),
    );
    expect(body, contains('object.item.audioItem.musicTrack'));
    expect(body, contains('DLNA.ORG_OP=01;DLNA.ORG_CI=0'));
    expect(body, contains('duration=&quot;00:04:00&quot;'));
    expect(body, isNot(contains('albumArtURI')));
    expect(body, isNot(contains('&lt;dc:creator&gt;')));
    expect(body, isNot(contains('&lt;upnp:album&gt;')));
    expect(body, isNot(contains('&lt;dc:description&gt;')));
  });

  test('artist, album and lyrics are carried in the audio DIDL', () async {
    final renderer = _Renderer.record();
    final session = _sessionFor(renderer);
    addTearDown(session.dispose);
    await session.connect();

    await session.loadAudio(
      const CastMedia(
        url: _transcodeUrl,
        type: CastMediaType.mp4,
        title: '夜曲',
        imageUrl: 'http://192.168.1.10:14533/rest/getCoverArt?id=c1',
        duration: Duration(minutes: 3),
      ),
      metadata: buildCastAudioMetadata(
        artist: '周杰伦 & 方文山',
        album: '十一月的萧邦',
        lyricsText: '一群嗜血的蚂蚁被腐肉所吸引\n我面无表情 看孤独的风景',
        lyricsLrc: '[00:12.00]一群嗜血的蚂蚁被腐肉所吸引',
      ),
    );

    final body = renderer.bodies.firstWhere(
      (body) => body.contains('SetAVTransportURI'),
    );
    expect(
      body,
      contains(
        '&lt;dc:creator&gt;周杰伦 &amp;amp; 方文山&lt;/dc:creator&gt;',
      ),
    );
    expect(body, contains('&lt;upnp:artist role=&quot;Performer&quot;&gt;'));
    expect(
      body,
      contains('&lt;upnp:album&gt;十一月的萧邦&lt;/upnp:album&gt;'),
    );
    expect(body, contains('&lt;dc:description&gt;一群嗜血的蚂蚁'));
    expect(body, contains('&lt;dc:longDescription&gt;[00:12.00]'));
    expect(body, contains('JPEG_TN'));
    expect(body, contains('xmlns:dlna='));
    // The extra metadata must not turn the item back into a videoItem.
    expect(body, contains('object.item.audioItem.musicTrack'));
    expect(body, isNot(contains('videoItem')));
  });

  test('metadata text is scrubbed before it reaches XML', () {
    final meta = buildCastAudioMetadata(
      artist: '  A\u0000B  ',
      album: '   ',
      lyricsText: '词' * 3000,
      lyricsLrc: '[00:01.00]line\u0001',
    );
    expect(meta.artist, 'AB');
    expect(meta.album, isNull);
    expect(meta.description, hasLength(2000));
    expect(meta.longDescription, '[00:01.00]line');
    expect(buildCastAudioMetadata().artist, isNull);
  });
}
