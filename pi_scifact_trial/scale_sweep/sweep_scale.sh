#!/bin/bash
# Corpus-size scaling sweep: for each size in SIZES, run all CLAIMS, average
# the wall time, stop if any run hard-fails (nonzero exit, incl. 10-min timeout).
set -u

DIR="d:/Downloads/Content/NUS/lab/pi_scifact_trial/scale_sweep"
PI="D:/Downloads/Content/NUS/lab/pi/pi.exe"
CLAIMS="206 546 920"
SIZES="500 1500 5000 15000 50000 150000 500000"
CSV="$DIR/sweep_results.csv"

cd "$DIR" || exit 1
echo "size,claim_id,duration_sec,exit_code,timed_out" > "$CSV"

for N in $SIZES; do
  echo "=== size=$N ==="
  durations=""
  scale_failed=0
  for CID in $CLAIMS; do
    corpus="corpus_${CID}_${N}.jsonl"
    task="task_${CID}_${N}.md"
    result="result_${CID}_${N}.txt"
    if [ ! -f "$corpus" ] || [ ! -f "$task" ]; then
      echo "MISSING $corpus or $task -- skipping"
      continue
    fi

    start=$(date +%s)
    timeout 600s "$PI" --print --provider lum-llm --model qwen3.6-27b \
      --name "sweep-${CID}-${N}" "@${task}" > "$result" 2>&1
    rc=$?
    end=$(date +%s)
    dur=$((end - start))

    timed_out=0
    if [ $rc -eq 124 ]; then
      timed_out=1
    fi

    echo "$N,$CID,$dur,$rc,$timed_out" >> "$CSV"
    echo "  claim=$CID  duration=${dur}s  exit=$rc  timed_out=$timed_out"

    durations="$durations $dur"
    if [ $rc -ne 0 ]; then
      scale_failed=1
    fi
  done

  # average
  sum=0
  count=0
  for d in $durations; do
    sum=$((sum + d))
    count=$((count + 1))
  done
  if [ $count -gt 0 ]; then
    avg=$((sum / count))
    echo "size=$N avg_duration=${avg}s over $count claims"
  fi

  if [ $scale_failed -eq 1 ]; then
    echo "STOP: size=$N hit a hard failure (nonzero exit or 10-min timeout) on at least one claim."
    echo "UPPER_BOUND=$N" >> "$CSV"
    break
  fi
done

echo "Sweep finished."
