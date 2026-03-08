//! End-to-end integration test: ElevenLabs TTS -> PCM files -> transcription pipeline -> Google Meet format.
//!
//! Generates synthetic therapy sessions with two AI voices and realistic
//! turn-taking (silence in each track while the other person speaks), then
//! runs the full local transcription pipeline and verifies the output.
//!
//! Requires:
//!   - ELEVENLABS_API_KEY in .env (project root) or environment
//!   - Internet access (ElevenLabs API + Whisper model download on first run)
//!   - ~75 MB disk for ggml-tiny.en model (cached in core/target/test-models/)
//!
//! Run short test:
//!   cargo test --manifest-path core/Cargo.toml --test e2e_pipeline -- --ignored --nocapture e2e_synthetic_therapy_session
//!
//! Run full 60-minute test (downloads ~466 MB model on first run):
//!   WHISPER_MODEL=small cargo test --manifest-path core/Cargo.toml --test e2e_pipeline -- --ignored --nocapture e2e_full_therapy_session

mod support;
use support::therapy_script_60min::{ScriptLine, Speaker};

use pablo_core::{
    render_google_meet, transcribe_session_1on1, GoogleMeetOptions, SpeakerLabel,
    TranscriptionConfig,
};
use std::path::PathBuf;

// ── ElevenLabs config ────────────────────────────────────────────────────────

const THERAPIST_VOICE: &str = "21m00Tcm4TlvDq8ikWAM"; // Rachel — calm, professional
const CLIENT_VOICE: &str = "pNInz6obpgDQGcFmaJgB"; // Adam — distinct male voice
const TTS_SAMPLE_RATE: u32 = 16000;

/// Pause between turns in seconds (natural conversation gap).
const TURN_GAP_SECS: f64 = 0.8;

// ── Whisper model config ─────────────────────────────────────────────────────

struct ModelInfo {
    filename: &'static str,
    url: &'static str,
}

fn model_info() -> ModelInfo {
    match std::env::var("WHISPER_MODEL").as_deref() {
        Ok("small") => ModelInfo {
            filename: "ggml-small.en.bin",
            url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin",
        },
        Ok("base") => ModelInfo {
            filename: "ggml-base.en.bin",
            url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin",
        },
        _ => ModelInfo {
            filename: "ggml-tiny.en.bin",
            url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.en.bin",
        },
    }
}

// ── Short script (6 turns, ~30s) ─────────────────────────────────────────────

const SHORT_SCRIPT: &[ScriptLine] = &[
    ScriptLine {
        speaker: Speaker::Therapist,
        text: "Good afternoon. How have things been since our last session?",
    },
    ScriptLine {
        speaker: Speaker::Client,
        text: "Hi doctor. It's been a tough week honestly. I've been having a lot of anxiety about work.",
    },
    ScriptLine {
        speaker: Speaker::Therapist,
        text: "That sounds really difficult. Can you tell me more about what triggered that anxiety?",
    },
    ScriptLine {
        speaker: Speaker::Client,
        text: "My manager announced layoffs are coming and I can't stop thinking about it. I'm not sleeping well at all.",
    },
    ScriptLine {
        speaker: Speaker::Therapist,
        text: "I hear you. It's completely normal to feel overwhelmed in situations like that. What coping strategies have you tried?",
    },
    ScriptLine {
        speaker: Speaker::Client,
        text: "I tried the breathing exercises you suggested last time. They help a little bit but the worry comes back pretty quickly.",
    },
];

// ── Helpers ──────────────────────────────────────────────────────────────────

async fn generate_speech(
    client: &reqwest::Client,
    api_key: &str,
    voice_id: &str,
    text: &str,
) -> Vec<u8> {
    let url = format!(
        "https://api.elevenlabs.io/v1/text-to-speech/{voice_id}?output_format=pcm_{TTS_SAMPLE_RATE}"
    );

    let resp = client
        .post(&url)
        .header("xi-api-key", api_key)
        .header("Content-Type", "application/json")
        .json(&serde_json::json!({
            "text": text,
            "model_id": "eleven_monolingual_v1"
        }))
        .send()
        .await
        .expect("ElevenLabs API call failed");

    let status = resp.status();
    if !status.is_success() {
        let body = resp.text().await.unwrap_or_default();
        panic!("ElevenLabs returned {status}: {body}");
    }

    resp.bytes()
        .await
        .expect("Failed to read TTS response")
        .to_vec()
}

/// Build two PCM tracks (mic + system) from individual turn audio clips.
///
/// Each track spans the full session duration. When the therapist speaks,
/// the mic track has audio and the system track has silence (and vice versa).
/// A natural pause is inserted between every turn.
///
/// Returns (mic_track, system_track) as raw S16LE PCM bytes.
fn build_tracks(turns: &[(Speaker, Vec<u8>)]) -> (Vec<u8>, Vec<u8>) {
    let gap_samples = (TURN_GAP_SECS * TTS_SAMPLE_RATE as f64) as usize;
    let gap_bytes = gap_samples * 2; // 16-bit = 2 bytes per sample

    let mut mic_track: Vec<u8> = Vec::new();
    let mut sys_track: Vec<u8> = Vec::new();

    for (i, (speaker, audio)) in turns.iter().enumerate() {
        let silence = vec![0u8; audio.len()];

        match speaker {
            Speaker::Therapist => {
                mic_track.extend_from_slice(audio);
                sys_track.extend_from_slice(&silence);
            }
            Speaker::Client => {
                mic_track.extend_from_slice(&silence);
                sys_track.extend_from_slice(audio);
            }
        }

        // Add gap after each turn (except the last)
        if i < turns.len() - 1 {
            mic_track.extend(vec![0u8; gap_bytes]);
            sys_track.extend(vec![0u8; gap_bytes]);
        }
    }

    (mic_track, sys_track)
}

/// Duplicate mono PCM (S16LE) into stereo (L=R) to exercise the stereo downmix path.
fn mono_to_fake_stereo(mono_pcm: &[u8]) -> Vec<u8> {
    let mut stereo = Vec::with_capacity(mono_pcm.len() * 2);
    for sample in mono_pcm.chunks_exact(2) {
        stereo.extend_from_slice(sample); // Left
        stereo.extend_from_slice(sample); // Right
    }
    stereo
}

/// Wrap raw S16LE PCM bytes in a WAV header so the file is playable.
fn write_wav(path: &std::path::Path, pcm: &[u8], channels: u16, sample_rate: u32) {
    let data_len = pcm.len() as u32;
    let byte_rate = sample_rate * channels as u32 * 2; // 16-bit = 2 bytes
    let block_align = channels * 2;
    let file_len = 36 + data_len; // RIFF header + fmt chunk + data header

    let mut buf: Vec<u8> = Vec::with_capacity(44 + pcm.len());
    buf.extend_from_slice(b"RIFF");
    buf.extend_from_slice(&file_len.to_le_bytes());
    buf.extend_from_slice(b"WAVE");
    // fmt sub-chunk
    buf.extend_from_slice(b"fmt ");
    buf.extend_from_slice(&16u32.to_le_bytes()); // sub-chunk size
    buf.extend_from_slice(&1u16.to_le_bytes()); // PCM format
    buf.extend_from_slice(&channels.to_le_bytes());
    buf.extend_from_slice(&sample_rate.to_le_bytes());
    buf.extend_from_slice(&byte_rate.to_le_bytes());
    buf.extend_from_slice(&block_align.to_le_bytes());
    buf.extend_from_slice(&16u16.to_le_bytes()); // bits per sample
                                                 // data sub-chunk
    buf.extend_from_slice(b"data");
    buf.extend_from_slice(&data_len.to_le_bytes());
    buf.extend_from_slice(pcm);

    std::fs::write(path, &buf).unwrap();
}

/// Compute a deterministic cache key from the script content and TTS config.
fn audio_cache_key(script: &[ScriptLine]) -> String {
    use std::hash::{Hash, Hasher};
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    for line in script {
        line.text.hash(&mut hasher);
        match line.speaker {
            Speaker::Therapist => THERAPIST_VOICE.hash(&mut hasher),
            Speaker::Client => CLIENT_VOICE.hash(&mut hasher),
        }
    }
    TTS_SAMPLE_RATE.hash(&mut hasher);
    format!("{:016x}", hasher.finish())
}

/// Load cached TTS audio or generate via ElevenLabs and cache the result.
/// Returns one PCM byte vec per script line, in order.
async fn ensure_tts_audio(
    script: &[ScriptLine],
    http: &reqwest::Client,
    api_key: &str,
) -> Vec<(Speaker, Vec<u8>)> {
    let cache_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("target/test-audio-cache")
        .join(audio_cache_key(script));

    // Check cache
    let all_cached = std::fs::metadata(&cache_dir).is_ok()
        && script
            .iter()
            .enumerate()
            .all(|(i, _)| cache_dir.join(format!("turn_{i}.pcm")).exists());

    if all_cached {
        eprintln!("Using cached TTS audio from: {}", cache_dir.display());
        return script
            .iter()
            .enumerate()
            .map(|(i, line)| {
                let audio = std::fs::read(cache_dir.join(format!("turn_{i}.pcm"))).unwrap();
                let duration = audio.len() as f64 / (2.0 * TTS_SAMPLE_RATE as f64);
                eprintln!("  Turn {}: {:.1}s (cached)", i + 1, duration);
                (line.speaker, audio)
            })
            .collect();
    }

    // Generate and cache
    eprintln!("Generating TTS audio via ElevenLabs (will be cached for future runs)...");
    std::fs::create_dir_all(&cache_dir).unwrap();

    let mut turns = Vec::new();
    for (i, line) in script.iter().enumerate() {
        let voice = match line.speaker {
            Speaker::Therapist => THERAPIST_VOICE,
            Speaker::Client => CLIENT_VOICE,
        };
        let label = match line.speaker {
            Speaker::Therapist => "Therapist",
            Speaker::Client => "Client",
        };

        eprintln!(
            "  Turn {}/{}: {} — generating...",
            i + 1,
            script.len(),
            label
        );
        let audio = generate_speech(http, api_key, voice, line.text).await;
        let duration = audio.len() as f64 / (2.0 * TTS_SAMPLE_RATE as f64);
        eprintln!("    {:.1}s: \"{}\"", duration, line.text);

        std::fs::write(cache_dir.join(format!("turn_{i}.pcm")), &audio).unwrap();
        turns.push((line.speaker, audio));
    }

    eprintln!("Audio cached to: {}", cache_dir.display());
    turns
}

/// Download the Whisper GGML model if not already cached.
async fn ensure_model(client: &reqwest::Client) -> PathBuf {
    let info = model_info();
    let cache_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("target/test-models");
    std::fs::create_dir_all(&cache_dir).unwrap();
    let model_path = cache_dir.join(info.filename);

    if model_path.exists() {
        eprintln!("Using cached model: {}", model_path.display());
        return model_path;
    }

    eprintln!("Downloading {} (first run only)...", info.filename);
    let resp = client
        .get(info.url)
        .send()
        .await
        .expect("Model download request failed");

    assert!(
        resp.status().is_success(),
        "Model download failed: {}",
        resp.status()
    );

    let bytes = resp.bytes().await.expect("Failed to read model bytes");
    let size_mb = bytes.len() as f64 / 1_048_576.0;
    std::fs::write(&model_path, &bytes).unwrap();
    eprintln!("Model saved: {} ({size_mb:.0} MB)", model_path.display());

    model_path
}

/// Shared pipeline: setup -> TTS -> build tracks -> WAV output -> transcribe -> return result.
async fn run_pipeline(
    script: &[ScriptLine],
    session_id: &str,
    output_prefix: &str,
) -> pablo_core::TranscriptResult {
    // ── Setup ────────────────────────────────────────────────────────────────
    let project_root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .to_path_buf();
    dotenvy::from_path(project_root.join(".env")).ok();

    let api_key = std::env::var("ELEVENLABS_API_KEY")
        .expect("ELEVENLABS_API_KEY must be set in .env or environment");

    let http = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(600))
        .build()
        .unwrap();

    // ── Download model (cached after first run) ──────────────────────────────
    let model_path = ensure_model(&http).await;

    // ── Get TTS audio (cached or generated) ─────────────────────────────────
    let turns = ensure_tts_audio(script, &http, &api_key).await;

    let total_tts_duration: f64 = turns
        .iter()
        .map(|(_, audio)| audio.len() as f64 / (2.0 * TTS_SAMPLE_RATE as f64))
        .sum();
    let total_gaps = script.len().saturating_sub(1) as f64 * TURN_GAP_SECS;
    let total_session = total_tts_duration + total_gaps;
    eprintln!(
        "\nSession: {:.1}s speech + {:.1}s gaps = {:.1}s total ({:.1} minutes)",
        total_tts_duration,
        total_gaps,
        total_session,
        total_session / 60.0
    );

    // ── Build two-track recording ────────────────────────────────────────────
    let (mic_track, sys_track) = build_tracks(&turns);

    // System audio → fake stereo (exercises stereo downmix path)
    let sys_stereo = mono_to_fake_stereo(&sys_track);

    eprintln!(
        "Mic track: {} bytes ({:.1}s mono)",
        mic_track.len(),
        mic_track.len() as f64 / (2.0 * TTS_SAMPLE_RATE as f64)
    );
    eprintln!(
        "System track: {} bytes ({:.1}s stereo)",
        sys_stereo.len(),
        sys_stereo.len() as f64 / (4.0 * TTS_SAMPLE_RATE as f64)
    );

    // ── Save playable WAV files to test-output ─────────────────────────────
    let output_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("target/test-output");
    std::fs::create_dir_all(&output_dir).unwrap();

    write_wav(
        &output_dir.join(format!("{output_prefix}_therapist_mic.wav")),
        &mic_track,
        1,
        TTS_SAMPLE_RATE,
    );
    write_wav(
        &output_dir.join(format!("{output_prefix}_client_system.wav")),
        &sys_track,
        1,
        TTS_SAMPLE_RATE,
    );

    // Mixed stereo file (therapist=L, client=R) for easy listening
    let mut mixed_stereo: Vec<u8> = Vec::with_capacity(mic_track.len() * 2);
    for (mic_sample, sys_sample) in mic_track.chunks_exact(2).zip(sys_track.chunks_exact(2)) {
        mixed_stereo.extend_from_slice(mic_sample); // Left = therapist
        mixed_stereo.extend_from_slice(sys_sample); // Right = client
    }
    write_wav(
        &output_dir.join(format!("{output_prefix}_session_mixed.wav")),
        &mixed_stereo,
        2,
        TTS_SAMPLE_RATE,
    );

    eprintln!("Audio saved to: {}", output_dir.display());

    // ── Write temp PCM files for pipeline ────────────────────────────────────
    let tmp = std::env::temp_dir().join(format!("pablo_e2e_{session_id}"));
    std::fs::create_dir_all(&tmp).unwrap();
    let mic_path = tmp.join("therapist_mic.pcm");
    let sys_path = tmp.join("client_system.pcm");
    std::fs::write(&mic_path, &mic_track).unwrap();
    std::fs::write(&sys_path, &sys_stereo).unwrap();

    // ── Run transcription pipeline ───────────────────────────────────────────
    eprintln!("\nRunning transcription pipeline...");
    let start = std::time::Instant::now();

    let config = TranscriptionConfig {
        model_path: model_path.to_string_lossy().to_string(),
        mic_channels: 1,
        mic_sample_rate: TTS_SAMPLE_RATE,
        system_channels: 2,
        system_sample_rate: TTS_SAMPLE_RATE,
    };

    let result = transcribe_session_1on1(
        session_id.to_string(),
        mic_path.to_string_lossy().to_string(),
        Some(sys_path.to_string_lossy().to_string()),
        config,
    )
    .await
    .expect("Transcription pipeline failed");

    let elapsed = start.elapsed();
    eprintln!("Pipeline completed in {elapsed:.1?}");

    // ── Print transcript ─────────────────────────────────────────────────────
    eprintln!("\n{}", "=".repeat(60));
    eprintln!("TRANSCRIPT ({} segments)", result.segments.len());
    eprintln!("{}", "=".repeat(60));
    for seg in &result.segments {
        let speaker = match seg.speaker {
            SpeakerLabel::Therapist => "THERAPIST",
            SpeakerLabel::Client => "CLIENT   ",
            _ => "OTHER    ",
        };
        eprintln!(
            "  [{:>6.1}s - {:>6.1}s] {speaker}: {}",
            seg.start_seconds, seg.end_seconds, seg.text
        );
    }

    // ── Cleanup temp audio files ─────────────────────────────────────────────
    std::fs::remove_dir_all(&tmp).ok();

    result
}

// ── Tests ────────────────────────────────────────────────────────────────────

#[tokio::test]
#[ignore] // Requires ELEVENLABS_API_KEY + internet; run with: --ignored --nocapture
async fn e2e_synthetic_therapy_session() {
    let result = run_pipeline(SHORT_SCRIPT, "e2e-test-short", "short").await;

    // ── Assert: segments exist with correct speaker labels ───────────────────
    assert!(!result.segments.is_empty(), "Pipeline produced no segments");
    assert!(
        result
            .segments
            .iter()
            .any(|s| s.speaker == SpeakerLabel::Therapist),
        "No THERAPIST segments found"
    );
    assert!(
        result
            .segments
            .iter()
            .any(|s| s.speaker == SpeakerLabel::Client),
        "No CLIENT segments found"
    );

    // ── Assert: segments sorted by start time ────────────────────────────────
    for pair in result.segments.windows(2) {
        assert!(
            pair[0].start_seconds <= pair[1].start_seconds,
            "Segments not sorted: {:.1}s > {:.1}s",
            pair[0].start_seconds,
            pair[1].start_seconds
        );
    }

    // ── Assert: turn-taking — therapist and client should alternate ──────────
    let speakers: Vec<&SpeakerLabel> = result.segments.iter().map(|s| &s.speaker).collect();
    let has_interleaving = speakers.windows(2).any(|w| w[0] != w[1]);
    assert!(
        has_interleaving,
        "Expected interleaved speakers but got: {:?}",
        speakers
    );

    // ── Assert: key phrases transcribed correctly ────────────────────────────
    let therapist_text: String = result
        .segments
        .iter()
        .filter(|s| s.speaker == SpeakerLabel::Therapist)
        .map(|s| s.text.as_str())
        .collect::<Vec<_>>()
        .join(" ")
        .to_lowercase();

    let client_text: String = result
        .segments
        .iter()
        .filter(|s| s.speaker == SpeakerLabel::Client)
        .map(|s| s.text.as_str())
        .collect::<Vec<_>>()
        .join(" ")
        .to_lowercase();

    let therapist_checks = [
        ("last session", "therapist greeting"),
        ("triggered", "therapist follow-up"),
        ("coping", "therapist coping question"),
    ];
    let client_checks = [
        ("anxiety", "client presenting problem"),
        ("layoff", "client stressor"), // "layoffs" may become "layoff"
        ("breathing", "client coping strategy"),
    ];

    eprintln!("\n--- Keyword checks ---");
    let mut all_passed = true;

    for (phrase, label) in &therapist_checks {
        let found = therapist_text.contains(phrase);
        let icon = if found { "PASS" } else { "MISS" };
        eprintln!("  [{icon}] Therapist: '{phrase}' ({label})");
        if !found {
            all_passed = false;
        }
    }
    for (phrase, label) in &client_checks {
        let found = client_text.contains(phrase);
        let icon = if found { "PASS" } else { "MISS" };
        eprintln!("  [{icon}] Client: '{phrase}' ({label})");
        if !found {
            all_passed = false;
        }
    }

    if !all_passed {
        eprintln!("\nSome keywords missed — expected with tiny model.");
        eprintln!("Re-run with WHISPER_MODEL=small for higher accuracy.");
    }

    // Hard assertion: at least 2/3 keywords per speaker must match.
    let therapist_hits = therapist_checks
        .iter()
        .filter(|(p, _)| therapist_text.contains(p))
        .count();
    let client_hits = client_checks
        .iter()
        .filter(|(p, _)| client_text.contains(p))
        .count();

    assert!(
        therapist_hits >= 2,
        "Only {therapist_hits}/3 therapist keywords found. Therapist text:\n{therapist_text}"
    );
    assert!(
        client_hits >= 2,
        "Only {client_hits}/3 client keywords found. Client text:\n{client_text}"
    );

    // ── Assert: Google Meet format ───────────────────────────────────────────
    let meet_output = render_google_meet(
        result,
        GoogleMeetOptions {
            session_date: "March 7, 2026".to_string(),
            therapist_name: "Dr. Sarah Chen".to_string(),
            client_name: "Alex Rivera".to_string(),
            client_a_name: String::new(),
            client_b_name: String::new(),
        },
    );

    eprintln!("\n{}", "=".repeat(60));
    eprintln!("GOOGLE MEET FORMAT");
    eprintln!("{}", "=".repeat(60));
    eprintln!("{meet_output}");

    assert!(
        meet_output.starts_with("Google Meet Transcript\n"),
        "Missing header"
    );
    assert!(
        meet_output.contains("Session Date: March 7, 2026"),
        "Missing session date"
    );
    assert!(
        meet_output.contains("Dr. Sarah Chen:"),
        "Missing therapist name in turns"
    );
    assert!(
        meet_output.contains("Alex Rivera:"),
        "Missing client name in turns"
    );
    assert!(meet_output.contains("Speakers: 2"), "Expected 2 speakers");
    assert!(
        meet_output.contains("Dr. Sarah Chen (Therapist)"),
        "Missing therapist in speaker list"
    );
    assert!(
        meet_output.contains("Alex Rivera (Client)"),
        "Missing client in speaker list"
    );
    assert!(
        meet_output.contains("[Session ends"),
        "Missing session end marker"
    );

    // ── Write transcript to file ────────────────────────────────────────────
    let output_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("target/test-output");
    std::fs::write(output_dir.join("short_transcript.txt"), &meet_output).unwrap();
    eprintln!(
        "\nTranscript written to: {}",
        output_dir.join("short_transcript.txt").display()
    );

    eprintln!("E2E short test passed.");
}

#[tokio::test]
#[ignore] // Requires ELEVENLABS_API_KEY + internet + ~10-30 min transcription time
async fn e2e_full_therapy_session() {
    let result = run_pipeline(
        support::therapy_script_60min::SCRIPT,
        "e2e-test-60min",
        "full_60min",
    )
    .await;

    // ── Assert: sufficient segments from both speakers ───────────────────────
    assert!(!result.segments.is_empty(), "Pipeline produced no segments");

    let therapist_count = result
        .segments
        .iter()
        .filter(|s| s.speaker == SpeakerLabel::Therapist)
        .count();
    let client_count = result
        .segments
        .iter()
        .filter(|s| s.speaker == SpeakerLabel::Client)
        .count();
    eprintln!(
        "\nSegment counts: {} therapist, {} client, {} total",
        therapist_count,
        client_count,
        result.segments.len()
    );

    assert!(
        therapist_count >= 10,
        "Expected at least 10 therapist segments, got {therapist_count}"
    );
    assert!(
        client_count >= 10,
        "Expected at least 10 client segments, got {client_count}"
    );

    // ── Assert: segments sorted by start time ────────────────────────────────
    for pair in result.segments.windows(2) {
        assert!(
            pair[0].start_seconds <= pair[1].start_seconds,
            "Segments not sorted: {:.1}s > {:.1}s",
            pair[0].start_seconds,
            pair[1].start_seconds
        );
    }

    // ── Assert: interleaved speakers ─────────────────────────────────────────
    let speakers: Vec<&SpeakerLabel> = result.segments.iter().map(|s| &s.speaker).collect();
    let has_interleaving = speakers.windows(2).any(|w| w[0] != w[1]);
    assert!(
        has_interleaving,
        "Expected interleaved speakers but got: {:?}",
        speakers
    );

    // ── Assert: reasonable word count for a 60-minute session ─────────────────
    let total_words: usize = result
        .segments
        .iter()
        .map(|s| s.text.split_whitespace().count())
        .sum();
    eprintln!("Total words transcribed: {total_words}");
    assert!(
        total_words >= 500,
        "Expected at least 500 words for 60-min session, got {total_words}"
    );

    // ── Assert: spot-check keywords from different session phases ────────────
    let all_text: String = result
        .segments
        .iter()
        .map(|s| s.text.as_str())
        .collect::<Vec<_>>()
        .join(" ")
        .to_lowercase();

    let spot_checks = [
        "catastroph", // catastrophizing (Phase 3)
        "evidence",   // evidence-based technique (Phase 6)
        "layoff",     // presenting problem (Phase 2)
        "anxiety",    // core symptom (throughout)
        "gym",        // behavioral activation (Phase 8)
        "girlfriend", // relationship impact (Phase 4/11)
        "sleep",      // sleep hygiene (Phase 9)
        "breathing",  // coping strategy (Phase 1)
    ];

    eprintln!("\n--- Spot-check keywords ---");
    let mut hits = 0;
    for keyword in &spot_checks {
        let found = all_text.contains(keyword);
        let icon = if found { "PASS" } else { "MISS" };
        eprintln!("  [{icon}] '{keyword}'");
        if found {
            hits += 1;
        }
    }
    assert!(
        hits >= 4,
        "Only {hits}/{} keywords found in full session",
        spot_checks.len()
    );

    // ── Google Meet format ───────────────────────────────────────────────────
    let meet_output = render_google_meet(
        result,
        GoogleMeetOptions {
            session_date: "March 7, 2026".to_string(),
            therapist_name: "Dr. Sarah Chen".to_string(),
            client_name: "Alex Rivera".to_string(),
            client_a_name: String::new(),
            client_b_name: String::new(),
        },
    );

    assert!(
        meet_output.starts_with("Google Meet Transcript\n"),
        "Missing header"
    );
    assert!(meet_output.contains("Speakers: 2"), "Expected 2 speakers");

    // Write full transcript
    let output_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("target/test-output");
    std::fs::write(output_dir.join("full_60min_transcript.txt"), &meet_output).unwrap();
    eprintln!(
        "\nFull transcript written to: {}",
        output_dir.join("full_60min_transcript.txt").display()
    );

    eprintln!("E2E full 60-minute test passed.");
}
