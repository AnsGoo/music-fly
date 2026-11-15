/// Device picker and remote control for casting.
///
/// Opened from the cast button in the transport: before a session it lists
/// discovered DLNA renderers, after connecting it becomes the remote —
/// progress, play/pause, queue stepping, volume and disconnect.
library;

import 'dart:async';

import 'package:dart_cast/dart_cast.dart' show SessionState;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/models.dart' show formatClock;
import '../state/app_model.dart';
import 'controls.dart';
import 'theme.dart';
import 'widgets.dart' show MfSpinner;

/// Opens the cast sheet and kicks off a fresh device scan.
Future<void> showCastSheet(BuildContext context) {
  final model = context.read<AppModel>();
  unawaited(model.startCastScan());
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Mf.surface,
    shape: RoundedRectangleBorder(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(MfRadius.sheet)),
      side: BorderSide(color: Mf.border),
    ),
    builder: (_) => ChangeNotifierProvider<AppModel>.value(
      value: model,
      child: const CastSheet(),
    ),
  );
}

class CastSheet extends StatelessWidget {
  const CastSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final model = context.watch<AppModel>();
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
        child: model.casting
            ? const _CastRemote()
            : const _CastDevicePicker(),
      ),
    );
  }
}

// ---- Device picker ----------------------------------------------------------

class _CastDevicePicker extends StatelessWidget {
  const _CastDevicePicker();

  @override
  Widget build(BuildContext context) {
    final model = context.watch<AppModel>();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SheetHeader(title: '投屏', showRescan: true),
        const SizedBox(height: 4),
        if (model.castScanning)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 22),
            child: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  MfSpinner(size: 14),
                  SizedBox(width: 10),
                  Text(
                    '正在搜索局域网内的投屏设备…',
                    style: TextStyle(color: Mf.muted, fontSize: 13),
                  ),
                ],
              ),
            ),
          )
        else if (model.castDevices.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 22),
            child: Center(
              child: Text(
                model.castScanDone
                    ? '未发现投屏设备，请确认设备与本机在同一局域网'
                    : '尚未扫描',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Mf.muted, fontSize: 13),
              ),
            ),
          )
        else
          for (final device in model.castDevices)
            _DeviceRow(
              name: device.name,
              subtitle: 'DLNA · ${device.address.address}',
              onTap: () => context.read<AppModel>().connectCast(device),
            ),
      ],
    );
  }
}

class _SheetHeader extends StatelessWidget {
  const _SheetHeader({required this.title, this.showRescan = false});

  final String title;
  final bool showRescan;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Icon(Icons.cast_rounded, size: 18, color: Mf.textSoft),
        const SizedBox(width: 9),
        Text(
          title,
          style: const TextStyle(
            color: Mf.text,
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
        const Spacer(),
        if (showRescan)
          MfIconButton(
            icon: Icons.refresh_rounded,
            size: 28,
            glyph: 16,
            tooltip: '重新扫描',
            onTap: () => context.read<AppModel>().startCastScan(),
          ),
      ],
    );
  }
}

class _DeviceRow extends StatelessWidget {
  const _DeviceRow({
    required this.name,
    required this.subtitle,
    required this.onTap,
  });

  final String name;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '连接到投屏设备 $name',
      child: InkWell(
        borderRadius: BorderRadius.circular(MfRadius.md),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: Mf.accentWash,
                  borderRadius: BorderRadius.circular(MfRadius.sm),
                ),
                child: const Icon(
                  Icons.speaker_rounded,
                  size: 17,
                  color: Mf.accentHover,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Mf.text,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Mf.muted, fontSize: MfType.label),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded, size: 18, color: Mf.muted),
            ],
          ),
        ),
      ),
    );
  }
}

// ---- Remote -----------------------------------------------------------------

class _CastRemote extends StatelessWidget {
  const _CastRemote();

  @override
  Widget build(BuildContext context) {
    final model = context.watch<AppModel>();
    final state = model.castState;
    final playing =
        state == SessionState.playing ||
        state == SessionState.buffering ||
        state == SessionState.loading;
    final stateLabel = switch (state) {
      SessionState.playing => '正在播放',
      SessionState.buffering => '缓冲中',
      SessionState.loading => '加载中',
      SessionState.paused => '已暂停',
      SessionState.idle => '已停止',
      _ => '已连接',
    };
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Mf.accentHover, Mf.accent],
                ),
                borderRadius: BorderRadius.circular(MfRadius.sm),
              ),
              child: const Icon(
                Icons.cast_rounded,
                size: 17,
                color: Mf.cream,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    model.castDevice?.name ?? '投屏设备',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Mf.text,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    stateLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Mf.muted, fontSize: MfType.label),
                  ),
                ],
              ),
            ),
            MfIconButton(
              icon: Icons.link_off_rounded,
              size: 30,
              glyph: 16,
              tooltip: '断开投屏',
              onTap: () {
                context.read<AppModel>().disconnectCast();
                Navigator.of(context).pop();
              },
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          model.currentTrack?.title ?? '',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Mf.textSoft, fontSize: 13),
        ),
        const SizedBox(height: 8),
        const _CastProgress(),
        CastTransportControls(
          playing: playing,
          onToggle: model.togglePlay,
          onPrevious: model.previous,
          onNext: model.next,
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            const Icon(Icons.volume_up_rounded, size: 16, color: Mf.muted),
            const SizedBox(width: 8),
            Expanded(
              child: MfScrubber(
                label: '投屏音量',
                fraction: model.castVolume,
                thumbColor: Mf.textSoft,
                activeColor: Mf.muted,
                onScrub: model.setVolume,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Icon-only transport row for the remote. Every button is the same 34dp
/// size — the play/pause control used to be a filled icon+label pill, which
/// looked oversized next to the skip buttons.
class CastTransportControls extends StatelessWidget {
  const CastTransportControls({
    super.key,
    required this.playing,
    required this.onToggle,
    required this.onPrevious,
    required this.onNext,
  });

  final bool playing;
  final VoidCallback onToggle;
  final VoidCallback onPrevious;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        MfIconButton(
          icon: Icons.skip_previous_rounded,
          size: 34,
          glyph: 22,
          tooltip: '上一首',
          onTap: onPrevious,
        ),
        const SizedBox(width: 10),
        MfPlayButton(
          playing: playing,
          tooltip: playing ? '暂停' : '播放',
          onTap: onToggle,
        ),
        const SizedBox(width: 10),
        MfIconButton(
          icon: Icons.skip_next_rounded,
          size: 34,
          glyph: 22,
          tooltip: '下一首',
          onTap: onNext,
        ),
      ],
    );
  }
}

/// Remote position bar. The renderer reports position once a second through
/// the session stream; dragging previews locally and seeks on release.
class _CastProgress extends StatefulWidget {
  const _CastProgress();

  @override
  State<_CastProgress> createState() => _CastProgressState();
}

class _CastProgressState extends State<_CastProgress> {
  double? _preview;

  @override
  Widget build(BuildContext context) {
    final model = context.watch<AppModel>();
    final session = model.castSession;
    if (session == null) return const SizedBox.shrink();
    return StreamBuilder<Duration>(
      stream: session.positionStream,
      initialData: session.position,
      builder: (context, snapshot) {
        final position = snapshot.data ?? Duration.zero;
        final duration = session.duration;
        final seconds = duration.inMilliseconds / 1000.0;
        final fraction = _preview ??
            (seconds > 0
                ? (position.inMilliseconds / 1000.0 / seconds).clamp(0.0, 1.0)
                : 0.0);
        return Column(
          children: [
            Row(
              children: [
                SizedBox(
                  width: 38,
                  child: Text(
                    formatClock(_preview != null
                        ? _preview! * seconds
                        : position.inMilliseconds / 1000.0),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                      color: Mf.muted,
                      fontSize: MfType.label,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: MfScrubber(
                    label: '投屏播放进度',
                    fraction: fraction,
                    onScrub: (value) => setState(() => _preview = value),
                    onCommit: () {
                      final target = _preview;
                      setState(() => _preview = null);
                      if (target != null && seconds > 0) {
                        model.seek(Duration(
                          milliseconds: (target * seconds * 1000).round(),
                        ));
                      }
                    },
                  ),
                ),
                const SizedBox(width: 10),
                SizedBox(
                  width: 38,
                  child: Text(
                    formatClock(seconds),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Mf.muted,
                      fontSize: MfType.label,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}
