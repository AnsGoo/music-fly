# MusicFly（乐记）项目约定

Flutter App 在 `flutter_app/`，后端 `~/Documents/code/music-free/backend`（Go/Gin，localhost:14533，admin/admin，用户自己启动）。

## 工作流偏好

- **不要每次改动后打包 DMG/APK**：用户在 VS Code 里 launch 调试（支持热重载）。验证 = `flutter analyze` + `flutter test`，必须绕代理：`env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy -u ALL_PROXY NO_PROXY=127.0.0.1,localhost ~/development/flutter/bin/flutter test`。只在用户明确要安装包时跑 `scripts/package_*.sh` / `flutter build apk`。
- Flutter SDK：macOS `~/development/flutter`；Windows `D:\flutter`（不在 PATH），VS 2022 C++ 工具链已装。
- 视觉验证用临时 golden 渲染（Arial Unicode + RepaintBoundary.toImage），核对后删测试文件；沙箱无 screencapture 权限。
- **界面提示要少**：登录页一次只显示一条状态条（error 优先于 relogin notice）；长文本必须 `maxLines` + `ellipsis`；说明文字用 `Mf.muted` 不用 `Mf.faint`；重登第二步隐藏「已连接」摘要。
- **播放/暂停一律 34dp 纯图标按钮**（`MfPlayButton`，22dp glyph），不要「图标+文字」胶囊；桌面播放条与投屏遥控面板共用，遥控控制行是 `CastTransportControls`。
- 品牌色保留暖黑 + 朱红，不用技能推荐的深蓝/绿；触控区只放大移动端，桌面 34dp 不变。

## 关键技术事实

- Subsonic 认证必须 token（md5(password+salt)），`p=` 会被后端拒（code 50）。
- 流播放：只有 wma/ape 等系统解不了的格式走 `format=mp3` 转码（chunked、无 Range、无时长），其余直传（206 + Content-Length，才有进度条拖动与真实时长）。**此规则只管本机播放，投屏另有一套**。`needsTranscode` 不要拿来判投屏。
- **DLNA 投屏**：`dart_cast` 的 DIDL 硬编码成 `videoItem`，电视会报「播放器异常」→ `AudioDlnaSession` 自建 `musicTrack` DIDL（`dc:creator` + `upnp:artist role=Performer` + `upnp:album` + 两条 albumArtURI，XML 双重转义）。URL 由 `castStreamUrl` 生成，host 必须从 `allAddresses` 挑纯 LAN 裸 IP（排除 `/app/` 网关、relay、loopback，否则 401）；非 MP3 走后端 `format=mp3&estimateContentLength=true&dlna=true`（`serveTranscodedDLNA` 落临时文件 + ServeContent），MP3 才直传；protocolInfo 与后端 `didl.go` 都是 `OP=00;CI=1`。UPnP AV 无标准歌词字段，纯文本进 `dc:description`、LRC 进 `dc:longDescription`。歌词必须在推 SetAVTransportURI **之前**取（`retryable: false` + 1s 超时）。
- App 端歌词/进度/唱片/列表高亮统一读 `AppModel.playback`（本地镜像 + 投屏时由 cast session 驱动），不要直接绑 `player.state`；该 notifier 实例在 local↔cast 切换中必须保持同一个。
- **热重载陷阱**：`State` 里别用 `late final` 缓存 notifier 再在 `initState` 赋值（Hot Reload 不重跑 initState → `LateInitializationError`）。用可空 `_playback?` + `_bindPlayback()`，在 `didChangeDependencies` 与 `reassemble` 重绑（identical 去重），回调用空安全。
- **测试约定**：含真实异步 + AppModel 探测 timer 的文件（如 `cast_test.dart`）只放 `test()`；混入 `testWidgets` 会因 FakeAsync 不推进而永久挂起。要测 UI 就把控件抽成纯参数 widget 再单文件 `testWidgets`。
- `just_audio` 的 `durationStream` 可能发 0 → `player.dart` 已 guard 忽略 ≤0。
- `cached_network_image` 不走自定义 http client → 全局 `HttpOverrides`（私有地址 DIRECT）解决。
- 沙箱内 `flutter test` 会因 HTTP_PROXY 报 "Invalid WebSocket upgrade request"，必须绕代理（见上）。
- Windows 构建依赖 `windows/CMakeLists.txt` 的全局 `/utf-8` 与 `_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS`（中文代码页 C4819、MSVC 14.51 STL1011），删了必挂。
- **本机调试地址/工具**：鸿蒙 hdc 在 `D:\command-line-tools\sdk\default\openharmony\toolchains\hdc.exe`，真机 TCP `10.1.57.23:37105` 需真机授权（首次连生成 `~/.harmony/hdckey.pub`）；鸿蒙 APK/HAP 本机编不了（缺 flutter_flutter ohos 分支 + 签名）。Android adb 在 `~/AppData/Local/Android/Sdk/platform-tools/adb.exe`（不在 PATH）。**Android 16 模拟器**：AVD `pixel6_api36`（Pixel 6 / API 36，主 SDK 直启），镜像 `system-images;android-36;google_apis;x86_64` 是 curl 直下 `dl.google.com/android/repository/sys-img/google_apis/x86_64-36_r07.zip` 手动解压装的（Java sdkmanager TLS 被掐、慢到不可用；cmdline-tools 同法装在 `Sdk/cmdline-tools/latest`）；锁屏 PIN 1234。Git Bash 会改写 adb/hdc 的 `/data/...` 路径，pull/screenshot 的远程路径写 `//sdcard/...`（双斜杠）即可在 Bash 直接用；adb daemon 会在工具会话间被清理，每条命令先 `start-server` 再操作。`locksettings set-pin` 后 keyguard 不出现要查 `locksettings get-disabled`（可能为 true，须 set-disabled false）。模拟器强断电会半损坏 userdata（包在组件丢），只能 wipe-data。
- Android 构建：device_info_plus 9.1.2 写死 compileSdk 33，靠 `android/build.gradle.kts` 的 subprojects + afterEvaluate 反射抬到 36，且该块要在 `evaluationDependsOn(":app")` 之前；`kotlin.incremental=false` 为绕 Windows 缓存报错。
- 锁屏/后台播放（三端机制不同）：
  - Android/iOS：`audio_service`（`lib/audio/media_session.dart`，main() 里先 start 再 runApp）+ manifest 的 AudioService/MediaButtonReceiver/FOREGROUND_SERVICE(mediaPlayback)/WAKE_LOCK。`import 'player.dart' as mf;` 隔开两套 PlaybackState，别改回去。**MainActivity 必须继承 `AudioServiceActivity`（不是 `FlutterActivity`）**：audio_service 0.18 在 onAttachedToActivity 比对 plugin messenger 与 FlutterEngineCache 里的引擎，普通 FlutterActivity 不注册 → 抛 "has not provided the correct FlutterEngine" → MediaSession 完全建不起来（锁屏/线控全失效），2026-11-17 真机实测修。
  - Android 13+ 要 `POST_NOTIFICATIONS`（首次播放时经 channel `musicfly/notification` 请求），否则「暂停后锁屏控制器消失」；通知小图标必须单色 vector `ic_stat_music.xml` 并配 `androidNotificationIcon`。
  - **Android 锁屏「收藏/播放顺序」按钮**（2026-11-17 加）：与鸿蒙 AVSession 是两套组件，audio_service 0.18 标准 MediaControl 没有收藏/循环，靠 `MediaControl.custom()`→原生 CustomAction 实现。Android 13+（targetSdk=36）媒体面板槽位固定：1 播放/暂停、2 上一首、3 下一首、4/5 自定义——**顺序系统定，做不到「循环在左收藏在右」**，实际是 播放/上一首/下一首/收藏/循环；Android 12- 只显示前 3 个。`media_session.dart` 的 `bind()` 注入 `onFavorite`/`onCycleMode`/`extrasProvider`（复用 AppModel 的 `systemToggleFavorite`/`systemCyclePlayMode`），`publish()` 用顶层纯函数 `mfMediaControls()` 构造按钮、图标随收藏态/模式切换，`customAction(name)` 分发（`musicfly_favorite`/`musicfly_cycle_mode`）；状态变化时 `_syncSystemExtras()` 调 `refreshExtras()` 重推。6 个纯白 vector 图标 `ic_mf_{favorite_on,favorite_off,repeat_sequential,repeat_all,repeat_one,shuffle}.xml`。`test/media_session_test.dart` 覆盖。
  - **Android 锁屏封面必须带 `artHeaders`**（2026-11-17 修）：audio_service 0.18 对 http(s) artUri 由 Dart 侧 `cacheManager.getSingleFile(url, headers: mediaItem.artHeaders)` 自己下载；飞牛网关/relay 封面无 header 会 401 → 媒体通知 `android.largeIcon=null` → 锁屏永远无封面（非 Android 16 特有）。`MediaItem` 原生有 `artHeaders` 字段：client.`artHeadersFor(url)`（=`fnRelayHeadersFor(url, bearerToken)`）经 `MfMediaSession.bind()` 的 `artHeadersProvider` 注入 `publish()`。App 内封面正常是因为自己带 header，别误判成网络问题。诊断命令：`dumpsys notification --noredact | grep largeIcon`。
  - iOS 还要启动时把 AVAudioSession 配成 playback（`system_audio.dart` 用 `AudioSessionConfiguration.music()`）。
  - 鸿蒙：module.json5 的 `backgroundModes: ["audioPlayback"]` **和** `KEEP_BACKGROUND_RUNNING` 都要，再由 EntryAbility 经 channel `com.seasonyuu.musicfly/background_audio` 起长时任务（`lib/audio/background_task.dart`，真的 playing 后才申请）。孤立的任一半都无效。AVSession/媒体面板由 just_audio ohos 分支在 ArkTS 侧创建，鸿蒙上没有 audio_service。`configureSystemAudio()` 必须 try/catch（鸿蒙 override 到 audio_session 0.2.4，必抛 MissingPluginException）。
- **鸿蒙锁屏元数据**：`system_artwork.dart` 带 `fnRelayHeadersFor` 下载字节 → `player.dart` setMetadata 的 `artwork` 字段 → vendor `MediaAvPlayer.ets` 解码 PixelMap → `AVMetadata.mediaImage`。系统自己取 URL 会 401；`mediaImage` 传 undefined 会让整次 setAVMetadata 401，空串才是合法兜底。需要鉴权的封面 URL（`fnRelayHeadersFor(url) != null`）一律不下发给系统，先推空串、再由字节补 PixelMap——锁屏卡片取不到新图会把上一首的封面留在原位。快照（AppStorage）是进程级唯一，assetId = trackId，同曲多次推送不变、换曲才变。**封面异步解码必须带 artworkAssetId 归属 + 每次 await 后重验 token/active 实例**，否则旧图落进新歌快照，锁屏出现「封面是上一首、歌名是这一首」（2026-11-16 修）。Dart 侧确认补推要等「已出声 + 封面定局」（`_playbackStarted`/`_coverResolved`），别在播放刚开始就推半成品。
  - **writeChain 挂死（2026-11-17 修）**：`setAVMetadata` 用 `snapshot.writeChain` 串行化，无超时——一次 `session.setAVMetadata`/`activate()` 永不返回 → 链永久堵死，**之后所有切歌推送排队永不执行，锁屏冻结在旧歌**（App 内 A/C/E/F、锁屏一直 B）。`setAVPlaybackState` 不走 writeChain，所以进度/暂停正常——「命令活着、只有元数据死」就是此症。修法：所有系统调用套 `mfAwaitWithTimeout`（3s）+ writeFailures≥3 触发 `recoverBrokenSession`（destroy→重建→补写）。排障：release 包 **ArkTS console.* 全被剥离**（日志必须走 `mfLogInfo/mfLogError` hilog API）；AVSession 实况用 `hidumper -s AVSessionService -a '-show_session_info'/'-show_metadata'` 直接看系统侧真值；Dart 日志经 `XComFlutterOHOS_Native` 透传可见。待修：vendored 播放器 ~10Hz 调 setSpeed 把 hilog 冲爆（后台 `nohup hilog > /data/local/tmp/xxx.log` 落盘抓跨天现场）。
  - **会话单例与 AppStorage（2026-11-18/19 两次修）**：后台冻结数小时解冻后播放器重建 → 旧会话仍占坑、新 createAVSession 被拒且拒绝态被缓存 → 锁屏冻死（11-18）。修法：`mfSharedSession` 双缓存 + 创建重试（destroy 旧会话、500ms 退避 ×3）+ 拒绝不缓存 + `setAVMetadata` 会话缺失时主动 createSession 自愈。**但 Promise/AVSession 绝不能存 AppStorage**——AppStorage 是可观察存储，取回被观测包装不再是原生实例，`await` 抛 `Then: thisValue is not promise!`（11-19：首个实例全天正常，第二实例命中缓存即全灭）。现只用模块级静态 `mfSessionPromise/mfSessionInstance`（本文件内自产自销无跨模块读取）+ `instanceof Promise` 校验变质缓存；`mfAwaitWithTimeout` 对非 Promise reject 明确错误。AppStorage 只放简单类型/纯数据快照（MF_ACTIVE_PLAYER_KEY、MF_AV_METADATA_KEY 保留）；`createSession failed: {}` 空对象是 JSON.stringify(BusinessError) 的坑，用 `mfSessionErrorDetail` 抽 code/message。
  - **音频焦点中断（2026-11-17 修）**：vendored 插件无 audioInterrupt 处理，微信视频抢焦点把 AVPlayer 暂停后 Dart 永远停在 playing=true（just_audio 事件无 playing 字段，playing 全靠 Dart 自己维护）；且 `pause()` 在原生已暂停时不回 result → Dart pause future 挂死（「暂停再播放无效」）。修法：注册 `avPlayer.on('audioInterrupt')`，BEGIN+PAUSE → 显式补 pause + updateIsPlay(false) + forward `pause` 给 Dart；END+RESUME 且 `wantPlaying` → forward `play` 自动续播。**`expectingForcedPause` 标记必须区分「中断强制暂停」与「用户手动暂停」**——强制的那个绕回原生 pause() 时不能清 wantPlaying。play 失败回退 isPlaying；pause 必回 result。
- FNID/LAN 切换：`session.addresses` 存飞牛返回的全部候选链路（含当次不可达的）；网关/中继需 fnOS token。
- 连接恢复状态机（`app_model.dart` + `musicfree_client.dart`）：2 分钟常规探测 + 全离线 3/5/10/20/30s 退避；连续 3 轮全不可达 → `reloginRequired`。`onTransportFailure`/`onAuthFailure` 是 `Future<bool> Function()` 可等待回调，client 成功后会重放一次请求（`_get` 的 URI 必须在闭包内构造）。`ServerInfo.authRequired` 区分「链路通但凭据失效」。「链路通但凭据失效」这类误判是全地址不可达假象的根因。`_reloginSilently()` 只对 `/app/` 网关链路免密续期；`_post` 一律 `retryable: false`。
- **FNID 地址池是内部实现，绝不暴露**：设置页只显示一条只读「当前连接」，不能增删改（`addressesManaged` 拦截）。
- **FNID 登录无端口项，后端端口定死 14533**（`kDefaultBackendPort` 唯一来源）；普通登录仍可带任意端口。
- **FNID 连上 NAS 后必须输入账号密码**（防网关免密登进默认账号）：`loginFnPrepared()` 要求非空凭据，网关链路走 `gateway-bind`（任何失败都 fallback 同地址 `login`，别按异常类型区分），直连/中继走普通 `login`。`gatewayLogin()` 只留给 `_reloginSilently()`。退出登录回 FNID 页签（`preferFnConnectTab`）。
- 队列面板：`queue_sheet.dart`（当前/历史双 tab、删除+拖拽、当前项高亮、底部播放模式与「回到当前」）；入口 = 迷你条 / 桌面条 / 全屏播放器。`PlayMode {sequential, loopAll, loopOne, shuffle}` + `queueSource` + `history`。**默认仍 `sequential`**（播完停止），未确认别改列表循环；`_advance(auto:)` 只有自动续播才认单曲循环。**系统级切歌（鸿蒙 AVSession / 耳机线控 → `systemSkip`）必须走 `_nextIndex`/`_previousIndex` 并传 `forceWrap: true`（保留末尾循环 + 连点合并），别自己写 index 算术**——否则 shuffle 下不会随机选曲（2026-11-17 修）。
- **鸿蒙锁屏播控按钮**：种类与顺序由系统按会话类型固定（audio = `收藏/上一首/播放暂停/下一首/循环模式`），App **不能自定义排列顺序**，只能靠注册对应回调让按钮亮起 + 上报状态刷新图标。vendored `MediaAvPlayer.ets` 已注册 `setLoopMode`/`toggleFavorite` 转发到 `MfOhosMediaControl`；`AVPlaybackState` 字段是 `loopMode` + `isFavorite`（不是 favorite）；LoopMode 4 值 `SEQUENCE0/SINGLE1/LIST2/SHUFFLE3` 与 Dart `ohosPlayModeIndex()` 一一映射。切模式/收藏/换歌后必须 `AppModel._syncSystemExtras()` 回推，否则锁屏图标不同步。改 ArkTS 后需 DevEco 重编译安装，热重载无效。
- **PC 队列是右侧停靠面板**：`showQueue(context, {fromFullPlayer})` 按 `kDockedQueueBreakpoint = 900` 分流；面板挂在 HomeShell 内容区 Row 右侧、止于播放条上方（放整行末尾会压窄播放条导致溢出）；播放条 <760 宽时镜像 `rightSpan` 归 0。
- 队列底部按钮保持紧凑 chip（`_Pill` 视觉 30px、内容宽度、外层 38px 点击区；footer padding 14/8）。
- `reorderQueue` 用旧 `onReorder` 插入索引语义（newIndex > oldIndex 时 -1），别换 `onReorderItem`。
- 移动端竖屏（宽 < 560）全屏播放器按钮两行：主行（模式/上一首/播放/下一首/队列）+ 次级行（收藏/歌曲信息/音量/投屏）；桌面单行 + 音量 slider。迷你条只留播放 + 播放列表。
- **竖屏唱片不能按 maxHeight 比例硬算**：`Expanded(LayoutBuilder)` + 固定高度 `_credits`，唱片 = `min(宽×0.78, 剩余高-4, 300)`；封面:歌词 6:4，歌词区 < 140 隐藏面板。`test/now_playing_test.dart` 有多尺寸回归。
- **设计 token**：颜色只用 `Mf.*`；文字只用 `Mf.text`/`textSoft`/`muted`（≥4.5:1），`faint`/`disabled` 不写字；字号 `MfType`、圆角 `MfRadius`、间距 `MfSpace`、动效 `MfMotion`。`test/ui_theme_test.dart` 有对比度与 token 纪律回归。
- 首页「查看全部」右对齐：`Expanded` 占满 + 行尾固定按钮，别用 `Spacer()` 混排（`test/home_header_align_test.dart` 锁定）。

## 遗留事项

- 图标：鸿蒙已换 Music Free SVG 版（`ohos/*/media/{app_icon,icon}.png`，源 `music-free/frontend/public/logo.svg`）；iOS/Android/macOS 仍是默认图。
- 仓库目录名仍是 `FnMusic`（用户未要求改）。
- 本地库有 4 首残缺片段 + 3 个孤儿文件待清理（用户未确认）；8 组重复记录待去重。
- 「漠河舞厅 (摇滚版)」实际是 m4a 但扩展名 .mp3，直传播不出，需重命名 + rescan。
