# Router eval

`router_eval.jsonl` has ~210 labelled commands (English, Hinglish, noisy speech, chat that
must NOT trigger anything, and genuinely ambiguous ones). Each line:

    {"id": "...", "slice": "...", "text": "...", "expect": "music:pause | tool:mac.wifi | chat", "args": {...}}

`expect` can list several acceptable answers separated by `|`. `args` (optional) are checked
loosely: names by substring, numbers and booleans exactly.

## Run it
VOID menu → Router eval →
- **Run offline**: phone/music rules and tool search only. Instant, no model needed.
- **Run full**: also runs the small model (music router and tool planner). Takes a few minutes.

It writes `Eval/results/router_eval_<mode>_<time>.md` and reveals it in Finder. Nothing is
executed: no song plays, no text is sent.

## Growing it from real use
VOID now records every command and the path it took in
`~/Library/Application Support/VOID/commands.jsonl` (local only). Copy lines you want into
`router_eval.jsonl` with the right `expect`. Turn the log off with
`defaults write com.adityainnovates.void commandLog -bool NO`.

`make_eval.py` regenerates the starter set.
