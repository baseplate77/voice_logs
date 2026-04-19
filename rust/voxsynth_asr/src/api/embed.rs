//! Multilingual-e5-small text embeddings via candle.
//!
//! Loads the XLM-RoBERTa-base backbone that `intfloat/multilingual-e5-small`
//! is built on, tokenises a batch with the model's own BPE tokenizer,
//! runs a forward pass, mean-pools the last hidden state over non-padding
//! tokens, and L2-normalises. Returns 384-d vectors.
//!
//! Exposed API:
//!   - [`load_e5`] — one-time session setup per process
//!   - [`embed_batch`] — batched inference (pre-prefixed, the Dart side
//!     owns `"query: "` vs `"passage: "`)
//!   - [`dispose_embedder`]
//!
//! Pure-Rust / no extra ONNX Runtime copy — same reasoning as Phase 3b's
//! Gemma: one inference stack (candle) for all text models, separate
//! from sherpa-onnx's ORT used for ASR.

use std::sync::Mutex;

use candle_core::{DType, Device, Tensor};
use candle_nn::VarBuilder;
use candle_transformers::models::xlm_roberta::{Config as XlmCfg, XLMRobertaModel};
use tokenizers::{PaddingParams, PaddingStrategy, Tokenizer};

struct E5Session {
    model: XLMRobertaModel,
    tokenizer: Tokenizer,
    device: Device,
    /// Hidden size — e5-small is 384. Cached at load so we don't reach
    /// into the XLMRobertaModel to read it per call.
    hidden_size: usize,
}

static E5: Mutex<Option<E5Session>> = Mutex::new(None);

/// Load the e5 model.
///
/// `weights_path` → `model.safetensors` (fp32 from HF, loaded as F16 in
/// memory), `config_path` → `config.json`, `tokenizer_path` →
/// `tokenizer.json`.
pub fn load_e5(
    weights_path: String,
    config_path: String,
    tokenizer_path: String,
) -> Result<(), String> {
    let device = Device::Cpu;

    let config_json = std::fs::read_to_string(&config_path)
        .map_err(|e| format!("read config {config_path}: {e}"))?;
    let config: XlmCfg = serde_json::from_str(&config_json)
        .map_err(|e| format!("parse config: {e}"))?;

    let hidden_size = config.hidden_size as usize;
    let pad_id = config.pad_token_id;

    // F16 keeps the fp32 470 MB weights at 235 MB in RAM with negligible
    // quality loss for pooled embeddings.
    let vb = unsafe {
        VarBuilder::from_mmaped_safetensors(
            &[weights_path.clone()],
            DType::F16,
            &device,
        )
        .map_err(|e| format!("mmap safetensors {weights_path}: {e:?}"))?
    };
    let model = XLMRobertaModel::new(&config, vb)
        .map_err(|e| format!("XLMRobertaModel::new: {e:?}"))?;

    let mut tokenizer = Tokenizer::from_file(&tokenizer_path)
        .map_err(|e| format!("tokenizer {tokenizer_path}: {e:?}"))?;
    tokenizer
        .with_padding(Some(PaddingParams {
            strategy: PaddingStrategy::BatchLongest,
            pad_id,
            ..Default::default()
        }))
        .with_truncation(None)
        .map_err(|e| format!("tokenizer config: {e}"))?;

    let mut slot = E5.lock().map_err(|_| "E5 mutex poisoned")?;
    *slot = Some(E5Session {
        model,
        tokenizer,
        device,
        hidden_size,
    });
    Ok(())
}

/// Embed a batch of strings. Callers must add `"query: "` or `"passage: "`
/// before calling — the Dart `Embedder` interface does that for us.
///
/// Returns one 384-d L2-normalised vector per input, in order.
pub fn embed_batch(texts: Vec<String>) -> Result<Vec<Vec<f32>>, String> {
    if texts.is_empty() {
        return Ok(Vec::new());
    }

    let mut slot = E5.lock().map_err(|_| "E5 mutex poisoned")?;
    let session = slot
        .as_mut()
        .ok_or_else(|| "e5 model not loaded — call load_e5 first".to_string())?;

    let encodings = session
        .tokenizer
        .encode_batch(texts, true)
        .map_err(|e| format!("tokenize batch: {e:?}"))?;

    let batch = encodings.len();
    let seq_len = encodings.first().map(|e| e.get_ids().len()).unwrap_or(0);
    if seq_len == 0 {
        return Ok(vec![vec![0.0; session.hidden_size]; batch]);
    }

    // Flatten token ids + attention mask into row-major [batch, seq_len].
    let mut ids = Vec::with_capacity(batch * seq_len);
    let mut mask = Vec::with_capacity(batch * seq_len);
    for enc in &encodings {
        ids.extend_from_slice(enc.get_ids());
        mask.extend(enc.get_attention_mask().iter().map(|&v| v as i64));
    }
    let ids_tensor = Tensor::from_vec(ids, (batch, seq_len), &session.device)
        .map_err(|e| format!("ids tensor: {e:?}"))?;
    let mask_tensor = Tensor::from_vec(mask, (batch, seq_len), &session.device)
        .map_err(|e| format!("mask tensor: {e:?}"))?;
    // XLM-R has a single token_type, all zeros.
    let token_type_ids = Tensor::zeros((batch, seq_len), DType::I64, &session.device)
        .map_err(|e| format!("token_type_ids: {e:?}"))?;

    let hidden = session
        .model
        .forward(&ids_tensor, &mask_tensor, &token_type_ids, None, None, None)
        .map_err(|e| format!("forward: {e:?}"))?;

    // hidden: [batch, seq_len, hidden_size], F16 (from the VarBuilder).
    // attention_mask: [batch, seq_len], I64.
    let hidden = hidden
        .to_dtype(DType::F32)
        .map_err(|e| format!("to f32: {e:?}"))?;

    let pooled = mean_pool(&hidden, &mask_tensor)
        .map_err(|e| format!("pool: {e:?}"))?;
    let normalized =
        l2_normalize(&pooled).map_err(|e| format!("normalize: {e:?}"))?;

    // Read out to Vec<Vec<f32>>.
    let flat = normalized
        .flatten_all()
        .map_err(|e| format!("flatten: {e:?}"))?
        .to_vec1::<f32>()
        .map_err(|e| format!("to_vec1: {e:?}"))?;

    let dim = session.hidden_size;
    let mut out = Vec::with_capacity(batch);
    for i in 0..batch {
        out.push(flat[i * dim..(i + 1) * dim].to_vec());
    }
    Ok(out)
}

/// Mean pool `[batch, seq_len, hidden]` using `mask [batch, seq_len]`.
/// Returns `[batch, hidden]`.
fn mean_pool(hidden: &Tensor, mask: &Tensor) -> candle_core::Result<Tensor> {
    // mask_f32: [batch, seq_len, 1]
    let mask_f32 = mask.to_dtype(DType::F32)?.unsqueeze(2)?;
    // Sum over seq dimension with broadcasting:
    // masked_hidden: [batch, seq_len, hidden] → sum along dim 1 → [batch, hidden]
    let masked = hidden.broadcast_mul(&mask_f32)?;
    let summed = masked.sum(1)?;
    // Divide by token counts (avoid div-by-zero with a 1.0 floor).
    let counts = mask_f32.sum(1)?.clamp(1.0f64, f64::INFINITY)?;
    summed.broadcast_div(&counts)
}

/// L2 normalize each row of `[batch, hidden]`. Returns same shape.
fn l2_normalize(v: &Tensor) -> candle_core::Result<Tensor> {
    let norm = v
        .sqr()?
        .sum_keepdim(1)?
        .sqrt()?
        .clamp(1e-12f64, f64::INFINITY)?;
    v.broadcast_div(&norm)
}

pub fn dispose_embedder() {
    if let Ok(mut slot) = E5.lock() {
        *slot = None;
    }
}

pub fn is_e5_loaded() -> bool {
    E5.lock().map(|s| s.is_some()).unwrap_or(false)
}
