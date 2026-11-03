# VOID — Prototype 1

A fully local voice assistant for macOS. VOID hears you (Parakeet), thinks with two
brains (Qwen3.5 0.8B + 2B on MLX) that speak as one voice, and talks back with an
expressive neural voice (Chatterbox Nano, or Kokoro for speed). Nothing leaves your Mac
after the first model download. Needs macOS 15 or newer.

## Run it

You need Xcode 26 or newer and Homebrew.

```bash
cd ~/Desktop/"Projects/Personal Projects/VOID/Prototype1"
./build.sh
```

`build.sh` installs XcodeGen if needed, generates `VOID.xcodeproj`, builds and launches
VOID. If it fails, it prints the errors and saves everything to `build.log`.

On first launch VOID downloads its models (about 3.5 GB: brains, Parakeet ears,
Chatterbox voice). After that it runs offline. macOS asks for **microphone access** the first time
you talk. Allow it.

## Using it

- **Hold ⌥Space** and talk. Let go to send. (A quick tap shows or hides the orb.)
- **Click the orb** to talk hands-free: it listens until you stop speaking.
- Or type and press Return. **Esc** stops VOID mid-sentence, or hides the orb.
- Talking over VOID while it speaks cuts it off.
- The menu bar circle has the transcript, a new conversation, "Speak replies", the
  **voice** (Expressive · Chatterbox, or Fast · Kokoro), and the brain mode. **Focus mode** swaps the deep brain to Qwen3.5 4B; use it with heavy apps closed.

## The orb

Glowing rings, not a globe. Idle: one ring and a faint one inside, breathing. Listening:
the ring becomes a soft wave that follows your voice. Thinking: rings appear inside and
spin like a gyroscope; the deep brain adds a third ring, a violet tint, and waves pulsing
outward. Speaking: the ring waves with VOID's real audio and loud moments send ripples out.

## How it's built

| Piece | File | What it does |
| --- | --- | --- |
| App shell | `App/VOIDApp.swift`, `App/AppDelegate.swift` | Menu bar app, ⌥Space tap/hold, memory pressure |
| State | `App/AppState.swift` | One observable state that drives the orb and captions |
| Orb | `UI/OrbView.swift` | Rings drawn in a Canvas, driven by the live audio level and thinking depth |
| Panel | `UI/OrbPanel.swift` | Borderless, blurred, dark floating panel |
| Ears | `Audio/VoiceInput.swift`, `Audio/Transcriber.swift` | Mic at 16 kHz, silence detection, Parakeet TDT 0.6B v3 |
| Voice | `Audio/SpeechOutput.swift`, `Audio/SentenceChunker.swift` | Chatterbox Nano or Kokoro, sentence by sentence, gapless playback, system-voice fallback |
| Level | `Audio/OrbSignal.swift` | Loudness history shared by mic, speaker and orb |
| Brains | `Brain/MLXBrain.swift` | One MLX model on the GPU: load, stream, unload |
| Two-brain logic | `Brain/Conversation.swift` | Listen → reflex → deep → speak |
| Personality | `Brain/Persona.swift` | VOID's persona, reflex rules, router, model choices |

### Two brains, one voice

1. The **reflex** (Qwen3.5 0.8B) is told it is the first instant of VOID's voice. It either
   answers small talk outright (`ANSWER: …`) or says just the opening words, reacting to
   the specific question (`LEAD: Ah, pipeline stalls. The classic headache.`). That line is
   spoken at once.
2. The **deep brain** (Qwen3.5 2B) is handed those exact words as the start of its own
   reply (a pre-filled assistant turn), so it simply keeps talking, in the same mood,
   without repeating or re-greeting. It's spoken sentence by sentence as it's written.
3. Both share one memory: small talk the reflex handled is in the deep brain's history,
   and every reply is stored as one message. Switching brain mode keeps the memory.
4. The deep brain sleeps after 10 idle minutes, and on critical memory pressure.

The transcript shows each reply as one message with reflex time, deep first-word time
and tokens/sec.

### The voice

**Chatterbox Nano** (Resemble AI, 110M, MIT) runs through FluidAudio on Core ML. It sounds
much more human than Kokoro and can perform `[chuckle]`, `[laugh]`, `[sigh]` and `[gasp]`;
the deep brain is allowed to use one rarely. It's a bit slower to start each sentence.
**Kokoro** is the fast fallback. Only one is loaded at a time.

## Next

- Hands-free wake word and barge-in by voice (Silero VAD).
- A custom cloned voice (Pocket TTS can clone from a short clip).
- Tools.
