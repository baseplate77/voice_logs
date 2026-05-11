import 'package:flutter/material.dart';

import '../memory/memory_types.dart';
import '../search/hybrid_retriever.dart';
import 'ask_chat_message.dart';

/// Expandable source context panel for an Ask answer.
class AskContextPanel extends StatelessWidget {
  const AskContextPanel({
    super.key,
    required this.message,
    required this.onOpenLog,
  });

  /// Assistant message containing retrieval context.
  final AskChatMessage message;

  /// Called when the user taps a retrieved voice-log source.
  final ValueChanged<String> onOpenLog;

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      childrenPadding: EdgeInsets.zero,
      title: Text(
        'Context (${message.memoryHits.length + message.logHits.length})',
      ),
      children: [
        for (final hit in message.memoryHits) _buildMemoryTile(hit),
        for (final hit in message.logHits) _buildLogTile(hit),
      ],
    );
  }

  Widget _buildMemoryTile(MemoryHit hit) {
    return ListTile(
      dense: true,
      leading: const Icon(Icons.memory_outlined),
      title: Text(hit.memory.text),
      subtitle: Text(
        'memory • ${hit.memory.type.wire} • ${_memorySources(hit.matchedVia)}',
      ),
    );
  }

  Widget _buildLogTile(SearchHit hit) {
    return ListTile(
      dense: true,
      leading: const Icon(Icons.notes_outlined),
      title: Text(hit.snippet, maxLines: 3, overflow: TextOverflow.ellipsis),
      subtitle: Text('voice log • ${_logSources(hit.matchedVia)}'),
      onTap: () => onOpenLog(hit.logId),
    );
  }
}

String _memorySources(Set<MemoryMatchSource> sources) {
  if (sources.isEmpty) return 'retrieved';
  return sources
      .map((source) {
        return switch (source) {
          MemoryMatchSource.fts => 'keyword',
          MemoryMatchSource.vector => 'semantic',
          MemoryMatchSource.entity => 'entity',
        };
      })
      .join(' + ');
}

String _logSources(Set<MatchSource> sources) {
  if (sources.isEmpty) return 'retrieved';
  return sources
      .map((source) {
        return switch (source) {
          MatchSource.fts => 'keyword',
          MatchSource.vector => 'semantic',
          MatchSource.entity => 'entity',
        };
      })
      .join(' + ');
}
