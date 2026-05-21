import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import '../../app_theme.dart';
import '../../core/db/providers.dart';
import '../../core/db/repositories/voice_log_repository.dart';
import '../detail/audio_player_controller.dart';
import '../detail/log_detail_screen.dart';
import 'bloom_animation.dart';
import 'flower_themes.dart';

/// Synthia Garden Screen displaying an interactive contribution map.
class VoxGardenScreen extends ConsumerStatefulWidget {
  const VoxGardenScreen({super.key});

  @override
  ConsumerState<VoxGardenScreen> createState() => _VoxGardenScreenState();
}

class _VoxGardenScreenState extends ConsumerState<VoxGardenScreen> {
  int _selectedYear = DateTime.now().year;
  VoiceLogView? _activeLog;
  AudioPlayerController? _audioPlayer;
  bool _isPlaying = false;
  Duration _currentPos = Duration.zero;
  Duration _totalDur = Duration.zero;
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<bool>? _playingSub;

  @override
  void dispose() {
    _disposePlayer();
    super.dispose();
  }

  DateTime _getStartDate(int year) {
    final firstDay = DateTime(year);
    final weekday = firstDay.weekday;
    if (weekday == DateTime.sunday) return firstDay;
    // Walk back to the nearest Sunday of the first week
    return firstDay.subtract(Duration(days: weekday));
  }

  String _formatDuration(Duration d) {
    final mins = d.inMinutes;
    final secs = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$mins:$secs';
  }

  String _formatDate(DateTime dt) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    return '${months[dt.month - 1]} ${dt.day}, ${dt.year}';
  }

  Future<void> _selectLog(VoiceLogView log) async {
    await _disposePlayer();

    final player = AudioPlayerController();
    final error = await player.loadFile(log.audioPath);
    if (error != null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error)),
        );
      }
      await player.dispose();
      return;
    }

    setState(() {
      _activeLog = log;
      _audioPlayer = player;
      _totalDur = player.duration ?? Duration.zero;
      _currentPos = Duration.zero;
    });

    _posSub = player.positionStream.listen((pos) {
      if (mounted) {
        setState(() {
          _currentPos = pos;
        });
      }
    });

    _playingSub = player.playingStream.listen((playing) {
      if (mounted) {
        setState(() {
          _isPlaying = playing;
        });
      }
    });
  }

  Future<void> _disposePlayer() async {
    await _posSub?.cancel();
    await _playingSub?.cancel();
    await _audioPlayer?.dispose();
    _audioPlayer = null;
    _posSub = null;
    _playingSub = null;
  }

  @override
  Widget build(BuildContext context) {
    final logsAsync = ref.watch(voiceLogsStreamProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: 'Synthia Garden',
                style: TextStyle(
                  fontFamily: 'NDot',
                  fontWeight: FontWeight.bold,
                  fontSize: 20.sp,
                  color: VoxAppColors.primary,
                ),
              ),
              TextSpan(
                text: '.',
                style: TextStyle(
                  fontFamily: 'NDot',
                  fontWeight: FontWeight.bold,
                  fontSize: 20.sp,
                  color: VoxAppColors.accent,
                ),
              ),
            ],
          ),
        ),
      ),
      body: logsAsync.when(
        data: (logs) {
          // Filter logs to the selected year
          final yearLogs = logs.where((l) => l.createdAt.year == _selectedYear).toList();

          // Map logs by normalized date
          final Map<DateTime, VoiceLogView> logsByDate = {};
          final counts = <FlowerType, int>{};
          for (final type in FlowerType.values) {
            counts[type] = 0;
          }

          for (final log in yearLogs) {
            final dt = log.createdAt;
            final normalized = DateTime(dt.year, dt.month, dt.day);
            logsByDate[normalized] = log;

            if (log.flowerType != null) {
              final normType = log.flowerType!.trim().toLowerCase();
              for (final type in FlowerType.values) {
                if (type.name == normType) {
                  counts[type] = (counts[type] ?? 0) + 1;
                  break;
                }
              }
            }
          }

          final startDate = _getStartDate(_selectedYear);

          return Stack(
            children: [
              // Canvas layout
              SingleChildScrollView(
                padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 8.h),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Year Toggle Selector
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Your Journaling Ecosystem',
                          style: TextStyle(
                            fontSize: 13.sp,
                            fontWeight: FontWeight.w600,
                            color: VoxAppColors.muted,
                            fontFamily: 'monospace',
                          ),
                        ),
                        Container(
                          padding: EdgeInsets.symmetric(horizontal: 4.w),
                          decoration: BoxDecoration(
                            border: Border.all(color: VoxAppColors.outline),
                            borderRadius: BorderRadius.circular(8.r),
                            color: VoxAppColors.surface,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                iconSize: 16.r,
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(),
                                icon: const Icon(Icons.chevron_left_rounded),
                                onPressed: () {
                                  setState(() {
                                    _selectedYear--;
                                    _activeLog = null;
                                    _disposePlayer();
                                  });
                                },
                              ),
                              SizedBox(width: 6.w),
                              Text(
                                '$_selectedYear',
                                style: TextStyle(
                                  fontSize: 12.sp,
                                  fontWeight: FontWeight.bold,
                                  fontFamily: 'NDot',
                                  color: VoxAppColors.primary,
                                ),
                              ),
                              SizedBox(width: 6.w),
                              IconButton(
                                iconSize: 16.r,
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(),
                                icon: const Icon(Icons.chevron_right_rounded),
                                onPressed: () {
                                  setState(() {
                                    _selectedYear++;
                                    _activeLog = null;
                                    _disposePlayer();
                                  });
                                },
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: 12.h),

                    // Dot Matrix Container
                    Container(
                      height: 125.h,
                      width: double.infinity,
                      padding: EdgeInsets.all(12.r),
                      decoration: CardTheme.of(context).shape != null
                          ? BoxDecoration(
                              color: VoxAppColors.surface,
                              borderRadius: BorderRadius.circular(16.r),
                              border: Border.all(color: VoxAppColors.outline),
                            )
                          : BoxDecoration(
                              color: VoxAppColors.surface,
                              border: Border.all(color: VoxAppColors.outline),
                            ),
                      child: VoxGardenCanvas(
                        logsByDate: logsByDate,
                        startDate: startDate,
                        onLogTapped: _selectLog,
                        onEmptyCellTapped: () {
                          setState(() {
                            _activeLog = null;
                            _disposePlayer();
                          });
                        },
                      ),
                    ),
                    SizedBox(height: 16.h),

                    // Legend and Stats Drawer Panel
                    Text(
                      'FLORAL LEGEND & WELLNESS STATS',
                      style: TextStyle(
                        fontSize: 10.sp,
                        fontWeight: FontWeight.bold,
                        color: VoxAppColors.muted,
                        letterSpacing: 1.0,
                        fontFamily: 'NDot',
                      ),
                    ),
                    SizedBox(height: 8.h),
                    ListView.separated(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: FlowerType.values.length,
                      separatorBuilder: (context, index) => SizedBox(height: 6.h),
                      itemBuilder: (_, index) {
                        final type = FlowerType.values[index];
                        final count = counts[type] ?? 0;
                        
                        return Container(
                          padding: EdgeInsets.all(10.r),
                          decoration: BoxDecoration(
                            color: VoxAppColors.surface,
                            borderRadius: BorderRadius.circular(12.r),
                            border: Border.all(color: VoxAppColors.outline),
                          ),
                          child: Row(
                            children: [
                              // Mini painted floral preview
                              SizedBox(
                                width: 28.w,
                                height: 28.w,
                                child: CustomPaint(
                                  painter: _MiniFlowerPainter(type),
                                ),
                              ),
                              SizedBox(width: 12.w),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Text(
                                          type.displayName,
                                          style: TextStyle(
                                            fontSize: 13.sp,
                                            fontWeight: FontWeight.bold,
                                            color: VoxAppColors.primary,
                                            fontFamily: 'monospace',
                                          ),
                                        ),
                                        SizedBox(width: 6.w),
                                        Text(
                                          '•  ${type.vibe}',
                                          style: TextStyle(
                                            fontSize: 11.sp,
                                            color: VoxAppColors.muted,
                                            fontWeight: FontWeight.w500,
                                            fontFamily: 'monospace',
                                          ),
                                        ),
                                      ],
                                    ),
                                    SizedBox(height: 2.h),
                                    Text(
                                      type.description,
                                      style: TextStyle(
                                        fontSize: 10.sp,
                                        color: VoxAppColors.muted,
                                        height: 1.25,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              SizedBox(width: 8.w),
                              Container(
                                padding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 4.h),
                                decoration: BoxDecoration(
                                  color: count > 0 ? const Color(0xFFF5EBEB) : VoxAppColors.soft,
                                  borderRadius: BorderRadius.circular(20.r),
                                  border: Border.all(
                                    color: count > 0 ? VoxAppColors.accent.withValues(alpha: 0.2) : VoxAppColors.outline,
                                  ),
                                ),
                                child: Text(
                                  '$count planted',
                                  style: TextStyle(
                                    fontSize: 10.sp,
                                    fontWeight: FontWeight.bold,
                                    fontFamily: 'monospace',
                                    color: count > 0 ? VoxAppColors.accent : VoxAppColors.muted,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                    SizedBox(height: 80.h), // Spacing for floating player card
                  ],
                ),
              ),

              // Floating detailed card popover
              if (_activeLog != null)
                Positioned(
                  left: 12.w,
                  right: 12.w,
                  bottom: 12.h,
                  child: Container(
                    padding: EdgeInsets.all(12.r),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16.r),
                      border: Border.all(color: VoxAppColors.accent, width: 1.2),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.08),
                          blurRadius: 16.r,
                          offset: Offset(0, 4.h),
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Card Header
                        Row(
                          children: [
                            SizedBox(
                              width: 32.w,
                              height: 32.w,
                              child: CustomPaint(
                                painter: _MiniFlowerPainter(
                                  _parseFlowerType(_activeLog!.flowerType),
                                ),
                              ),
                            ),
                            SizedBox(width: 8.w),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    _activeLog!.displayTitle,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 13.sp,
                                      fontWeight: FontWeight.bold,
                                      color: VoxAppColors.primary,
                                      fontFamily: 'monospace',
                                    ),
                                  ),
                                  SizedBox(height: 1.h),
                                  Row(
                                    children: [
                                      Text(
                                        _formatDate(_activeLog!.createdAt),
                                        style: TextStyle(
                                          fontSize: 10.sp,
                                          color: VoxAppColors.muted,
                                          fontFamily: 'monospace',
                                        ),
                                      ),
                                      SizedBox(width: 8.w),
                                      Text(
                                        '•  ${_parseFlowerType(_activeLog!.flowerType).vibe}',
                                        style: TextStyle(
                                          fontSize: 10.sp,
                                          color: VoxAppColors.accent,
                                          fontWeight: FontWeight.bold,
                                          fontFamily: 'monospace',
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              iconSize: 18.r,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                              icon: const Icon(Icons.close_rounded),
                              onPressed: () {
                                setState(() {
                                  _activeLog = null;
                                  _disposePlayer();
                                });
                              },
                            ),
                          ],
                        ),
                        Divider(height: 16.h),

                        // Inline Audio Scrubber
                        Row(
                          children: [
                            IconButton(
                              style: IconButton.styleFrom(
                                backgroundColor: VoxAppColors.primary,
                                foregroundColor: Colors.white,
                                padding: EdgeInsets.all(6.r),
                              ),
                              icon: Icon(
                                _isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                              ),
                              onPressed: () {
                                if (_isPlaying) {
                                  _audioPlayer?.pause();
                                } else {
                                  _audioPlayer?.play();
                                }
                              },
                            ),
                            SizedBox(width: 6.w),
                            Text(
                              _formatDuration(_currentPos),
                              style: TextStyle(
                                fontSize: 10.sp,
                                fontFamily: 'monospace',
                                color: VoxAppColors.primary,
                              ),
                            ),
                            Expanded(
                              child: SliderTheme(
                                data: SliderThemeData(
                                  trackHeight: 2.h,
                                  activeTrackColor: VoxAppColors.primary,
                                  inactiveTrackColor: VoxAppColors.outline,
                                  thumbColor: VoxAppColors.accent,
                                  thumbShape: RoundSliderThumbShape(
                                    enabledThumbRadius: 5.r,
                                  ),
                                  overlayShape: RoundSliderOverlayShape(
                                    overlayRadius: 10.r,
                                  ),
                                ),
                                child: Slider(
                                  value: _currentPos.inMilliseconds.toDouble(),
                                  max: math.max(
                                    1.0,
                                    _totalDur.inMilliseconds.toDouble(),
                                  ),
                                  onChanged: (val) {
                                    _audioPlayer?.seek(
                                      Duration(milliseconds: val.toInt()),
                                    );
                                  },
                                ),
                              ),
                            ),
                            Text(
                              _formatDuration(_totalDur),
                              style: TextStyle(
                                fontSize: 10.sp,
                                fontFamily: 'monospace',
                                color: VoxAppColors.primary,
                              ),
                            ),
                          ],
                        ),

                        // Open Full Details Link
                        Align(
                          alignment: Alignment.centerRight,
                          child: InkWell(
                            onTap: () {
                              final logId = _activeLog!.id;
                              // Clean up audio player since detail screen will launch its own player
                              _activeLog = null;
                              _disposePlayer();
                              
                              Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) => LogDetailScreen(logId: logId),
                                ),
                              );
                            },
                            child: Padding(
                              padding: EdgeInsets.symmetric(vertical: 4.h, horizontal: 8.w),
                              child: Text(
                                'Open journal entry →',
                                style: TextStyle(
                                  fontSize: 11.sp,
                                  fontWeight: FontWeight.bold,
                                  color: VoxAppColors.primary,
                                  decoration: TextDecoration.underline,
                                  fontFamily: 'monospace',
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          );
        },
        loading: () => const Center(child: CircularProgressIndicator.adaptive()),
        error: (err, _) => Center(child: Text('Error loading ecosystem: $err')),
      ),
    );
  }

  FlowerType _parseFlowerType(String? raw) {
    if (raw == null) return FlowerType.sakura;
    final normalized = raw.trim().toLowerCase();
    for (final type in FlowerType.values) {
      if (type.name == normalized) return type;
    }
    return FlowerType.sakura;
  }
}

/// Mini painted flower helper for stats rows and player card
class _MiniFlowerPainter extends CustomPainter {
  _MiniFlowerPainter(this.type);

  final FlowerType type;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final dimension = math.min(size.width, size.height);
    
    final strokePaint = Paint();
    final accentPaint = Paint();

    type.paint(canvas, center, dimension, strokePaint, accentPaint);
  }

  @override
  bool shouldRepaint(covariant _MiniFlowerPainter oldDelegate) {
    return oldDelegate.type != type;
  }
}
