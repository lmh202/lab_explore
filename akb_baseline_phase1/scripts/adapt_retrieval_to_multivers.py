"""Convert SciFact-Open BM25 rankings into MultiVerS's claim input schema.

MultiVerS (external/multivers/multivers/data.py, MultiVerSReader) reads a
claims file with {"id", "claim", "doc_ids"} and a corpus file with
{"doc_id", "title", "abstract"}. SciFact-Open's corpus.jsonl already uses
that exact corpus schema, so only the claims side needs adapting: take the
top-K BM25 doc_ids per claim (retrieval is the gate between the 500K
corpus and the verifier) and pair them with the claim text.
"""

import argparse
import json
from pathlib import Path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--claims", type=Path, default=Path("external/scifact-open/data/claims.jsonl")
    )
    parser.add_argument(
        "--rankings", type=Path, default=Path("outputs/scifact_open/bm25/rankings.jsonl")
    )
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--top-k", type=int, default=10)
    parser.add_argument(
        "--claim-ids",
        type=int,
        nargs="*",
        default=None,
        help="Optional subset of claim IDs (for smoke runs).",
    )
    args = parser.parse_args()

    claims = {c["id"]: c for c in (json.loads(l) for l in open(args.claims, encoding="utf-8"))}
    rankings = {}
    for line in open(args.rankings, encoding="utf-8"):
        record = json.loads(line)
        rankings[record["claim_id"]] = [item["doc_id"] for item in record["retrieved"]]

    claim_ids = args.claim_ids if args.claim_ids else list(claims.keys())

    args.output.parent.mkdir(parents=True, exist_ok=True)
    written = 0
    with open(args.output, "w", encoding="utf-8") as out:
        for claim_id in claim_ids:
            doc_ids = rankings.get(claim_id, [])[: args.top_k]
            if not doc_ids:
                continue
            out.write(
                json.dumps(
                    {
                        "id": claim_id,
                        "claim": claims[claim_id]["claim"],
                        "doc_ids": doc_ids,
                        "evidence": {},
                    }
                )
                + "\n"
            )
            written += 1

    print(f"Wrote {written} MultiVerS-format claims (top-{args.top_k}) -> {args.output}")


if __name__ == "__main__":
    main()
