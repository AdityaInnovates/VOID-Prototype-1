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

## Trying other brains

The menu bar has two pickers for A/B testing on your own Mac:

- **Reflex brain:** Qwen3.5 0.8B (default) or LFM2 1.2B. LFM is built for instruction following and short chat.
- **Deep brain:** Qwen3.5 2B or 4B (4B needs ~3 GB free), or Liquid LFM2 1.2B or 2.6B. The choice is remembered.

Each reply's metrics line now shows how long the prompt took to process, e.g. `reflex 410 ms (prompt 620 tok in 280 ms)`.
Use it to see whether caching the fixed system prompt is worth building.

## Music (YouTube Music in Chrome)

VOID plays music through your own YouTube Music tab, using the extension in `VOIDMusicExtension/`.

**Set up once**
1. Build and run VOID (`./build.sh`).
2. In Chrome, open `chrome://extensions`, turn on **Developer mode**, click **Load unpacked**, and choose the `VOIDMusicExtension` folder.
3. In VOID's menu, click **Copy music pairing code**. Click the extension's icon in Chrome, paste the code, and click **Connect**.
4. The menu shows "Music: connected", then reads your library from music.youtube.com/library (you need to be signed in in Chrome).

**Say things like**
- "play some music" or "play something calm": VOID picks one of your playlists for the moment
- "play my gym playlist", "play my liked songs"
- "play Blinding Lights by The Weeknd": searches YouTube Music, plays the song, then its radio
- "play a random song", "play a random chill song"
- "pause", "resume", "next", "go back", "louder", "volume 40", "mute"
- "what's playing?", "I love this song" (saved to likes), "I don't like this" (skips it and remembers)
- "resync my library"

The music goes quiet while you talk to VOID or VOID talks back, then comes back up.

**What VOID stores** (in `~/Library/Application Support/VOID/music/`)
- `library.json`: your playlists and a sample of each one's tracks, refreshed each time Chrome connects
- `liked.json`: VOID's own record of every song you like, with when and in what situation
- `plays.jsonl`: one line per song played: how long you listened, whether you skipped it, what you were doing

**If something stops working:** YouTube Music has no public API, so the extension reads the page. When Google changes the page, the fix is in `VOIDMusicExtension/page.js`, which holds every page selector. After editing it, click the reload icon on the extension in `chrome://extensions`.

### How VOID picks music for you ("play some music", "play a random song")

What you say and how you react come first. Sensed signals are small nudges.

- **Your words:** a mood you name ("something calm") overrides everything. A mood you mention ("I'm tired", "stressed", "feeling low") is remembered for 3 hours. For sad, stressed, angry or tired, VOID asks once whether you want music that stays with it or lifts you, then remembers your answer.
- **Your reactions:** what you kept playing, liked, or skipped, weighted by time of day and weekday vs weekend. A quick skip of a playlist VOID picked counts strongly against it; hearing a playlist you asked for counts strongly for it; later songs and radio count weakly. After two quick skips VOID stops guessing and asks what you want.
- **Small nudges:** time of day, weekend, weather (macOS Location, cached a day), the app you're in, idle time, a 2 second room listen through the mic only at the moment of choosing (labels only, never audio), and how lively your voice sounds against your own usual (speed and loudness, never what you feel).
- The menu's "Last pick" line shows what it saw and chose, and VOID says the main reason out loud. Say "not that one" or "play another" and it learns.

**First run:** macOS will ask once for location access. If you say no, the weather part is skipped and everything else still works.

### Songs you keep replaying ("Listen again")

Each time Chrome connects (or you resync), the extension also reads music.youtube.com/listen_again and VOID keeps those songs in `listen_again.json`. They get a gentle push, only when they fit the moment:
- when a playlist is chosen, the song it starts on is about 3 times as likely to be one of your replays
- playlists holding several replays get a small bonus in the scoring
- for "play a random song", about 4 times in 10 VOID first looks for a replayed song whose playlists feel right for this moment (it can only judge a song that sits in one of your mood-named playlists), and says so ("…one you keep replaying")
