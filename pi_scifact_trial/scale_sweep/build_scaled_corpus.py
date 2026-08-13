"""Build nested per-claim corpus subsets at increasing sizes.

For each claim, corpus_<claim>_<size>.jsonl always contains the claim's gold
evidence doc(s) + its BM25 top-10 candidates, padded with random distractors
(fixed seed, shared shuffle order across claims) up to <size> docs. Corpora
are nested: corpus_<claim>_1500 is corpus_<claim>_500 plus 1000 more
distractors, etc. Also writes task_<claim>_<size>.md per (claim, size) pair
for use as a pi @file attachment.
"""
import json
import random
from pathlib import Path

AKB = Path("d:/Downloads/Content/NUS/lab/akb_baseline_phase1")
OUT = Path("d:/Downloads/Content/NUS/lab/pi_scifact_trial/scale_sweep")
OUT.mkdir(parents=True, exist_ok=True)

CLAIM_IDS = [206, 546, 920]
SIZES = [500, 1500, 5000, 15000, 50000, 150000, 500000]
SEED = 42

claims = {}
with open(AKB / "external/scifact-open/data/claims.jsonl", encoding="utf-8") as f:
    for line in f:
        c = json.loads(line)
        if c["id"] in CLAIM_IDS:
            claims[c["id"]] = c

rankings = {}
with open(AKB / "outputs/scifact_open/bm25/rankings.jsonl", encoding="utf-8") as f:
    for line in f:
        r = json.loads(line)
        if r["claim_id"] in CLAIM_IDS:
            rankings[r["claim_id"]] = [item["doc_id"] for item in r["retrieved"][:10]]

must_include = {}
for cid in CLAIM_IDS:
    gold = {int(k) for k in claims[cid]["evidence"].keys()}
    must_include[cid] = gold | set(rankings[cid])
    print(f"claim {cid}: gold={gold} must_include_size={len(must_include[cid])}")

print("Reading full corpus (this is ~850MB, may take a bit)...")
with open(AKB / "external/scifact-open/data/corpus.jsonl", encoding="utf-8") as f:
    all_lines = f.readlines()
print(f"Loaded {len(all_lines)} corpus lines.")

by_id = {}
for line in all_lines:
    d = json.loads(line)
    by_id[d["doc_id"]] = line

rng = random.Random(SEED)
shuffled = all_lines[:]
rng.shuffle(shuffled)
print("Shuffled corpus for distractor sampling (shared order across claims).")

for cid in CLAIM_IDS:
    selected = []
    seen = set()
    for doc_id in must_include[cid]:
        if doc_id in by_id and doc_id not in seen:
            selected.append(by_id[doc_id])
            seen.add(doc_id)

    next_idx = 0
    for size in SIZES:
        while len(selected) < size and next_idx < len(shuffled):
            line = shuffled[next_idx]
            next_idx += 1
            d_id = json.loads(line)["doc_id"]
            if d_id not in seen:
                selected.append(line)
                seen.add(d_id)

        snapshot = selected[:size]
        snap_rng = random.Random(SEED + size)
        snap_rng.shuffle(snapshot)  # don't let position leak which docs are "special"

        corpus_path = OUT / f"corpus_{cid}_{size}.jsonl"
        corpus_path.write_text("".join(snapshot), encoding="utf-8")

        task_path = OUT / f"task_{cid}_{size}.md"
        task_path.write_text(
            f"""You are in a working directory containing corpus_{cid}_{size}.jsonl, a JSONL file with {size} scientific paper records (fields: doc_id, title, abstract as a list of sentences). This is a large read-only reference dataset -- do not modify, sort, rewrite, or delete it; only read/search it.

Use your tools to search this file for evidence relevant to the claim below, then decide whether the claim is SUPPORTed, CONTRADICTed, or NEI (not enough evidence in this corpus).

Claim: {claims[cid]['claim']}

When done, output your final answer as exactly one line of JSON at the very end of your response, on its own line, using this exact shape:

{{"label": "SUPPORT", "doc_id": 123, "evidence": "the exact sentence text"}}

label must be SUPPORT, CONTRADICT, or NEI. doc_id is the decisive document id, or null. evidence is the exact sentence text that justifies the label, or an empty string if NEI.
""",
            encoding="utf-8",
        )
        print(f"claim {cid} size {size}: wrote {len(snapshot)} docs")

print("Done.")
