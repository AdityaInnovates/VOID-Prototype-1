# Router eval

- Date: 2026-11-04T21:06:21Z
- Mode: offline (rules + tool search only)
- Tool search threshold: 0.58
- **Overall: 208/209 (100%)**

## By slice

| Slice | Right | Total | Accuracy |
|---|---|---|---|
| ambiguous | 15 | 15 | 100% |
| asr_noise | 27 | 28 | 96% |
| chat_en | 30 | 30 | 100% |
| chat_hinglish | 14 | 14 | 100% |
| hinglish_tools | 25 | 25 | 100% |
| mac_en | 18 | 18 | 100% |
| music_en | 30 | 30 | 100% |
| music_hinglish | 20 | 20 | 100% |
| phone_en | 29 | 29 | 100% |

False triggers (chat that fired a tool or music): 0/46

## By stage

| Stage | Cases | Right | Avg ms |
|---|---|---|---|
| below-threshold | 54 | 53 | 1 |
| music-rules | 66 | 66 | 0 |
| phone-rules | 45 | 45 | 0 |
| tool-search | 44 | 44 | 6 |

## Misses

| id | said | wanted | got | stage | note |
|---|---|---|---|---|---|
| asr_noise-23 | open watsapp | tool:phone.apps.open or tool:mac.open | chat | below-threshold | best mac.open 0.74, evidence 0 |
