import 'package:flutter/material.dart';
import '../../core/db/repositories/voice_log_repository.dart';
import 'garden_painter.dart';

/// An interactive, highly responsive dot-matrix contribution canvas widget.
/// Manages tap gestures, cell coordinate mapping, and elastic blooming animations.
class VoxGardenCanvas extends StatefulWidget {
  const VoxGardenCanvas({
    super.key,
    required this.logsByDate,
    required this.startDate,
    this.onLogTapped,
    this.onEmptyCellTapped,
  });

  /// Map of logs grouped by normalized date (year, month, day).
  final Map<DateTime, VoiceLogView> logsByDate;

  /// The starting Sunday of the 53-week grid.
  final DateTime startDate;

  /// Triggered when a flower on the canvas is tapped.
  final ValueChanged<VoiceLogView>? onLogTapped;

  /// Triggered when an empty dot cell is tapped.
  final VoidCallback? onEmptyCellTapped;

  @override
  State<VoxGardenCanvas> createState() => _VoxGardenCanvasState();
}

class _VoxGardenCanvasState extends State<VoxGardenCanvas>
    with SingleTickerProviderStateMixin {
  late final AnimationController _bloomController;
  DateTime? _newlyProcessedDate;
  DateTime? _selectedDate;

  @override
  void initState() {
    super.initState();
    _bloomController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
  }

  @override
  void didUpdateWidget(covariant VoxGardenCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);

    // Detect if any log was newly refined/inserted
    for (final entry in widget.logsByDate.entries) {
      final oldLog = oldWidget.logsByDate[entry.key];
      final newLog = entry.value;

      // If the log is now refined and it wasn't refined before, trigger bloom!
      if (newLog.flowerType != null &&
          (oldLog == null || oldLog.flowerType == null)) {
        setState(() {
          _newlyProcessedDate = entry.key;
        });
        _bloomController.reset();
        _bloomController.forward();
        break;
      }
    }
  }

  @override
  void dispose() {
    _bloomController.dispose();
    super.dispose();
  }

  void _handleTap(TapUpDetails details, BoxConstraints constraints) {
    const columns = 53;
    const rows = 7;

    final cellWidth = constraints.maxWidth / columns;
    final cellHeight = constraints.maxHeight / rows;

    // Calculate grid coordinate from local tap offset
    final col = (details.localPosition.dx / cellWidth).floor().clamp(0, columns - 1);
    final row = (details.localPosition.dy / cellHeight).floor().clamp(0, rows - 1);

    // Map coordinate to exact calendar date
    final dayOffset = col * 7 + row;
    final clickedDate = widget.startDate.add(Duration(days: dayOffset));
    final normalizedDate = DateTime(clickedDate.year, clickedDate.month, clickedDate.day);

    setState(() {
      _selectedDate = normalizedDate;
    });

    final log = widget.logsByDate[normalizedDate];
    if (log != null) {
      widget.onLogTapped?.call(log);
    } else {
      widget.onEmptyCellTapped?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return GestureDetector(
          onTapUp: (details) => _handleTap(details, constraints),
          child: AnimatedBuilder(
            animation: _bloomController,
            builder: (context, child) {
              return CustomPaint(
                size: Size(constraints.maxWidth, constraints.maxHeight),
                painter: GardenPainter(
                  logsByDate: widget.logsByDate,
                  startDate: widget.startDate,
                  animationValue: _bloomController.value,
                  newlyProcessedDate: _newlyProcessedDate,
                  selectedDate: _selectedDate,
                ),
              );
            },
          ),
        );
      },
    );
  }
}
