import 'package:flutter/material.dart';

/// Detail view for a single voice log — cleaned text, entity chips, playback.
///
/// Phase 0 placeholder.
class LogDetailScreen extends StatelessWidget {
  const LogDetailScreen({super.key, required this.logId});

  /// ID of the voice log to render.
  final String logId;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Log $logId')),
      body: const Center(child: Text('Detail (Phase 1+)')),
    );
  }
}
