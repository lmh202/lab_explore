# AKB Benchmark Baseline Validation - Phase 1

This directory is the thin orchestration workspace required by the Phase 1 task specification. Author repositories remain unchanged under `external/`; future adapters and evaluation wrappers belong in `scripts/`.

## Preparation status

Prepared on 2026-08-08:

- SciFact author repository and official dataset: ready.
- MultiVerS author repository, processed data, and public `scifact.ckpt`: ready.
- SciFact-Open author repository, official 500K corpus, 279 claims, author predictions, and retrievals: ready.
- Existing `base` environment: reused for the SciFact and SciFact-Open evaluators.
- MultiVerS environment: `akb-multivers` created because no existing environment exposed the required legacy Lightning APIs.
- SciFact-Open author-prediction evaluator sanity run: passed.
- SciFact dev MultiVerS inference and official evaluation: passed with reproducible outputs.
- BM25 indexing: not run yet.

See `env/environment_notes.md` for pinned commits, file counts, checksums, and environment requirements. See `RUNLOG.md` for exact preparation commands and `reports/blockers.md` for the resolved Windows line-ending issue.

## Layout

```text
external/   # pinned author repositories and downloaded assets
scripts/    # our future adapters, wrappers, and metric collection
outputs/    # predictions, rankings, evaluator output, and metrics
reports/    # result table and blockers
env/        # environment and provenance notes
```

## Next execution step

Build the SciFact-Open full-corpus BM25 index. The SciFact-Open evaluator can be repeated with:

```powershell
conda run -n base python scripts/run_scifact_open_eval.py --output outputs/scifact_open/official_eval/metrics.txt
```
