# Baseline Results

Public assets are prepared, but no inference, indexing, or evaluation has been run yet. `PENDING` is used deliberately so preparation is not confused with a benchmark result.

| Dataset | Method | Split/Corpus | Checkpoint | Status | Metrics | Runtime | Notes |
|---|---|---|---|---|---|---|---|
| SciFact | MultiVerS | dev / cited docs | scifact | PASS | abstract label F1 1.0000; abstract rationalized F1 1.0000; sentence selection/label F1 0.9986 | 83.11 sec inference + 1.45 sec evaluation | Execution is reproducible, but score is not a clean generalization estimate; public checkpoint metadata says `combined_split` and exactly recovers all 209 dev gold document labels |
| SciFact | VeriSci | dev/open | official | PENDING | official pipeline output | - | Code present in SciFact repo; optional baseline |
| SciFact-Open | Official stored predictions | 279 claims | author-provided | PASS | P/R/F1/AP emitted for 5 models | 3.53 sec | Evaluator sanity passed in existing `base` via compatibility wrapper |
| SciFact-Open | BM25 | 500K corpus | N/A | PENDING | Recall@1/5/10/50/100 | - | Full corpus prepared; index not built |
| SciFact-Open | BM25 -> MultiVerS | top-K | scifact | OPTIONAL | document-level verification | - | Adapter not implemented |

## Phase 1 completion questions

These cannot be answered until the required evaluator, inference, and full-corpus retrieval runs are complete.

1. Can SciFact be evaluated locally with a strong public verifier without training? **Yes. MultiVerS inference and official evaluation pass; the published checkpoint's dev score is split-contaminated and should be used only as pipeline validation.**
2. Can SciFact-Open be evaluated on the full 500K corpus with a reproducible retrieval baseline? **Pending.**
3. Can retrieval output be transformed into a verifier/AKB-compatible interface with a thin adapter? **Pending.**
4. Which baseline should remain fixed when AKB is introduced? **Pending evidence.**
