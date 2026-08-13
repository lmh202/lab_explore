#!/bin/bash
# Watch the v4 (patched-pi + tool-result-guard) rerun cases -- chaii, tgs-salt.
set -u

cd "d:/Downloads/Content/NUS/lab/mle-bench" || exit 1
PY="/d/automata/python"
CANDIDATES="chaii-hindi-and-tamil-question-answering tgs-salt-identification-challenge"

OLD_DIRS=$(mktemp)
for c in $CANDIDATES; do
  for d in runs/pi-qwen/"$c"/baseline/*/; do
    [ -d "$d" ] && echo "$d" >> "$OLD_DIRS"
  done
done

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
integ = d.get('integrity') or {}
psv = d.get('public_submission_validation') or {}
print('RERUN_V4_DONE %s status=%s dur=%.0fs integrity_clean=%s submission_valid_host=%s score=%s bronze=%s lower_better=%s valid_submission_grader=%s' % (
    d.get('competition_id'), d.get('status'), d.get('duration_seconds') or 0,
    integ.get('clean'), psv.get('valid'),
    g.get('score'), g.get('bronze_threshold'), g.get('is_lower_better'), g.get('valid_submission'),
))
"
}

SEEN_FILE=$(mktemp)
DONE_CANDIDATES=$(mktemp)

while true; do
  for c in $CANDIDATES; do
    for runjson in runs/pi-qwen/"$c"/baseline/*/run.json; do
      [ -f "$runjson" ] || continue
      rundir=$(dirname "$runjson")/
      grep -qxF "$rundir" "$OLD_DIRS" 2>/dev/null && continue
      grep -qxF "$runjson" "$SEEN_FILE" 2>/dev/null && continue
      if is_finished "$runjson"; then
        echo "$runjson" >> "$SEEN_FILE"
        emit_summary "$runjson"
        grep -qxF "$c" "$DONE_CANDIDATES" 2>/dev/null || echo "$c" >> "$DONE_CANDIDATES"
      fi
    done
  done
  done_count=$(wc -l < "$DONE_CANDIDATES")
  if [ "$done_count" -ge 2 ]; then
    echo "ALL_RERUNS_V4_REPORTED"
    break
  fi
  sleep 45
done
