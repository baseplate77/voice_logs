//! Gemma-3 LLM inference exposed to Dart via flutter_rust_bridge.
//!
//! Runs on candle (pure Rust, no new C++ runtime) to avoid the abseil
//! collision that flutter_gemma + sherpa-onnx had on iOS — both bundled
//! their own copy, and libc++'s dual static init segfaulted during
//! `absl::flags_internal::FlagImpl::SetCallback`.
//!
//! Exposed API:
//!   - [`load_gemma`] — read GGUF weights + tokenizer once per session
//!   - [`generate_sync`] — buffered greedy/temperature sampling
//!   - [`dispose_llm`] — drop the model + tokenizer
//!
//! Streaming generation (token-by-token) is left to Phase 3b+1; the
//! Dart-side `LlmRunner` interface stubs streaming to emit the full
//! completion in a single chunk for now, which is fine for the
//! cleanup pipeline's four one-shot calls.

use std::sync::Mutex;

use anyhow::anyhow;
use candle_core::{quantized::gguf_file, Device, Tensor};
use candle_transformers::{
    generation::{LogitsProcessor, Sampling},
    models::quantized_gemma3::ModelWeights,
    utils::apply_repeat_penalty,
};
use tokenizers::Tokenizer;

struct GemmaSession {
    model: ModelWeights,
    tokenizer: Tokenizer,
    eos_token: u32,
    device: Device,
}

/// Global slot — one Gemma model in memory at a time. ~800 MB for
/// gemma-3-1b Q4_K_M, so holding two would be wasteful.
static GEMMA: Mutex<Option<GemmaSession>> = Mutex::new(None);

/// Load a quantized Gemma 3 model + its tokenizer.
///
/// `model_path`: path to a GGUF file (`*.gguf`).
/// `tokenizer_path`: path to a `tokenizer.json` produced by the
/// `tokenizers` crate (Gemma 3's official tokenizer works as-is).
pub fn load_gemma(model_path: String, tokenizer_path: String) -> Result<(), String> {
    let device = Device::Cpu;

    let mut file = std::fs::File::open(&model_path)
        .map_err(|e| format!("cannot open {model_path}: {e}"))?;
    let gguf =
        gguf_file::Content::read(&mut file).map_err(|e| format!("GGUF read failed: {e:?}"))?;
    let model = ModelWeights::from_gguf(gguf, &mut file, &device)
        .map_err(|e| format!("ModelWeights::from_gguf failed: {e:?}"))?;

    let tokenizer = Tokenizer::from_file(&tokenizer_path)
        .map_err(|e| format!("tokenizer from {tokenizer_path}: {e:?}"))?;

    // Gemma 3 chat format terminates turns with `<end_of_turn>`. We look
    // it up once so the generation loop can test against it in O(1).
    let eos_token = tokenizer
        .get_vocab(true)
        .get("<end_of_turn>")
        .copied()
        .ok_or_else(|| "tokenizer missing <end_of_turn> token".to_string())?;

    let mut slot = GEMMA.lock().map_err(|_| "GEMMA mutex poisoned")?;
    *slot = Some(GemmaSession {
        model,
        tokenizer,
        eos_token,
        device,
    });
    Ok(())
}

/// Generate a completion for [`prompt`]. Returns the generated text
/// only — the prompt itself is not echoed.
///
/// Sampling: greedy when `temperature <= 0`, temperature-only otherwise.
/// `max_tokens` caps the generation length; a `repeat_penalty` of 1.1
/// is applied over the last 64 tokens (matching candle's example
/// defaults, which avoid Gemma's common repeat-loop failure mode).
pub fn generate_sync(
    prompt: String,
    max_tokens: i32,
    temperature: f32,
) -> Result<String, String> {
    let mut slot = GEMMA.lock().map_err(|_| "GEMMA mutex poisoned")?;
    let session = slot
        .as_mut()
        .ok_or_else(|| "Gemma not loaded — call load_gemma first".to_string())?;

    let max_tokens = max_tokens.max(1) as usize;
    let temp = temperature as f64;

    let encoded = session
        .tokenizer
        .encode(prompt, true)
        .map_err(|e| format!("tokenize: {e:?}"))?;
    let prompt_tokens: Vec<u32> = encoded.get_ids().to_vec();

    // Context-window guard: Gemma 3 supports 8k by default. Trim from
    // the left if we'd overflow.
    const MAX_SEQ_LEN: usize = 8192;
    let prompt_tokens = if prompt_tokens.len() + max_tokens > MAX_SEQ_LEN - 10 {
        let to_remove = prompt_tokens.len() + max_tokens + 10 - MAX_SEQ_LEN;
        prompt_tokens[prompt_tokens.len().saturating_sub(to_remove)..].to_vec()
    } else {
        prompt_tokens
    };

    let sampling = if temp <= 0.0 {
        Sampling::ArgMax
    } else {
        Sampling::All { temperature: temp }
    };
    let mut logits_processor = LogitsProcessor::from_sampling(299_792_458, sampling);

    let generated = generate_tokens(
        session,
        &prompt_tokens,
        &mut logits_processor,
        max_tokens,
    )
    .map_err(|e| format!("generate: {e:?}"))?;

    let text = session
        .tokenizer
        .decode(&generated, true)
        .map_err(|e| format!("decode: {e:?}"))?;
    Ok(text)
}

fn generate_tokens(
    session: &mut GemmaSession,
    prompt_tokens: &[u32],
    logits_processor: &mut LogitsProcessor,
    max_tokens: usize,
) -> anyhow::Result<Vec<u32>> {
    let device = session.device.clone();

    // Feed the whole prompt in one shot to get the first sampled token.
    let input = Tensor::new(prompt_tokens, &device)?.unsqueeze(0)?;
    let logits = session.model.forward(&input, 0)?;
    let logits = logits.squeeze(0)?;
    let mut next_token = logits_processor.sample(&logits)?;

    let mut out = Vec::with_capacity(max_tokens);
    out.push(next_token);

    // Generation loop. Apply a light repeat penalty over the last 64
    // tokens — matches candle's example defaults.
    const REPEAT_PENALTY: f32 = 1.1;
    const REPEAT_LAST_N: usize = 64;

    for i in 0..max_tokens.saturating_sub(1) {
        if next_token == session.eos_token {
            break;
        }
        let input = Tensor::new(&[next_token], &device)?.unsqueeze(0)?;
        let logits = session.model.forward(&input, prompt_tokens.len() + i)?;
        let logits = logits.squeeze(0)?;
        let logits = if REPEAT_PENALTY == 1.0 {
            logits
        } else {
            let start_at = out.len().saturating_sub(REPEAT_LAST_N);
            apply_repeat_penalty(&logits, REPEAT_PENALTY, &out[start_at..])?
        };
        next_token = logits_processor.sample(&logits)?;
        out.push(next_token);
    }

    // If generation terminated on EOS, drop the trailing token so the
    // caller doesn't see `<end_of_turn>` literalised into the text.
    if out.last().copied() == Some(session.eos_token) {
        out.pop();
    }

    Ok::<Vec<u32>, anyhow::Error>(out).map_err(|e| anyhow!("{e}"))
}

/// Drop the loaded model. Safe to call multiple times.
pub fn dispose_llm() {
    if let Ok(mut slot) = GEMMA.lock() {
        *slot = None;
    }
}

/// `true` when a Gemma model is loaded — used by Dart-side lifecycle.
pub fn is_gemma_loaded() -> bool {
    GEMMA.lock().map(|s| s.is_some()).unwrap_or(false)
}
