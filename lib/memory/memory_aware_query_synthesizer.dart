import '../core/logger.dart';
import '../synth/models/synthesis_event.dart';
import '../synth/query_synthesizer.dart';
import 'memory_retriever.dart';
import 'models/profile_summary.dart';
import 'models/ranked_memory.dart';
import 'profile_builder.dart';

/// How many memories to retrieve per question. Narrow because the
/// always-on profile already covers broad "about me" context — these
/// are for specific, relevance-matched hits.
const int kMemoryAwareLimit = 3;

/// Memory-aware wrapper around [QuerySynthesizer].
///
/// Pulls the cached profile + relevance-ranked memories, then calls
/// [QuerySynthesizer.answerWithContext]. If the memory side fails
/// (corpus empty, retriever errored, embedder unavailable), we fall
/// back to the unaugmented path — memory grounding is additive, not
/// load-bearing.
class MemoryAwareQuerySynthesizer {
  MemoryAwareQuerySynthesizer({
    required this.inner,
    required this.memoryRetriever,
    required this.profileBuilder,
    AppLogger? logger,
  }) : _logger = logger ?? AppLogger();

  final QuerySynthesizer inner;
  final MemoryRetriever memoryRetriever;
  final ProfileBuilder profileBuilder;
  final AppLogger _logger;

  /// Stream an answer for [question] with profile + memory context.
  Stream<SynthesisEvent> answer(
    String question, {
    bool? forceTemporal,
  }) async* {
    final profile = await _loadProfile();
    final memories = await _loadMemories(question);
    yield* inner.answerWithContext(
      question,
      forceTemporal: forceTemporal,
      profile: profile,
      memories: memories,
    );
  }

  Future<ProfileSummary?> _loadProfile() async {
    final r = await profileBuilder.current();
    if (r.isErr) {
      _logger.warn(
        'MemoryAwareQuerySynthesizer: profile load failed: '
        '${r.errOrNull}',
      );
      return null;
    }
    final summary = r.okOrNull!;
    if (summary.summary.trim().isEmpty) return null;
    return summary;
  }

  Future<List<RankedMemory>> _loadMemories(String question) async {
    final r =
        await memoryRetriever.retrieve(question, limit: kMemoryAwareLimit);
    if (r.isErr) {
      _logger.warn(
        'MemoryAwareQuerySynthesizer: memory retrieve failed: '
        '${r.errOrNull}',
      );
      return const <RankedMemory>[];
    }
    return r.okOrNull!;
  }
}
