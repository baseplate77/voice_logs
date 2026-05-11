# VoxSynth (v2)

Privacy-led voice journal. Flutter app. 100% on-device inference. English only for v1.

## Non-negotiables
- Flutter 3.x, Dart 3.x. Null safety, strict lints.
- 100% on-device inference. No network calls for core features. Asserted by `test/no_network_test.dart`.
- Target platforms: iOS 16+, Android 10+ (API 29+).
- No telemetry, no analytics SDKs, no crash reporters.
- All user content (audio, transcripts, embeddings) stays in app's private storage.
- All persistent data encrypted at rest — keys in platform keychain via `flutter_secure_storage`.
- Heavy work (STT, LLM, embedding) on background isolates. UI thread stays responsive.
- Recording stop → user on home list within 500ms, with the raw transcript already searchable.

## Stack (locked)
- **STT:** Parakeet via `sherpa_onnx` (streaming ASR). Model files bundled at `assets/models/parakeet/`.
- **LLM:** Gemma 3 1B IT Q4 LiteRT-LM running through `flutter_gemma`. Replaced SmolLM2 in Phase 7.1 after local eval showed stronger transcript cleanup.
  - Bundle: `assets/models/gemma/Gemma3-1B-IT_multi-prefill-seq_q4_ekv4096.litertlm` (~560 MB, git-ignored, gated HF asset populated manually).
  - Refine is a two-stage pipeline: cleanup JSON first, then exact-substring entity extraction from the cleaned text. No chunker for v1 voice-log lengths.
  - LLM inference is strictly serial. `Gemma3Runner.generate` serializes all calls and the single-worker queue prevents overlapping refine/memory jobs. Same rule applies to any future LLM, regardless of runtime.
- **Embeddings:** e5-small-v2 QInt8 ONNX (`model_opt2_QInt8.onnx` from `nixiesearch/e5-small-v2-onnx`, ~33 MB) via `flutter_onnxruntime`. Bundled in app assets.
  - 384-dim. Mean pooling over `last_hidden_state` with attention mask. L2-normalize before storage.
  - Prompt prefixes: `"query: "` for search queries, `"passage: "` for indexed content. Non-optional.
- **Storage:** `drift` on `sqlite3` 3.x (build hooks → SQLite3MultipleCiphers for SQLCipher wire format). **FTS5** for keyword search. **sqlite-vec** for vector search — extension-loading spike in Phase 3.
- **State:** Riverpod 2.x.
- **Background:** `workmanager` (Android), `BGTaskScheduler` via platform channel (iOS).
- **Data classes:** `freezed` + `json_serializable`.

## Pipeline
1. **Record + stream STT (live):** Parakeet streams partial transcripts into the UI.
2. **Stop (<500ms):** persist audio file + raw transcript, enqueue `refine` job, return to list. User is free.
3. **Refine (background, ~10–20s):** SmolLM2 runs a `record_log(cleaned_text, entities[])`-style prompt over the whole transcript. Char offsets recovered in Dart by forward-scan matching against `cleaned_text`. JSON parse failure → one structured retry; second failure → fall back to raw transcript with no entities.
4. **Embed (background, ~1–3s):** e5-small-v2 per-segment (~200-token chunks, 1-sentence overlap), L2-normalized, stored per-segment in `sqlite-vec`.
5. **Canonicalize entities (background, <1s):** similarity match via e5 on `(mention_text + local context)` against the user's canonical entity graph. Link or create.

## Single-worker isolate
One long-lived isolate hosts SmolLM2 + e5. FIFO queue, newest-first within priority. Never run two inferences concurrently.

- e5 is resident always (~33 MB).
- SmolLM2 loads on first refine job, stays warm 5 minutes after last use, then unloads (~200–400 MB RAM).
- On app resume, any job whose `state != 'embedded'` is resumed.

## Hybrid search
Reciprocal rank fusion (k=60) over three paths:
1. FTS5 on `raw_transcript` + `cleaned_text`.
2. Vector cosine (sqlite-vec) on segment embeddings, query prefixed `"query: "`, top 20.
3. Entity filter: if the query matches a canonical entity, boost all logs mentioning it.

Raw-transcript-only results are always included — this is the guarantee that search works the instant recording stops, even before refine finishes.

## Memory subsystem (planned)
Local-only durable memory is planned after entity canonicalization. It is an evidence-backed layer of user facts, preferences, relationships, projects, routines, places, and useful ongoing context extracted from refined logs.

- No cloud memory, sync, telemetry, crash reporting, or remote model APIs.
- Memory extraction runs as a background job after refine/embed/canonicalize; never blocks record stop.
- Memories are stored in encrypted Drift tables with source evidence back to voice logs and char offsets.
- Memory retrieval uses local FTS5 + sqlite-vec + entity boosts, with e5 prefixes enforced (`"passage: "` for memory cards, `"query: "` for lookups).
- Sensitive memories stay in review/candidate state and are not used in Gemma prompts until confirmed.
- Users must be able to inspect, edit, merge, delete, export, and disable memory.
- Full design lives in `docs/memory_subsystem.md`; implementation is scheduled as Phase 5.5.

## Directory layout
```
lib/
  core/
    result.dart        -- Result<T, AppError>
    app_error.dart
    logger.dart
    db/
      database.dart    -- @DriftDatabase, migration, LazyDatabase factory
      schema/          -- one file per table
  features/
    record/            -- recording screen + capture service
    list/              -- home list
    detail/            -- per-log detail view
    search/            -- hybrid search + embedder
    settings/
  app.dart             -- root MaterialApp
  main.dart            -- ProviderScope entry
assets/
  models/
    silero_vad.onnx    -- optional (endpointing)
    e5/                -- model_opt2_QInt8.onnx + tokenizer.json
    parakeet/          -- encoder/decoder/joiner.int8.onnx + tokens.txt
    smollm/            -- model.onnx (INT8) + tokenizer.json + tokenizer_config.json
```

## Coding rules
- No `print`. Use the `Logger` in `lib/core/logger.dart`.
- No singletons. Use Riverpod providers.
- All async operations return `Result<T, AppError>` across layer boundaries — never throw across layers.
- One widget per file. Files named after the widget.
- Public APIs documented with `///`. Private helpers do not need doc comments.
- No TODO comments in merged code. If incomplete, it's a draft PR.

## How to work on this repo
- Read this file first every session.
- Read `IMPLEMENTATION_PLAN.md` to find the current phase.
- Before writing any code, state which phase you are working on and list the files you will touch.
- Write tests alongside implementation. No untested repository or service.
- `make analyze` (`dart analyze --fatal-infos` + `dart format --set-exit-if-changed`) and `flutter test` clean before declaring a task done.
- `make codegen` after drift / freezed / json_serializable changes.
- When something could be built in two ways, ask. Do not silently pick one.
