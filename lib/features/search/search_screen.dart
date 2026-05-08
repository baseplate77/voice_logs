import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/providers.dart';
import '../../core/result.dart';
import '../../core/worker/providers.dart';
import '../detail/log_detail_screen.dart';
import 'hybrid_retriever.dart';

/// Hybrid search screen. FTS works immediately on raw transcripts;
/// embedded logs also participate in vector search after background
/// refinement/embedding finishes.
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
    final hitsAsync = ref.watch(_hybridSearchProvider(query));
    return hitsAsync.when(
      data: (rows) {
        if (rows.isEmpty) {
          return const Center(child: Text('No matches.'));
        }
        return ListView.separated(
          itemCount: rows.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (_, i) {
            final hit = rows[i];
            return ListTile(
              title: Text(
                hit.snippet,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(_sourceLabel(hit.matchedVia)),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => LogDetailScreen(logId: hit.logId),
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

String _sourceLabel(Set<MatchSource> sources) {
  if (sources.isEmpty) return 'keyword';
  final labels = sources
      .map((s) {
        return switch (s) {
          MatchSource.fts => 'keyword',
          MatchSource.vector => 'semantic',
          MatchSource.entity => 'entity',
        };
      })
      .join(' + ');
  return labels;
}

final _hybridSearchProvider = FutureProvider.family<List<SearchHit>, String>((
  ref,
  query,
) async {
  final vecStore = ref.watch(vecStoreProvider);
  await vecStore.load();
  final retriever = HybridRetriever(
    db: ref.watch(voxSynthDatabaseProvider),
    embedder: ref.watch(embedderProvider),
    vecStore: vecStore,
  );
  final res = await retriever.search(query, limit: 20);
  return switch (res) {
    Ok(:final value) => value,
    Err(:final error) => throw StateError(error.message),
  };
});
