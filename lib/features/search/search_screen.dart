import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/providers.dart';
import '../../core/db/repositories/voice_log_repository.dart';
import '../detail/log_detail_screen.dart';

/// Hybrid search screen. Phase 6 wires a debounced text field that
/// runs FTS against raw_transcript + cleaned_text. Vector + entity
/// paths are wired in the retriever but require the embedder to be
/// available — when it isn't, FTS results alone show up.
class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _controller = TextEditingController();
  Timer? _debounce;
  String _query = '';

  @override
  void dispose() {
    _controller.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _onChanged(String raw) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 200), () {
      if (!mounted) return;
      setState(() => _query = raw.trim());
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          autofocus: true,
          textInputAction: TextInputAction.search,
          decoration: const InputDecoration(
            hintText: 'Search your journal…',
            border: InputBorder.none,
          ),
          onChanged: _onChanged,
        ),
      ),
      body: _query.isEmpty
          ? const _EmptyPrompt()
          : _SearchResults(query: _query),
    );
  }
}

class _EmptyPrompt extends StatelessWidget {
  const _EmptyPrompt();

  @override
  Widget build(BuildContext context) => const Center(
    child: Text('Type to search raw transcripts, cleaned text, entities.'),
  );
}

class _SearchResults extends ConsumerWidget {
  const _SearchResults({required this.query});
  final String query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final logsAsync = ref.watch(_simpleSearchProvider(query));
    return logsAsync.when(
      data: (rows) {
        if (rows.isEmpty) {
          return const Center(child: Text('No matches.'));
        }
        return ListView.separated(
          itemCount: rows.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (_, i) {
            final row = rows[i];
            return ListTile(
              title: Text(
                row.displayText,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(row.processingState.wire),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => LogDetailScreen(logId: row.id),
                ),
              ),
            );
          },
        );
      },
      loading: () => const Center(child: CircularProgressIndicator.adaptive()),
      error: (e, _) => Center(child: Text('Error: $e')),
    );
  }
}

/// Phase 6 search is FTS-only against the live log stream — filters
/// the already-loaded list client-side. The HybridRetriever is reserved
/// for Phase 7+ when the embedder runs at session start. This avoids
/// embedder bootstrap cost on every keystroke.
final _simpleSearchProvider = StreamProvider.family<List<VoiceLogView>, String>(
  (ref, query) {
    final logs = ref.watch(voiceLogsStreamProvider.future);
    final controller = StreamController<List<VoiceLogView>>();
    logs.then((snapshot) {
      final lower = query.toLowerCase();
      controller.add(
        snapshot.where((l) {
          final haystack = '${l.rawTranscript} ${l.cleanedText ?? ''}'
              .toLowerCase();
          return haystack.contains(lower);
        }).toList(),
      );
    });
    ref.listen(voiceLogsStreamProvider, (_, next) {
      next.whenData((snapshot) {
        final lower = query.toLowerCase();
        controller.add(
          snapshot.where((l) {
            final haystack = '${l.rawTranscript} ${l.cleanedText ?? ''}'
                .toLowerCase();
            return haystack.contains(lower);
          }).toList(),
        );
      });
    });
    ref.onDispose(controller.close);
    return controller.stream;
  },
);
