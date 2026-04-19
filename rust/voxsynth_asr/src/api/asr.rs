//! Parakeet-TDT ASR exposed to Dart via flutter_rust_bridge.
//!
//! The runtime lives in `sherpa-rs` (thin wrapper over the C++ sherpa-onnx
//! project), which owns the encoder/decoder/joiner ONNX sessions plus the
//! transducer beam-search decoder. We expose:
//!
//! - [`load_parakeet`] — build a `TransducerRecognizer` for the Parakeet-TDT
//!   model at `model_dir` and stash it in a process-global slot. Idempotent:
//!   calling again replaces the existing session (caller is expected to
//!   [`dispose`] first, but we handle the sloppy case too).
//! - [`transcribe_pcm_s16le`] — feed a 16 kHz s16le PCM buffer to the
//!   recognizer and return the decoded text. PCM conversion to f32 happens
//!   on the Rust side to keep the frb bridge payload smaller.
//! - [`dispose`] — drop the recognizer and free native resources.
//!
//! Word-level timestamps are a planned follow-up: the sherpa-rs 0.6 API
//! exposes only `String` transcripts. The Dart-side `Transcript` type
//! reserves a `words` field so we can fill it in once sherpa-rs surfaces
//! richer results (or we drop down to the C bindings directly).

use std::path::PathBuf;
use std::sync::Mutex;

use sherpa_rs::transducer::{TransducerConfig, TransducerRecognizer};

/// Process-global recognizer. One in-flight model at a time: Phase 4 RAG
/// workloads will want to share this across capture sessions rather than
/// rebuild 500 MB of weights on every new recording.
static RECOGNIZER: Mutex<Option<TransducerRecognizer>> = Mutex::new(None);

/// DTO returned to Dart.
#[derive(Debug, Clone)]
pub struct TranscriptDto {
    pub text: String,
    pub detected_language: String,
}

/// Load the Parakeet-TDT model sitting under `model_dir`. Expects the
/// sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8 layout:
///
/// ```text
/// model_dir/
///   encoder.int8.onnx
///   decoder.int8.onnx
///   joiner.int8.onnx
///   tokens.txt
/// ```
///
/// Returns a human-readable error on failure (frb maps `Result<_, String>`
/// into Dart exceptions we'll catch and re-box as `ModelLoadError`).
pub fn load_parakeet(model_dir: String, num_threads: i32) -> Result<(), String> {
    let dir = PathBuf::from(&model_dir);
    let encoder = dir.join("encoder.int8.onnx");
    let decoder = dir.join("decoder.int8.onnx");
    let joiner = dir.join("joiner.int8.onnx");
    let tokens = dir.join("tokens.txt");

    for (label, path) in [
        ("encoder", &encoder),
        ("decoder", &decoder),
        ("joiner", &joiner),
        ("tokens", &tokens),
    ] {
        if !path.exists() {
            return Err(format!(
                "Parakeet {label} file missing at {}",
                path.display()
            ));
        }
    }

    let config = TransducerConfig {
        encoder: encoder.to_string_lossy().into_owned(),
        decoder: decoder.to_string_lossy().into_owned(),
        joiner: joiner.to_string_lossy().into_owned(),
        tokens: tokens.to_string_lossy().into_owned(),
        // sherpa-onnx distinguishes Zipformer transducers ("transducer")
        // from NeMo transducers; Parakeet-TDT is the latter.
        model_type: "nemo_transducer".to_string(),
        num_threads: num_threads.max(1),
        sample_rate: 16_000,
        feature_dim: 80,
        debug: false,
        ..Default::default()
    };

    let recognizer = TransducerRecognizer::new(config)
        .map_err(|e| format!("TransducerRecognizer::new failed: {e:?}"))?;

    let mut slot = RECOGNIZER.lock().map_err(|_| "recognizer mutex poisoned")?;
    *slot = Some(recognizer);
    Ok(())
}

/// Transcribe a 16 kHz signed-16-bit little-endian PCM buffer.
///
/// Returns the transcript plus the detected language (always `"en"` for
/// Parakeet-TDT-0.6B-v2 — preserved for interface stability with future
/// multilingual models).
pub fn transcribe_pcm_s16le(pcm: Vec<u8>) -> Result<TranscriptDto, String> {
    if pcm.len() % 2 != 0 {
        return Err(format!(
            "s16le PCM must have an even byte length, got {}",
            pcm.len()
        ));
    }

    let mut slot = RECOGNIZER.lock().map_err(|_| "recognizer mutex poisoned")?;
    let recognizer = slot
        .as_mut()
        .ok_or_else(|| "Parakeet model not loaded — call load_parakeet first".to_string())?;

    let samples = s16le_to_f32(&pcm);
    let text = recognizer.transcribe(16_000, &samples);

    Ok(TranscriptDto {
        text: text.trim().to_string(),
        detected_language: "en".to_string(),
    })
}

/// Drop the loaded recognizer. Safe to call multiple times.
pub fn dispose() {
    if let Ok(mut slot) = RECOGNIZER.lock() {
        *slot = None;
    }
}

/// `true` when a recognizer is loaded — used by Dart-side lifecycle tests.
pub fn is_loaded() -> bool {
    RECOGNIZER
        .lock()
        .map(|s| s.is_some())
        .unwrap_or(false)
}

fn s16le_to_f32(pcm: &[u8]) -> Vec<f32> {
    let n = pcm.len() / 2;
    let mut out = Vec::with_capacity(n);
    for chunk in pcm.chunks_exact(2) {
        let sample = i16::from_le_bytes([chunk[0], chunk[1]]);
        out.push(f32::from(sample) / 32768.0);
    }
    out
}
