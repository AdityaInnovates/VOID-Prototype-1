# Router eval

- Date: 2026-11-04T21:01:23Z
- Mode: offline (rules + tool search only)
- Tool search threshold: 0.58
- **Overall: 203/209 (97%)**

## By slice

| Slice | Right | Total | Accuracy |
|---|---|---|---|
| ambiguous | 13 | 15 | 87% |
| asr_noise | 27 | 28 | 96% |
| chat_en | 28 | 30 | 93% |
| chat_hinglish | 14 | 14 | 100% |
| hinglish_tools | 25 | 25 | 100% |
| mac_en | 18 | 18 | 100% |
| music_en | 30 | 30 | 100% |
| music_hinglish | 19 | 20 | 95% |
| phone_en | 29 | 29 | 100% |

False triggers (chat that fired a tool or music): 3/46

## By stage

| Stage | Cases | Right | Avg ms |
|---|---|---|---|
| below-threshold | 50 | 48 | 3 |
| music-rules | 65 | 65 | 0 |
| phone-rules | 43 | 43 | 0 |
| tool-search | 51 | 47 | 4 |

## Misses

| id | said | wanted | got | stage | note |
|---|---|---|---|---|---|
| music_hinglish-10 | volume pachas kar do | music:volume | chat | below-threshold | best mac.volume 0.57, evidence 1 |
| asr_noise-23 | open watsapp | tool:phone.apps.open or tool:mac.open | chat | below-threshold | best mac.open 0.79, evidence 0 |
| chat_en-01 | how are you | chat | tool:phone.notifications | tool-search | 0.59 |
| chat_en-16 | good morning | chat | tool:mac.shortcut | tool-search | 0.62 |
| ambiguous-02 | i need to focus | chat or music:suggest | tool:mac.shortcut | tool-search | 0.62 |
| ambiguous-09 | call | chat | tool:phone.call | tool-search | 0.67 |
