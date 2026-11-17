/// Android 锁屏/通知栏媒体面板的按钮构造与自定义命令分发测试。
///
/// Android 13+ 会在媒体面板槽位 4/5 显示 custom action；这里验证：
/// - 三个标准 transport 按钮恒在，紧凑槽位仍只放这三个；
/// - 收藏 / 播放顺序两个自定义按钮按注入情况出现，图标随状态切换；
/// - custom action 的 name 稳定（Dart↔原生契约），不与标准 action 冲突。
library;

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musicfly/audio/media_session.dart';

void main() {
  group('mfMediaControls', () {
    test('只有三个标准按钮：当没有注入自定义回调', () {
      final controls = mfMediaControls(
        playing: true,
        favorite: false,
        playModeIndex: 0,
        includeFavorites: false,
        includeCycleMode: false,
      );

      expect(controls, hasLength(3));
      expect(controls[0].action, MediaAction.skipToPrevious);
      expect(controls[1].action, MediaAction.pause); // playing → 显示暂停
      expect(controls[2].action, MediaAction.skipToNext);
      expect(controls.every((c) => c.action != MediaAction.custom), isTrue);
    });

    test('暂停态显示 play 而非 pause', () {
      final controls = mfMediaControls(
        playing: false,
        favorite: false,
        playModeIndex: 0,
        includeFavorites: false,
        includeCycleMode: false,
      );
      expect(controls[1].action, MediaAction.play);
    });

    test('注入回调后追加收藏 + 循环两个自定义按钮', () {
      final controls = mfMediaControls(
        playing: true,
        favorite: false,
        playModeIndex: 0,
        includeFavorites: true,
        includeCycleMode: true,
      );

      expect(controls, hasLength(5));
      expect(controls[3].action, MediaAction.custom);
      expect(controls[3].customAction?.name, 'musicfly_favorite');
      expect(controls[4].action, MediaAction.custom);
      expect(controls[4].customAction?.name, 'musicfly_cycle_mode');
    });

    test('收藏图标随状态切换', () {
      final off = mfMediaControls(
        playing: true,
        favorite: false,
        playModeIndex: 0,
        includeFavorites: true,
        includeCycleMode: false,
      ).last;
      final on = mfMediaControls(
        playing: true,
        favorite: true,
        playModeIndex: 0,
        includeFavorites: true,
        includeCycleMode: false,
      ).last;

      expect(off.androidIcon, 'drawable/ic_mf_favorite_off');
      expect(off.label, '收藏');
      expect(on.androidIcon, 'drawable/ic_mf_favorite_on');
      expect(on.label, '取消收藏');
      // name 恒定，原生回传时才能稳定分发。
      expect(off.customAction?.name, on.customAction?.name);
    });

    test('四种播放模式映射到各自图标', () {
      String icon(int mode) => mfMediaControls(
            playing: true,
            favorite: false,
            playModeIndex: mode,
            includeFavorites: false,
            includeCycleMode: true,
          ).last.androidIcon;

      expect(icon(0), 'drawable/ic_mf_repeat_sequential');
      expect(icon(1), 'drawable/ic_mf_repeat_all');
      expect(icon(2), 'drawable/ic_mf_repeat_one');
      expect(icon(3), 'drawable/ic_mf_shuffle');
      // 越界值兜底为顺序播放，不崩。
      expect(icon(99), 'drawable/ic_mf_repeat_sequential');
    });

    test('自定义按钮独立于注入顺序，可只加其中一个', () {
      final onlyFavorite = mfMediaControls(
        playing: true,
        favorite: true,
        playModeIndex: 3,
        includeFavorites: true,
        includeCycleMode: false,
      );
      final onlyCycle = mfMediaControls(
        playing: true,
        favorite: true,
        playModeIndex: 3,
        includeFavorites: false,
        includeCycleMode: true,
      );

      expect(onlyFavorite, hasLength(4));
      expect(onlyFavorite.last.customAction?.name, 'musicfly_favorite');
      expect(onlyCycle, hasLength(4));
      expect(onlyCycle.last.customAction?.name, 'musicfly_cycle_mode');
    });
  });
}
