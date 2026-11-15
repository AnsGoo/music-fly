/// DLNA casting tuned for music.
///
/// [DlnaSession.loadMedia] in dart_cast is built around video: it funnels
/// every remote URL through its local HTTP proxy and labels the DIDL-Lite
/// metadata `videoItem` / `video/mp4`. Many audio renderers sniff the actual
/// stream and cope, but strict ones refuse the mismatched protocolInfo. This
/// subclass pushes the server's direct stream URL with proper audio metadata
/// instead, and polls position/transport state itself so the shared
/// [CastSession] streams keep working.
library;

import 'dart:async';

import 'package:dart_cast/dart_cast.dart';

/// A [DlnaSession] that casts audio via the source URL directly.
///
/// The server's stream endpoint embeds its own auth token, so the renderer
/// only needs LAN access to the media server — no local proxy hop — and the
/// direct body supports byte ranges, which DLNA renderers use to seek.
///
/// It also builds its own DIDL-Lite metadata. [DlnaSoapBuilder] is a video
/// helper: it hard-codes `<upnp:class>object.item.videoItem</upnp:class>`.
/// Passing an audio `protocolInfo` on top of that still makes TV renderers
/// hand the URI to the *video* pipeline, which is what surfaces messages like
/// "播放器异常" and then falls back to another play route. Audio renderers
/// need `object.item.audioItem.musicTrack` and a protocolInfo that matches
/// the bytes actually served.
/// Extra DIDL-Lite fields that [CastMedia] has no room for.
///
/// UPnP AV defines no "lyrics" property at all. `dc:description` and
/// `dc:longDescription` are the two standard free-text properties of an
/// `audioItem`, so plain/timed lyrics are put there for renderers that surface
/// them. The in-app lyrics pane remains the reliable, synced view.
class CastAudioMetadata {
  const CastAudioMetadata({
    this.artist,
    this.album,
    this.description,
    this.longDescription,
  });

  final String? artist;
  final String? album;
  final String? description;
  final String? longDescription;
}

/// Scrubs metadata text before it goes into XML. XML 1.0 forbids most control
/// characters, and one stray byte can make a renderer reject the whole DIDL.
/// Long lyrics are truncated so the double-escaped SOAP body stays small.
String? _cleanMetadata(String? value, {required int maxLength}) {
  if (value == null) return null;
  final cleaned = StringBuffer();
  for (final rune in value.runes) {
    final valid =
        rune == 0x9 ||
        rune == 0xA ||
        rune == 0xD ||
        (rune >= 0x20 && rune <= 0xD7FF) ||
        (rune >= 0xE000 && rune <= 0xFFFD) ||
        (rune >= 0x10000 && rune <= 0x10FFFF);
    if (valid) cleaned.write(String.fromCharCode(rune));
  }
  final text = cleaned.toString().trim();
  if (text.isEmpty) return null;
  return text.length > maxLength ? text.substring(0, maxLength) : text;
}

/// Builds the renderer metadata for one track. Kept pure so the queue/state
/// layer can be tested without standing up a SOAP endpoint.
CastAudioMetadata buildCastAudioMetadata({
  String? artist,
  String? album,
  String? lyricsText,
  String? lyricsLrc,
}) => CastAudioMetadata(
  artist: _cleanMetadata(artist, maxLength: 200),
  album: _cleanMetadata(album, maxLength: 200),
  description: _cleanMetadata(lyricsText, maxLength: 2000),
  longDescription: _cleanMetadata(lyricsLrc, maxLength: 2000),
);

/// Attaches [metadata] on DLNA sessions that build their own DIDL, and falls
/// back to plain [CastSession.loadMedia] on any future session type.
Future<void> loadCastAudio(
  CastSession session,
  CastMedia media, {
  CastAudioMetadata metadata = const CastAudioMetadata(),
}) {
  final dlna = session;
  if (dlna is AudioDlnaSession) {
    return dlna.loadAudio(media, metadata: metadata);
  }
  return session.loadMedia(media);
}

class AudioDlnaSession extends DlnaSession {
  AudioDlnaSession({
    required super.device,
    required super.description,
    DlnaHttpClient? httpClient,
  }) : _http = httpClient ?? DlnaHttpClient();

  /// Builds a session from a [CastDevice] produced by
  /// [DlnaDiscoveryProvider] — the parent's factory is not inherited.
  factory AudioDlnaSession.fromDevice(CastDevice device) {
    final parent = DlnaSession.fromDevice(device);
    return AudioDlnaSession(device: device, description: parent.description);
  }

  /// Standard DLNA flags (STREAMING | BACKGROUND | CONNECTION_STALL | V1.5),
  /// the same set VLC, MiniDLNA and the Music Free backend advertise.
  static const String _dlnaFlags = '01700000000000000000000000000000';

  /// An unmodified MP3 file: byte seek works and the content is not converted.
  static const String _directProtocolInfo =
      'http-get:*:audio/mpeg:DLNA.ORG_PN=MP3;'
      'DLNA.ORG_OP=01;DLNA.ORG_CI=0;'
      'DLNA.ORG_FLAGS=$_dlnaFlags';

  /// The backend's DLNA transcode route (format=mp3&dlna=true) serves a
  /// generated stream. The backend deliberately advertises CI=1/OP=00 so
  /// strict renderers do not try byte-range seeking against a converter.
  static const String _transcodedProtocolInfo =
      'http-get:*:audio/mpeg:DLNA.ORG_PN=MP3;'
      'DLNA.ORG_OP=00;DLNA.ORG_CI=1;'
      'DLNA.ORG_FLAGS=$_dlnaFlags';

  final DlnaHttpClient _http;
  Timer? _pollTimer;
  bool _pollBusy = false;

  String? get _controlUrl => description.avTransportControlUrl;

  @override
  Future<void> loadMedia(CastMedia media) => _load(media, const CastAudioMetadata());

  /// Same as [loadMedia], but carries the extra audio metadata that
  /// [CastMedia] cannot express (artist, album, lyrics).
  Future<void> loadAudio(
    CastMedia media, {
    CastAudioMetadata metadata = const CastAudioMetadata(),
  }) => _load(media, metadata);

  Future<void> _load(CastMedia media, CastAudioMetadata metadata) async {
    final controlUrl = _controlUrl;
    if (controlUrl == null) {
      throw StateError(
        'No AVTransport control URL for "${device.name}" — the device must '
        'come from DlnaDiscoveryProvider.',
      );
    }
    stateMachine.transitionTo(SessionState.loading);
    final duration =
        media.duration != null && media.duration! > Duration.zero
        ? media.duration
        : null;
    await _http.sendAction(
      controlUrl,
      DlnaServiceType.avTransport,
      'SetAVTransportURI',
      _buildSetAvTransportUri(
        url: media.url,
        protocolInfo: _protocolInfoFor(media.url),
        title: media.title,
        imageUrl: media.imageUrl,
        duration: duration == null
            ? null
            : NetworkUtils.formatDuration(duration),
        artist: metadata.artist,
        album: metadata.album,
        description: metadata.description,
        longDescription: metadata.longDescription,
      ),
    );
    await _http.sendAction(
      controlUrl,
      DlnaServiceType.avTransport,
      'Play',
      DlnaSoapBuilder.buildPlay(),
    );
    updatePosition(Duration.zero);
    if (duration != null) updateDuration(duration);
    stateMachine.transitionTo(SessionState.playing);
    _startPolling();
  }

  /// A `dlna=true` stream URL is the backend's pre-transcoded MP3 route.
  static String _protocolInfoFor(String url) =>
      Uri.tryParse(url)?.queryParameters['dlna'] == 'true'
      ? _transcodedProtocolInfo
      : _directProtocolInfo;

  /// Builds an audio-only SetAVTransportURI action.
  ///
  /// `CurrentURIMetaData` is an XML document embedded as *text* inside the
  /// SOAP body, so the DIDL is escaped once on the way in; values inside it
  /// (URL / title / artwork) are escaped once more when the DIDL itself is
  /// built. That double escaping is intentional and is what the renderer
  /// unwinds when it parses the DIDL.
  static String _buildSetAvTransportUri({
    required String url,
    required String protocolInfo,
    String? title,
    String? imageUrl,
    String? duration,
    String? artist,
    String? album,
    String? description,
    String? longDescription,
  }) {
    final didl = StringBuffer()
      ..write(
        '<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/"'
        ' xmlns:dc="http://purl.org/dc/elements/1.1/"'
        ' xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/"'
        ' xmlns:dlna="urn:schemas-dlna-org:metadata-1-0/">',
      )
      ..write('<item id="0" parentID="-1" restricted="1">')
      ..write('<dc:title>${_escapeXml(title ?? 'Music')}</dc:title>')
      ..write('<upnp:class>object.item.audioItem.musicTrack</upnp:class>');
    // Both spellings matter: some renderers read dc:creator (Dublin Core),
    // others only the UPnP performer property. Without them the TV shows
    // "未知歌手 / 未知专辑" even though the library has the tags.
    if (artist != null && artist.isNotEmpty) {
      didl
        ..write('<dc:creator>${_escapeXml(artist)}</dc:creator>')
        ..write(
          '<upnp:artist role="Performer">${_escapeXml(artist)}</upnp:artist>',
        );
    }
    if (album != null && album.isNotEmpty) {
      didl.write('<upnp:album>${_escapeXml(album)}</upnp:album>');
    }
    if (imageUrl != null && imageUrl.isNotEmpty) {
      final art = _escapeXml(imageUrl);
      didl
        ..write('<upnp:albumArtURI>$art</upnp:albumArtURI>')
        ..write(
          '<upnp:albumArtURI dlna:profileID="JPEG_TN">$art</upnp:albumArtURI>',
        );
    }
    // UPnP AV has no lyrics property. These two standard free-text properties
    // are the only portable way to hand lyrics to a renderer; a plain-text
    // copy goes in description and the timed LRC in longDescription.
    if (description != null && description.isNotEmpty) {
      didl.write('<dc:description>${_escapeXml(description)}</dc:description>');
    }
    if (longDescription != null && longDescription.isNotEmpty) {
      didl.write(
        '<dc:longDescription>${_escapeXml(longDescription)}</dc:longDescription>',
      );
    }
    final durationAttr = duration == null ? '' : ' duration="$duration"';
    didl
      ..write(
        '<res protocolInfo="$protocolInfo"$durationAttr>'
        '${_escapeXml(url)}</res>',
      )
      ..write('</item></DIDL-Lite>');

    return '<?xml version="1.0" encoding="utf-8"?>'
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"'
        ' s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
        '<s:Body>'
        '<u:SetAVTransportURI xmlns:u="${DlnaServiceType.avTransport}">'
        '<InstanceID>0</InstanceID>'
        '<CurrentURI>${_escapeXml(url)}</CurrentURI>'
        '<CurrentURIMetaData>${_escapeXml(didl.toString())}</CurrentURIMetaData>'
        '</u:SetAVTransportURI>'
        '</s:Body>'
        '</s:Envelope>';
  }

  static String _escapeXml(String input) {
    final out = StringBuffer();
    for (final rune in input.runes) {
      // XML 1.0 forbids most C0 control characters and unpaired surrogates;
      // lyrics and tags from arbitrary files can contain them.
      final valid =
          rune == 0x9 ||
          rune == 0xA ||
          rune == 0xD ||
          (rune >= 0x20 && rune <= 0xD7FF) ||
          (rune >= 0xE000 && rune <= 0xFFFD) ||
          (rune >= 0x10000 && rune <= 0x10FFFF);
      if (!valid) continue;
      final char = String.fromCharCode(rune);
      out.write(
        switch (char) {
          '&' => '&amp;',
          '<' => '&lt;',
          '>' => '&gt;',
          '"' => '&quot;',
          "'" => '&apos;',
          _ => char,
        },
      );
    }
    return out.toString();
  }

  @override
  Future<void> disconnect() async {
    _pollTimer?.cancel();
    _pollTimer = null;
    final controlUrl = _controlUrl;
    if (controlUrl != null) {
      try {
        await _http.sendAction(
          controlUrl,
          DlnaServiceType.avTransport,
          'Stop',
          DlnaSoapBuilder.buildStop(),
        );
      } catch (_) {
        // The renderer may already be gone; dropping the session locally is
        // what matters.
      }
    }
    stateMachine.transitionTo(SessionState.disconnected);
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _http.close();
    super.dispose();
  }

  // ---- Renderer polling ---------------------------------------------------

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 1), (_) => _poll());
  }

  Future<void> _poll() async {
    if (_pollBusy) return;
    if (stateMachine.state == SessionState.disconnected) return;
    final controlUrl = _controlUrl;
    if (controlUrl == null) return;
    _pollBusy = true;
    try {
      final position = await _http.sendAction(
        controlUrl,
        DlnaServiceType.avTransport,
        'GetPositionInfo',
        DlnaSoapBuilder.buildGetPositionInfo(),
      );
      final info = DlnaSoapParser.parsePositionInfo(position);
      updatePosition(info.position);
      if (info.duration > Duration.zero) updateDuration(info.duration);

      final transport = await _http.sendAction(
        controlUrl,
        DlnaServiceType.avTransport,
        'GetTransportInfo',
        DlnaSoapBuilder.buildGetTransportInfo(),
      );
      _handleTransport(DlnaSoapParser.parseTransportInfo(transport));

      // RenderingControl is optional on some renderers; a missing volume is
      // not worth failing the whole poll over.
      final renderingUrl = description.renderingControlUrl;
      if (renderingUrl != null) {
        try {
          final volume = await _http.sendAction(
            renderingUrl,
            DlnaServiceType.renderingControl,
            'GetVolume',
            DlnaSoapBuilder.buildGetVolume(),
          );
          updateVolume(DlnaSoapParser.parseVolume(volume) / 100.0);
        } catch (_) {}
      }
    } catch (_) {
      // A single dropped poll is normal on Wi-Fi renderers.
    } finally {
      _pollBusy = false;
    }
  }

  void _handleTransport(String transportState) {
    switch (transportState) {
      case 'PLAYING':
      case 'TRANSITIONING':
        if (stateMachine.state != SessionState.playing &&
            stateMachine.canTransitionTo(SessionState.playing)) {
          stateMachine.transitionTo(SessionState.playing);
        }
      case 'PAUSED_PLAYBACK':
        if (stateMachine.state != SessionState.paused &&
            stateMachine.canTransitionTo(SessionState.paused)) {
          stateMachine.transitionTo(SessionState.paused);
        }
      case 'STOPPED':
        if (stateMachine.state != SessionState.idle &&
            stateMachine.canTransitionTo(SessionState.idle)) {
          stateMachine.transitionTo(SessionState.idle);
          _pollTimer?.cancel();
          _pollTimer = null;
        }
      case 'NO_MEDIA_PRESENT':
        break;
    }
  }
}
