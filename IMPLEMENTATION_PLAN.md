# VoxSynth — Implementation plan for Claude Code

A local-first voice-log synthesizer in Flutter. Everything runs on-device: Whisper for transcription, Gemma for structuring and synthesis, ObjectBox for vector search, SQLite for metadata and keyword search.

This document is for Claude Code to read. Feed it one phase at a time. Do not let it skip ahead.

---

## 0. Before you start Claude Code

Get these right manually. They are the things Claude Code gets wrong most often when left to improvise.

1. **Flutter channel:** stable. Check `flutter --version` ≥ 3.24.
2. **Create the repo** and `flutter create voxsynth --org com.nj.voxsynth --platforms=ios,android`.
3. **Write `CLAUDE.md`** at repo root with the content in section 1 below. Claude Code reads this on every session — it is how you prevent re-litigation of architectural decisions.
4. **Lock package versions** in `pubspec.yaml` before Claude Code touches it. Pinning avoids the common failure mode where Claude Code upgrades a package mid-phase and breaks earlier work.
5. **Pre-download the model files** to `assets/models/` (Whisper small int8, multilingual-e5-small int8, Gemma INT4). Do not let Claude Code fetch these — it will waste time on broken HuggingFace URLs.
6. **iOS permissions:** add `NSMicrophoneUsageDescription`, `NSSpeechRecognitionUsageDescription` to `Info.plist` manually. **Android:** `RECORD_AUDIO`, `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_MICROPHONE`, `POST_NOTIFICATIONS`, `WAKE_LOCK` in `AndroidManifest.xml`.
7. **Git hygiene:** one commit per phase, branch per phase (`phase-1-capture`, etc.), squash-merge to main only after the phase's acceptance criteria pass.

---

## 1. `CLAUDE.md` — paste this into repo root

See `CLAUDE.md` at repo root.

---

## 2. Phase 1 — Audio capture + VAD

**Goal:** a working `CaptureService` that records mic audio, runs Silero VAD on it, emits speech segments.

**Files to produce:**
- `lib/capture/capture_service.dart`
- `lib/capture/vad_runner.dart`
- `lib/capture/models/speech_segment.dart`
- `lib/capture/capture_service_test.dart`
- `lib/capture/vad_runner_test.dart`

**Prompt for Claude Code:**

```
Implement Phase 1 from IMPLEMENTATION_PLAN.md.

Interfaces to produce:

abstract class CaptureService {
  Future<void> start();
  Future<void> pause();
  Future<RecordingHandle> stop();
  Stream<SpeechSegment> get segments;
  Stream<CaptureState> get state;
}

class SpeechSegment {
  final int startMs;
  final int endMs;
  final Uint8List pcm16kMono;
}

Requirements:
- Use `record` package for PCM 16kHz mono.
- Run Silero VAD (ONNX, assets/models/silero_vad.onnx) via `onnxruntime` on a background isolate.
- VAD emits segments with at least 300ms of speech, separated by at least 500ms of silence. Expose these as constants.
- Do not accumulate audio in memory beyond a rolling 60s buffer. Flush completed segments to tmp disk.
- Handle permission-denied explicitly, return a typed AppError.
- Write unit tests with a fake VAD runner and a fixed PCM fixture.
- Do not add UI yet.
```

**Acceptance criteria:**
- `flutter test` passes with ≥80% coverage on `capture/`.
- `flutter analyze` clean.
- Manual test: record "one two three [5s silence] four five six" → two segments emitted.
- Memory usage stable over a 10-minute idle recording (check with profiler).

**Gotchas Claude Code hits here:**
- It will try to use `flutter_sound` instead of `record`. Reject — `record` has better 16kHz PCM support and lower latency.
- It will put VAD on the main isolate. Reject — must be `Isolate.spawn` or `compute`.
- It will forget to release the ONNX session on `dispose`. Explicitly ask for lifecycle tests.
- It will use `Stream.broadcast()` without backpressure. Ask for a bounded buffer.

---

## 3. Phase 2 — Whisper ASR + chunking

**Goal:** given a `SpeechSegment` or a long `RecordingHandle`, produce a clean transcript with word-level timestamps.

**Files to produce:**
- `lib/asr/whisper_ffi.dart` (raw FFI bindings)
- `lib/asr/whisper_runner.dart` (Dart-side wrapper, runs on isolate)
- `lib/asr/chunker.dart` (30s windows, 2s overlap, stitching)
- `lib/asr/models/transcript.dart`
- tests for each

**Prompt for Claude Code:**

```
Implement Phase 2. Depends on Phase 1.

The whisper.cpp native library is already built. iOS dylib is at
ios/Frameworks/whisper.xcframework, Android shared libs are at
android/src/main/jniLibs/{arm64-v8a,armeabi-v7a,x86_64}/libwhisper.so.
The model file is at assets/models/ggml-small-q8_0.bin.

Interfaces:

abstract class WhisperRunner {
  Future<void> load({required String modelPath, int threads = 4});
  Future<Transcript> transcribe(Uint8List pcm16kMono, {String? languageHint});
  Future<void> dispose();
}

class Transcript {
  final String text;
  final List<Word> words;  // with startMs, endMs, confidence
  final String detectedLanguage;
}

Requirements:
- FFI bindings via `dart:ffi`. Use `ffi` package, not raw pointers.
- All FFI calls happen on a dedicated Isolate — never the main one.
- For audio > 30s, chunk into 30s windows with 2s overlap. Stitch at word boundaries using Needleman-Wunsch on the overlap region. Keep the stitching simple — longest common suffix/prefix is fine as a v1.
- Expose progress as a Stream<double> 0.0-1.0.
- Support explicit language hint ('hi', 'mr', 'en') but default to auto-detect.
- Tests: round-trip a fixture WAV and assert transcript matches within edit-distance 3.

Do not touch the native build files. If you think they need changes, stop and ask.
```

**Acceptance criteria:**
- Transcribes a 10s English clip, a 10s Marathi clip, a 10s Hindi clip from `test/fixtures/`.
- 60s clip transcribed with correct stitching (no duplicated words at chunk boundaries).
- UI thread stays responsive during transcription (manual test: scroll a list while transcribing).

**Gotchas:**
- Claude Code will try to load Whisper on the main isolate. Stop it.
- It will hallucinate the whisper.cpp API. Feed it the actual header file (`whisper.h`) as context before asking it to write bindings.
- Stitching at chunk boundaries is where it introduces bugs. Write the stitch test first, then ask it to implement.

---

## 4. Phase 3 — Gemma wrapper + cleanup pipeline

**Goal:** Gemma runs on-device, callable with templated prompts. First use: clean up a raw transcript (remove fillers, fix punctuation, detect topic boundaries for chunking).

**Files to produce:**
- `lib/llm/gemma_runner.dart`
- `lib/llm/prompt_templates.dart`
- `lib/llm/cleanup_pipeline.dart`
- `lib/llm/topic_chunker.dart`
- tests

**Prompt for Claude Code:**

```
Implement Phase 3. Depends on Phases 1-2.

Gemma model is at assets/models/gemma-4-it-int4.task. Use `flutter_gemma`
package as the inference backend. If you think a different package is needed,
stop and ask — do not silently swap.

Interfaces:

abstract class GemmaRunner {
  Future<void> load({int maxTokens = 2048, double temperature = 0.3});
  Stream<String> generate(String prompt, {double? temperatureOverride});
  Future<String> generateSync(String prompt);
  Future<void> dispose();
}

class CleanupPipeline {
  Future<CleanedTranscript> clean(Transcript raw);
}

class CleanedTranscript {
  final String text;                    // fillers removed, punctuation added
  final List<TopicChunk> chunks;        // semantic boundaries
  final List<Entity> entities;          // names, projects, decisions
  final List<String> tags;
}

Requirements:
- Prompt templates in `prompt_templates.dart` as top-level const strings, not
  inlined in code. Each template has a name, a required variables list, and
  unit tests that assert the rendered prompt contains the variables.
- Cleanup prompt must be deterministic enough that temperature 0.3 produces
  identical output across three runs on the same fixture (within 5% edit
  distance).
- Topic chunker: Gemma identifies boundary token positions. Chunks must be
  50-500 words. If Gemma returns bad boundaries (overlapping, out of range),
  fall back to fixed 200-word chunks with a logged warning.
- Entity extraction: JSON output, parsed strictly. If JSON parse fails, retry
  once with a stricter prompt, then fall back to an empty entity list.
- All Gemma calls run on a dedicated isolate. Load once, reuse.

Tests must use a mocked GemmaRunner — do not hit the real model in unit tests.
Integration tests (tagged @integration) can hit the real model, but only one
sample per test run.
```

**Acceptance criteria:**
- Unit tests pass with mocked runner.
- Integration test: clean a 2-minute fixture transcript, verify (a) fillers removed, (b) 3-6 topic chunks, (c) at least 2 entities extracted.
- Memory stable — load Gemma, run 50 cleanups, no leak (check with DevTools).

**Gotchas:**
- Claude Code will inline prompts in the pipeline code. Force the template file pattern.
- It will not retry on bad JSON. Be explicit about the retry policy.
- Gemma may fail to load with OOM on older Android devices. Add a probe at startup and surface a clear error.

---

## 5. Phase 4 — Embeddings + ObjectBox vector index

**Goal:** embed chunks, store them, query by cosine similarity with HNSW.

**Files to produce:**
- `lib/embed/embedder.dart` (e5-small wrapper)
- `lib/store/objectbox_store.dart`
- `lib/store/drift_store.dart`
- `lib/store/audio_file_store.dart`
- `lib/store/voice_log_repository.dart` (the layer the rest of the app uses)
- schema migration files
- tests

**Prompt for Claude Code:**

```
Implement Phase 4. Depends on Phases 1-3.

Embedding model: assets/models/multilingual-e5-small-int8.onnx (384-dim output).
Run via `onnxruntime` package, on a dedicated isolate, batched (up to 16
chunks per call).

Interfaces:

abstract class Embedder {
  Future<void> load();
  Future<List<Float32List>> embed(List<String> texts);
  Future<void> dispose();
}

// Drift tables:
// voice_logs(id, created_at, duration_sec, audio_path, raw_transcript,
//            cleaned_transcript, source_tag, language)
// chunks(id, log_id FK, text, start_sec, end_sec, topic_cluster_id,
//        created_at, objectbox_id)
// entities(id, canonical_name, aliases_json, first_seen, last_seen)
// chunk_entities(chunk_id, entity_id)
// FTS5 virtual table: chunks_fts(text, content='chunks')

// ObjectBox entity:
@Entity()
class ChunkVector {
  int id;  // matches chunks.objectbox_id
  @HnswIndex(dimensions: 384, distanceType: VectorDistanceType.cosine)
  List<double> embedding;
}

class VoiceLogRepository {
  Future<VoiceLogId> ingest({
    required RecordingHandle recording,
    required Transcript transcript,
    required CleanedTranscript cleaned,
  });
  Future<List<Chunk>> keywordSearch(String query, {int limit = 20});
  Future<List<Chunk>> vectorSearch(Float32List queryVec, {int limit = 20});
  Future<VoiceLog?> getLog(VoiceLogId id);
  Future<void> deleteLog(VoiceLogId id);  // cascades to chunks + vectors + audio
}

Requirements:
- E5 requires a "query: " or "passage: " prefix. Enforce this via two methods:
  `embedPassages` and `embedQuery`. Make the unprefixed `embed` private.
- Embeddings stored as List<double> for ObjectBox but converted to/from
  Float32List at the API boundary (memory matters).
- Drift migration from v0: single migration script. Test the migration
  with a fixture v0 DB.
- Deletion must be atomic across drift + objectbox + filesystem. Write a
  test that simulates a crash mid-delete and verifies recovery on next
  startup (orphan cleanup job).
- Encryption: SQLCipher via `drift_sqflite_sqlcipher` (or equivalent).
  Key is 32 bytes, stored in platform keychain via `flutter_secure_storage`.
  First-run generates the key.

Tests should include a full ingest → search → delete cycle.
```

**Acceptance criteria:**
- Ingest 100 fixture logs, keyword search returns relevant results in <50ms, vector search in <100ms.
- Kill the app mid-ingest, restart — no orphaned chunks, no orphaned vectors.
- Delete a log — every trace of it (DB, vector, audio file) is gone.

**Gotchas:**
- E5 prefix is the #1 mistake. Without "passage: " / "query: ", retrieval quality drops ~30%.
- Claude Code will store Float32List in ObjectBox directly — it does not serialize. Must be `List<double>`.
- ObjectBox codegen (`dart run build_runner build`) must run after entity changes. Claude Code forgets this.
- SQLCipher setup is platform-specific. Be explicit about which package/version.

---

## 6. Phase 5 — Hybrid retrieval + reranker

**Goal:** given a user query, return the top-k most relevant chunks using BM25 + vectors + Gemma reranking.

**Files to produce:**
- `lib/retrieve/query_expander.dart`
- `lib/retrieve/hybrid_retriever.dart`
- `lib/retrieve/reranker.dart`
- `lib/retrieve/time_decay.dart`
- tests

**Prompt for Claude Code:**

```
Implement Phase 5. Depends on Phase 4.

Interfaces:

class HybridRetriever {
  Future<List<RankedChunk>> retrieve(
    String query, {
    int limit = 5,
    DateRange? dateRange,
    double timeDecayHalfLifeDays = 30,
  });
}

class RankedChunk {
  final Chunk chunk;
  final double fusedScore;
  final double bm25Score;
  final double vectorScore;
  final double rerankScore;
  final double timeDecayFactor;
}

Algorithm:
1. Query expansion: Gemma generates 2 paraphrases + extracts key entities.
   Original + paraphrases form the expanded query set.
2. For each expanded query:
   - BM25 via SQLite FTS5, top 30
   - Vector cosine via ObjectBox, top 30
3. Reciprocal rank fusion across all result lists (k=60).
4. Take top 20 after RRF.
5. Apply time decay: fused *= exp(-age_days * ln(2) / halfLifeDays).
6. Rerank top 20 with Gemma: score each chunk 0-10 for relevance to
   original query. Use a compact prompt that fits 20 chunks into
   context (summaries if chunk > 200 words).
7. Return top `limit` by final score.

Requirements:
- Everything after step 1 runs in parallel where possible (Future.wait).
- Full retrieve latency target: <2s on a Pixel 8 / iPhone 15 for a 10k-chunk corpus.
- Expose intermediate scores in RankedChunk so we can debug retrieval quality.
- Benchmark test: a fixed 1000-chunk fixture, a set of 20 queries with
  gold-labeled relevant chunks, asserts recall@5 >= 0.85.
```

**Acceptance criteria:**
- Recall@5 ≥ 0.85 on the benchmark.
- Latency target met on profiled device.
- Query "what did I say about GlowUp pricing last week" correctly filters to the last 7 days.

**Gotchas:**
- Claude Code will skip query expansion or reranking to save tokens. Insist on all steps.
- Time decay formula: off-by-one bugs are common. Add an explicit test.
- FTS5 tokenizer config for Hindi/Marathi is not obvious. Use `unicode61 remove_diacritics 2` and test with a Marathi query.

---

## 7. Phase 6 — RAG synthesis (query path)

**Goal:** user asks a question, gets a cited answer.

**Files to produce:**
- `lib/synth/query_synthesizer.dart`
- `lib/synth/multi_hop_retriever.dart`
- `lib/synth/citation_formatter.dart`
- tests

**Prompt for Claude Code:**

```
Implement Phase 6. Depends on Phase 5.

Interfaces:

class QuerySynthesizer {
  Stream<SynthesisEvent> answer(String question);
}

sealed class SynthesisEvent {}
class RetrievalStarted extends SynthesisEvent {}
class RetrievalComplete extends SynthesisEvent {
  final List<RankedChunk> chunks;
}
class TokenGenerated extends SynthesisEvent { final String token; }
class SynthesisComplete extends SynthesisEvent {
  final String answer;
  final List<Citation> citations;  // chunk_id + span in answer text
}

Two query paths:

SIMPLE (default): single-shot RAG.
1. HybridRetriever.retrieve(question, limit=5)
2. Format prompt with chunks, each tagged [C1]..[C5]
3. Gemma generates answer, must cite using [Cn] markers
4. Post-process: parse citations, map to chunk IDs

TEMPORAL (triggered by phrases like "how has", "over time", "evolved",
"changed", "this week", "this month", or explicitly by the caller):
1. First hop: retrieve with broad query, cluster results by week
2. For each week-cluster with ≥2 results: retrieve densely within that week
3. Synthesize across weeks in a single Gemma call, ordered chronologically,
   showing the evolution

Trigger detection is a simple keyword classifier, documented in a single
constant list. No ML classifier.

Requirements:
- Streaming tokens for good UX.
- Citation markers in output are non-optional. If Gemma fails to cite,
  retry once with a stricter prompt.
- Unit tests mock Gemma and assert prompt structure.
- Integration test: ask "what did I decide about X" against a fixture
  corpus, verify the answer references the correct chunk.
```

**Acceptance criteria:**
- Tokens stream visibly (<500ms to first token).
- Every sentence in the answer has at least one citation.
- Temporal query returns a chronological narrative.

**Gotchas:**
- Gemma drops citation markers sometimes. The retry prompt matters. Write it carefully.
- Multi-hop can blow the context window. Keep chunk counts tight.

---

## 8. Phase 7 — Background synthesis jobs

**Goal:** daily brief, weekly themes, monthly shifts — all generated while the device is charging + idle.

**Files to produce:**
- `lib/synth/background/daily_brief_job.dart`
- `lib/synth/background/weekly_themes_job.dart`
- `lib/synth/background/monthly_shifts_job.dart`
- `lib/synth/background/scheduler.dart`
- tests

**Prompt for Claude Code:**

```
Implement Phase 7. Depends on Phase 6.

Use `workmanager` package. Each job:
- Registers with a unique name.
- Runs only when: charging OR battery > 50%, device idle, on WiFi is NOT required (we're local).
- Has a max runtime and kills itself cleanly if exceeded.
- Writes a Synthesis record to the database on success.

Jobs:

DailyBriefJob (runs at 02:00 local):
  Input: today's chunks
  Output: action items extracted, 3-5 key moments, 1-paragraph summary

WeeklyThemesJob (runs Sunday 02:30):
  Input: last 7 days of chunks
  Output: 3-5 recurring themes with supporting chunk IDs, list of
  contradictions (positions that shifted during the week)

MonthlyShiftsJob (runs 1st of month 03:00):
  Input: last 30 days of Synthesis records + chunks
  Output: what changed this month vs the previous month

Requirements:
- All jobs idempotent. Re-running produces the same output (temperature
  set low, prompts deterministic, inputs deterministically ordered).
- If a job crashes, log to `lib/core/logger.dart` and reschedule for the
  next slot. Do not retry immediately.
- Scheduler exposes a test-mode that runs a job immediately, for debugging
  in development builds.
- Each job's output schema is a Dart data class with `freezed`.

Tests: mock the repository, assert the job produces the expected Synthesis
structure from a fixture corpus.
```

**Acceptance criteria:**
- Daily job runs overnight on a real device, brief is visible on next open.
- Weekly job output contains at least one theme with >1 supporting chunk.
- All jobs complete in under 60s on target hardware.

**Gotchas:**
- iOS background execution is restrictive. Test on a real iPhone, not just simulator.
- `workmanager` quirks per platform — be ready to diverge per platform.

---

## 9. How to work with Claude Code on this

**Patterns that work:**
- Feed one phase at a time. Paste the prompt block, not the whole plan.
- Before each phase, tell it to re-read `CLAUDE.md` and `IMPLEMENTATION_PLAN.md`.
- Ask for the test file first, then the implementation. Forces it to think about the interface.
- Make it commit after every passing test. Small commits, easy rollback.
- When it hallucinates a package or API, paste the real docs and ask it to redo.

**Anti-patterns to avoid:**
- "Implement the whole app." You will get 800 lines of broken glue code.
- Letting it run `dart run build_runner` without reviewing generated code — catches bugs early to eyeball the diff.
- Accepting "it compiles" as done. The acceptance criteria per phase are the real bar.
- Letting it add packages unilaterally. Every new package is a small architectural decision. Approve explicitly.

**Per-phase discipline:**
1. Open a branch `phase-N-{slug}`.
2. Paste the phase prompt block.
3. Review files produced — do they match the declared file list?
4. Run `flutter analyze` — zero warnings.
5. Run `flutter test` — all green.
6. Run the phase's integration/manual tests.
7. Hit the acceptance criteria, not a subset.
8. Merge to main with a squashed commit: `feat: phase N - {name}`.
9. Tag the commit `phase-N-done`.

**If you get stuck:** ask Claude Code to explain what it did in the last 3 commits. If the explanation doesn't match what you asked for, roll back and restart the phase with a tighter prompt.

---

## 10. What comes after the plan

These are out of scope for v1 but worth noting so you don't let Claude Code build them prematurely:

- Obsidian / Markdown export
- iCloud / Google Drive encrypted backup
- Desktop (macOS, Windows) — same Flutter codebase, different native libs
- Shared corpus for teams (would break the local-first premise; needs careful thought)
- Voice-activated queries ("hey VoxSynth, what did I decide about...") — wake-word model, extra complexity

Ship v1 first. Use it daily for 30 days. Then decide.
