# Router eval

- Date: 2026-11-04T19:32:17Z
- Mode: offline (rules + tool search only)
- Tool search threshold: 0.58
- **Overall: 135/209 (65%)**

## By slice

| Slice | Right | Total | Accuracy |
|---|---|---|---|
| ambiguous | 9 | 15 | 60% |
| asr_noise | 20 | 28 | 71% |
| chat_en | 14 | 30 | 47% |
| chat_hinglish | 6 | 14 | 43% |
| hinglish_tools | 14 | 25 | 56% |
| mac_en | 16 | 18 | 89% |
| music_en | 29 | 30 | 97% |
| music_hinglish | 0 | 20 | 0% |
| phone_en | 27 | 29 | 93% |

False triggers (chat that fired a tool or music): 25/46

## By stage

| Stage | Cases | Right | Avg ms |
|---|---|---|---|
| below-threshold | 43 | 23 | 4 |
| music-rules | 39 | 37 | 0 |
| phone-rules | 35 | 27 | 0 |
| tool-search | 92 | 48 | 6 |

## Misses

| id | said | wanted | got | stage | note |
|---|---|---|---|---|---|
| music_en-28 | play something for the gym | music:suggest | music:song | music-rules |  |
| music_hinglish-01 | gaana pause karo | music:pause | tool:mac.wifi | tool-search | 0.62 |
| music_hinglish-02 | gaana band karo | music:pause | chat | below-threshold | best phone.call 0.55 |
| music_hinglish-03 | music rok do | music:pause | chat | below-threshold | best phone.media 0.57 |
| music_hinglish-04 | agla gaana chalao | music:next | chat | below-threshold | best mac.wifi 0.51 |
| music_hinglish-05 | gaana change karo | music:next | tool:mac.wifi | tool-search | 0.62 |
| music_hinglish-06 | ye gaana skip karo | music:next | tool:mac.wifi | tool-search | 0.60 |
| music_hinglish-07 | pichla gaana lagao | music:previous | chat | below-threshold | best mac.wifi 0.52 |
| music_hinglish-08 | volume thoda kam karo | music:volume | tool:mac.volume | tool-search | 0.61 |
| music_hinglish-09 | awaaz badha do | music:volume | chat | below-threshold | best mac.wifi 0.56 |
| music_hinglish-10 | volume pachas kar do | music:volume | chat | below-threshold | best mac.volume 0.57 |
| music_hinglish-11 | ye konsa gaana hai | music:nowPlaying | chat | below-threshold | best mac.wifi 0.57 |
| music_hinglish-12 | ye gaana pasand aaya | music:like | chat | below-threshold | best mac.wifi 0.57 |
| music_hinglish-13 | mere liked songs chalao | music:likedSongs | chat | below-threshold | best phone.sms.send 0.41 |
| music_hinglish-14 | kuch shaant sa chalao | music:suggest | chat | below-threshold | best mac.wifi 0.53 |
| music_hinglish-15 | koi sad gaana lagao | music:suggest | chat | below-threshold | best phone.call 0.49 |
| music_hinglish-16 | arijit singh ka koi gaana chalao | music:song or music:suggest | chat | below-threshold | best mac.wifi 0.51 |
| music_hinglish-17 | laal pari chalao | music:song | chat | below-threshold | best mac.wifi 0.52 |
| music_hinglish-18 | gaana chalu karo | music:resume | tool:mac.wifi | tool-search | 0.58 |
| music_hinglish-19 | phir se wahi gaana chalao | music:replay | chat | below-threshold | best mac.wifi 0.54 |
| music_hinglish-20 | kuch random gaana laga do | music:random or music:suggest | chat | below-threshold | best mac.wifi 0.56 |
| phone_en-04 | where is my phone | tool:phone.location | tool:phone.ring | phone-rules |  |
| phone_en-29 | vibrate my phone | tool:phone.vibrate | tool:phone.ringer | phone-rules |  |
| mac_en-07 | set the mac volume to 30 | tool:mac.volume | music:volume | music-rules |  |
| mac_en-16 | what did i copy on my mac | tool:mac.clipboard.get | tool:phone.clipboard.get | tool-search | 0.97 |
| hinglish_tools-01 | mera phone ring karo | tool:phone.ring | tool:phone.call | tool-search | 0.89 |
| hinglish_tools-02 | phone dhundo | tool:phone.ring or tool:phone.location | tool:phone.call | phone-rules |  |
| hinglish_tools-04 | mere messages padho | tool:phone.sms.read | tool:phone.notifications | tool-search | 0.64 |
| hinglish_tools-06 | mummy ko call karo | tool:phone.call | tool:mac.lock | tool-search | 0.60 |
| hinglish_tools-10 | phone ko silent kar do | tool:phone.ringer | tool:phone.call | phone-rules |  |
| hinglish_tools-11 | phone ko ring mode pe karo | tool:phone.ringer | tool:phone.call | phone-rules |  |
| hinglish_tools-13 | dnd on karo | tool:phone.dnd | tool:mac.wifi | tool-search | 0.63 |
| hinglish_tools-14 | subah 6 baje ka alarm lagao | tool:phone.alarm | chat | below-threshold | best mac.wifi 0.56 |
| hinglish_tools-16 | ek ghante baad yaad dilana | tool:phone.timer | chat | below-threshold | best mac.wifi 0.49 |
| hinglish_tools-24 | phone par whatsapp kholo | tool:phone.apps.open | tool:phone.call | phone-rules |  |
| hinglish_tools-25 | phone lock kar do | tool:phone.lock | tool:phone.call | phone-rules |  |
| asr_noise-03 | pause the musik | music:pause | tool:mac.wifi | tool-search | 0.64 |
| asr_noise-04 | skip ths song | music:next | chat | below-threshold | best phone.media 0.55 |
| asr_noise-05 | nex song | music:next | chat | below-threshold | best phone.media 0.55 |
| asr_noise-07 | start the music | music:resume | tool:phone.media | tool-search | 0.67 |
| asr_noise-08 | what is playing right now | music:nowPlaying | tool:phone.location | tool-search | 0.63 |
| asr_noise-09 | plays something calm | music:suggest | chat | below-threshold | best phone.speak 0.42 |
| asr_noise-10 | volume fourty | music:volume | tool:mac.volume | tool-search | 0.76 |
| asr_noise-16 | what's the baterry on my fone | tool:phone.status | tool:mac.apps | tool-search | 0.73 |
| chat_en-01 | how are you | chat | tool:mac.status | tool-search | 0.64 |
| chat_en-02 | tell me a joke | chat | tool:phone.notifications | tool-search | 0.76 |
| chat_en-03 | what's the capital of france | chat | tool:phone.location | tool-search | 0.64 |
| chat_en-07 | tell me something interesting | chat | tool:phone.speak | tool-search | 0.76 |
| chat_en-08 | what is bluetooth | chat | tool:mac.clipboard.get | tool-search | 0.67 |
| chat_en-09 | how does wifi work | chat | tool:mac.status | tool-search | 0.77 |
| chat_en-10 | my phone is so slow lately | chat | tool:phone.ringer | tool-search | 0.73 |
| chat_en-12 | explain how a battery works | chat | tool:phone.status | tool-search | 0.71 |
| chat_en-14 | should i call my mom more often | chat | tool:phone.call | tool-search | 0.65 |
| chat_en-16 | good morning | chat | tool:mac.shortcut | tool-search | 0.62 |
| chat_en-19 | what time is it | chat | tool:phone.location | tool-search | 0.69 |
| chat_en-21 | is a torch the same as a flashlight | chat | tool:phone.torch | tool-search | 0.58 |
| chat_en-23 | what does volume mean in finance | chat | tool:mac.clipboard.get | tool-search | 0.58 |
| chat_en-25 | what should i eat tonight | chat | tool:phone.notifications | tool-search | 0.72 |
| chat_en-26 | what's the difference between a mac and a pc | chat | tool:phone.location | tool-search | 0.66 |
| chat_en-29 | tell me about the song shape of you | chat | tool:phone.speak | tool-search | 0.59 |
| chat_hinglish-02 | mujhe neend aa rahi hai | chat | tool:mac.wifi | tool-search | 0.59 |
| chat_hinglish-03 | aaj ka din bahut bura tha | chat | tool:mac.wifi | tool-search | 0.62 |
| chat_hinglish-04 | ek joke sunao | chat | tool:phone.sms.send | tool-search | 0.62 |
| chat_hinglish-07 | bluetooth kya hota hai | chat | tool:mac.bluetooth | tool-search | 0.62 |
| chat_hinglish-08 | mera mood off hai | chat | tool:mac.bluetooth | tool-search | 0.69 |
| chat_hinglish-09 | padhai mein mann nahi lag raha | chat | tool:mac.wifi | tool-search | 0.58 |
| chat_hinglish-11 | phone mein kya kya features hote hain | chat | tool:phone.call | phone-rules |  |
| chat_hinglish-14 | mummy ko kya gift dun | chat | tool:phone.sms.send | tool-search | 0.58 |
| ambiguous-02 | i need to focus | chat or music:suggest | tool:mac.shortcut | tool-search | 0.62 |
| ambiguous-07 | turn it off | chat or music:pause | tool:mac.volume | tool-search | 0.87 |
| ambiguous-08 | text mom | tool:phone.sms.send | tool:phone.call | tool-search | 0.79 |
| ambiguous-09 | call | chat | tool:phone.call | tool-search | 0.67 |
| ambiguous-10 | what's the volume | chat or music:volume or tool:mac.volume | tool:phone.location | tool-search | 0.75 |
| ambiguous-14 | what's up with my phone | chat or tool:phone.status | tool:phone.clipboard.get | tool-search | 0.86 |
