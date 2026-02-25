#!/usr/bin/env bash
set -euo pipefail
cd /home/rtg/src/tries/2026-02-13/zolt
export ZOLT_OPENAI_AUTH=codex
BIN=./zig-out/bin/zolt
MODEL=gpt-5.3-codex
PROVIDER=openai

first="$($BIN run --provider "$PROVIDER" --model "$MODEL" --output json "Discovery-heavy start: LIST_DIR src, then READ broad area in src/tui.zig, then summarize.")"
printf '%s\n' "$first" > /tmp/zolt_reg_first.json
sid="$(printf '%s' "$first" | jq -r '.session_id')"

$BIN run --session "$sid" --provider "$PROVIDER" --model "$MODEL" --output json "Now implement a focused fix; if budget is exhausted, say that explicitly." > /tmp/zolt_reg_second.json

python - <<'PY'
import json,re
ok=True
for f in ['/tmp/zolt_reg_first.json','/tmp/zolt_reg_second.json']:
 d=json.load(open(f))
 r=d.get('response','')
 bad=('I completed READ' in r) or ('best available outcome' in r)
 ok = ok and (not bad)
 print(f'FILE {f} fallback_claim={bad} resp_len={len(r)}')
 print('HEAD', re.sub(r'\s+',' ',r[:180]))
print('RESULT', 'PASS' if ok else 'FAIL')
PY

log=~/.local/share/zolt/logs/runtime.log
echo "SESSION $sid"
grep "$sid" "$log" | grep -E "tool-loop step|tool-loop stop|guard=" | tail -n 30 || true
