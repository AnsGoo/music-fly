/// 鸿蒙锁屏 / 媒体面板的命令双向通道。
///
/// Android / iOS / macOS 由 audio_service 的 MediaSession 接管（见
/// media_session.dart）；鸿蒙没有 audio_service 实现，系统 AVSession 是
/// just_audio 的 ohos 分支在 ArkTS 侧创建的，命令会先落到插件里。而插件内部
/// 的播放列表恒为 1 首（本 App 每次只 setUrl 一首，队列在 AppModel），原生
/// 切歌 / 切模式 / 收藏无从下手。插件因此把命令经下面这条通道转发过来，这里
/// 再交给 AppModel，保证系统面板与应用内按钮用的是同一套控制。
///
/// **play / pause 也必须在这里处理**：ArkTS 的转发器对所有 AVSession 命令
/// 都返回 true 以拦住原生 fallback（那套只会操作只有 1 首的本地引擎），所以
/// 如果 Dart 侧漏接 play/pause，锁屏上点暂停就会「两边都不管」——命令被原生
/// 拦下、Dart 又丢弃，表现为锁屏暂停完全无效。
///
/// 反向 [syncState] 把播放模式 / 收藏推回原生写进 AVPlaybackState：鸿蒙规定
/// 只有注册了 setLoopMode / toggleFavorite 回调按钮才亮起，而图标长什么样
/// 取决于应用上报的 loopMode / favorite，不推就一直是默认（顺序 / 未收藏）。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class MfOhosMediaControl {
  MfOhosMediaControl._();

  /// 与 ohos 侧 MainMethodCallHandler 里创建的 MethodChannel 同名。
  static const String channelName = 'com.seasonyuu.musicfly/media_control';

  static const MethodChannel _channel = MethodChannel(channelName);

  /// 每次开播都会重新绑定：Flutter 引擎热重启后旧的 handler 会失效，只绑一次
  /// 时锁屏按钮发出去的命令会被系统静默丢弃。`setMethodCallHandler` 是覆盖式，
  /// 重复调用没有副作用（其它平台不会收到这条通道的消息，注册本身不发起平台
  /// 调用，widget tests 里也安全）。
  ///
  /// onPlay / onPause / onLoopMode / onFavorite 可选是为了兼容只关心切歌的
  /// 调用方；AppModel 会把六个命令都接上：暂停同样要区分本机播放与投屏，见
  /// AppModel.systemPause；循环与收藏走队列所有者的同一套状态。
  static void bind({
    required Future<void> Function() onNext,
    required Future<void> Function() onPrevious,
    Future<void> Function()? onPlay,
    Future<void> Function()? onPause,
    Future<void> Function()? onLoopMode,
    Future<void> Function()? onFavorite,
  }) {
    _channel.setMethodCallHandler((call) async {
      debugPrint('MF media control: received ${call.method}');
      // 不 await 队列切换：一次 setUrl 可能要几秒，回执卡住时系统侧会认为
      // 命令没送达；命令本身在 AppModel 里串行合并，不怕连点。
      Future<void> Function()? action;
      switch (call.method) {
        case 'next':
          action = onNext;
        case 'play':
          action = onPlay;
        case 'pause':
          action = onPause;
        case 'previous':
          action = onPrevious;
        case 'loopMode':
          action = onLoopMode;
        case 'favorite':
          action = onFavorite;
      }
      if (action != null) {
        unawaited(action().catchError((Object error) {
          debugPrint('MF media control: ${call.method} failed: $error');
        }));
      }
      return null;
    });
    debugPrint('MF media control: handler bound');
  }

  /// 把当前播放模式与收藏状态推给 AVSession，决定锁屏上「循环 / 收藏」按钮
  /// 的图标。[playModeIndex] 与 ArkTS 侧约定：0=顺序 1=列表循环 2=单曲 3=随机。
  ///
  /// 非鸿蒙平台通道对端不存在，`invokeMethod` 会抛 MissingPluginException；
  /// 这里吞掉异常，让 AppModel 在无条件调用时也不用判断平台。
  static Future<void> syncState({
    required int playModeIndex,
    required bool favorite,
  }) async {
    try {
      await _channel.invokeMethod<void>('setPlaybackExtras', <String, dynamic>{
        'playModeIndex': playModeIndex,
        'favorite': favorite,
      });
    } catch (_) {
      // 非鸿蒙平台 / 测试环境对端不存在是常态，静默忽略（见方法注释）。
    }
  }
}
