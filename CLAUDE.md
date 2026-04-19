# VoxSynth

Local-first voice-log synthesizer. Flutter app. Everything on-device.

## Non-negotiables
- No network calls for core features. Lint should fail on any http/dio/websocket import outside `lib/sync/` (not yet built).
- No third-party analytics, no crash reporting SDKs that upload.
- Heavy work (ASR, LLM, embedding) runs on background isolates. UI thread stays responsive.
- All persistent data encrypted at rest. Keys in platform keychain.

## Stack
- Flutter stable, Dart 3.5+
- `record` for audio capture
- `onnxruntime` for Silero VAD + e5-small embeddings
- `whisper.cpp` via FFI for ASR
- `flutter_gemma` (MediaPipe) for Gemma inference
- `drift` for SQLite + FTS5
- `objectbox` + `objectbox_flutter_libs` for vector index (HNSW)
- `workmanager` for background jobs
- `riverpod` for state management
- `freezed` + `json_serializable` for data classes

## Directory layout
```
lib/
  core/           -- shared primitives, result types, error classes
  capture/        -- audio recording + VAD
  asr/            -- Whisper FFI + chunking
  llm/            -- Gemma wrapper + prompt templates
  embed/          -- e5-small wrapper
  store/          -- drift + objectbox + audio file store
  retrieve/       -- hybrid search + reranker
  synth/          -- RAG query path + background synthesis jobs
  ui/             -- screens, widgets
  app.dart        -- root
  main.dart
```

## Coding rules
- No `print`. Use the `Logger` in `lib/core/logger.dart`.
- No singletons. Use Riverpod providers.
- All async operations return `Result<T, AppError>` — never throw across layer boundaries.
- One widget per file. Files named after the widget.
- Public APIs documented with `///`. Private helpers do not need doc comments.
- No TODO comments in merged code. If incomplete, it's a draft PR.

## How to work on this repo
- Read this file first every session.
- Read `IMPLEMENTATION_PLAN.md` to find the current phase.
- Before writing any code, state which phase you are working on and list the files you will touch.
- Write tests alongside implementation. No untested repository or service classes.
- Run `flutter analyze` and `flutter test` before declaring a task done.
