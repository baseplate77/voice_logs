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

## Working rules

- One phase per session. Stop at the end of a phase to demo what works.
- Small commits with conventional messages. No squash across phase boundaries.
- When stuck or ambiguous, ask before implementing.
- Flag new dependencies before adding them. No silent upgrades mid-phase.
- `make analyze` + `flutter test` clean before any commit.
- `make codegen` after touching drift tables, freezed, or json_serializable.
