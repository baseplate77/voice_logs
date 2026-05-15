# VoxSynth (v2) — implementation plan

Greenfield rewrite on branch `v2` per the new privacy-first spec. Phases
0–6, plus a memory subsystem phase after entity canonicalization. Each phase ends with a demo stop — do not roll one phase into the next.

The locked stack and non-negotiables live in `CLAUDE.md`; this file only
lists the phased delivery shape.

---

## Phase 0 — Scaffolding (1 day)

No features. Proves the project compiles, the DB migrates, and the
analyze/test loop is green.

**Delivered in this PR:**
- Feature-based folder structure: `lib/features/{record,list,detail,search,settings}/` + `lib/core/` (`Result`, `AppError`, `Logger`, drift schema).
- Riverpod + `ProviderScope` wired at `main.dart`.
- drift schema v1: `VoiceLogs`, `EntityMentions`, `CanonicalEntities`, `ProcessingJobs` + FTS5 virtual table.
- `pubspec.yaml` rewritten for v2 stack (sherpa_onnx, flutter_onnxruntime, flutter_gemma, drift, sqlite3+mc).
- E5 model + tokenizer bundled at `assets/models/e5/` (verify ~33 MB via `scripts/fetch_models.sh`).
- Android `minSdkVersion 29`, iOS deployment target 16.0, microphone permissions in place.
- `analysis_options.yaml` with strict lints + `Makefile` (`make analyze`, `make test`, `make codegen`, `make check`).
- `test/no_network_test.dart` — walks `lib/` and fails on banned network imports outside `lib/sync/`.
- `test/widget_test.dart` — smoke test that the app boots.

**Deferred decisions flagged in the Phase 0 PR:**
- `sqlite-vec` loading path — no first-class Flutter package; two candidates (`sqlite_vector`, `sqlite_vec`), both pre-1.0. Spike in Phase 3.
- `flutter_isolate` staleness (last publish 19 months ago) — Phase 1 decides between pinning and using `Isolate.spawn` + plugin isolate pattern.
- Whether to keep `silero_vad.onnx` — kept in assets by default; wire or drop in Phase 1 if Parakeet's streaming VAD is enough.

---

## Phase 1 — Recording + Parakeet STT (2–3 days)

Audio capture and live streaming transcription, visible in the UI.

**Files to produce:**
- `lib/features/record/capture_service.dart` — wraps `record` for PCM 16 kHz mono.
- `lib/features/record/parakeet_runner.dart` — streaming recognizer via `sherpa_onnx`, on an isolate.
- `lib/features/record/record_screen.dart` — record button, live waveform, live caption.
- `lib/features/list/home_list_screen.dart` — fills in real rows.
- `lib/core/db/repositories/voice_log_repository.dart` — write path only: insert `VoiceLog` on stop.

**Acceptance:**
- Record → stop → a row appears on home list within 500ms with raw transcript.
- Raw transcript searchable via FTS5 the instant the row lands.
- No UI jank during recording (DevTools profile clean).
- Tests: `flutter test` passes, including a fake-isolate test for the recognizer wrapper.

---

## Phase 2 — Background queue + drift persistence (2 days)

Worker isolate scaffolding + dummy refine job to prove the UI update pattern.

**Files:**
- `lib/core/worker/job_queue.dart` — FIFO queue over `ProcessingJobs`.
- `lib/core/worker/worker_isolate.dart` — long-lived isolate entry.
- `lib/core/db/repositories/voice_log_repository.dart` — extend with `markRefined`, `markFailed`, etc.
- Dummy refine job: copies `raw_transcript` → `cleaned_text` after a 5 s delay.

**Acceptance:**
- Stop → enqueued `refine` job → 5 s later the row updates silently if the user is on the list, or with a gentle diff animation if they're on the detail screen.
- Crash-recovery: kill the app mid-job; on resume, `processingState` remains consistent and the job re-runs.

---

## Phase 3 — E5 embeddings + sqlite-vec vector search (2 days)

Embeddings are deterministic and small, so proving them early de-risks the
whole retrieval experience.

**Files:**
- `lib/features/search/embedder.dart` — `flutter_onnxruntime` wrapper, mean pooling, L2-normalize.
- `lib/features/search/tokenizer.dart` — e5-small-v2 tokenizer (`tokenizer.json`).
- `lib/core/db/vec_store.dart` — sqlite-vec virtual-table spike + extension loader.
- `lib/features/search/hybrid_retriever.dart` — RRF(k=60) over FTS5 + vector; entity path stubbed.
- Golden test: embeds 5 fixed inputs, asserts output vectors match a pre-computed reference within 1e-3.

**Acceptance:**
- Golden test green.
- Hybrid search returns relevant results on a 100-log fixture in <150 ms.
- E5 prefixes enforced via two distinct methods (`embedPassages`, `embedQuery`); unprefixed path private.

---

## Phase 4 — Gemma 4 E2B refinement (3–4 days)

Swaps the dummy refine job for real Gemma inference. Entity chips appear.

**Files:**
- `lib/features/record/refine/gemma_runner.dart` — `flutter_gemma` wrapper, single-session, serial queue.
- `lib/features/record/refine/prompt_templates.dart` — `record_log(cleaned_text, entities[])` function-call prompt, no thinking tokens.
- `lib/features/record/refine/offset_recovery.dart` — forward-scan matcher recovering char offsets on `cleaned_text`.
- `lib/features/detail/entity_chips.dart` — UI surface for extracted entities.

**Acceptance:**
- Real Gemma cleanup replaces the dummy job.
- Entity chips render on the detail screen.
- Retry button visible + working when refinement fails.
- Memory: load Gemma, run 20 cleanups, no leak (DevTools).

---

## Phase 5 — Entity canonicalization (2–3 days)

**Files:**
- `lib/features/search/canonicalizer.dart` — similarity match mention_text+context against canonical graph, link or create.
- `lib/features/search/entities_view.dart` — merge / rename / delete UI.

**Acceptance:**
- Record "met Shivani at Cafe Coffee Day"; record "Shivani paid for coffee" later. The two mentions link to the same canonical `PERSON` entity without intervention.
- Manual merge collapses two canonical entities, retroactively relinking mentions.

---

## Phase 5.5 — Local memory subsystem (3–4 days)

Memory is a local-only, evidence-backed layer of durable user context extracted from refined voice logs. It depends on Gemma refinement, e5 embeddings, sqlite-vec retrieval, and entity canonicalization. Full design: `docs/memory_subsystem.md`.

**Files:**
- `lib/features/memory/memory_extractor.dart` — Gemma prompt + validation for durable memory candidates.
- `lib/features/memory/memory_repository.dart` — CRUD, source evidence, merge/archive/delete semantics.
- `lib/features/memory/memory_retriever.dart` — RRF over memory FTS + vector + entity-linked boosts.
- `lib/features/memory/memory_types.dart` — enums/data classes for memory type, status, sensitivity.
- `lib/features/memory/memory_screen.dart` — inspect, edit, merge, delete, pin/confirm memories.
- `lib/core/db/schema/memory_items.dart` — encrypted Drift table + FTS integration.
- `lib/core/db/schema/memory_sources.dart` — evidence links back to voice logs and char offsets.
- `lib/core/db/schema/memory_entity_links.dart` — links memory cards to canonical entities.

**Acceptance:**
- Memory extraction runs as a background job after canonicalization and never blocks record stop.
- All memories, source evidence, and embeddings stay encrypted in local private storage.
- No network calls, sync SDKs, telemetry, crash reporting, or remote model APIs are introduced.
- Sensitive memories enter review/candidate state and are not used in Gemma prompts until confirmed.
- Deleting a memory removes its row, source links, and embedding, without deleting the original voice log.
- Memory retrieval returns relevant cards from a local fixture using FTS + vector + entity boosts.
- Tests cover extraction validation, repository delete/merge semantics, retrieval ranking, and `test/no_network_test.dart`.

---

## Phase 6 — Polish + shipping readiness (ongoing)

- Thermal / low-battery throttling with transparent UI message.
- WorkManager / BGTask lifecycle on real devices.
- Export (zip of audio + transcripts), delete-all, onboarding, empty states.
- Real-device profiling on mid-range hardware (Redmi Note class).
- CI with a mock HTTP client that fails on any network call.

---

## Phase 7 — SmolLM2 360M swap (superseded)

Replaced `flutter_gemma` + Gemma 4 E2B with SmolLM2-360M-Instruct (INT8 ONNX) on the existing `flutter_onnxruntime` runtime. Superseded by Phase 7.1 after Gemma 3 1B eval showed stronger transcript cleanup than SmolLM2/Gemma 270M for the current refine fixture.

**Files added:**
- `lib/features/refine/smollm/chat_template.dart` — ChatML wrapper.
- `lib/features/refine/smollm/bpe_tokenizer.dart` — byte-level BPE loaded from `tokenizer.json`.
- `lib/features/refine/smollm/kv_cache.dart` — past-K/V buffers + ORT input/output naming.
- `lib/features/refine/smollm/sampler.dart` — greedy + temperature/top-p sampler.
- `lib/features/refine/smollm/smollm_runner.dart` — `LlmRunner` impl with prefill + decode loop, serial `_opChain`, idle TTL.
- `assets/models/smollm/` — `model.onnx` (INT8) + `tokenizer.json` + `tokenizer_config.json` (fetched via `scripts/fetch_models.sh`).

**Files modified:**
- `lib/core/model_bootstrap.dart` — `ensureSmolLm()` next to `ensureE5()`.
- `lib/features/refine/prompt_templates.dart` — return user-message body; runner wraps in ChatML.
- `lib/features/refine/gemma_refiner.dart` → `refine_runner.dart` — drops chunking, refines whole transcript in one call.
- `lib/features/memory/memory_prompt_templates.dart` — same shape, slightly tighter for the smaller model.
- `lib/core/worker/providers.dart` — provider points at `SmolLmRunner`.
- `pubspec.yaml` — drops `flutter_gemma`, adds `assets/models/smollm/`.
- `CLAUDE.md` — stack section reflects SmolLM2; context window 8192; Gemma references removed.

**Files removed:**
- `lib/features/refine/gemma_runner.dart`
- `lib/features/refine/llm_chunker.dart`
- `assets/models/gemma/` (and the `fetch_models.sh` entry).
- `test/features/refine/gemma_runner_test.dart`, `llm_chunker_test.dart`, `gemma_refiner_test.dart` (replaced).

**Acceptance:**
- `flutter test` and `make analyze` clean.
- BPE tokenizer encode/decode parity with HF reference fixtures.
- ChatML template + sampler unit-tested.
- Refine + memory pipelines run end-to-end against a fake `LlmRunner` in tests.
- JSON parse-success rate ≥ 95% on the existing fixture set in real-device smoke (manual). Below that → Phase 7.1 = grammar-constrained sampling.
- `test/no_network_test.dart` still passes.

**Risks called out before start:**
- Small-model JSON drift on the structured `record_log` schema. Mitigated with prompt + parse-and-retry; escape hatch is grammar-constrained sampling.
- ONNX I/O contract names (`past_key_values.{i}.{key,value}` / `present.{i}.{key,value}`) are conventional but export-specific; verify on first device load.

---

## Phase 7.1 — Gemma 3 1B replacement (in progress)

Replace SmolLM2 as the production LLM with Gemma 3 1B IT Q4 LiteRT-LM via `flutter_gemma`.

**Rationale from local eval:**
- Gemma 3 270M: fast but repeated/hallucinated outputs; entity F1 0.0%, text F1 29.4% on 50 cases.
- Gemma 3 1B: materially stronger cleanup; text F1 71.5%, parseable with 45/50 first-pass on the legacy one-shot eval, but weak entity recall.

**Implementation shape:**
- `lib/features/refine/gemma3/gemma3_runner.dart` implements `LlmRunner` and serializes all `flutter_gemma` calls.
- Production refine becomes two-stage: cleanup-only JSON, then exact-substring entity extraction from cleaned text.
- `pubspec.yaml` ships `assets/models/gemma/` and moves `flutter_gemma` back to production dependencies.

**Acceptance:**
- `make analyze` and `flutter test` clean.
- Real-device/simulator smoke: record/refine with Gemma 3 1B model present.
- Re-run refine eval through the production two-stage path; decide whether entity prompt tuning is needed before shipping.

---

## Phase 9 — Magical search (slices 1 + 2)

Lift hybrid search from "list of matched logs" to "land on the exact moment that matched, with the dimensions of your journal as facets."

**In scope:**
- Per-segment snippets with keyword highlighting. Tapping a result opens `LogDetailScreen` at the matching segment's `startTimeMs` and visually accents the matched range.
- Faceted filters above the search field:
  - People / Places / Projects — pickers over `canonical_entities` grouped by `type`. Logic: **AND across types, OR within** (e.g. `(Shivani OR Aman) AND (Cafe Coffee Day)`).
  - Date range — Today / This week / This month / Custom over `voice_logs.createdAt`.
  - Tasks — toggle restricting to logs with rows in `action_items`.
- Local "why this matched" rationale per tile (e.g. "Mentions Shivani · cleaned text" / "Semantically similar — segment at 0:42"). No LLM yet.

**Files:**
- `lib/features/search/vec_store.dart` — carry `startTimeMs`/`endTimeMs` on `VectorHit`.
- `lib/features/search/hybrid_retriever.dart` — wire entity-boost path, apply `SearchFilters`, surface `bestSegmentId` + `bestSegmentStartMs/EndMs` + `localReason` on `SearchHit`, pinpoint a segment for FTS-only hits.
- `lib/features/search/search_filters.dart` *(new, freezed)* — filter model + Riverpod state notifier.
- `lib/features/search/entity_facet_provider.dart` *(new)* — canonical entities grouped by type.
- `lib/features/search/search_screen.dart` — filter bar, rationale line, jump-to-moment navigation.
- `test/features/search/hybrid_retriever_test.dart` — filter + pinpoint cases.
- `test/features/search/search_filters_test.dart` *(new)* — filter composition logic.

**Out of scope (deferred):**
- Gemma-generated rationales — Phase 9.1, on-demand on tile expansion.
- Mood/emotion filter — needs a new refine pass + schema column.
- Inline action_items rendering in results — toggle filter only this phase.

**Acceptance:**
- `make codegen`, `make analyze`, `flutter test` clean.
- Manual: search "coffee with Shivani" → tap result → detail screen opens with audio queued at the matching segment and the matched span accented.
- No new dependencies. No schema migration.

---

## Phase 10 — Per-log structured summaries

Adds a structured summary card to every refined log: one-liner, three
bullets, important people/projects, decisions, and follow-ups. Surfaces
the "what happened" of each log at a glance on the detail screen.

**Implementation shape:**
- Reuses the existing polymorphic `summaries` table (`type='log'`,
  `source_id=<logId>`, deterministic `id='log:<logId>'`) added in
  Phase 9.0. No schema migration.
- New `JobType.summarize` handler (`lib/features/summarize/summarize_runner.dart`)
  runs after refine: one Gemma 3 1B call returns a single JSON object with
  all five fields; one stricter retry on parse failure; best-effort —
  failure leaves no row and never blocks the pipeline.
- `LogSummaryRepository` (`lib/core/db/repositories/log_summary_repository.dart`)
  abstracts the row shape: bullets stored newline-joined in `body`,
  people/projects/decisions/follow-ups as JSON arrays in
  `topics_json` / `decisions_json` / `action_items_json`.
- Detail screen renders `LogSummaryPanel` above the entity chips; widget
  hides itself until the summarize job lands.

**Files added:**
- `lib/core/db/repositories/log_summary_repository.dart`
- `lib/features/summarize/summary_prompt.dart`
- `lib/features/summarize/summary_response_parser.dart`
- `lib/features/summarize/summarize_runner.dart`
- `lib/features/detail/log_summary_panel.dart`
- `test/features/summarize/summary_response_parser_test.dart`
- `test/features/summarize/summarize_runner_test.dart`
- `test/core/db/log_summary_repository_test.dart`

**Files modified:**
- `lib/core/db/providers.dart` — `logSummaryRepositoryProvider`,
  `logSummaryForLogProvider`.
- `lib/core/worker/providers.dart` — `summarizeHandlerProvider`,
  registered in the worker handler map.
- `lib/features/refine/refine_runner.dart` — enqueues `summarize` after
  `embed` on the success path.
- `lib/features/detail/log_detail_screen.dart` — slots
  `LogSummaryPanel` above `EntityChips`.

**Acceptance:**
- `make analyze` and `flutter test` clean.
- Record a multi-topic log → refine completes → detail screen shows the
  structured summary card within seconds of refine landing.
- Parse-failure path: when the LLM never produces parseable JSON, the
  job completes successfully with no summary row and the detail screen
  hides the panel cleanly.

**Out of scope (deferred):**
- Manual "Regenerate summary" button on the detail screen.
- Linking `people_projects` to canonical entities at write time, and
  merging `follow_ups` into the existing `action_items` table — the
  fields are regenerated standalone for v1.

---

## Phase 11 — Daily / weekly digests

Cross-log summaries computed over a calendar window. A "Today" card
surfaces what happened, people mentioned, tasks created, decisions, and
mood/theme. A "This week" card surfaces main themes, project progress,
repeated concerns, and unfinished tasks. On-demand only — no background
scheduling, no stale cached digests.

**Implementation shape:**
- Reuses the polymorphic `summaries` table from Phase 10. Rows use
  `type='daily'` or `type='weekly'`, `source_id=<YYYY-MM-DD>` (the
  start-of-window date in the user's local timezone), deterministic
  `id='daily:<date>'` / `id='weekly:<date>'`. No schema migration.
- `DigestRunner` pulls `voice_logs` (and `LogSummary` rows where
  present) for the window, builds a single Gemma 3 1B prompt, parses
  one JSON object, writes via `LogSummaryRepository` under the new
  types. One stricter retry on parse failure; second failure leaves
  no row.
- Runs through the existing single-worker queue — LLM inference stays
  serial (see CLAUDE.md non-negotiables).
- Trigger is on-demand only: opening the digest screen enqueues the
  job if no row exists for the window; the screen shows a spinner and
  swaps in the card when the row lands. No `workmanager` /
  `BGTaskScheduler` involvement.
- Bullets stored newline-joined in `body`. Arrays
  (`peopleMentioned` / `tasksCreated` / `decisions` for daily;
  `mainThemes` / `projectProgress` / `repeatedConcerns` /
  `unfinishedTasks` for weekly) stored in
  `topics_json` / `decisions_json` / `action_items_json` — exact
  field mapping documented in `digest_response_parser.dart`.

**Files added:**
- `lib/features/digest/digest_prompt.dart` — daily + weekly prompt
  templates.
- `lib/features/digest/digest_response_parser.dart` — mirrors
  `summary_response_parser.dart`.
- `lib/features/digest/digest_runner.dart` — window query, prompt
  call, parse + retry, repository write.
- `lib/features/digest/digest_screen.dart` — Today / This week tabs;
  shows the card or a "Generate" affordance when no row exists.
- `test/features/digest/digest_response_parser_test.dart`
- `test/features/digest/digest_runner_test.dart`

**Files modified:**
- `lib/core/db/repositories/log_summary_repository.dart` — add
  `digestForWindow(type, date)` lookup and a typed write path; bullets
  field naming stays generic.
- `lib/core/worker/providers.dart` — `digestHandlerProvider`,
  registered in the worker handler map under a new
  `JobType.digest`.
- `lib/core/db/job_state.dart` — extend `JobType` with `digest`.
- `lib/features/debug/pipeline_debug_screen.dart` — add **"Generate
  today's digest"** and **"Generate this week's digest"** buttons
  that enqueue the job for the current local date and render the
  resulting row.

**Acceptance:**
- `make analyze` and `flutter test` clean.
- Record a few logs across a day → tap "Generate today's digest" on
  the debug screen → a digest row lands within ~10–20s with
  bullets, people, tasks, decisions, mood.
- Weekly digest spans 7 days ending on the current local date and
  surfaces themes / progress / concerns / unfinished tasks.
- Parse-failure path: when the LLM never produces parseable JSON,
  the job completes successfully with no digest row and the screen
  shows the empty / retry state.
- `test/no_network_test.dart` still passes.

**Out of scope (deferred):**
- Background scheduling at a fixed local time — revisit once the
  on-demand path is validated.
- A user-facing entry point in the home nav. The debug screen and
  a direct route are enough for v1.
- Linking `peopleMentioned` to canonical entities at write time.
- Cross-week / monthly digests.
- Mood timeline visualization.

---

## Working rules

- One phase per session. Stop at the end of a phase to demo what works.
- Small commits with conventional messages. No squash across phase boundaries.
- When stuck or ambiguous, ask before implementing.
- Flag new dependencies before adding them. No silent upgrades mid-phase.
- `make analyze` + `flutter test` clean before any commit.
- `make codegen` after touching drift tables, freezed, or json_serializable.
