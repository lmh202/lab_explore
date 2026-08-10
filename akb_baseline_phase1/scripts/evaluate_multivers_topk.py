"""Document-level P/R/F1 for the optional BM25 -> MultiVerS end-to-end run.

MultiVerS only sees the top-K BM25 doc_ids per claim (retrieval is the gate
between the 500K corpus and the verifier), so recall here is capped by how
many gold documents made it into that top-K pool - this is a distinct,
stricter number than the pure-retrieval Recall@K in
outputs/scifact_open/bm25/metrics.txt. The official evaluator
(run_eval.py) expects a parquet file with SUPPORT/CONTRADICT confidence
scores that this predict-only pipeline doesn't produce, so this script
computes label-match P/R/F1 directly from predicted vs. gold evidence,
the same definition run_eval.py's compute_f1_score uses.
"""

import argparse
import json
from pathlib import Path

LABEL_MAP = {"SUPPORT": "SUPPORT", "CONTRADICT": "CONTRADICT"}


def load_gold(claims_path):
    gold = {}
    for line in open(claims_path, encoding="utf-8"):
        claim = json.loads(line)
        gold[claim["id"]] = {
            int(doc_id): entry["label"] for doc_id, entry in claim["evidence"].items()
        }
    return gold


def load_predictions(predictions_path):
    preds = {}
    for line in open(predictions_path, encoding="utf-8"):
        record = json.loads(line)
        preds[record["id"]] = {
            int(doc_id): entry["label"] for doc_id, entry in record["evidence"].items()
        }
    return preds


def load_pool(input_path):
    pool = {}
    for line in open(input_path, encoding="utf-8"):
        record = json.loads(line)
        pool[record["id"]] = set(record["doc_ids"])
    return pool


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--claims", type=Path, default=Path("external/scifact-open/data/claims.jsonl")
    )
    parser.add_argument(
        "--input", type=Path, default=Path("outputs/scifact_open/multivers_topk/input.jsonl")
    )
    parser.add_argument(
        "--predictions",
        type=Path,
        default=Path("outputs/scifact_open/multivers_topk/predictions.jsonl"),
    )
    parser.add_argument(
        "--output", type=Path, default=Path("outputs/scifact_open/multivers_topk/metrics.txt")
    )
    args = parser.parse_args()

    gold = load_gold(args.claims)
    preds = load_predictions(args.predictions)
    pool = load_pool(args.input)

    n_gold_pairs = 0
    n_gold_pairs_in_pool = 0
    n_predicted_pairs = 0
    n_correct = 0

    for claim_id, gold_docs in gold.items():
        claim_pool = pool.get(claim_id, set())
        claim_preds = preds.get(claim_id, {})

        for doc_id, label in gold_docs.items():
            n_gold_pairs += 1
            if doc_id in claim_pool:
                n_gold_pairs_in_pool += 1
                if claim_preds.get(doc_id) == label:
                    n_correct += 1

        n_predicted_pairs += len(claim_preds)

    precision = n_correct / n_predicted_pairs if n_predicted_pairs else float("nan")
    recall_of_pool = n_correct / n_gold_pairs_in_pool if n_gold_pairs_in_pool else float("nan")
    recall_of_all_gold = n_correct / n_gold_pairs if n_gold_pairs else float("nan")
    f1 = (
        2 * precision * recall_of_all_gold / (precision + recall_of_all_gold)
        if (precision + recall_of_all_gold) > 0
        else float("nan")
    )

    lines = [
        "SciFact-Open BM25(top-K) -> MultiVerS document-level verification (OPTIONAL, SFO-D)",
        f"Claims scored: {len(gold)}; claim-document pairs predicted (non-NEI): {n_predicted_pairs}",
        f"Gold claim-document pairs: {n_gold_pairs}; of those, present in the retrieved top-K pool: {n_gold_pairs_in_pool}",
        f"Correct label matches: {n_correct}",
        "",
        f"Precision (of predicted pairs): {precision:.4f}",
        f"Recall (of gold pairs that made it into top-K): {recall_of_pool:.4f}",
        f"Recall (of ALL gold pairs, retrieval-capped): {recall_of_all_gold:.4f}",
        f"F1 (retrieval-capped recall): {f1:.4f}",
        "",
        "Recall-of-ALL-gold is capped by BM25 top-K retrieval quality (see "
        "outputs/scifact_open/bm25/metrics.txt for pure retrieval Recall@K); "
        "Recall-of-pool isolates the verifier's own accuracy given perfect retrieval.",
    ]

    report = "\n".join(lines)
    print(report)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(report + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
