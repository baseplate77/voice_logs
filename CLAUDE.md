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
- **LLM:** `flutter_gemma` (MediaPipe / LiteRT-LM) running Gemma 4 E2B IT.
  - **User override** of the original spec's `fllama` choice — `flutter_gemma`'s GPU path is materially faster on mobile.
  - Bundle: `assets/models/gemma/gemma-4-E2B-it.litertlm` (~2.58 GB, git-ignored, fetched via `scripts/fetch_models.sh`).
  - `maxTokens` is hard-baked at 2048 in the litertlm bundle — shrink input instead of raising it.
  - Gemma inference is strictly serial. Concurrent sessions OOM on mobile — all callers go through a single queue.
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
3. **Refine (background, ~15–25s):** Gemma runs a `record_log(cleaned_text, entities[])` function-call-style prompt. Char offsets recovered in Dart by forward-scan matching against `cleaned_text`.
4. **Embed (background, ~1–3s):** e5-small-v2 per-segment (~200-token chunks, 1-sentence overlap), L2-normalized, stored per-segment in `sqlite-vec`.
5. **Canonicalize entities (background, <1s):** similarity match via e5 on `(mention_text + local context)` against the user's canonical entity graph. Link or create.

## Single-worker isolate
One long-lived isolate hosts Gemma + e5. FIFO queue, newest-first within priority. Never run two inferences concurrently.

- e5 is resident always (~33 MB).
- Gemma loads on first refine job, stays warm 60s after last use, then unloads (~1.3 GB RAM).
- On app resume, any job whose `state != 'embedded'` is resumed.

## Hybrid search
Reciprocal rank fusion (k=60) over three paths:
1. FTS5 on `raw_transcript` + `cleaned_text`.
2. Vector cosine (sqlite-vec) on segment embeddings, query prefixed `"query: "`, top 20.
3. Entity filter: if the query matches a canonical entity, boost all logs mentioning it.

Raw-transcript-only results are always included — this is the guarantee that search works the instant recording stops, even before refine finishes.

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
    gemma/             -- gemma-4-E2B-it.litertlm
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
