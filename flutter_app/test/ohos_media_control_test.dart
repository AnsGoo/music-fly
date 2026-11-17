/// 鸿蒙锁屏 / 媒体面板的命令双向通道：ohos 插件把 AVSession 的
/// next / previous / play / pause / loopMode / favorite 经 MethodChannel 送回
/// Dart，必须落到 AppModel 的队列/状态方法上；反向 syncState 把播放模式和
/// 收藏推给原生刷新锁屏图标。
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:musicfly/audio/ohos_media_control.dart';
import 'package:musicfly/state/app_model.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const codec = StandardMethodCodec();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  /// 模拟 ArkTS 侧 MethodChannel.invokeMethod 发来的一条命令。
  Future<void> send(String method) async {
    await messenger.handlePlatformMessage(
      MfOhosMediaControl.channelName,
      codec.encodeMethodCall(MethodCall(method)),
      (_) {},
    );
    // handler 是 async 的，让事件循环把 Future 跑完。
    await Future<void>.delayed(Duration.zero);
  }

  test('next / previous are forwarded to the queue', () async {
    var next = 0;
    var previous = 0;
    MfOhosMediaControl.bind(
      onNext: () async => next++,
      onPrevious: () async => previous++,
    );

    await send('next');
    await send('previous');
    await send('next');

    expect(next, 2);
    expect(previous, 1);
  });

  test('play / pause are forwarded (lock-screen pause regression)', () async {
    var play = 0;
    var pause = 0;
    var next = 0;
    var previous = 0;
    MfOhosMediaControl.bind(
      onNext: () async => next++,
      onPrevious: () async => previous++,
      onPlay: () async => play++,
      onPause: () async => pause++,
    );

    await send('pause');
    await send('play');
    await send('pause');

    expect(play, 1);
    expect(pause, 2);
    // Play/pause must never leak into the queue.
    expect(next, 0);
    expect(previous, 0);
  });

  test('optional play / pause callbacks stay optional', () async {
    var next = 0;
    MfOhosMediaControl.bind(
      onNext: () async => next++,
      onPrevious: () async {},
    );

    // No onPlay/onPause injected: these must be ignored, not throw.
    await send('pause');
    await send('play');
    await send('next');

    expect(next, 1);
  });

  test('loop mode / favorite are forwarded', () async {
    var loopMode = 0;
    var favorite = 0;
    var next = 0;
    MfOhosMediaControl.bind(
      onNext: () async => next++,
      onPrevious: () async {},
      onLoopMode: () async => loopMode++,
      onFavorite: () async => favorite++,
    );

    await send('loopMode');
    await send('favorite');
    await send('loopMode');

    expect(loopMode, 2);
    expect(favorite, 1);
    // These must never leak into the queue.
    expect(next, 0);
  });

  test('syncState pushes play mode and favorite to the AVSession', () async {
    MethodCall? captured;
    const channel = MethodChannel(MfOhosMediaControl.channelName);
    messenger.setMockMethodCallHandler(
      channel,
      (call) async {
        captured = call;
        return null;
      },
    );

    await MfOhosMediaControl.syncState(playModeIndex: 3, favorite: true);

    final call = captured;
    expect(call, isNotNull);
    expect(call!.method, 'setPlaybackExtras');
    expect(call.arguments['playModeIndex'], 3);
    expect(call.arguments['favorite'], true);

    messenger.setMockMethodCallHandler(channel, null);
  });

  test('PlayMode maps to the AVSession loop-mode index contract', () {
    expect(ohosPlayModeIndex(PlayMode.sequential), 0);
    expect(ohosPlayModeIndex(PlayMode.loopAll), 1);
    expect(ohosPlayModeIndex(PlayMode.loopOne), 2);
    expect(ohosPlayModeIndex(PlayMode.shuffle), 3);
  });

  test('unknown commands are ignored', () async {
    var next = 0;
    var previous = 0;
    MfOhosMediaControl.bind(
      onNext: () async => next++,
      onPrevious: () async => previous++,
    );

    await send('stop');

    expect(next, 0);
    expect(previous, 0);
  });
}
