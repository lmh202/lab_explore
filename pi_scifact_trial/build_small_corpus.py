import json
import random
from pathlib import Path

AKB = Path("d:/Downloads/Content/NUS/lab/akb_baseline_phase1")
OUT = Path("d:/Downloads/Content/NUS/lab/pi_scifact_trial")

CLAIM_ID = 1122  # start with just one claim
SUBSET_SIZE = 500

claims = {}
for line in open(AKB / "external/scifact-open/data/claims.jsonl", encoding="utf-8"):
    c = json.loads(line)
    if c["id"] == CLAIM_ID:
        claims[c["id"]] = c
claim = claims[CLAIM_ID]
gold_doc_ids = {int(k) for k in claim["evidence"].keys()}

rankings = {}
for line in open(AKB / "outputs/scifact_open/bm25/rankings.jsonl", encoding="utf-8"):
    r = json.loads(line)
    if r["claim_id"] == CLAIM_ID:
        rankings[CLAIM_ID] = [item["doc_id"] for item in r["retrieved"][:10]]

must_include = gold_doc_ids | set(rankings[CLAIM_ID])

rng = random.Random(42)
selected = []
seen = set()
with open(AKB / "external/scifact-open/data/corpus.jsonl", encoding="utf-8") as f:
    all_lines = f.readlines()

# First pass: grab the must-include docs.
by_id = {}
for line in all_lines:
    d = json.loads(line)
    if d["doc_id"] in must_include:
        by_id[d["doc_id"]] = line

for doc_id in must_include:
    if doc_id in by_id and doc_id not in seen:
        selected.append(by_id[doc_id])
        seen.add(doc_id)

# Fill the rest with a random sample of other docs (distractors).
rng.shuffle(all_lines)
for line in all_lines:
    if len(selected) >= SUBSET_SIZE:
        break
    d = json.loads(line)
    if d["doc_id"] not in seen:
        selected.append(line)
        seen.add(d["doc_id"])

rng.shuffle(selected)  # don't let position leak which docs are "special"

(OUT / "corpus_500.jsonl").write_text("".join(selected), encoding="utf-8")
(OUT / "task_1122.md").write_text(
    f"**Claim to verify:** {claim['claim']}\n", encoding="utf-8"
)
print(f"Wrote {len(selected)} docs to corpus_500.jsonl")
print(f"Gold doc_ids for claim {CLAIM_ID}: {gold_doc_ids} (label(s): "
      f"{[e['label'] for e in claim['evidence'].values()]})")
print(f"must_include size: {len(must_include)}")
