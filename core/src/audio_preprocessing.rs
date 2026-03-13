// Audio preprocessing: raw PCM (signed 16-bit LE) -> mono f32 at 16 kHz.
// Ready for whisper-rs consumption.
// Accepts any input sample rate (e.g. 48 kHz built-in, 16 kHz Bluetooth HFP).

use crate::PabloError;
use byteorder::{LittleEndian, ReadBytesExt};
use rubato::{
    Async, FixedAsync, Resampler, SincInterpolationParameters, SincInterpolationType,
    WindowFunction,
};
use std::io::Cursor;

const TARGET_SAMPLE_RATE: u32 = 16000;

fn audio_err(msg: String) -> PabloError {
    PabloError::AudioPreprocessing { message: msg }
}

/// Read a raw PCM sidecar file (signed 16-bit LE, no header),
/// downmix to mono if stereo, resample to 16 kHz, and return normalized f32 samples.
///
/// - `path`: absolute path to the raw PCM file
/// - `channels`: 1 (mono mic) or 2 (stereo interleaved system audio)
/// - `sample_rate`: actual sample rate of the input (e.g. 48000, 44100, 16000)
pub async fn preprocess_pcm(
    path: String,
    channels: u8,
    sample_rate: u32,
) -> Result<Vec<f32>, PabloError> {
    if channels == 0 || channels > 2 {
        return Err(audio_err(format!(
            "unsupported channel count: {channels} (expected 1 or 2)"
        )));
    }
    if sample_rate == 0 {
        return Err(audio_err("sample_rate must be > 0".to_string()));
    }

    // Read the raw PCM file
    let raw_bytes = tokio::fs::read(&path)
        .await
        .map_err(|e| audio_err(format!("failed to read PCM file '{path}': {e}")))?;

    if raw_bytes.is_empty() {
        return Ok(Vec::new());
    }

    // Each sample is 2 bytes (signed 16-bit LE)
    let total_samples = raw_bytes.len() / 2;
    if raw_bytes.len() % 2 != 0 {
        return Err(audio_err(
            "PCM file has odd byte count; expected 16-bit (2 bytes per sample)".to_string(),
        ));
    }

    // Parse i16 samples
    let mut cursor = Cursor::new(&raw_bytes);
    let mut samples_i16 = Vec::with_capacity(total_samples);
    for _ in 0..total_samples {
        let sample = cursor
            .read_i16::<LittleEndian>()
            .map_err(|e| audio_err(format!("failed to read PCM sample: {e}")))?;
        samples_i16.push(sample);
    }

    // Convert to f32 normalized [-1.0, 1.0] and downmix to mono if stereo
    let mono_f32: Vec<f32> = if channels == 2 {
        if samples_i16.len() % 2 != 0 {
            return Err(audio_err(
                "stereo PCM has odd sample count; expected interleaved L/R pairs".to_string(),
            ));
        }
        samples_i16
            .chunks_exact(2)
            .map(|pair| {
                let left = pair[0] as f32 / 32768.0;
                let right = pair[1] as f32 / 32768.0;
                (left + right) / 2.0
            })
            .collect()
    } else {
        samples_i16.iter().map(|&s| s as f32 / 32768.0).collect()
    };

    if mono_f32.is_empty() {
        return Ok(Vec::new());
    }

    // Skip resampling if already at target rate
    if sample_rate == TARGET_SAMPLE_RATE {
        return Ok(mono_f32);
    }

    resample_to_16k(mono_f32, sample_rate)
}

/// Resample mono f32 audio from `input_rate` Hz to 16 kHz using rubato's async sinc resampler.
fn resample_to_16k(input: Vec<f32>, input_rate: u32) -> Result<Vec<f32>, PabloError> {
    let ratio = TARGET_SAMPLE_RATE as f64 / input_rate as f64;

    let params = SincInterpolationParameters {
        sinc_len: 256,
        f_cutoff: 0.95,
        interpolation: SincInterpolationType::Linear,
        oversampling_factor: 256,
        window: WindowFunction::BlackmanHarris2,
    };

    let chunk_size = 1024;
    let mut resampler = Async::<f32>::new_sinc(
        ratio, 2.0, &params, chunk_size, 1, // mono
        FixedAsync::Input,
    )
    .map_err(|e| audio_err(format!("resampler init failed: {e}")))?;

    use audioadapter_buffers::direct::SequentialSliceOfVecs;

    let input_len = input.len();
    let input_data = vec![input]; // 1 channel
    let input_buf = SequentialSliceOfVecs::new(&input_data, 1, input_len)
        .map_err(|e| audio_err(format!("input buffer setup failed: {e}")))?;

    let output_len = resampler.process_all_needed_output_len(input_len);
    let mut output_data = vec![vec![0.0f32; output_len]]; // 1 channel
    let mut output_buf = SequentialSliceOfVecs::new_mut(&mut output_data, 1, output_len)
        .map_err(|e| audio_err(format!("output buffer setup failed: {e}")))?;

    let (_nbr_in, nbr_out) = resampler
        .process_all_into_buffer(&input_buf, &mut output_buf, input_len, None)
        .map_err(|e| audio_err(format!("resample failed: {e}")))?;

    output_data[0].truncate(nbr_out);
    Ok(output_data.into_iter().next().unwrap())
}

#[cfg(test)]
mod tests {
    use super::*;
    use byteorder::WriteBytesExt;
    use std::io::Write;

    /// Helper: write raw PCM i16 LE samples to a temp file and return the path.
    fn write_pcm_file(samples: &[i16]) -> String {
        let dir = std::env::temp_dir();
        let path = dir.join(format!(
            "pablo_test_{}_{}.pcm",
            std::process::id(),
            samples.len()
        ));
        let mut file = std::fs::File::create(&path).unwrap();
        for &s in samples {
            file.write_i16::<LittleEndian>(s).unwrap();
        }
        file.flush().unwrap();
        path.to_string_lossy().to_string()
    }

    #[tokio::test]
    async fn mono_48k_resamples_to_16k() {
        // Generate 48000 samples (1 second of mono 48 kHz silence with a blip)
        let mut samples = vec![0i16; 48000];
        samples[0] = 16384; // quarter-amplitude blip
        let path = write_pcm_file(&samples);

        let result = preprocess_pcm(path.clone(), 1, 48000).await.unwrap();
        std::fs::remove_file(&path).ok();

        // Should produce roughly 16000 samples (1 second at 16 kHz)
        assert!(
            result.len() >= 15000 && result.len() <= 17000,
            "expected ~16000 samples, got {}",
            result.len()
        );
        // All values should be in [-1.0, 1.0]
        for &s in &result {
            assert!(s >= -1.0 && s <= 1.0, "sample out of range: {s}");
        }
    }

    #[tokio::test]
    async fn stereo_downmix_produces_output() {
        // Generate 1 second of stereo 48 kHz: L=8192, R=-8192 -> mono should be ~0
        let num_frames = 48000;
        let mut samples = Vec::with_capacity(num_frames * 2);
        for _ in 0..num_frames {
            samples.push(8192i16); // left
            samples.push(-8192i16); // right
        }
        let path = write_pcm_file(&samples);

        let result = preprocess_pcm(path.clone(), 2, 48000).await.unwrap();
        std::fs::remove_file(&path).ok();

        // Should produce roughly 16000 samples
        assert!(
            result.len() >= 15000 && result.len() <= 17000,
            "expected ~16000 samples, got {}",
            result.len()
        );
        // Since L and R cancel out, all samples should be near zero
        for &s in &result {
            assert!(s.abs() < 0.01, "expected near-zero after downmix, got {s}");
        }
    }

    #[tokio::test]
    async fn already_16k_skips_resampling() {
        // 16000 samples = 1 second at 16 kHz, should pass through without resampling
        let samples: Vec<i16> = (0..16000).map(|i| (i % 100) as i16).collect();
        let path = write_pcm_file(&samples);

        let result = preprocess_pcm(path.clone(), 1, 16000).await.unwrap();
        std::fs::remove_file(&path).ok();

        // Exact sample count — no resampling, just i16->f32 conversion
        assert_eq!(result.len(), 16000);
        // Verify normalization: sample 1 should be 1/32768
        assert!((result[1] - 1.0 / 32768.0).abs() < 1e-6);
    }

    #[tokio::test]
    async fn empty_file_returns_empty() {
        let path = write_pcm_file(&[]);
        let result = preprocess_pcm(path.clone(), 1, 48000).await.unwrap();
        std::fs::remove_file(&path).ok();
        assert!(result.is_empty());
    }

    #[tokio::test]
    async fn invalid_channel_count_errors() {
        let path = write_pcm_file(&[0i16; 100]);
        let err = preprocess_pcm(path.clone(), 3, 48000).await.unwrap_err();
        std::fs::remove_file(&path).ok();
        match err {
            PabloError::AudioPreprocessing { message } => {
                assert!(message.contains("unsupported channel count"));
            }
            _ => panic!("expected AudioPreprocessing error"),
        }
    }
}
