"""Retrieve top-K BM25 documents for each SciFact-Open claim from the full
500K-document index built by build_scifact_open_bm25_index.py.

Scoring stays in dense numpy arrays sized to the corpus (a few MB) per
query so that per-term postings lookups vectorize instead of falling back
to a Python-level loop over potentially large postings lists.
"""

import argparse
import json
import pickle
import time
from pathlib import Path

import numpy as np
import scipy.sparse as sp


def load_index(index_dir):
    term_doc_csc = sp.load_npz(index_dir / "term_doc_csc.npz")
    doc_ids = np.load(index_dir / "doc_ids.npy")
    doc_len = np.load(index_dir / "doc_len.npy")
    idf = np.load(index_dir / "idf.npy")
    with open(index_dir / "vectorizer.pkl", "rb") as handle:
        vectorizer = pickle.load(handle)
    with open(index_dir / "stats.json", encoding="utf-8") as handle:
        stats = json.load(handle)
    return term_doc_csc, doc_ids, doc_len, idf, vectorizer, stats


def bm25_scores(query_text, term_doc_csc, doc_len, idf, vectorizer, k1, b, avgdl):
    n_docs = term_doc_csc.shape[0]
    analyzer = vectorizer.build_analyzer()
    vocabulary = vectorizer.vocabulary_
    terms = {t for t in analyzer(query_text) if t in vocabulary}

    scores = np.zeros(n_docs, dtype=np.float64)
    for term in terms:
        col = vocabulary[term]
        start, end = term_doc_csc.indptr[col], term_doc_csc.indptr[col + 1]
        if start == end:
            continue
        rows = term_doc_csc.indices[start:end]
        tf = term_doc_csc.data[start:end].astype(np.float64)
        denom = tf + k1 * (1.0 - b + b * doc_len[rows] / avgdl)
        contrib = idf[col] * (tf * (k1 + 1.0)) / denom
        scores[rows] += contrib

    return scores


def top_k_indices(scores, k):
    nonzero = np.nonzero(scores)[0]
    if nonzero.size == 0:
        return nonzero
    if nonzero.size > k:
        partitioned = np.argpartition(-scores[nonzero], k - 1)[:k]
        nonzero = nonzero[partitioned]
    order = np.argsort(-scores[nonzero])
    return nonzero[order]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--claims", type=Path, default=Path("external/scifact-open/data/claims.jsonl")
    )
    parser.add_argument(
        "--index-dir", type=Path, default=Path("outputs/scifact_open/bm25/index")
    )
    parser.add_argument(
        "--output", type=Path, default=Path("outputs/scifact_open/bm25/rankings.jsonl")
    )
    parser.add_argument("--top-k", type=int, default=100)
    args = parser.parse_args()

    start = time.time()
    term_doc_csc, doc_ids, doc_len, idf, vectorizer, stats = load_index(args.index_dir)
    avgdl, k1, b = stats["avgdl"], stats["k1"], stats["b"]
    print(f"Loaded index ({stats['n_docs']} docs, {stats['n_terms']} terms) in {time.time() - start:.1f}s")

    claims = [json.loads(line) for line in open(args.claims, encoding="utf-8")]

    args.output.parent.mkdir(parents=True, exist_ok=True)
    retrieve_start = time.time()
    empty_query_claims = 0
    with open(args.output, "w", encoding="utf-8") as out:
        for claim in claims:
            scores = bm25_scores(claim["claim"], term_doc_csc, doc_len, idf, vectorizer, k1, b, avgdl)
            top = top_k_indices(scores, args.top_k)
            if top.size == 0:
                empty_query_claims += 1
            retrieved = [
                {"doc_id": int(doc_ids[row]), "rank": rank + 1, "score": float(scores[row])}
                for rank, row in enumerate(top)
            ]
            out.write(json.dumps({"claim_id": claim["id"], "retrieved": retrieved}) + "\n")

    elapsed = time.time() - retrieve_start
    print(
        f"Retrieved top-{args.top_k} for {len(claims)} claims in {elapsed:.1f}s "
        f"({empty_query_claims} claims had zero matching terms) -> {args.output}"
    )


if __name__ == "__main__":
    main()
