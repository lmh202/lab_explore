"""Evaluate the SciFact-Open BM25 retrieval baseline against gold evidence
document IDs and run the SFO-C6 sanity sample.

The official evaluator (external/scifact-open/script/run_eval.py) scores
verification predictions (label + confidence), not raw retrieval, so it
cannot compute Recall@K. Recall@K here is derived directly and
unambiguously from each claim's gold evidence document IDs in
data/claims.jsonl: for claim c with gold documents G(c) and a ranked list
retrieved(c), Recall@K(c) = |G(c) intersect retrieved(c)[:K]| / |G(c)|,
averaged over claims that have at least one gold evidence document.
Claims with no evidence (NEI, no cited/pooled document) are excluded from
the average since they have nothing to recall.
"""

import argparse
import json
import random
from pathlib import Path

import numpy as np


def load_gold(claims_path):
    gold = {}
    for line in open(claims_path, encoding="utf-8"):
        claim = json.loads(line)
        gold[claim["id"]] = {int(doc_id) for doc_id in claim["evidence"].keys()}
    return gold


def load_rankings(rankings_path):
    rankings = {}
    for line in open(rankings_path, encoding="utf-8"):
        record = json.loads(line)
        rankings[record["claim_id"]] = [item["doc_id"] for item in record["retrieved"]]
    return rankings


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--claims", type=Path, default=Path("external/scifact-open/data/claims.jsonl")
    )
    parser.add_argument(
        "--rankings", type=Path, default=Path("outputs/scifact_open/bm25/rankings.jsonl")
    )
    parser.add_argument(
        "--index-dir", type=Path, default=Path("outputs/scifact_open/bm25/index")
    )
    parser.add_argument(
        "--output", type=Path, default=Path("outputs/scifact_open/bm25/metrics.txt")
    )
    parser.add_argument("--ks", type=int, nargs="+", default=[1, 5, 10, 50, 100])
    parser.add_argument("--sanity-seed", type=int, default=42)
    parser.add_argument("--sanity-n", type=int, default=5)
    args = parser.parse_args()

    gold = load_gold(args.claims)
    rankings = load_rankings(args.rankings)
    evaluable = {cid: docs for cid, docs in gold.items() if docs}

    lines = []
    lines.append("SciFact-Open BM25 retrieval evaluation (full 500K corpus)")
    lines.append(f"Claims total: {len(gold)}")
    lines.append(f"Claims with gold evidence (used for Recall@K): {len(evaluable)}")
    lines.append(f"Claims with no evidence (NEI, excluded): {len(gold) - len(evaluable)}")
    lines.append("")

    for k in args.ks:
        recalls = []
        for cid, gold_docs in evaluable.items():
            retrieved_k = set(rankings.get(cid, [])[:k])
            recalls.append(len(gold_docs & retrieved_k) / len(gold_docs))
        recall_at_k = sum(recalls) / len(recalls) if recalls else float("nan")
        lines.append(f"Recall@{k}: {recall_at_k:.4f}")

    doc_ids_in_corpus = set(np.load(args.index_dir / "doc_ids.npy").tolist())
    rng = random.Random(args.sanity_seed)
    sample_ids = rng.sample(sorted(evaluable.keys()), min(args.sanity_n, len(evaluable)))

    lines.append("")
    lines.append(
        f"SFO-C6 sanity sample ({len(sample_ids)} random claims with gold evidence, "
        f"seed={args.sanity_seed}):"
    )
    for cid in sample_ids:
        retrieved = rankings.get(cid, [])
        retrieved_valid = all(doc_id in doc_ids_in_corpus for doc_id in retrieved)
        gold_valid = all(doc_id in doc_ids_in_corpus for doc_id in gold[cid])
        found_in_topk = len(gold[cid] & set(retrieved))
        lines.append(
            f"  claim_id={cid}: retrieved_doc_ids_in_corpus={retrieved_valid}, "
            f"gold_doc_ids_in_corpus={gold_valid}, gold_docs={len(gold[cid])}, "
            f"gold_found_in_top{len(retrieved)}={found_in_topk}"
        )

    report = "\n".join(lines)
    print(report)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(report + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
