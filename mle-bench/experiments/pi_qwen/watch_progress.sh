#!/bin/bash
# Poll runs/pi-qwen/<candidate>/baseline/*/run.json and emit one line the
# first time each run's ended_at_utc becomes non-null (i.e. the case finished,
# regardless of which terminal status it landed on).
set -u

cd "d:/Downloads/Content/NUS/lab/mle-bench" || exit 1
PY="/d/automata/python"
CANDIDATES="tabular-playground-series-may-2022 ventilator-pressure-prediction chaii-hindi-and-tamil-question-answering text-normalization-challenge-english-language statoil-iceberg-classifier-challenge tgs-salt-identification-challenge"
SEEN_FILE=$(mktemp)      # run.json paths already processed (dedup within a candidate's retries)
DONE_CANDIDATES=$(mktemp)  # distinct candidate IDs with at least one finished run (dedup across retries)

is_finished() {
  "$PY" -c "
import json, sys
try:
    d = json.load(open(r'$1', encoding='utf-8'))
except Exception:
    sys.exit(1)
sys.exit(0 if d.get('ended_at_utc') else 1)
" 2>/dev/null
}

emit_summary() {
  "$PY" -c "
import json
d = json.load(open(r'$1', encoding='utf-8'))
g = d.get('grade') or {}
print('DONE %s status=%s dur=%.0fs score=%s bronze=%s lower_better=%s valid_submission=%s' % (
    d.get('competition_id'), d.get('status'), d.get('duration_seconds') or 0,
    g.get('score'), g.get('bronze_threshold'), g.get('is_lower_better'), g.get('valid_submission'),
))
"
}

# Priming pass: silently mark whatever is already finished as seen (both the
# per-file dedup set and the per-candidate dedup set) so we only emit
# genuinely new completions from here on.
for c in $CANDIDATES; do
  for runjson in runs/pi-qwen/"$c"/baseline/*/run.json; do
    [ -f "$runjson" ] || continue
    if is_finished "$runjson"; then
      echo "$runjson" >> "$SEEN_FILE"
      grep -qxF "$c" "$DONE_CANDIDATES" 2>/dev/null || echo "$c" >> "$DONE_CANDIDATES"
    fi
  done
done

while true; do
  for c in $CANDIDATES; do
    for runjson in runs/pi-qwen/"$c"/baseline/*/run.json; do
      [ -f "$runjson" ] || continue
      grep -qxF "$runjson" "$SEEN_FILE" 2>/dev/null && continue
      if is_finished "$runjson"; then
        echo "$runjson" >> "$SEEN_FILE"
        emit_summary "$runjson"
        grep -qxF "$c" "$DONE_CANDIDATES" 2>/dev/null || echo "$c" >> "$DONE_CANDIDATES"
      fi
    done
  done
  # stop once all six DISTINCT candidates have a finished run (a candidate
  # can have >1 run.json across retries, so dedup by candidate ID, not file).
  done_count=$(wc -l < "$DONE_CANDIDATES")
  if [ "$done_count" -ge 6 ]; then
    echo "ALL_SIX_DONE"
    break
  fi
  sleep 45
done
