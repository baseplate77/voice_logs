import '../core/logger.dart';
import '../llm/llm_runner.dart';
import '../llm/prompt_templates.dart';
import '../retrieve/hybrid_retriever.dart';
import '../retrieve/models/ranked_chunk.dart';
import 'citation_formatter.dart';
import 'models/synthesis_event.dart';
import 'multi_hop_retriever.dart';
import 'temporal_trigger.dart';

/// Top-k chunks fed into the simple-path prompt. Larger k fills the
/// prompt with near-miss chunks the reranker already demoted; smaller
/// k drops too much context. Plan §7 pins it at 5.
const int kSynthSimpleChunkLimit = 5;

const PromptTemplate _simpleTemplate = PromptTemplate(
  name: 'synth_simple',
  body: '''
You are VoxSynth, a personal voice-log assistant. Answer the user's
question using ONLY the source snippets below. Every non-trivial claim
must be followed by a `[Cn]` citation matching one of the source
labels. If none of the sources answer the question, say so briefly in
one sentence — do not fabricate.

Sources:
{{sources}}

Question: {{question}}

Answer:
''',
  requiredVariables: <String>['sources', 'question'],
);

const PromptTemplate _simpleRetryTemplate = PromptTemplate(
  name: 'synth_simple_retry',
  body: '''
Your previous answer did not include any `[Cn]` citation markers. That
is not acceptable. Answer the question again using ONLY the sources
below. Every sentence must end with at least one `[Cn]` marker that
matches a source label (e.g. "The pricing decision was made [C2].").

Sources:
{{sources}}

Question: {{question}}

Answer:
''',
  requiredVariables: <String>['sources', 'question'],
);

const PromptTemplate _temporalTemplate = PromptTemplate(
  name: 'synth_temporal',
  body: '''
You are VoxSynth, a personal voice-log assistant. The user is asking a
question about how a topic has evolved over time. Below are sources
grouped by week, oldest week first. Narrate the evolution
chronologically — week by week — citing each week's sources with
`[Cn]` markers. If a week has no noteworthy change, it is fine to skip
it. Do not fabricate.

Sources (oldest → newest):
{{sources}}

Question: {{question}}

Answer:
''',
  requiredVariables: <String>['sources', 'question'],
);

const PromptTemplate _temporalRetryTemplate = PromptTemplate(
  name: 'synth_temporal_retry',
  body: '''
Your previous answer did not include any `[Cn]` citation markers. Try
again. Narrate the evolution chronologically, and end every sentence
with at least one `[Cn]` marker that matches a source label.

Sources (oldest → newest):
{{sources}}

Question: {{question}}

Answer:
''',
  requiredVariables: <String>['sources', 'question'],
);

/// Streaming RAG answerer. Bridges [HybridRetriever] +
/// [MultiHopRetriever] to an [LlmRunner].
///
/// Two paths, selected by [isTemporalQuery] (or by [forceTemporal]):
///
/// - **Simple:** top-5 hybrid retrieve → single-prompt generation.
/// - **Temporal:** multi-hop week-clustered retrieve → single prompt
///   with chronological sources.
///
/// Citation-aware: if the streamed answer contains no `[Cn]` markers,
/// we retry once with a stricter prompt before giving up.
class QuerySynthesizer {
  QuerySynthesizer({
    required this.retriever,
    required this.multiHopRetriever,
    required this.runner,
    this.temporalTrigger = isTemporalQuery,
    AppLogger? logger,
  }) : _logger = logger ?? AppLogger();

  final HybridRetriever retriever;
  final MultiHopRetriever multiHopRetriever;
  final LlmRunner runner;

  /// Predicate deciding whether to take the temporal branch. Injectable
  /// so callers can override the default keyword classifier.
  final bool Function(String) temporalTrigger;
  final AppLogger _logger;

  /// Stream an answer for [question].
  ///
  /// - `forceTemporal`: bypasses [temporalTrigger] and takes the
  ///   multi-hop path. Used by background jobs that already know the
  ///   question is time-shaped.
  Stream<SynthesisEvent> answer(
    String question, {
    bool? forceTemporal,
  }) async* {
    yield const RetrievalStarted();
    final trimmed = question.trim();
    if (trimmed.isEmpty) {
      yield const SynthesisFailed(message: 'question was empty');
      return;
    }
    final useTemporal = forceTemporal ?? temporalTrigger(trimmed);
    try {
      if (useTemporal) {
        yield* _temporalPath(trimmed);
      } else {
        yield* _simplePath(trimmed);
      }
    } on Object catch (e, st) {
      _logger.error('synthesis failed', error: e, stackTrace: st);
      yield SynthesisFailed(
        message: 'synthesis failed: $e',
        cause: e,
      );
    }
  }

  Stream<SynthesisEvent> _simplePath(String question) async* {
    // kSynthSimpleChunkLimit matches HybridRetriever.retrieve's default
    // limit; kept named so changes land in both places.
    assert(kSynthSimpleChunkLimit == 5,
        'bump HybridRetriever default limit too');
    final r = await retriever.retrieve(question);
    if (r.isErr) {
      yield SynthesisFailed(
        message: 'retrieve failed',
        cause: r.errOrNull,
      );
      return;
    }
    final chunks = r.okOrNull!;
    yield RetrievalComplete(chunks: chunks);
    if (chunks.isEmpty) {
      yield const SynthesisComplete(answer: '', citations: <Citation>[]);
      return;
    }
    final formatted = formatChunksForPrompt(chunks);
    final prompt = _simpleTemplate.render(<String, String>{
      'sources': formatted.block,
      'question': question,
    });
    yield* _streamWithCitationRetry(
      prompt: prompt,
      tagToChunkId: formatted.tagToChunkId,
      retryBuilder: () => _simpleRetryTemplate.render(<String, String>{
        'sources': formatted.block,
        'question': question,
      }),
    );
  }

  Stream<SynthesisEvent> _temporalPath(String question) async* {
    final r = await multiHopRetriever.retrieveTemporal(question);
    if (r.isErr) {
      yield SynthesisFailed(
        message: 'temporal retrieve failed',
        cause: r.errOrNull,
      );
      return;
    }
    final weeks = r.okOrNull!;
    // Fall back to the simple path when the multi-hop returns nothing.
    // Temporal trigger is a cheap classifier — not every "changed"
    // question actually has a week-structured corpus behind it.
    if (weeks.isEmpty) {
      yield* _simplePath(question);
      return;
    }
    // Flatten clusters into RankedChunks (chronological) for the
    // RetrievalComplete payload. The prompt sees the week structure,
    // the UI sees a flat "here's what we'll cite" list.
    final flat = <RankedChunk>[];
    for (final w in weeks) {
      flat.addAll(w.chunks);
    }
    yield RetrievalComplete(chunks: flat);
    final formatted = formatWeekClustersForPrompt(weeks);
    final prompt = _temporalTemplate.render(<String, String>{
      'sources': formatted.block,
      'question': question,
    });
    yield* _streamWithCitationRetry(
      prompt: prompt,
      tagToChunkId: formatted.tagToChunkId,
      retryBuilder: () => _temporalRetryTemplate.render(<String, String>{
        'sources': formatted.block,
        'question': question,
      }),
    );
  }

  /// Stream [prompt] through the LLM, emit [TokenGenerated] for each
  /// token, and emit a terminal event:
  ///
  /// - [SynthesisComplete] with resolved citations when the answer
  ///   contains at least one valid `[Cn]` marker, OR when the retry
  ///   also fails (we take whatever we got).
  /// - [SynthesisFailed] if the stream throws.
  ///
  /// On no-citation answers, re-streams [retryBuilder]; tokens from
  /// both passes appear in the event stream (the terminal answer is
  /// the retry's — see class-level doc). UIs that replay tokens as
  /// they arrive should clear on the second [TokenGenerated] burst.
  Stream<SynthesisEvent> _streamWithCitationRetry({
    required String prompt,
    required Map<String, int> tagToChunkId,
    required String Function() retryBuilder,
  }) async* {
    final firstBuf = StringBuffer();
    try {
      await for (final tok in runner.generate(prompt)) {
        firstBuf.write(tok);
        yield TokenGenerated(token: tok);
      }
    } on Object catch (e) {
      yield SynthesisFailed(message: 'LLM stream failed: $e', cause: e);
      return;
    }
    var answer = firstBuf.toString();
    if (!answerHasCitations(answer, tagToChunkId)) {
      _logger.warn('synth: no citations in first pass, retrying');
      final retryPrompt = retryBuilder();
      final retryBuf = StringBuffer();
      try {
        await for (final tok in runner.generate(retryPrompt)) {
          retryBuf.write(tok);
          yield TokenGenerated(token: tok);
        }
      } on Object catch (e) {
        yield SynthesisFailed(
          message: 'LLM retry stream failed: $e',
          cause: e,
        );
        return;
      }
      // Only replace the answer if the retry produced citations —
      // otherwise the first pass is at least a real attempt.
      final retryAnswer = retryBuf.toString();
      if (answerHasCitations(retryAnswer, tagToChunkId)) {
        answer = retryAnswer;
      }
    }
    yield SynthesisComplete(
      answer: answer,
      citations: parseCitations(answer, tagToChunkId),
    );
  }
}
