# AKB Benchmark Baseline Validation - Phase 1

This directory is the thin orchestration workspace required by the Phase 1 task specification. Author repositories remain unchanged under `external/`; future adapters and evaluation wrappers belong in `scripts/`.

## Preparation status

Prepared on 2026-08-08; core Phase-1 evaluation completed on 2026-08-10:

- SciFact author repository and official dataset: ready.
- MultiVerS author repository, processed data, and public `scifact.ckpt`: ready.
- SciFact-Open author repository, official 500K corpus, 279 claims, author predictions, and retrievals: ready.
- Existing `base` environment: reused for the SciFact and SciFact-Open evaluators and for BM25 indexing/retrieval/evaluation.
- MultiVerS environment: `akb-multivers` created because no existing environment exposed the required legacy Lightning APIs.
- SciFact-Open author-prediction evaluator sanity run: passed.
- SciFact dev MultiVerS inference and official evaluation: passed with reproducible outputs (score is pipeline validation only; see `reports/blockers.md` for the split-contamination note).
- SciFact-Open full-corpus (500K) BM25 index, top-100 retrieval, and Recall@1/5/10/50/100 evaluation: passed.
- Optional BM25(top-10) -> MultiVerS end-to-end adapter and full 279-claim run: passed.
- VeriSci (optional): SKIP, documented in `reports/blockers.md`.

**Phase-1 is DONE**: SciFact-MultiVerS, SciFact-Open official-eval sanity, and SciFact-Open full-corpus retrieval all have reproducible outputs. See `reports/baseline_results.md` for the full results table and the Phase-1 completion-gate answers.

See `env/environment_notes.md` for pinned commits, file counts, checksums, and environment requirements. See `RUNLOG.md` for exact commands and `reports/blockers.md` for resolved issues and the VeriSci skip rationale.

## Layout

```text
external/   # pinned author repositories and downloaded assets
scripts/    # our adapters, wrappers, and metric collection
outputs/    # predictions, rankings, evaluator output, and metrics
reports/    # result table and blockers
env/        # environment and provenance notes
```

## Reproducing the results

```powershell
# SciFact-Open official evaluator sanity
conda run -n base python scripts/run_scifact_open_eval.py --output outputs/scifact_open/official_eval/metrics.txt

# SciFact-Open full-corpus BM25 retrieval baseline
conda run -n base python scripts/build_scifact_open_bm25_index.py
conda run -n base python scripts/retrieve_scifact_open_bm25.py
conda run -n base python scripts/evaluate_scifact_open_retrieval.py

# Optional: BM25 -> MultiVerS end-to-end (run from the akb-multivers env; see RUNLOG.md SFO-D1-D4 for exact paths)
conda run -n base python scripts/adapt_retrieval_to_multivers.py --output outputs/scifact_open/multivers_topk/input.jsonl --top-k 10
conda run -n base python scripts/evaluate_multivers_topk.py
```

## Suggested next phase (not started)

Per the task specification's section 9: replace the verifier/evidence-management stage with AKB output while keeping the same dataset and evaluator; only add a knowledge-management-oriented comparison once core metrics are stable; then test a structurally different benchmark (MetaSyn or SciQA-ORKG); ResearchClawBench stays deferred to an agent/harness integration experiment.
