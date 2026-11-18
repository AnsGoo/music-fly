/**
 * Copyright (C) 2024 Huawei Device Co., Ltd.
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 * */

import { media } from '@kit.MediaKit';
import { audio } from '@kit.AudioKit';
import { common, wantAgent } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { AVCastPickerState, avSession } from '@kit.AVSessionKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import MediaSource from './MediaSource';
import { fileIo } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { Log, MethodResult } from '@ohos/flutter_ohos';

const TAG = 'MediaAvPlayer';

/// 元数据写超时。AVSession IPC 偶发「永不返回」：2026-11-17 真机实测一次
/// setAVMetadata（或其后的 activate）挂死后，writeChain 被永久堵住，此后任何
/// 切歌的元数据推送都排队在永不结束的闭包后面——锁屏从此冻结在上一首
/// （App 内播放 A/C/E/F，锁屏一直是 B）。每次系统调用都必须限时，超时按失败
/// 处理，让串行链继续流动。
const METADATA_WRITE_TIMEOUT_MS = 3000;

function mfAwaitWithTimeout<T>(label: string, p: Promise<T>): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(() => {
      reject(new Error(`${label} timed out after ${METADATA_WRITE_TIMEOUT_MS}ms`));
    }, METADATA_WRITE_TIMEOUT_MS);
    p.then(
      (value: T) => { clearTimeout(timer); resolve(value); },
      (error: object) => { clearTimeout(timer); reject(error); }
    );
  });
}

/// console.* 在 release 构建里会被整体剥离（2026-11-17 排障时整条元数据链路
/// 零日志，只能靠 hidumper 反推）。锁屏链路的日志必须走 hilog API，release
/// 下仍然可见。
export function mfLogInfo(message: string): void {
  hilog.info(0x0000, TAG, '%{public}s', message);
}

export function mfLogError(message: string): void {
  hilog.error(0x0000, TAG, '%{public}s', message);
}

/// 系统媒体面板（锁屏 / 耳机 / 蓝牙）的「上一首 / 下一首」必须交给 Dart 队列。
/// MusicFly 每次只把一首歌 setUrl 给插件，插件内部的 songList 恒为 1 首：
/// 原生 playNext() 在 DEFAULT 模式下直接 return，playPrevious() 只会重播
/// 当前曲，所以锁屏按钮点了没反应。MainMethodCallHandler 会注入一个转发器，
/// 把命令经 MethodChannel 送到 AppModel.next()/previous()。没有注入时（其它
/// 使用本插件的 App）仍保留插件自带的原生切歌行为。
///
/// 用 AppStorage 而不用模块级变量：ArkTS 打包后 MainMethodCallHandler 与
/// MediaAvPlayer 可能落在不同模块记录里，同一个 .ets 的顶层变量各有副本
/// （实测 on playNext 时 forwarder=false，尽管插件构造时已注册）。AppStorage
/// 是进程级全局，EntryAbility 与插件之间共享 context/mediaService 已验证可用。
export const MF_MEDIA_COMMAND_KEY = 'musicflyMediaCommandForwarder';

export class MfMediaCommandForwarder {
  private handler: (command: string) => boolean;

  constructor(handler: (command: string) => boolean) {
    this.handler = handler;
  }

  forward(command: string): boolean {
    return this.handler(command);
  }
}

/// AVSession 的命令回调只能注册一次，而且**不能绑定到某个 MediaAvPlayer 实例**：
/// 每次 disposeAllPlayers / 引擎热重启都会新建实例，原来那套「先 off 全部命令
/// 再 on 回本实例」有两个致命问题 —— off 会把系统面板的 supported commands
/// 清掉，且多个实例异步 createSession 时会互相把对方刚注册的回调解绑。实测
/// 结果是锁屏按下一首时应用侧一条 `on playNext` 都收不到，系统却显示按钮可用。
/// 改成全局稳定回调：命令到了再从 AppStorage 取「当前」转发器 / 活跃实例。
/// （是否已注册按会话实例跟踪，见 mfRegisterSessionCommands。）

/// 锁屏播控中心的「循环模式 / 收藏」按钮：只有注册了对应回调按钮才亮起，
/// 图标则由 AVPlaybackState 的 loopMode / favorite 决定。状态放 AppStorage —— 
/// AVSession 回调与 Flutter 通道在 ArkTS 打包后可能落在不同模块记录里。
export const MF_PLAYBACK_EXTRAS_KEY = 'musicflyPlaybackExtras';

export class MfPlaybackExtras {
  /// 与 Dart 的 PlayMode 序号一致：0=顺序 1=列表循环 2=单曲循环 3=随机。
  playModeIndex: number = 0;
  favorite: boolean = false;
}

export function mfPlaybackExtras(): MfPlaybackExtras {
  let extras = AppStorage.get(MF_PLAYBACK_EXTRAS_KEY) as MfPlaybackExtras | undefined;
  if (!extras) {
    extras = new MfPlaybackExtras();
    AppStorage.setOrCreate(MF_PLAYBACK_EXTRAS_KEY, extras);
  }
  return extras;
}

/// 与 AppModel.ohosPlayModeIndex / PlayMode 一一对应，映射到 AVSession 的
/// 四个官方枚举值（见 @ohos.multimedia.avsession 的 LoopMode）：
/// 0=顺序 SEQUENCE 1=列表循环 LIST 2=单曲 SINGLE 3=随机 SHUFFLE。
function mfAvLoopMode(playModeIndex: number): avSession.LoopMode {
  switch (playModeIndex) {
    case 1:
      return avSession.LoopMode.LOOP_MODE_LIST;
    case 2:
      return avSession.LoopMode.LOOP_MODE_SINGLE;
    case 3:
      return avSession.LoopMode.LOOP_MODE_SHUFFLE;
    default:
      return avSession.LoopMode.LOOP_MODE_SEQUENCE;
  }
}

/// Dart 侧播放模式 / 收藏变化后主动同步，让系统面板图标立刻更新。
export function mfApplyPlaybackExtras(playModeIndex: number, favorite: boolean): void {
  const extras = mfPlaybackExtras();
  extras.playModeIndex = playModeIndex;
  extras.favorite = favorite;
  const active = AppStorage.get(MF_ACTIVE_PLAYER_KEY) as MediaAvPlayer | undefined;
  if (active) {
    active.syncPlaybackState();
  }
}

let mfCommandsRegisteredOn: avSession.AVSession | undefined;

export function mfRegisterSessionCommands(session: avSession.AVSession): void {
  // 守卫必须按会话实例判断，不能用 AppStorage 布尔标志：会话销毁重建后标志
  // 还在，新会话就永远注册不上命令回调，锁屏按钮全部失灵。
  if (mfCommandsRegisteredOn === session) {
    return;
  }
  try {
    session.on('play', () => {
      mfDispatchPanelCommand('play');
    });
    session.on('pause', () => {
      mfDispatchPanelCommand('pause');
    });
    session.on('playNext', () => {
      mfDispatchPanelCommand('next');
    });
    session.on('playPrevious', () => {
      mfDispatchPanelCommand('previous');
    });
    // 循环模式 / 收藏：注册后锁屏面板的这两个按钮才会亮起。回调带回的是
    // 系统「当前」图标状态，由 AppModel 自行 cycle 后回推新状态。
    session.on('setLoopMode', (mode: avSession.LoopMode) => {
      console.info(TAG, `AVSession setLoopMode: ${mode}`);
      mfDispatchPanelCommand('loopMode');
    });
    session.on('toggleFavorite', (assetId: string) => {
      console.info(TAG, `AVSession toggleFavorite: ${assetId}`);
      mfDispatchPanelCommand('favorite');
    });
    mfCommandsRegisteredOn = session;
    console.info(TAG, 'AVSession command listeners registered');
  } catch (error) {
    console.error(TAG, `register AVSession commands failed: ${JSON.stringify(error)}`);
  }
}

export function mfDispatchPanelCommand(command: string): void {
  console.info(TAG, `AVSession command received: ${command}`);
  const forwarder = AppStorage.get(MF_MEDIA_COMMAND_KEY) as MfMediaCommandForwarder | undefined;
  if (forwarder) {
    try {
      if (forwarder.forward(command)) {
        console.info(TAG, `AVSession command forwarded to Dart: ${command}`);
        return;
      }
    } catch (error) {
      console.error(TAG, `forward command failed: ${JSON.stringify(error)}`);
    }
  }
  // 转发器还没注册（或通道已失效）时保留插件原生行为，至少按钮不是死的。
  const active = AppStorage.get(MF_ACTIVE_PLAYER_KEY) as MediaAvPlayer | undefined;
  if (active) {
    active.handlePanelCommand(command);
  } else {
    console.error(TAG, `no active player for command: ${command}`);
  }
}

/// 锁屏面板的元数据必须是**进程级唯一**的。热重启 / 重新登录会再建一个
/// AudioPlayer → MediaAvPlayer，而旧实例仍持有自己的 dartTitle 与 AVSession；
/// 主通道的 setMetadata 若落到旧实例，锁屏就一直显示上一首（App 内是 A、
/// 锁屏是 B）。把活跃实例和曲目快照放 AppStorage，任何实例收到的元数据都写
/// 到同一份状态，新会话创建后也能直接读到当前曲目。
export const MF_ACTIVE_PLAYER_KEY = 'musicflyActiveMediaPlayer';
export const MF_AV_METADATA_KEY = 'musicflyAvMetadataSnapshot';
export const MF_AV_SESSION_KEY = 'musicflySharedAvSession';

/// 模块级兜底引用。AppStorage 在进程被系统冻结/解冻等场景下可能被框架清空
/// （2026-11-18 真机：后台冻结数小时后解冻，AppStorage 里的会话缓存消失，
/// 而旧 AVSession 仍在系统里占坑 → createAVSession 全部被拒）。模块静态与
/// JS 堆同生命周期，只要进程不死就能拿回旧会话。
let mfSessionPromise: Promise<avSession.AVSession> | undefined;
let mfSessionInstance: avSession.AVSession | undefined;

/// BusinessError 的属性不可枚举，JSON.stringify 只会得到 `{}`——2026-11-18
/// 真机排障时 `createSession failed: {}` 就是这么来的，完全看不出原因。
/// 这里显式抽取 code / message。
export function mfSessionErrorDetail(label: string, error: Object | undefined): string {
  const e = error as BusinessError | undefined;
  if (e && (e.code !== undefined || e.message !== undefined)) {
    return `${label}: code=${e.code}, message=${e.message}`;
  }
  return `${label}: ${JSON.stringify(error)}`;
}

function mfSleep(ms: number): Promise<void> {
  return new Promise<void>((resolve) => {
    setTimeout(resolve, ms);
  });
}

/// SDK 明确「An ability can only create one AVSession」。缓存创建 Promise：
/// 热重启 / 重建 AudioPlayer 时不再重复 createAVSession，锁屏始终只有一张
/// 卡片，元数据也只往这一处写。
export function mfSharedSession(context: common.UIAbilityContext): Promise<avSession.AVSession> {
  const cached = (AppStorage.get(MF_AV_SESSION_KEY) as Promise<avSession.AVSession> | undefined)
    ?? mfSessionPromise;
  if (cached) {
    return cached;
  }
  const pending = mfCreateSharedSession(context);
  AppStorage.setOrCreate(MF_AV_SESSION_KEY, pending);
  mfSessionPromise = pending;
  // 失败的 create 不能长期缓存：2026-11-18 真机实测，一次 createAVSession
  // 被拒（旧会话还占着坑）后拒绝态被永久缓存，后续所有推送都拿到同一个
  // 拒绝 → 会话永远建不回来，锁屏元数据冻死在最后一次成功写入的那首歌。
  pending.catch(() => {
    if ((AppStorage.get(MF_AV_SESSION_KEY) as Promise<avSession.AVSession> | undefined) === pending) {
      AppStorage.delete(MF_AV_SESSION_KEY);
    }
    if (mfSessionPromise === pending) {
      mfSessionPromise = undefined;
    }
  });
  return pending;
}

/// createAVSession 被拒的最常见原因是旧会话未销毁（同 ability 同 tag）。
/// 先销毁模块级追踪的旧会话再重试；三次都失败则把拒绝抛给调用方（缓存会被
/// mfSharedSession 的 catch 清掉，下一次推送从零再试）。
async function mfCreateSharedSession(context: common.UIAbilityContext): Promise<avSession.AVSession> {
  let lastError: Object | undefined;
  for (let attempt = 1; attempt <= 3; attempt++) {
    try {
      const created = await avSession.createAVSession(context, 'SESSION_NAME', 'audio');
      try {
        await created.activate();
      } catch (activateError) {
        mfLogError(mfSessionErrorDetail('activate new session failed', activateError));
      }
      mfSessionInstance = created;
      return created;
    } catch (error) {
      lastError = error;
      mfLogError(mfSessionErrorDetail(`createAVSession attempt ${attempt} failed`, error));
      if (attempt >= 3) {
        break;
      }
      const stale = mfSessionInstance;
      if (stale) {
        try {
          await mfAwaitWithTimeout('destroy stale session', stale.destroy());
          mfSessionInstance = undefined;
        } catch (destroyError) {
          mfLogError(mfSessionErrorDetail('destroy stale session failed', destroyError));
        }
      }
      await mfSleep(attempt * 500);
    }
  }
  throw new Error(mfSessionErrorDetail('createAVSession retries exhausted', lastError));
}

/// 会话单例失效（销毁失败 / 重建流程放弃）时清掉所有缓存引用，下一次
/// mfSharedSession 调用从头建。
export function mfInvalidateSharedSession(): void {
  mfSessionPromise = undefined;
  mfSessionInstance = undefined;
  AppStorage.delete(MF_AV_SESSION_KEY);
}

export class MfAvMetadata {
  title: string = '';
  artist: string = '';
  artUri: string = '';
  durationMs: number = 0;
  /// 曲目的稳定标识（Dart 下发 trackId）。assetId 每次推送都递增时，系统会把
  /// 同一首歌的「无封面 → 补推 → 封面」当成三个不同媒体项，锁屏卡片可能一直
  /// 停在第一次那个条目上。同曲保持同一个 assetId、换曲才变。
  assetId: string = '';
  revision: number = 0;
  artwork?: image.PixelMap;
  /// [artwork] 属于哪一首（= 解码那一刻的 assetId）。封面解码是异步的，
  /// 卡在 await 上的旧图可能在切歌之后才落地；带上归属后，写入面板前就能
  /// 拦住「上一首的封面 + 这一首的歌名」这种错配。
  artworkAssetId: string = '';
  /// 串行化 AVSession.setAVMetadata：异步回调（尤其失败后的 fallback）不能
  /// 把上一首的歌名写回到新歌上。
  writeChain: Promise<void> = Promise.resolve();
  /// 连续写入失败（超时 / 拒绝）计数。成功一次即清零；达到阈值触发会话
  /// 销毁重建自愈（见 recoverBrokenSession）。
  writeFailures: number = 0;
}

export function mfMetadata(): MfAvMetadata {
  let snapshot = AppStorage.get(MF_AV_METADATA_KEY) as MfAvMetadata | undefined;
  if (!snapshot) {
    snapshot = new MfAvMetadata();
    AppStorage.setOrCreate(MF_AV_METADATA_KEY, snapshot);
  }
  return snapshot;
}

/// 主通道统一入口：只写当前活跃实例，避免「主通道 handler 与 players 表不是
/// 同一份」时元数据丢失。返回 false 表示活跃实例尚未创建，由调用方兜底。
export function mfApplySystemMetadata(title?: string, artist?: string, artUri?: string,
  durationMs?: number, artwork?: Uint8Array, trackId?: string): boolean {
  const active = AppStorage.get(MF_ACTIVE_PLAYER_KEY) as MediaAvPlayer | undefined;
  if (active) {
    active.setSessionMetadata(title, artist, artUri, durationMs, artwork, trackId);
    return true;
  }
  return false;
}

const OPERATE_ERROR: number = 801;
const AVPLAYER_STATE_ERROR: number = 5400102;
const AVPLAYER_IO_ERROR: number = 5400103;

export enum AudioPlayerState {
  IDLE,
  INITIALIZED,
  LOAD,
  PREPARED,
  PLAY,
  PAUSE,
  STOP,
  ERROR,
  COMPLETED,
  RELEASED,
  PROGRESS_SPEED,
  TIME_UPDATE,
  VOLUME_CHANGE,
  UNKNOWN
}

export enum LoopMode {
  DEFAULT,
  SINGLE_CYCLE,
  LIST_LOOP
}

enum SeekMode {
  UNKNOWN,
  SEEK,
  FINISH
}

export enum PlaybackState {
  IDLE, STATE_READY, STATE_BUFFERING, STATE_ENDED
}

export interface onChangeMediaAvPlayerState {
  onPlaybackStateChanged(state: PlaybackState): void;

  onUpdateCurrentIndex(updateIndex: number): void;

  onUpdatePosition(updatePosition: number): void;

  onUpdateBufferedPosition(bufferedPosition: number): void;

  onAudioSessionIdChanged(audioSessionId: number): void;

  broadcastImmediatePlaybackEvent(): void;

  completeSeek(): void;

  completeInitial(): void;

  onStartBuffering(): void;

  onEndBuffering(): void;

  setAudioSessionId(audioSessionId: number): void

  onErrorCallback(err: BusinessError): void
}

export class MediaAvPlayer {
  private context: common.UIAbilityContext | undefined = AppStorage.get('context');
  public avPlayer: media.AVPlayer | null = null;
  public avPlayerNext: media.AVPlayer | null = null;
  public isPlaying: boolean = false;
  public songList: MediaSource[] = [];
  public state: AudioPlayerState = AudioPlayerState.IDLE;
  private session?: avSession.AVSession;
  private initialPos: number = -1;
  private initialIndex: number = -1;
  private volume: number = -1;
  private speed: number = 1;
  private seekModule: SeekMode = SeekMode.UNKNOWN;
  private playMode: LoopMode = LoopMode.DEFAULT;
  private isFirst: boolean = true;
  private isPrepared: boolean = false;
  private isClipping: boolean = false;
  private isPreBuffering: boolean = false;
  private isRandom: boolean = false;
  private musicIndex: number = 0;
  private preMusicIndex: number = 0;
  private songItem: MediaSource | null = null;
  private shuffleOrder: number[] = [];
  private avMetadataExtractor: media.AVMetadataExtractor | null = null;
  private avMetadata?: media.AVMetadata;
  public mediaAvPlayerStateChangeListener?: onChangeMediaAvPlayerState;
  // 播放策略
  private playStrategy: media.PlaybackStrategy = {
    //播放策略首选宽度，int类型，如1080。
    preferredWidth: 1,
    //播放策略首选高度，int类型，如1920。
    preferredHeight: 2,
    //播放策略首选缓冲持续时间，单位s，取值范围1-20。
    preferredBufferDuration: 1,
    //播放策略true是hdr，false非hdr，默认非hdr。
    preferredHdr: false
  };
  private seekIsFirst: number = -1
  private playMusicIndex: number = 0

  constructor() {
    // 后建的实例成为唯一「活跃」实例：旧实例的异步回调（prepared /
    // decodeArtwork / setAVMetadata 失败重试）不得再往锁屏写旧歌名。
    AppStorage.setOrCreate(MF_ACTIVE_PLAYER_KEY, this);
    this.initAudioPlayer();
  }

  /// 系统面板的 play/pause/next/previous 回调可能仍绑在旧实例上（AVSession
  /// 是全局共享的），统一转交给当前活跃实例，避免命令打到已释放的 AVPlayer。
  private activePlayer(): MediaAvPlayer {
    const active = AppStorage.get(MF_ACTIVE_PLAYER_KEY) as MediaAvPlayer | undefined;
    return active ?? this;
  }

  setMediaAvPlayerStateChange(listener: onChangeMediaAvPlayerState) {
    this.mediaAvPlayerStateChangeListener = listener
  }

  /**
   * 获取MediaAvPlayer实例
   * */
  public static getInstance(): MediaAvPlayer {
    let mediaAvPlayer: MediaAvPlayer | undefined = AppStorage.get('mediaService');
    if (!mediaAvPlayer) {
      mediaAvPlayer = new MediaAvPlayer();
      AppStorage.setOrCreate('mediaService', mediaAvPlayer);
    }
    return mediaAvPlayer;
  }

  private playCall: () => void = async () => {
    const target = this.activePlayer();
    if (target !== this) {
      target.playCall();
      return;
    }
    console.info(TAG, `on play , do play task`);
    if (this.isFirst) {
      await this.loadAssent(0);
    } else {
      this.play();
    }
  };
  private pauseCall: () => void = () => {
    const target = this.activePlayer();
    if (target !== this) {
      target.pauseCall();
      return;
    }
    console.info(TAG, `on pause , do pause task`);
    this.pause();
  };
  /// 返回 true 表示命令已转给 Dart，原生不必再用只有 1 首的 songList 切歌。
  private forwardSystemCommand(command: string): boolean {
    const forwarder = AppStorage.get(MF_MEDIA_COMMAND_KEY) as MfMediaCommandForwarder;
    if (forwarder !== undefined && forwarder !== null) {
      return forwarder.forward(command);
    }
    return false;
  }

  private playNextCall: () => void = () => {
    const forwarded = this.forwardSystemCommand('next');
    console.info(TAG, `on playNext: forwarded=${forwarded}, songList=${this.songList.length}`);
    if (forwarded) {
      return;
    }
    this.playNextAuto();
  };
  private playPreviousCall: () => void = () => {
    const forwarded = this.forwardSystemCommand('previous');
    console.info(TAG, `on playPrevious: forwarded=${forwarded}, songList=${this.songList.length}`);
    if (forwarded) {
      return;
    }
    this.playPrevious();
  };
  /**
   * 异常监听
   * */
  private errorCall: (err: BusinessError) => void = (err: BusinessError) => {
    if (err.code == OPERATE_ERROR || err.code == AVPLAYER_STATE_ERROR || err.code == AVPLAYER_IO_ERROR) {
      console.error(TAG, `AvPlayer Avoid Error Reporting: ${err}`);
      return;
    }
    console.error(TAG, `Invoke avPlayer failed, code is ${err.code}, message is ${err.message}`);
    this.loadAssent(this.musicIndex);
    this.mediaAvPlayerStateChangeListener?.onErrorCallback(err);
  };
  /**
   * 缓冲回调
   * */
  private bufferingUpdate: (infoType: media.BufferingInfoType, value: number) =>
  void = (infoType: media.BufferingInfoType, value: number) => {
    console.info(TAG, 'bufferingUpdate called,and infoType value is:' + infoType + ', value is :' + value);
    switch (infoType) {
      case media.BufferingInfoType.CACHED_DURATION:
        this.mediaAvPlayerStateChangeListener?.onUpdateBufferedPosition(value);
        break;
      case media.BufferingInfoType.BUFFERING_START:
        this.mediaAvPlayerStateChangeListener?.onStartBuffering();
        break;
      case media.BufferingInfoType.BUFFERING_PERCENT:
        if (value < 100) {
          this.mediaAvPlayerStateChangeListener?.onStartBuffering();
        } else if (this.seekModule != SeekMode.SEEK) {
          this.mediaAvPlayerStateChangeListener?.onEndBuffering();
        }
        break;
      case media.BufferingInfoType.BUFFERING_END:
        if (this.seekModule != SeekMode.SEEK) {
          this.mediaAvPlayerStateChangeListener?.onEndBuffering();
        }
        break;
    }
  }
  /**
   * 下一曲缓冲回调
   * */
  private bufferingUpdateNext: (infoType: media.BufferingInfoType, value: number) =>
  void = (infoType: media.BufferingInfoType, value: number) => {
    console.info(TAG, 'bufferingUpdateNext called,and infoType value is:' + infoType + ', value is :' + value);
  }
  /**
   * 监听资源播放当前时间，单位为毫秒（ms），用于刷新进度条当前位置，默认间隔100ms时间上报，因用户操作(seek)产生的时间变化会立刻上报
   * */
  private updateTimeCall: (updateTime: number) => void = (updateTime: number) => {
    if (this.volume != -1) {
      this.avPlayer?.setVolume(this.volume);
      this.volume = -1;
    }
    this.avPlayer?.setSpeed(this.speed);
    if (this.isClipping) {
      if (this.avPlayer && updateTime > 0 && this.getDuration() > 0 &&
        (this.songItem!.getEndUs() / 1000) < updateTime) {
        this.seek(this.playMode != LoopMode.SINGLE_CYCLE ? this.avPlayer.duration :
          (this.songItem!.getStartUs() / 1000));
      }
    }
  };
  /**
   * 进度条拖动回调,拖动松手后不会立刻回调,完成后回调
   * */
  private seekCall: (seekDoneTime: number) => void = async (seekDoneTime: number) => {
    this.mediaAvPlayerStateChangeListener?.completeSeek();
    this.seekModule = SeekMode.FINISH;
    if (this.state == AudioPlayerState.PREPARED || this.state == AudioPlayerState.PLAY ||
      this.state == AudioPlayerState.PAUSE || this.state == AudioPlayerState.COMPLETED) {
      this.playingState();
    }
    // seek 完成后同步给锁屏播控面板，否则面板进度停留在旧位置。
    // 换源时的初始 seek（未 prepared）不上报：此时参数不全，native 会拒绝（401）。
    if (this.isPrepared) {
      this.updateIsPlay(this.isPlaying);
    }
    console.info(TAG, `AVPlayer seek succeeded, seek time is ${seekDoneTime}`);
  };
  /**
   *订阅录制状态机AVRecorderState切换的事件，当 AVRecorderState状态机发生变化时，会通过订阅的回调方法通知用户。用户只能订阅一个状态机切换事件的回调方法，当用户重复订阅时，以最后一次订阅的回调接口为准
   * */
  private stateCall: (state: string) => Promise<void> = async (state: string) => {
    switch (state) {
      case 'idle':
        console.info(TAG, 'AVPlayer state idle called.');
        this.state = AudioPlayerState.IDLE;
        if (this.songList.length === 0) {
          break;
        }
        if (this.avPlayerNext == null) {
          this.offAVPlayerNextCallback();
          this.preMusicIndex = this.musicIndex + 1;
          let nextSong: MediaSource = this.songList[this.preMusicIndex];
          if (this.musicIndex == this.songList.length - 1) {
            if (this.playMode == LoopMode.LIST_LOOP) {
              this.preMusicIndex = 0;
              nextSong = this.songList[this.preMusicIndex];
            }
          }
          if (this.isRandom && this.shuffleOrder.length == this.songList.length) {
            let currentIndex = this.shuffleOrder.indexOf(this.musicIndex);
            if (currentIndex != -1) {
              if (currentIndex == this.shuffleOrder.length - 1) {
                this.preMusicIndex = this.shuffleOrder[0];
              } else {
                this.preMusicIndex = this.shuffleOrder[currentIndex+1];
              }
              nextSong = this.songList[this.preMusicIndex];
            }
          }
          if (nextSong) {
            media.createAVPlayer().then((value: media.AVPlayer) => {
              this.avPlayerNext = value;
              this.setAVPlayerNextCallback();
              let nextUrl = nextSong.getUri();
              if (nextUrl && this.avPlayerNext.state == "idle") {
                this.loadUri(this.avPlayerNext, nextUrl);
              }
            });
          }
        }
        break;
      case 'initialized':
        console.info(TAG, 'AVPlayer state initialized called.');
        this.state = AudioPlayerState.INITIALIZED;
        if (this.avPlayer) {
          this.avPlayer.prepare().then(() => {
            console.info(TAG, 'AVPlayer prepare succeeded.');
          }, (err: BusinessError) => {
            console.error(TAG, `Invoke prepare failed, code is ${err.code}, message is ${err.message}`);
          });
        }
        break;
      case 'prepared':
        this.state = AudioPlayerState.PREPARED;
        this.isPrepared = true
        console.info(TAG, 'AVPlayer prepared .');
        if (this.initialPos != -1 && this.initialIndex != -1 && this.initialIndex == this.musicIndex) {
          this.seek(this.initialPos);
          this.initialPos = -1;
          this.initialIndex = -1;
          this.mediaAvPlayerStateChangeListener?.completeInitial();
          this.mediaAvPlayerStateChangeListener?.onPlaybackStateChanged(PlaybackState.STATE_READY);
          break;
        }
        if (this.isClipping) {
          this.avPlayer?.seek(this.songItem!.getStartUs() / 1000);
          this.mediaAvPlayerStateChangeListener?.onPlaybackStateChanged(PlaybackState.STATE_BUFFERING);
          break;
        }
        if (this.playMusicIndex == this.musicIndex) {
          this.playingState();
        } else {
          this.songItem = this.songList[this.musicIndex];
          let url = this.songItem?.getUri();
          if (url && this.avPlayer?.state == "idle") {
            this.loadUri(this.avPlayer, url);
          }
        }
        // App 已通过 setMetadata 下发曲目信息时，忽略 fetchMetadata 的结果
        // —— 它在网络流上经常异步晚到且字段为空，会覆盖掉正确的标题。
        // 用全局快照判断，重建播放器后旧实例也不会拿上一首的提取结果回填。
        if (mfMetadata().title.length === 0) {
          this.avMetadata = await this.avMetadataExtractor?.fetchMetadata();
        }
        this.setAVMetadata();
        break;
      case 'playing':
        console.info(TAG, 'AVPlayer state playing called.');
        this.seekIsFirst = -1
        this.isPlaying = true;
        this.state = AudioPlayerState.PLAY;
        // 首次加载后的自动播放走不到 play() 的 isPrepared 分支，必须在这里
        // 把「正在播放 + 位置」上报给 AVSession，否则锁屏面板进度条不走。
        this.updateIsPlay(true);
        this.mediaAvPlayerStateChangeListener?.onEndBuffering();
        break;
      case 'paused':
        console.info(TAG, 'AVPlayer state paused called.');
        this.state = AudioPlayerState.PAUSE;
        break;
      case 'completed':
        console.info(TAG, 'AVPlayer state completed called.');
        this.state = AudioPlayerState.COMPLETED;
        if ((this.playMode == LoopMode.DEFAULT && this.musicIndex == this.songList.length - 1) ||
          this.songList.length == 0) {
          this.mediaAvPlayerStateChangeListener?.onPlaybackStateChanged(PlaybackState.STATE_ENDED);
        }
        this.playNextAuto();
        break;
      case 'stopped':
        console.info(TAG, 'AVPlayer state stopped called.');
        this.state = AudioPlayerState.STOP;
        break;
      case 'released':
        console.info(TAG, 'AVPlayer state released called.');
        this.state = AudioPlayerState.RELEASED;
        break;
      default:
        console.info(TAG, 'AVPlayer state unknown called.');
        this.state = AudioPlayerState.UNKNOWN;
        this.loadAssent(this.musicIndex)
        break;
    }
  };
  /**
   *订阅录制状态机AVRecorderState切换的事件，当 AVRecorderState状态机发生变化时，会通过订阅的回调方法通知用户。用户只能订阅一个状态机切换事件的回调方法，当用户重复订阅时，以最后一次订阅的回调接口为准
   * */
  private preStateCall: (state: string) => Promise<void> = async (state: string) => {
    switch (state) {
      case 'idle':
        console.info(TAG, 'avPlayerNext state idle called.');
        break;
      case 'initialized':
        console.info(TAG, 'avPlayerNext state initialized called.');
        this.avPlayerNext?.prepare().then(() => {
          console.info(TAG, 'avPlayerNext AVPlayer prepare succeeded.');
        }, (err: BusinessError) => {
          console.error(TAG, `avPlayerNext Invoke prepare failed, code is ${err.code}, message is ${err.message}`);
        });
        break;
      case 'prepared':
        if (this.isPreBuffering) {
          console.info(TAG, 'avPlayerNext state isPreBuffering ');
          this.isPreBuffering = false;
          this.playingState();
        }
        console.info(TAG, 'avPlayerNext state prepared ');
        break;
      case 'playing':
        console.info(TAG, 'avPlayerNext state playing called.');
        break;
      case 'paused':
        console.info(TAG, 'avPlayerNext state paused called.');
        break;
      case 'completed':
        console.info(TAG, 'avPlayerNext state completed called.');
        break;
      case 'stopped':
        console.info(TAG, 'avPlayerNext state stopped called.');
        break;
      case 'released':
        console.info(TAG, 'avPlayerNext state released called.');
        this.avPlayerNext = null;
        break;
      default:
        console.info(TAG, 'avPlayerNext state unknown called.');
        break;
    }
  };

  playingState() {
    if (this.isPlaying) {
      this.avPlayer?.play().then(() => {
        console.info(TAG, 'AVPlayer play succeeded.');
        this.mediaAvPlayerStateChangeListener?.onPlaybackStateChanged(PlaybackState.STATE_READY);
      }, (err: BusinessError) => {
        console.error(TAG, `Invoke play failed, code is ${err.code}, message is ${err.message}`);
      });
    } else if (this.avPlayer?.state == 'prepared' || this.avPlayer?.state == 'paused') {
      this.mediaAvPlayerStateChangeListener?.onPlaybackStateChanged(PlaybackState.STATE_READY);
    }
  }

  setAVPlayerNextCallback() {
    this.avPlayerNext?.on('stateChange', this.preStateCall);
    this.avPlayerNext?.on('bufferingUpdate', this.bufferingUpdateNext);
  }


  offAVPlayerNextCallback() {
    this.avPlayerNext?.off('stateChange', this.preStateCall);
    this.avPlayerNext?.off('bufferingUpdate', this.bufferingUpdateNext);
  }


  setListenerForMesFromController() {
    if (!this.session) {
      return;
    }
    // 只注册一次全局命令回调。绝不要在这里 off()：AVSession.off 会更新系统
    // 面板的 supported commands，多实例异步 createSession 时后注册的 off 会
    // 把前一个实例刚 on 的回调一起清掉，锁屏按钮就成了摆设。
    mfRegisterSessionCommands(this.session);
  }

  /// 转发器不可用时的原生兜底（普通 App 仍可用插件自带播放列表）。
  public handlePanelCommand(command: string): void {
    console.info(TAG, `native fallback command: ${command}`);
    switch (command) {
      case 'play':
        this.playCall();
        break;
      case 'pause':
        this.pauseCall();
        break;
      case 'next':
        this.playNextAuto();
        break;
      case 'previous':
        this.playPrevious();
        break;
      default:
        break;
    }
  }

  /// 用户最近一次 play/pause 表达的意图（恢复播放的唯一依据）。被打断期间
  /// 用户若在锁屏/App 内手动点了播放，这里也会变 true，焦点归还后自动续播。
  private wantPlaying: boolean = false;
  /// 中断时经锁屏命令通道让 Dart 暂停，那次 pause 会绕回原生 pause()——
  /// 置位此标记把它和「用户手动暂停」区分开，不能清掉 wantPlaying。
  private expectingForcedPause: boolean = false;
  /// 音频焦点当前是否被别的应用占用（微信视频、通话等）。
  private interrupted: boolean = false;

  /// 音频焦点中断（微信视频 / 通话抢焦点）：系统会把 AVPlayer 自动暂停并只
  /// 发 audioInterrupt 事件，而 just_audio 的 Dart 侧不接收原生播放事件——
  /// playing 状态永远停在「播放中」，App 显示播放中却没声音，手动暂停又因
  /// 原生已暂停而拿不到 result 回应、Dart 状态机卡死（2026-11-17 真机实测）。
  /// 处理：暂停方向把意图经锁屏命令通道转给 Dart（AppModel.systemPause），
  /// 让 Dart 状态 / AVSession / 锁屏面板三处同时落到暂停态；INTERRUPT_END
  /// 的 RESUME 提示到达时按 wantPlaying 自动恢复（同样走 Dart 单一状态源）。
  private audioInterruptCall: (event: audio.InterruptEvent) => void = (event: audio.InterruptEvent) => {
    const active = AppStorage.get(MF_ACTIVE_PLAYER_KEY) as MediaAvPlayer | undefined;
    if (active !== undefined && active !== this) {
      return;
    }
    mfLogInfo(`audioInterrupt: type=${event.eventType}, hint=${event.hintType}, wantPlaying=${this.wantPlaying}`);
    if (event.eventType === audio.InterruptType.INTERRUPT_TYPE_BEGIN) {
      if (event.hintType === audio.InterruptHint.INTERRUPT_HINT_PAUSE ||
        event.hintType === audio.InterruptHint.INTERRUPT_HINT_STOP) {
        this.interrupted = true;
        if (this.isPlaying) {
          this.isPlaying = false;
          // 部分系统版本只发事件不自动暂停，显式补一刀（已暂停则 no-op）。
          // 直接调 avPlayer，绕过 pause() 的意图标记逻辑。
          this.avPlayer?.pause().catch((e: BusinessError) => {
            mfLogError(`audioInterrupt pause failed: ${e.message}`);
          });
          this.updateIsPlay(false);
          this.expectingForcedPause = true;
          if (!this.forwardSystemCommand('pause')) {
            this.expectingForcedPause = false;
            mfLogError('audioInterrupt: forwarder missing, Dart state stays playing');
          }
        }
      }
      // DUCK / UNDUCK 只调音量，播放继续，不通知 Dart。
    } else if (event.eventType === audio.InterruptType.INTERRUPT_TYPE_END) {
      this.interrupted = false;
      if (event.hintType === audio.InterruptHint.INTERRUPT_HINT_RESUME && this.wantPlaying) {
        if (!this.forwardSystemCommand('play')) {
          mfLogError('audioInterrupt RESUME: forwarder missing, resume natively');
          this.play();
        }
      }
    }
  };

  /**
   * 为服务设置回调监听
   * */
  private setAVPlayerCallback() {
    if (!this.avPlayer) {
      return;
    }
    this.avPlayer.on('seekDone', this.seekCall);

    this.avPlayer.on('error', this.errorCall);

    this.avPlayer.on('timeUpdate', this.updateTimeCall);

    this.avPlayer.on('bufferingUpdate', this.bufferingUpdate);

    this.avPlayer.on('stateChange', this.stateCall);

    this.avPlayer.on('audioInterrupt', this.audioInterruptCall);

  }

  /**
   * 为服务注销回调监听
   * */
  private offAVPlayerCallback() {
    if (!this.avPlayer) {
      return;
    }
    this.avPlayer.off('seekDone', this.seekCall);

    this.avPlayer.off('error', this.errorCall);

    this.avPlayer.off('timeUpdate', this.updateTimeCall);

    this.avPlayer.off('bufferingUpdate', this.bufferingUpdate);

    this.avPlayer.off('stateChange', this.stateCall);

  }

  /**
   * Play previous music.
   */
  public async playPrevious() {


    switch (this.playMode) {
      case LoopMode.LIST_LOOP:
      case LoopMode.DEFAULT:
        if (this.isRandom) {
          this.playRandom();
          break;
        }
        if (this.musicIndex === 0) {
          this.updateMusicIndex(this.songList.length - 1);
        } else {
          this.updateMusicIndex(this.musicIndex - 1);
        }
        this.loadAssent(this.musicIndex);
        break;
      default:
        break;
    }
  }

  private updateMusicIndex(musicIndex: number) {
    this.mediaAvPlayerStateChangeListener?.onUpdateCurrentIndex(musicIndex)
    if (this.musicIndex !== musicIndex) {
      this.musicIndex = musicIndex;
    }
    this.setAVMetadata();
  }

  /// 曲目信息改成进程级全局快照（见 mfMetadata）。只存在实例字段时，重建
  /// AudioPlayer 后新会话读到的是 undefined/旧值，锁屏会显示上一首。
  private dartTitle?: string;
  private artworkToken: number = 0;

  public setSessionMetadata(title?: string, artist?: string, artUri?: string, durationMs?: number,
    artwork?: Uint8Array, trackId?: string) {
    const snapshot = mfMetadata();
    const nextTitle = title ?? '';
    const nextArtist = artist ?? '';
    // 与 setAVMetadata 用同一套规则，换曲判定才能对齐。
    const assetId = (trackId !== undefined && trackId.length > 0)
      ? trackId : `${nextTitle}|${nextArtist}`;
    const sameTrack = assetId.length > 0 && snapshot.assetId === assetId;
    snapshot.title = nextTitle;
    snapshot.artist = nextArtist;
    snapshot.artUri = artUri ?? '';
    snapshot.durationMs = durationMs ?? 0;
    // 同一首歌的所有推送（含封面补推、播放开始后的重推）共用一个 assetId。
    snapshot.assetId = assetId;
    snapshot.revision++;
    this.dartTitle = snapshot.title;
    this.artworkToken++;
    if (artwork && artwork.length > 0) {
      this.decodeArtwork(artwork, this.artworkToken, assetId);
    } else if (!sameTrack) {
      // 切歌时 App 会先推一次不带封面的元数据，先撤掉上一首的图避免串台。
      // 同一首歌的重推（封面还在路上）不能清空已经解好的图，否则面板会闪
      // 回可能取不到的 artUri。
      this.releaseArtwork();
    }
    mfLogInfo(`setSessionMetadata: title=${nextTitle}, artist=${nextArtist}, assetId=${assetId}, artworkBytes=${artwork ? artwork.length : 0}`);
    // 会话尚未就绪也要走一遍：全局快照已更新，createSession 完成后会补写。
    this.setAVMetadata();
  }

  private async releaseArtwork() {
    const snapshot = mfMetadata();
    const old = snapshot.artwork;
    snapshot.artwork = undefined;
    snapshot.artworkAssetId = '';
    if (old) {
      try {
        await old.release();
      } catch (error) {
        console.error(TAG, `release artwork failed: ${JSON.stringify(error)}`);
      }
    }
  }

  /// 这张封面此刻还该不该写进锁屏。解码 / 释放都要 await，每次 await 之后
  /// 现场都可能已经换了曲目甚至换了播放器实例，必须重新校验：
  /// 1. 当前仍是活跃实例（热重启 / 重新登录会造出第二个 MediaAvPlayer）；
  /// 2. 期间没有新的推送（artworkToken 变了说明已被覆盖）；
  /// 3. 全局快照的 assetId 仍是这张封面所属的曲目。
  /// 只做第一道校验时，慢一拍的旧封面会落进新歌的快照，锁屏就出现
  /// 「封面是上一首、歌名是这一首」——正是那个「偶发、无法稳定复现」的错配。
  private artworkStillWanted(token: number, assetId: string): boolean {
    const active = AppStorage.get(MF_ACTIVE_PLAYER_KEY) as MediaAvPlayer | undefined;
    if (active !== undefined && active !== this) {
      return false;
    }
    if (token !== this.artworkToken) {
      return false;
    }
    if (assetId.length > 0 && mfMetadata().assetId !== assetId) {
      return false;
    }
    return true;
  }

  private async decodeArtwork(bytes: Uint8Array, token: number, assetId: string) {
    try {
      // codec 传来的 Uint8Array 可能是共享缓冲区的一个视图，拷成独立的
      // ArrayBuffer 再交给 ImageKit，避免把多余的字节当成图片内容。
      const buffer = bytes.slice().buffer as ArrayBuffer;
      const source = image.createImageSource(buffer);
      // 锁屏面板用不到原图，缩到 512 限制跨进程传递的像素数据大小。
      let options: image.DecodingOptions = {
        desiredSize: { width: 512, height: 512 },
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888,
      };
      const pixelMap = await source.createPixelMap(options);
      // ImageSource 由内存缓冲区创建，不持有 fd，交给 GC 回收即可。
      if (!this.artworkStillWanted(token, assetId)) {
        await pixelMap.release();
        return;
      }
      // releaseArtwork 也是异步的：清旧图期间用户照样能切歌，落地前再验一次。
      await this.releaseArtwork();
      if (!this.artworkStillWanted(token, assetId)) {
        await pixelMap.release();
        return;
      }
      const snapshot = mfMetadata();
      snapshot.artwork = pixelMap;
      snapshot.artworkAssetId = assetId;
      snapshot.revision++;
      this.setAVMetadata();
    } catch (error) {
      mfLogError(`decode artwork failed: ${JSON.stringify(error)}`);
    }
  }

  async setAVMetadata() {
    // 只有当前活跃实例能写锁屏。旧实例的 prepared / updateMusicIndex /
    // decodeArtwork / 失败重试等异步回调可能晚到，会把上一首 B 写回到新歌 A 上。
    const active = AppStorage.get(MF_ACTIVE_PLAYER_KEY) as MediaAvPlayer | undefined;
    if (active !== undefined && active !== this) {
      return;
    }
    const session = this.session;
    if (!session) {
      // 会话不在（尚未建好 / 建会话失败 / AppStorage 缓存被框架清空后旧会话
      // 占坑）。快照已保存；主动尝试拿回会话——mfSharedSession 内部有缓存与
      // 重试去重，并发调用安全。成功后 createSession 回头补写当前曲目。
      this.createSession();
      return;
    }
    const snapshot = mfMetadata();
    const revision = snapshot.revision;
    try {
      // 注意：mediaImage 传 undefined 会触发 setAVMetadata 401
      // "get metaData failed"（整次设置被拒，锁屏面板就一直是空的），
      // 所以所有字段都必须落到确定的 string/number 或 PixelMap。
      let title = snapshot.title.length > 0 ? snapshot.title : (this.avMetadata?.title ?? "未知");
      let artist = snapshot.artist.length > 0 ? snapshot.artist : (this.avMetadata?.artist ?? "未知");
      let duration = snapshot.durationMs > 0 ? snapshot.durationMs : Math.max(0, this.getDuration());
      // 优先用 App 解码好的 PixelMap；没有时才退回 URL（普通局域网服务器
      // 的封面不需要鉴权，系统自己就能取到）。空串是合法兜底值。
      // 封面必须属于当前这首：解码是异步的，别的曲目的图绝不能借用。
      const artwork = (snapshot.artwork !== undefined &&
        (snapshot.artworkAssetId.length === 0 || snapshot.artworkAssetId === snapshot.assetId))
        ? snapshot.artwork : undefined;
      let mediaImage: string | image.PixelMap = snapshot.artUri;
      if (artwork) {
        mediaImage = artwork;
      }
      // assetId 按曲目固定：同曲多次推送（封面、播放开始后重推）不改标识，
      // 换曲才变。以前每次推送都用 mf-${revision}，系统在锁屏卡片上可能一直
      // 绑定第一次创建的那个媒体项，后面写进去的新歌名根本不显示。
      const assetId = snapshot.assetId.length > 0 ? snapshot.assetId : `mf-${title}|${artist}`;
      mfLogInfo(
        `setAVMetadata: rev=${revision}, final=${title}, assetId=${assetId}, hasArtwork=${artwork !== undefined}`);
      let metadata: avSession.AVMetadata = {
        assetId: assetId,
        title: title,
        artist: artist,
        mediaImage: mediaImage,
        duration: duration
      };
      let fallback: avSession.AVMetadata = {
        assetId: assetId,
        title: title,
        artist: artist,
        mediaImage: "",
        duration: duration
      };
      // 全局串行：异步写入和失败后的 fallback 都不能乱序覆盖更新的曲目。
      // 链上每个 await 都必须限时：一次挂死的系统调用会把整条链永久堵住
      // （2026-11-17 真机：锁屏冻结在上一首，之后所有切歌推送全部失效）。
      snapshot.writeChain = snapshot.writeChain.then(async () => {
        if (mfMetadata().revision !== revision) {
          return;
        }
        try {
          await mfAwaitWithTimeout('setAVMetadata', session.setAVMetadata(metadata));
          mfMetadata().writeFailures = 0;
          mfLogInfo(`SetAVMetadata successfully rev=${revision}`);
          // 只写元数据时，系统面板（尤其锁屏 / 息屏后）可能仍渲染旧卡片：
          // 会话被系统降级后会静默接受 setAVMetadata，但 UI 不刷新。重新
          // activate 即可让它成为前台会话。播放状态不要在这里补推 —— 切歌
          // 瞬间 AVPlayer 还在 idle/preparing，带 position/speed 的 state 会
          // 被 native 判 401「state not valid」，反而让卡片短暂停在旧歌；
          // stateCall/play/pause/seek 本来就会在真正开始播放时上报。
          try {
            await mfAwaitWithTimeout('activate', session.activate());
          } catch (stateError) {
            // activate 失败不影响元数据已写入，卡片内容是对的。
            mfLogError(`refresh panel state failed: ${JSON.stringify(stateError)}`);
          }
        } catch (error) {
          if (mfMetadata().revision !== revision) {
            return;
          }
          mfLogError(mfSessionErrorDetail(`SetAVMetadata failed rev=${revision}`, error));
          // 图片被系统拒绝时再退一次不带封面的版本，至少让歌名/歌手/时长
          // 出现在锁屏面板上，而不是整个 setAVMetadata 都失败。
          try {
            await mfAwaitWithTimeout('setAVMetadata fallback', session.setAVMetadata(fallback));
            mfMetadata().writeFailures = 0;
          } catch (retryError) {
            mfLogError(mfSessionErrorDetail('SetAVMetadata fallback failed', retryError));
            mfMetadata().writeFailures++;
            await this.recoverBrokenSession();
          }
        }
      });
    } catch (error) {
      mfLogError(`setAVMetadata prepare failed: ${JSON.stringify(error)}`);
    }
  }

  /// 会话写入连续失败（超时挂起或直接拒绝）时的自愈：销毁旧代理、清掉全局
  /// 缓存的 createAVSession Promise、重新建会话并补写当前曲目。系统限制一个
  /// ability 只能有一个 AVSession，旧代理 destroy 失败时重建会失败——那也比
  /// 把写入链永久堵死强，下一次推送还会再试。
  private async recoverBrokenSession(): Promise<void> {
    const snapshot = mfMetadata();
    if (snapshot.writeFailures < 3) {
      return;
    }
    snapshot.writeFailures = 0;
    mfLogError('AVSession writes keep failing, rebuilding session');
    const old = this.session;
    this.session = undefined;
    if (old) {
      try {
        await mfAwaitWithTimeout('destroy session', old.destroy());
      } catch (error) {
        mfLogError(mfSessionErrorDetail('destroy stale session failed', error));
      }
    }
    mfInvalidateSharedSession();
    await this.createSession();
    this.setAVMetadata();
  }

  public getDuration() {
    if (this.isPrepared && this.avPlayer) {
      if (this.isClipping && this.songItem) {
        let duration = this.songItem.getEndUs() - this.songItem.getStartUs();
        return duration / 1000;
      }
      return this.avPlayer.duration;
    }
    return 0;
  }

  public setLoopMode(loopMode: number) {
    this.playMode = loopMode;
  }

  public setShuffleMode(isShuffle: boolean) {
    this.isRandom = isShuffle;
  }

  public setVolume(volume: number) {
    this.volume = volume
    this.avPlayer?.setVolume(volume);
  }

  public setSpeed(speed: number) {
    if (speed > 0 && speed <= 0.125) {
      //x0.125
      this.speed = media.PlaybackSpeed.SPEED_FORWARD_0_125_X;
    } else if (speed > 0.125 && speed <= 0.4) {
      //x0.25
      this.speed = media.PlaybackSpeed.SPEED_FORWARD_0_25_X;
    } else if (speed > 0.4 && speed <= 0.6) {
      //x0.5
      this.speed = media.PlaybackSpeed.SPEED_FORWARD_0_50_X;
    } else if (speed > 0.6 && speed <= 0.8) {
      //x0.75
      this.speed = media.PlaybackSpeed.SPEED_FORWARD_0_75_X;
    } else if (speed > 0.8 && speed <= 1.1) {
      //x1
      this.speed = media.PlaybackSpeed.SPEED_FORWARD_1_00_X;
    } else if (speed > 1.1 && speed <= 1.4) {
      //x1.25
      this.speed = media.PlaybackSpeed.SPEED_FORWARD_1_25_X;
    } else if (speed > 1.4 && speed <= 1.6) {
      //x1.5
      this.speed = media.PlaybackSpeed.SPEED_FORWARD_1_50_X;
    } else if (speed > 1.6 && speed <= 1.8) {
      //x1.75
      this.speed = media.PlaybackSpeed.SPEED_FORWARD_1_75_X;
    } else if (speed > 1.8 && speed <= 2.0) {
      //x2.0
      this.speed = media.PlaybackSpeed.SPEED_FORWARD_2_00_X;
    } else if (speed > 2.0) {
      //由于2.0~3.0中间没有枚举速率,并且速率最大值为3.0,,所以大于2.0的速率都将映射到3.0x速度
      this.speed = media.PlaybackSpeed.SPEED_FORWARD_3_00_X;
    }
    this.avPlayer?.setSpeed(this.speed);
  }

  /**
   * 初始化音频播放器
   * */
  async initAudioPlayer() {
    if (!this.avPlayer) {
      this.avPlayer = await media.createAVPlayer();
    }
    this.avMetadataExtractor = await media.createAVMetadataExtractor();
    this.setAVPlayerCallback();
    this.createSession();
  }

  async createSession() {
    if (!this.context || this.session) {
      return;
    }
    try {
      // 全局共享一个 AVSession：每个新实例都 createAVSession 时，系统里会
      // 留下多个会话 / 多个命令回调，锁屏可能一直显示最老那张卡片的歌名。
      this.session = await mfSharedSession(this.context);
    } catch (error) {
      mfLogError(mfSessionErrorDetail('createSession failed', error));
      return;
    }
    // 会话可能晚于 Dart 的第一次 setMetadata 才就绪，这里用全局快照补写一次。
    this.setAVMetadata();
    let wantAgentInfo: wantAgent.WantAgentInfo = {
      wants: [
        {
          bundleName: this.context.abilityInfo.bundleName,
          abilityName: this.context.abilityInfo.name
        }
      ],
      requestCode: 0,
      wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    }
    wantAgent.getWantAgent(wantAgentInfo).then((agent) => {
      if (this.session) {
        this.session.setLaunchAbility(agent);
      }
    })
    this.mediaAvPlayerStateChangeListener?.setAudioSessionId(parseInt(this.session.sessionId))
    this.setListenerForMesFromController();
  }

  /**
   * Play music.
   */
  public async play(result?: MethodResult) {
    this.wantPlaying = true;
    this.isPlaying = true;
    if (!this.isPrepared) {
      this.start(0);
    } else if (this.avPlayer) {
      this.avPlayer.play().then(() => {
        this.updateIsPlay(true);
        this.state = AudioPlayerState.PLAY;
        result?.success(new Map<String, Object>());
      }).catch((e: BusinessError) => {
        // 被打断（微信视频等抢焦点）时 play 会失败：回退乐观标记并如实上报
        // 锁屏，等 INTERRUPT_END 的 RESUME 提示再自动恢复。之前这里只回错误，
        // isPlaying 停留在 true，锁屏一直显示播放中。
        this.isPlaying = false;
        this.updateIsPlay(false);
        result?.error(e.code.toString(), e.message, e.data);
        mfLogError(`play::error: ${e.message}`);
      });
    }
  }

  /**
   * Pause music.
   */
  public pause(result?: MethodResult) {
    if (this.expectingForcedPause) {
      // 音频焦点中断触发的强制暂停：不改用户意图，RESUME 后还要自动续播。
      this.expectingForcedPause = false;
    } else {
      this.wantPlaying = false;
    }
    if (this.isPlaying && this.avPlayer) {
      this.isPlaying = false;
      this.avPlayer.pause().then(() => {
        this.state = AudioPlayerState.PAUSE;
        this.updateIsPlay(false);
      }).catch((e: BusinessError) => {
        mfLogError(`pause::error: ${e.message}`);
      });
    }
    // 无论是否真的暂停了都要回应：原生已暂停（被打断）时跳过 avPlayer.pause()
    // 的话，旧实现不回 result，Dart 侧 pause future 永远挂起、状态机卡死。
    result?.success(new Map<String, Object>());
  }

  /**
   * Play next music.
   *
   * @param isFromControl
   */
  public async playNextAuto() {


    switch (this.playMode) {
      case LoopMode.SINGLE_CYCLE:
        if (this.avPlayer) {
          this.avPlayer.loop = true;
          this.loadAssent(this.musicIndex);
        }
        break;
      case LoopMode.LIST_LOOP:
      case LoopMode.DEFAULT:
        if (this.avPlayer) {
          this.avPlayer.loop = false;
        }
        if (this.isRandom) {
          this.playRandom();
        } else {
          this.playNext();
        }
        break;
      default:
        break;
    }
  }

  /**
   * Play music by index.
   *
   * @param musicIndex
   */
  async loadAssent(musicIndex: number) {
    if (this.seekModule == SeekMode.SEEK) {
      this.seekModule = SeekMode.UNKNOWN;
    }
    if (musicIndex >= this.songList.length) {
      musicIndex = this.songList.length - 1;
      console.error(TAG, `current musicIndex ${musicIndex}`);
      return;
    }
    this.mediaAvPlayerStateChangeListener?.onPlaybackStateChanged(PlaybackState.STATE_BUFFERING);
    this.mediaAvPlayerStateChangeListener?.onUpdateBufferedPosition(0);
    this.songItem = this.songList[musicIndex];
    this.isClipping = this.songItem.type == "clipping";
    this.updateMusicIndex(musicIndex);
    console.info(TAG, `MF loadAssent: index=${musicIndex} isFirst=${this.isFirst} preIndex=${this.preMusicIndex} hasNext=${!!this.avPlayerNext} avState=${this.avPlayer?.state} uri=${this.songItem?.getUri()}`);
    if (this.avPlayerNext && this.preMusicIndex == musicIndex && !this.isFirst) {
      this.offAVPlayerCallback();
      this.avPlayer?.release();
      this.avPlayer = this.avPlayerNext;
      this.setAVPlayerCallback();
      if (this.avPlayerNext.state == 'prepared') {
        this.playingState();
      } else {
        this.isPreBuffering = true;
      }
      this.avPlayerNext = null;
    } else {
      if (this.avPlayer) {
        this.offAVPlayerNextCallback()
        this.avPlayerNext?.release();
        this.avPlayerNext = null;
        if (this.isFirst) {
          this.isFirst = false;
        } else {
          await this.avPlayer.reset();
          this.playMusicIndex = musicIndex;
        }
        let url = this.songItem?.getUri();
        if (url && this.avPlayer.state == "idle") {
          this.loadUri(this.avPlayer, url);
        }
      }
    }
  }

  dispose() {
    this.avPlayer?.release();
    this.avPlayerNext?.release();
    this.avMetadataExtractor?.release();
    this.avMetadataExtractor = null;
    this.avPlayerNext = null;
    this.avPlayer = null;
  }

  private playNext() {
    if (this.musicIndex === this.songList.length - 1) {
      if (this.playMode == LoopMode.LIST_LOOP) {
        this.loadAssent(0);
      }
    } else {
      this.loadAssent(this.musicIndex + 1);
    }
  }

  private playRandom() {
    // 歌曲列表只有1首时跳过随机播放逻辑
    if (this.songList.length <= 1) {
      return;
    }
    if (this.shuffleOrder.length == 0) {
      // 本地生成洗牌序列，避免 Math.random() 无记忆导致重复
      this.shuffleOrder = this.generateShuffleOrder();
    }
    let orderIndex = this.shuffleOrder.indexOf(this.musicIndex);
    let num = orderIndex == this.shuffleOrder.length - 1 ? 0 : orderIndex + 1;
    this.updateMusicIndex(this.shuffleOrder[num]);
    this.loadAssent(this.shuffleOrder[num]);
  }

  /**
   * 生成 Fisher-Yates 洗牌序列，确保一轮内每首歌只播放一次，避免 Math.random() 无记忆导致的重复播放问题。
   * @returns 打乱后的歌曲索引数组
   */
  private generateShuffleOrder(): number[] {
    // 初始化顺序索引 [0, 1, 2, ..., N-1]
    let order: number[] = [];
    for (let i = 0; i < this.songList.length; i++) {
      order.push(i);
    }
    // Fisher-Yates 洗牌算法：从末尾向前遍历，随机交换当前位置与之前某个位置的元素
    for (let i = order.length - 1; i > 0; i--) {
      let j = Math.floor(Math.random() * (i + 1));
      let temp = order[i];
      order[i] = order[j];
      order[j] = temp;
    }
    return order;
  }

  /**
   * Seek play music.
   *
   * @param ms.
   */
  public async seek(ms: number, index?: number) {

    this.mediaAvPlayerStateChangeListener?.onStartBuffering();
    if (ms == this.avPlayer?.duration) {
      if (this.isRandom) {
        this.playRandom();
      } else if (this.playMode == LoopMode.LIST_LOOP) {
        this.playNext()
      } else {
        this.avPlayer.seek(this.avPlayer?.duration);
      }
      return;
    }

    let seekMode = this.getCurrentTime() < ms ? 0 : 1;
    if (this.isClipping) {
      ms = this.songItem!.getStartUs() / 1000 + ms;
    }
    let realTime = ms <= 0 ? 0 : ms;
    if (index || index == 0 && this.musicIndex != index) {
      this.avPlayer?.reset();
      this.loadAssent(index);
    } else {
      if ((this.state == AudioPlayerState.PREPARED || this.state == AudioPlayerState.PLAY ||
        this.state == AudioPlayerState.COMPLETED || this.state == AudioPlayerState.PAUSE) && this.avPlayer) {
        this.seekModule = SeekMode.SEEK;
        this.avPlayer.seek(realTime, seekMode);
      }
    }
  }

  private async loadUri(avPlayer: media.AVPlayer, uri: string) {
    console.info(TAG, `MF loadUri: uri=${uri} avState=${avPlayer.state}`);
    if (uri?.startsWith('http')) {
      let headers: Record<string, string> = { "User-Agent": "User-Agent-Value" };
      if (this.songItem?.getHeader()) {
        headers = this.songItem?.getHeader() as Record<string, string>
      }
      let mediaSource: media.MediaSource = media.createMediaSourceWithUrl(uri, headers);
      avPlayer.setMediaSource(mediaSource, this.playStrategy);
    } else if (uri?.startsWith('file')) {
      if (this.context) {
        const dartFilePrefix = 'file:///';
        if (uri.startsWith(dartFilePrefix)) {
          uri = uri.slice(dartFilePrefix.length);
        }
        let fd: number = fileIo.openSync(uri).fd;
        let fileSize: number = fileIo.statSync(uri).size;
        let src: media.AVDataSrcDescriptor = {
          fileSize: fileSize,
          callback: (buf: ArrayBuffer, length: number, pos: number | undefined) => {
            let num = 0;
            if (buf == undefined || length == undefined || pos == undefined) {
              return -1;
            }
            num = fileIo.readSync(fd, buf, { offset: pos, length: length });
            if (num > 0 && (fileSize >= pos)) {
              return num;
            }
            return -1;
          }
        }
        src.fileSize = fileSize;
        avPlayer.dataSrc = src;
        if (this.avMetadataExtractor) {
          this.avMetadataExtractor.dataSrc = src;
        }
      }
    } else {
      if (this.context) {
        let fileDescriptor = await getContext(this).resourceManager.getRawFd(avPlayer.url)
          .catch((error: BusinessError) => {
            console.error(`resourceManager error code ${error.code} message ${error.message}`);
          });
        if (fileDescriptor) {
          let avFileDescriptor: media.AVFileDescriptor =
            { fd: fileDescriptor.fd, offset: fileDescriptor.offset, length: fileDescriptor.length };
          if (this.avMetadataExtractor) {
            this.avMetadataExtractor.fdSrc = avFileDescriptor;
          }
          avPlayer.fdSrc = avFileDescriptor;
        }
      }
    }
  }

  public addPublicMediaSources(index: number, mediaSources: Array<MediaSource>) {
    if (mediaSources.length === 0) {
      return;
    }
    let insertIndex = index >= 0 ? index : this.songList.length;
    if (insertIndex > this.songList.length) {
      insertIndex = this.songList.length;
    }
    const wasEmpty = this.songList.length === 0;
    if (!wasEmpty && insertIndex <= this.musicIndex) {
      this.updateMusicIndex(this.musicIndex + mediaSources.length);
    }
    const before = this.songList.slice(0, insertIndex);
    const after = this.songList.slice(insertIndex);
    this.songList = before.concat(mediaSources, after);
    if (this.avPlayerNext != null && !wasEmpty) {
      this.offAVPlayerNextCallback();
      this.avPlayerNext.release();
      this.avPlayerNext = null;
      this.preMusicIndex = -1;
    }
    if (wasEmpty && this.avPlayer?.state == 'idle') {
      this.isFirst = true;
      this.loadAssent(0);
    }
  }

  public async removeMediaSourceRange(startIndex: number, endIndex: number) {
    if (startIndex < 0 || endIndex > this.songList.length || startIndex >= endIndex) {
      const message =
        `Invalid removeMediaSourceRange parameters: startIndex=${startIndex}, endIndex=${endIndex}, listLength=${this.songList.length}`;
      Log.e(TAG, message);
      throw new Error(message);
    }
    const deleteCount = endIndex - startIndex;
    this.songList.splice(startIndex, deleteCount);
    this.adjustPreMusicIndexAfterRemove(startIndex, endIndex);
    if (this.songList.length > 0) {
      if (this.musicIndex >= startIndex && this.musicIndex < endIndex) {
        await this.loadAssent(Math.min(startIndex, this.songList.length - 1));
      }
      this.updateCurrentIndex();
    } else {
      this.invalidateAvPlayerNext();
      this.isPlaying = false;
      this.isPrepared = false;
      this.songItem = null;
      this.musicIndex = 0;
      this.mediaAvPlayerStateChangeListener?.onUpdateCurrentIndex(0);
      this.mediaAvPlayerStateChangeListener?.onPlaybackStateChanged(PlaybackState.STATE_ENDED);
    }
  }

  public moveMediaSource(currentIndex: number, newIndex: number) {
    let moveItem = this.songList.splice(currentIndex, 1);
    this.songList.splice(newIndex, 0, moveItem[0]);
    this.updateCurrentIndex();
  }

  private updateCurrentIndex() {
    let index = this.songList.indexOf(this.songItem!);
    if (index != -1) {
      this.musicIndex = index;
      this.mediaAvPlayerStateChangeListener?.onUpdateCurrentIndex(index);
    }
  }

  private invalidateAvPlayerNext(): void {
    if (this.avPlayerNext != null) {
      this.offAVPlayerNextCallback();
      this.avPlayerNext.release();
      this.avPlayerNext = null;
    }
    this.preMusicIndex = -1;
  }

  /**
   * splice 删除后同步预缓冲索引：删除范围内则释放 avPlayerNext，否则按删除数量前移索引。
   */
  private adjustPreMusicIndexAfterRemove(startIndex: number, endIndex: number): void {
    if (this.preMusicIndex < 0) {
      return;
    }
    if (this.preMusicIndex >= startIndex && this.preMusicIndex < endIndex) {
      this.invalidateAvPlayerNext();
    } else if (this.preMusicIndex >= endIndex) {
      this.preMusicIndex -= (endIndex - startIndex);
    }
  }

  public setShuffleOrder(shuffleOrder: number[]) {
    this.shuffleOrder = shuffleOrder;
  }

  private getChildList(playList: MediaSource[]): MediaSource[] {
    if (playList.length == 1 && playList[0].getType() === 'concatenating') {
      return this.getChildList(playList[0].getChildMediaSource());
    }
    return playList;
  }

  public async load(mediaSource: MediaSource, currentIndex: number, seekPostion: number = 0) {
    this.initialPos = seekPostion ?? -1;
    if (this.initialPos != -1) {
      this.initialIndex = currentIndex
    }
    if (this.playMode != LoopMode.DEFAULT) {
      mediaSource.setMusicPlayMode(this.playMode);
    }
    let mSource: media.MediaSource;
    let mediaType = mediaSource.getType();
    console.info(TAG, `MF load: type=${mediaType} index=${currentIndex} uri=${mediaSource.getUri()} hasHeader=${!!mediaSource.getHeader()} avState=${this.avPlayer?.state}`);
    if (mediaType == "concatenating") {
      this.songList = this.getChildList(mediaSource.getChildMediaSource())
      this.playMode = mediaSource.getMusicPlayMode();
      this.setShuffleOrder(mediaSource.shuffleOrder);
      this.loadAssent(currentIndex);
    } else {
      this.songList = [mediaSource];
      if (mediaType == "clipping") {
        this.loadAssent(currentIndex);
      } else if (mediaSource.getHeader()) {
        mSource = media.createMediaSourceWithUrl(mediaSource.getUri(), mediaSource.getHeader());
        await this.avPlayer?.setMediaSource(mSource, this.playStrategy);
        await this.avPlayer?.prepare();
      } else {
        this.loadAssent(currentIndex)
      }
    }
  }

  public stop() {
    this.avPlayer?.stop();
  }

  private start(seekMs?: number) {
    if (this.avPlayer) {
      this.avPlayer.prepare().then(() => {
      }).catch((error: BusinessError) => {
        console.error(TAG, `start error ${JSON.stringify(error)}`);
        this.state = AudioPlayerState.ERROR;
        this.updateIsPlay(false);
        this.isPrepared = false;
      });
    }
  }

  private updateIsPlay(display: boolean) {
    // speed 是锁屏面板外推进度条的依据：不带 speed 视为倍速 0，进度条永远不动。
    const extras = mfPlaybackExtras();
    this.setPlayState({
      state: display ? avSession.PlaybackState.PLAYBACK_STATE_PLAY : avSession.PlaybackState.PLAYBACK_STATE_PAUSE,
      speed: display ? this.speed : 0,
      position: {
        elapsedTime: this.getCurrentTime(),
        updateTime: new Date().getTime()
      },
      // 按钮图标状态：循环模式与收藏。应用内切模式 / 收藏后由 Dart 同步进来。
      // 字段名以官方 @ohos.multimedia.avsession 的 AVPlaybackState 为准：
      // loopMode?: LoopMode、isFavorite?: boolean（不是 favorite）。
      loopMode: mfAvLoopMode(extras.playModeIndex),
      isFavorite: extras.favorite,
    });
  }

  /// Dart 同步 loopMode/favorite 后立刻重推一次 AVPlaybackState，让锁屏图标
  /// 马上反映新状态，不必等下一次播放/暂停事件。
  public syncPlaybackState(): void {
    this.updateIsPlay(this.isPlaying);
  }

  public getCurrentTime() {
    if (this.isPrepared && this.avPlayer) {
      if (this.isClipping) {
        return this.avPlayer.currentTime - (this.songItem!.getStartUs() / 1000);
      }
      if (this.initialPos != -1 && this.initialPos != 0) {
        this.seekIsFirst = this.initialPos
      }
      if (this.seekIsFirst != -1) {
        return this.seekIsFirst
      } else {
        return this.avPlayer.currentTime;
      }

    }
    return 0;
  }

  private setPlayState(playbackState: avSession.AVPlaybackState) {
    if (this.session) {
      this.session.setAVPlaybackState(playbackState, (err: BusinessError) => {
        if (err) {
          console.error(TAG, `SetAVPlaybackState BusinessError: code: ${err.code}, message: ${err.message}`);
        } else {
          console.info(TAG, 'SetAVPlaybackState successfully');
        }
      });
    }
  }
}
