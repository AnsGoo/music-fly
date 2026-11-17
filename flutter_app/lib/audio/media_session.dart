/// 把本地播放接入系统的媒体中心：Android 的通知栏 / 锁屏 / 蓝牙耳机按键；
/// iOS / macOS 的控制中心「正在播放」与锁屏控件。
///
/// 只负责「上报状态 + 收下发命令」，播放本身仍在 [MfPlayer] 里。没有这层时，
/// 应用退到后台、屏幕一锁，Android 会把进程当成普通的缓存进程回收掉，音频也就
/// 停了；[AudioService] 拉起一个 foreground service + MediaSession，系统才认为
/// 这是一个正在放音乐的进程，同时把锁屏与通知栏的控制权交给它。
///
/// Android / iOS / macOS 共用 audio_service 的实现（darwin 分支在 macOS 上走
/// MPNowPlayingInfoCenter / MPRemoteCommandCenter，即控制中心的「正在播放」）。
/// 鸿蒙走的是另一条路：系统媒体面板由 just_audio 的 ohos 分支创建 AVSession 来
/// 提供，灭屏存活靠「长时任务」，见 [background_task.dart]；Windows/Linux 没有
/// 接入，直接跳过。
library;

import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

// `PlaybackState` 两边都有：audio_service 的是媒体中心上报的状态，本项目的是
// 播放器状态。用前缀把本项目的隔开，避免各处 hide/重命名。
import 'player.dart' as mf;

/// 当前平台有没有系统级媒体会话可接。
///
/// macOS 也算：audio_service 的 darwin 实现原生支持（MPNowPlayingInfoCenter），
/// 启用后控制中心 / 菜单栏才会出现「正在播放」卡片。
bool get mediaSessionSupported =>
    !kIsWeb &&
    (Platform.isAndroid || Platform.isIOS || Platform.isMacOS);

class MfMediaSession {
  MfMediaSession._(this._handler);

  static MfMediaSession? _instance;

  /// 未初始化时（桌面 / 鸿蒙 / 测试）为 null，调用方一律按可选处理。
  static MfMediaSession? get instance => _instance;

  final _MfAudioHandler _handler;

  mf.MfPlayer? _player;

  /// 初始化系统媒体会话。失败不影响播放本身，所以异常只记日志。
  static Future<MfMediaSession?> start() async {
    if (!mediaSessionSupported) return null;
    if (_instance != null) return _instance;
    try {
      final handler = await AudioService.init(
        builder: _MfAudioHandler.new,
        config: const AudioServiceConfig(
          androidNotificationChannelId: 'com.seasonyuu.musicfly.playback',
          androidNotificationChannelName: '播放控制',
          androidNotificationChannelDescription: '锁屏和通知栏里的播放控制',
          // 通知栏用单色音符，否则默认的彩色启动图标会被系统渲染成白方块。
          androidNotificationIcon: 'drawable/ic_stat_music',
          // 播放中常驻，避免用户清理通知后前台服务被系统回收。
          androidNotificationOngoing: true,
          // 暂停时退出前台服务：不播放就不要再占着「正在运行」的位置。
          androidStopForegroundOnPause: true,
          androidResumeOnClick: true,
          androidShowNotificationBadge: false,
        ),
      );
      return _instance = MfMediaSession._(handler);
    } catch (error, stack) {
      debugPrint('系统媒体会话初始化失败，仅影响锁屏控制：$error\n$stack');
      return null;
    }
  }

  /// Android 13 起，媒体通知要用户授权才显示在通知栏 / 锁屏。播放中的前台服务
  /// 通知是豁免的，但一暂停服务就退出前台、通知降级为普通通知，没授权会直接
  /// 消失 —— 锁屏上的控制器跟着一起没了，用户就再也没法从锁屏点回播放。
  /// 所以第一次真正播放时讨一次权限，而不是启动时就弹窗。
  static bool _askedNotificationPermission = false;

  static Future<void> ensureNotificationPermission() async {
    if (_askedNotificationPermission || !mediaSessionSupported) return;
    if (!Platform.isAndroid) return;
    _askedNotificationPermission = true;
    try {
      await const MethodChannel(
        'musicfly/notification',
      ).invokeMethod<void>('requestPostNotifications');
    } catch (error) {
      // 通道缺失（旧版壳 / 测试）不影响播放，只是没有通知权限。
      debugPrint('请求通知权限失败：$error');
    }
  }

  /// 把 [player] 的状态同步到系统媒体中心，并把媒体中心下发的命令交回队列。
  /// 队列的上一首 / 下一首在 [onNext] / [onPrevious] 里由 `AppModel` 提供。
  ///
  /// [onFavorite] / [onCycleMode] 是 Android 13+ 锁屏媒体面板的两个自定义
  /// 按钮（收藏、播放顺序）。它们不是标准 transport action，只能走 custom
  /// action；此二者与其状态来源 [extrasProvider] 都是可选的——鸿蒙/桌面没有
  /// 这套面板，测试里的纯 MfPlayer 也不提供，缺任一就不显示这两个按钮。
  void bind(
    mf.MfPlayer player, {
    required Future<void> Function() onNext,
    required Future<void> Function() onPrevious,
    Future<void> Function()? onFavorite,
    Future<void> Function()? onCycleMode,
    ({bool favorite, int playModeIndex}) Function()? extrasProvider,
    Map<String, String>? Function(String url)? artHeadersProvider,
  }) {
    _handler
      ..onPlay = player.resume
      ..onPause = player.pause
      ..onSeek = player.seek
      ..onStop = player.stop
      ..onNext = onNext
      ..onPrevious = onPrevious
      ..onFavorite = onFavorite
      ..onCycleMode = onCycleMode
      ..extrasProvider = extrasProvider
      ..artHeadersProvider = artHeadersProvider;
    unbind();
    _player = player;
    // `state` 是 ValueNotifier，没有 stream；位置每 200ms 变一次，监听器里由
    // handler 自己节流，只推秒级增量。
    player.state.addListener(_push);
    _push();
  }

  /// 收藏状态 / 播放模式变化后主动重推一次媒体面板图标。这两个状态不在
  /// 播放器 [mf.PlaybackState] 里，播放器位置不动时 [_push] 不会被触发，
  /// 必须由 AppModel 在切模式 / 收藏 / 换歌后调用这里刷新。
  void refreshExtras() {
    final player = _player;
    if (player != null) _handler.publish(player.state.value, force: true);
  }

  void _push() {
    final player = _player;
    if (player != null) _handler.publish(player.state.value);
  }

  void unbind() {
    _player?.state.removeListener(_push);
    _player = null;
  }

  void dispose() {
    unbind();
    if (_instance == this) _instance = null;
  }
}

class _MfAudioHandler extends BaseAudioHandler {
  Future<void> Function()? onPlay;
  Future<void> Function()? onPause;
  Future<void> Function()? onStop;
  Future<void> Function()? onNext;
  Future<void> Function()? onPrevious;
  Future<void> Function()? onFavorite;
  Future<void> Function()? onCycleMode;
  Future<void> Function(Duration position)? onSeek;

  /// Android 锁屏自定义按钮的当前状态来源：收藏态 + 播放模式索引（0-3）。
  /// 由 AppModel 注入，只有它同时知道队列当前曲目和播放模式。
  ({bool favorite, int playModeIndex}) Function()? extrasProvider;

  /// 封面 URL 的鉴权 header 来源（飞牛网关 / relay 链路需要）。audio_service
  /// 自己下载锁屏封面，不带这些 header 就会拿到 401 → 通知 largeIcon=null，
  /// 表现为锁屏媒体卡片永远没有专辑封面。
  Map<String, String>? Function(String url)? artHeadersProvider;

  // custom action 的 name，与 mfMediaControls() 里的 name 对应。
  static const favoriteAction = 'musicfly_favorite';
  static const cycleModeAction = 'musicfly_cycle_mode';

  @override
  Future<dynamic> customAction(String name, [Map<String, dynamic>? extras]) {
    switch (name) {
      case favoriteAction:
        return onFavorite?.call() ?? Future.value();
      case cycleModeAction:
        return onCycleMode?.call() ?? Future.value();
      default:
        return super.customAction(name, extras);
    }
  }

  // 媒体中心只需要秒级粒度：播放位置每秒推一次就够，`PlaybackState.speed`
  // 会让系统自己在两次推送之间插值。全量推送会把平台通道刷爆。
  static const _positionEpsilon = Duration(seconds: 1);

  String? _lastTrackId;
  bool? _lastPlaying;
  Duration _lastPosition = Duration.zero;
  bool? _lastFavorite;
  int? _lastPlayModeIndex;

  @override
  Future<void> play() async => onPlay?.call();

  @override
  Future<void> pause() async => onPause?.call();

  @override
  Future<void> skipToNext() async => onNext?.call();

  @override
  Future<void> skipToPrevious() async => onPrevious?.call();

  @override
  Future<void> seek(Duration position) async => onSeek?.call(position);

  @override
  Future<void> stop() async {
    await onStop?.call();
    await super.stop();
  }

  /// 把播放器状态翻译成媒体中心要的两样东西：当前曲目（[mediaItem]）和
  /// 可播状态（[playbackState]，决定通知栏按钮长什么样）。
  void publish(mf.PlaybackState state, {bool force = false}) {
    final trackId = state.trackId;
    if (trackId == null) {
      if (mediaItem.value != null) mediaItem.add(null);
      _lastTrackId = null;
      _lastPlaying = null;
      _lastFavorite = null;
      _lastPlayModeIndex = null;
      playbackState.add(
        PlaybackState(processingState: AudioProcessingState.idle),
      );
      return;
    }

    final artUri = _parseUri(state.coverUrl);
    final item = MediaItem(
      id: trackId,
      title: state.title,
      artist: state.subtitle.isEmpty ? null : state.subtitle,
      duration: state.duration > Duration.zero ? state.duration : null,
      artUri: artUri,
      // 飞牛网关 / relay 封面必须带鉴权 header，否则 audio_service 的缓存
      // 管理器下载 401，锁屏媒体卡片拿不到 largeIcon。普通链路返回 null。
      artHeaders:
          artUri != null ? artHeadersProvider?.call(artUri.toString()) : null,
    );
    // 换歌才重建 MediaItem：位置跳动不该让通知栏重新加载封面。
    final previous = mediaItem.value;
    if (previous == null ||
        previous.id != item.id ||
        previous.title != item.title ||
        previous.artist != item.artist ||
        previous.duration != item.duration ||
        previous.artUri != item.artUri) {
      mediaItem.add(item);
    }

    // 收藏 / 循环模式不在播放器状态里，单独从 AppModel 注入的提供者读。
    final extras = extrasProvider?.call();
    final favorite = extras?.favorite ?? false;
    final modeIndex = extras?.playModeIndex ?? 0;

    final positionJumped =
        (state.position - _lastPosition).abs() >= _positionEpsilon;
    final extrasChanged = favorite != _lastFavorite ||
        modeIndex != _lastPlayModeIndex;
    if (!force &&
        _lastTrackId == trackId &&
        _lastPlaying == state.playing &&
        !positionJumped &&
        !extrasChanged) {
      return;
    }
    _lastTrackId = trackId;
    _lastPlaying = state.playing;
    _lastPosition = state.position;
    _lastFavorite = favorite;
    _lastPlayModeIndex = modeIndex;

    playbackState.add(
      PlaybackState(
        controls: mfMediaControls(
          playing: state.playing,
          favorite: favorite,
          playModeIndex: modeIndex,
          includeFavorites: onFavorite != null,
          includeCycleMode: onCycleMode != null,
        ),
        systemActions: const {MediaAction.seek},
        // 紧凑视图始终只放三个标准按钮；两个自定义按钮只在展开的媒体面板 /
        // Android 13+ 锁屏控件里出现，避免挤掉播放/切歌。
        androidCompactActionIndices: const [0, 1, 2],
        processingState: AudioProcessingState.ready,
        playing: state.playing,
        updatePosition: state.position,
        bufferedPosition: state.position,
        speed: 1.0,
      ),
    );
  }

  static Uri? _parseUri(String? value) {
    if (value == null || value.isEmpty) return null;
    return Uri.tryParse(value);
  }
}

/// 播放模式索引 → 图标资源。顺序与 `PlayMode` 一致：
/// 0 顺序 / 1 列表循环 / 2 单曲循环 / 3 随机。
String mfPlayModeIcon(int index) => switch (index) {
      1 => 'drawable/ic_mf_repeat_all',
      2 => 'drawable/ic_mf_repeat_one',
      3 => 'drawable/ic_mf_shuffle',
      _ => 'drawable/ic_mf_repeat_sequential',
    };

String mfPlayModeLabel(int index) => switch (index) {
      1 => '列表循环',
      2 => '单曲循环',
      3 => '随机播放',
      _ => '顺序播放',
    };

/// 构造锁屏/通知栏媒体面板的按钮列表。三个标准 transport 按钮恒在；两个
/// 自定义按钮（收藏、播放顺序）只有 AppModel 注入了对应回调才加入——Android
/// 13+ 会把 custom action 放进面板槽位 4/5，Android 12- 最多显示前三个。
///
/// 抽成顶层纯函数，便于在没有平台通道的单元测试里精确断言图标与按钮。
List<MediaControl> mfMediaControls({
  required bool playing,
  required bool favorite,
  required int playModeIndex,
  required bool includeFavorites,
  required bool includeCycleMode,
}) {
  final controls = <MediaControl>[
    MediaControl.skipToPrevious,
    if (playing) MediaControl.pause else MediaControl.play,
    MediaControl.skipToNext,
  ];
  if (includeFavorites) {
    controls.add(MediaControl.custom(
      androidIcon: favorite
          ? 'drawable/ic_mf_favorite_on'
          : 'drawable/ic_mf_favorite_off',
      label: favorite ? '取消收藏' : '收藏',
      name: _MfAudioHandler.favoriteAction,
    ));
  }
  if (includeCycleMode) {
    controls.add(MediaControl.custom(
      androidIcon: mfPlayModeIcon(playModeIndex),
      label: mfPlayModeLabel(playModeIndex),
      name: _MfAudioHandler.cycleModeAction,
    ));
  }
  return controls;
}
