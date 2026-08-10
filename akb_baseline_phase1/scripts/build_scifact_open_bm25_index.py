"""Build a BM25 index over the full SciFact-Open 500K-document corpus.

Indexes title + abstract text with a standard Okapi BM25 formulation
(Lucene/Elasticsearch idf variant, which stays non-negative). Uses
scikit-learn's CountVectorizer for tokenization/term counting and a
scipy sparse term-document matrix, so the whole corpus fits comfortably
in memory without a hand-rolled inverted index.
"""

import argparse
import json
import pickle
import time
from pathlib import Path

import numpy as np
import scipy.sparse as sp
from sklearn.feature_extraction.text import CountVectorizer


def load_corpus(corpus_path):
    doc_ids = []
    texts = []
    with open(corpus_path, encoding="utf-8") as handle:
        for line in handle:
            record = json.loads(line)
            doc_ids.append(int(record["doc_id"]))
            abstract = " ".join(record.get("abstract", []))
            texts.append(f"{record.get('title', '')} {abstract}")
    return doc_ids, texts


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--corpus", type=Path, default=Path("external/scifact-open/data/corpus.jsonl")
    )
    parser.add_argument(
        "--output-dir", type=Path, default=Path("outputs/scifact_open/bm25/index")
    )
    parser.add_argument("--k1", type=float, default=1.5)
    parser.add_argument("--b", type=float, default=0.75)
    args = parser.parse_args()

    start = time.time()
    doc_ids, texts = load_corpus(args.corpus)
    n_docs = len(doc_ids)
    print(f"Loaded {n_docs} documents in {time.time() - start:.1f}s")

    vectorizer = CountVectorizer(
        lowercase=True,
        token_pattern=r"(?u)\b\w\w+\b",
        stop_words="english",
        dtype=np.int32,
    )
    tf_start = time.time()
    term_doc = vectorizer.fit_transform(texts)
    print(
        f"Vectorized {term_doc.shape[1]} terms, "
        f"{term_doc.nnz} nonzeros in {time.time() - tf_start:.1f}s"
    )

    doc_len = np.asarray(term_doc.sum(axis=1)).ravel().astype(np.float64)
    avgdl = float(doc_len.mean())

    term_doc_csc = term_doc.tocsc()
    df = np.diff(term_doc_csc.indptr).astype(np.float64)
    idf = np.log((n_docs - df + 0.5) / (df + 0.5) + 1.0)

    args.output_dir.mkdir(parents=True, exist_ok=True)
    sp.save_npz(args.output_dir / "term_doc_csc.npz", term_doc_csc)
    np.save(args.output_dir / "doc_ids.npy", np.array(doc_ids, dtype=np.int64))
    np.save(args.output_dir / "doc_len.npy", doc_len)
    np.save(args.output_dir / "idf.npy", idf)
    with open(args.output_dir / "vectorizer.pkl", "wb") as handle:
        pickle.dump(vectorizer, handle)

    elapsed = time.time() - start
    stats = {
        "n_docs": n_docs,
        "n_terms": int(term_doc.shape[1]),
        "nnz": int(term_doc.nnz),
        "avgdl": avgdl,
        "k1": args.k1,
        "b": args.b,
        "stop_words": "sklearn english list",
        "corpus_path": str(args.corpus),
        "build_seconds": elapsed,
    }
    with open(args.output_dir / "stats.json", "w", encoding="utf-8") as handle:
        json.dump(stats, handle, indent=2)

    print(f"Index built in {elapsed:.1f}s -> {args.output_dir}")
    print(json.dumps(stats, indent=2))


if __name__ == "__main__":
    main()
