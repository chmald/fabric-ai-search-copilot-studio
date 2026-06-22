# 05 — Testing

End-to-end test plan for the RAG knowledge-base pattern. Run these tests after [03-deployment-manual.md](./03-deployment-manual.md) (or [04-deployment-automated.md](./04-deployment-automated.md)) Phase 4 validation passes **and** the Copilot Studio agent in [03c-copilot-studio-setup.md](./03c-copilot-studio-setup.md) is built — the manual and automated Azure paths converge to the same end-state, and Fabric ([03b](./03b-fabric-setup.md)) + Copilot Studio ([03c](./03c-copilot-studio-setup.md)) layer on top identically for both.

> **Purpose.** Catch regressions early, prove retrieval quality before a demo, and provide a repeatable evaluation harness that travels with the pattern to new deployments.

---

## Test categories

| Category | Goal | Cadence |
|---|---|---|
| **A. Pipeline functional** | Ingest → OCR → chunk → index path works end-to-end with no errors | Every deployment; after every pipeline change |
| **B. Index quality smoke** | Index has correct shape, semantic ranker fires, citations are present | Every deployment |
| **C. Retrieval quality (golden set)** | Top-K retrieval recall + ranking on a known Q&A set | Before a demo; quarterly post-launch |
| **D. Semantic ranker A/B** | Quantify the lift from semantic ranker vs hybrid-only | Once per pattern instance |
| **E. End-to-end demo script** | The lived user experience in Teams / M365 Copilot | Day-of-demo dry run |
| **F. Regression** | Cumulative checks before any production change | After every change to chunking, index schema, or agent config |
| **G. Document-level security** | Chunk-level access trimming returns only documents the caller is authorized to see | After any change to `group_ids` population or the security model |

---

## A — Pipeline functional tests

### A1. New file ingestion

1. Drop **one new document** into the source (different from previous test docs)
2. Trigger the pipeline manually (or wait for the next scheduled run)
3. Expected outcomes:
   - Control table has a new row with `ocr_status=succeeded`, `chunk_status=succeeded`
   - Blob `raw/<file_id>/<original_filename>` exists
   - Blob `chunks/<file_id>/` contains N JSON files
   - Each JSON has valid `id`, `doc_id`, `chunk_id`, `content`, `source_uri`, `page_start`, `page_end`

### A2. Re-run idempotency

1. Trigger the pipeline a **second time** without changing any source files
2. Expected: zero new rows in the control table, zero new blob writes, zero indexer changes
3. If the pipeline re-processes files: the lookup-new-files activity has a bug (likely `file_id` hash isn't stable)

### A3. Update / replace document

1. Modify a source document (e.g. add a paragraph)
2. Re-upload to the source (same filename — modification timestamp will differ)
3. Trigger pipeline
4. Expected: **new** `file_id` (hash includes modified timestamp), new row in control table, new blob + chunks. **Old chunks remain** unless an explicit deletion / replacement strategy is added (a separate hardening task).

### A4. Failure recovery

1. Temporarily revoke a permission (e.g. AI Search managed identity → Blob)
2. Trigger pipeline
3. Expected: control table row updated with `index_status=failed` and `last_error` populated
4. Restore permission; re-run; row updates to `succeeded`

### A5. Chunking sanity

For one sample document:

1. Open the original
2. Open all chunk JSONs for that `doc_id`
3. Verify:
   - Concatenating `content` across chunks (de-duplicating the overlap) reproduces the original text approximately
   - No chunk exceeds the configured token budget
   - Overlap is present between consecutive chunks
   - Page numbers are monotonic and don't skip

---

## B — Index quality smoke tests

### B1. Index population

Query the index document count:

```http
GET https://srch-rag-demo-eus.search.windows.net/indexes/idx-rag-documents/docs/$count?api-version=2024-07-01
api-key: <admin key>
```

Expected: count = sum of `chunk_count` from control table.

### B2. Vector field populated

```json
POST .../indexes/idx-rag-documents/docs/search?api-version=2024-07-01
{
  "search": "*",
  "select": "id",
  "top": 1,
  "$count": true
}
```

Then pick one ID and fetch its document with all fields:

```http
GET .../indexes/idx-rag-documents/docs/<id>?api-version=2024-07-01&$select=id,content_vector
```

Expected: `content_vector` is a non-empty array with the right dimensionality (3072 for `text-embedding-3-large`, 1536 for `-3-small`).

### B3. Semantic ranker fires

Run a semantic query (sample in 03-deployment-manual.md § 4.5 or 04-deployment-automated.md § "Verify"). Verify in the response:

- Top results have `@search.rerankerScore` between 0 and 4 (range varies)
- `@search.captions[].text` and `@search.captions[].highlights` are populated
- `@search.answers` (if requested) returns extractive answers when the query is question-shaped

### B4. Citation linkback

Pick a result. Take its `source_uri`. Confirm the URI:

- Resolves to a file in Blob `raw/` container
- Can be opened by a user with the correct Blob role
- Or, if using SAS / pre-signed URLs: produces a working temporary URL

---

## C — Retrieval quality (golden set)

This is the most important test for production-readiness. Build a **golden Q&A set** specific to the deployment's domain.

### C1. Build the golden set

Have a subject-matter expert produce **20–50 Q&A pairs** covering:

- Direct factual questions (specific fact buried in a specific document)
- Semantic / paraphrased questions (answer requires understanding, not keyword match)
- Multi-document questions (synthesis across 2+ source documents)
- Negative cases (questions with no answer in the corpus — confirm the agent says so)

For each Q&A pair, record:

- The **question**
- The **expected answer** (free text)
- The **expected source doc(s)** the answer should cite (one or more `doc_id` values)
- The **expected chunk(s)** if the SME can be that specific (preferred; enables precise recall metrics)

Store as a CSV / JSON / Lakehouse Delta table. Example schema:

```
golden_qa
├── q_id          STRING   PK
├── question      STRING
├── expected_answer  STRING
├── expected_doc_ids  ARRAY<STRING>
├── expected_chunk_ids  ARRAY<STRING>   nullable
└── category      STRING   factual | semantic | multi-doc | negative
```

### C2. Run retrieval evaluation

A simple Python harness:

```python
from azure.search.documents import SearchClient
from azure.identity import DefaultAzureCredential

search = SearchClient(
    endpoint="https://srch-rag-demo-eus.search.windows.net",
    index_name="idx-rag-documents",
    credential=DefaultAzureCredential(),
)

def retrieve(q, k=5, semantic=True):
    return list(search.search(
        search_text=q,
        query_type="semantic" if semantic else "simple",
        semantic_configuration_name="semantic-default" if semantic else None,
        vector_queries=[{
            "kind": "text", "text": q, "fields": "content_vector", "k": 50
        }],
        select=["id","doc_id","chunk_id"],
        top=k,
        captions="extractive" if semantic else None,
    ))

def evaluate(golden_set):
    metrics = {"recall@5_doc": 0, "recall@5_chunk": 0, "mrr_doc": 0, "n": 0}
    for q in golden_set:
        results = retrieve(q["question"], k=5, semantic=True)
        result_doc_ids   = [r["doc_id"]   for r in results]
        result_chunk_ids = [r["id"]       for r in results]

        if set(q["expected_doc_ids"]) & set(result_doc_ids):
            metrics["recall@5_doc"] += 1
        if q.get("expected_chunk_ids"):
            if set(q["expected_chunk_ids"]) & set(result_chunk_ids):
                metrics["recall@5_chunk"] += 1

        rr = 0
        for rank, d in enumerate(result_doc_ids, start=1):
            if d in q["expected_doc_ids"]:
                rr = 1.0 / rank; break
        metrics["mrr_doc"] += rr

        metrics["n"] += 1

    return {
        "recall@5_doc":  metrics["recall@5_doc"]   / metrics["n"],
        "recall@5_chunk":metrics["recall@5_chunk"] / metrics["n"] if any(q.get("expected_chunk_ids") for q in golden_set) else None,
        "mrr_doc":       metrics["mrr_doc"]        / metrics["n"],
    }
```

### C3. Acceptance thresholds

These are **starting points**; tune per deployment:

| Metric | Target | Action if below |
|---|---|---|
| recall@5 (doc) | ≥ 0.85 | Investigate chunking strategy, embedding model, query rewriting |
| recall@5 (chunk) | ≥ 0.65 | Chunking too aggressive or too coarse; tune token budget |
| MRR (doc) | ≥ 0.65 | Semantic ranker not firing, or wrong content fields prioritized |

### C4. Failure analysis

For every Q&A pair the retrieval misses:

1. Print the actual top-5 results
2. Print the expected doc / chunk
3. Categorize the failure: chunking issue / embedding issue / ranker issue / corpus gap / question ambiguity
4. Track in a `golden_qa_failures` table for iteration

---

## D — Semantic ranker A/B

Quantify the lift from semantic ranker on **this specific deployment** so you can defend the cost / latency tradeoff with data.

### D1. Run hybrid-only baseline

Re-use the retrieval harness from C, with `semantic=False`. Capture `recall@5_doc` and `mrr_doc`.

### D2. Run hybrid + semantic ranker

Same harness with `semantic=True`. Capture the same metrics.

### D3. Compare

Expected (from Microsoft benchmarks):

| Metric | Hybrid-only | Hybrid + semantic ranker | Lift |
|---|---|---|---|
| recall@5 (doc) | ~0.75–0.85 | ~0.85–0.95 | +10–15 pp |
| MRR (doc) | ~0.45–0.55 | ~0.65–0.80 | +0.15–0.25 |

If your lift is **less than 5 pp**, investigate:

- Are your content fields properly prioritized in `semantic.configurations`?
- Are your queries question-shaped (semantic ranker is trained for that)?
- Is your `content` field rich enough for the ranker to work with (vs. very short snippets)?

### D4. Latency check

Time both query modes:

| Mode | Typical p95 latency |
|---|---|
| Hybrid-only | 50–150 ms |
| Hybrid + semantic | 350–700 ms |

If semantic ranker latency exceeds 1 s, raise an issue (likely a regional or capacity problem).

---

## E — End-to-end demo script

A demo script for a live presentation. Use this as the **dry run** the day before any live demo.

### E1. Setup

- Have the agent open in Teams (full-screen, share-friendly)
- Have one tab open with the source document corpus visible (to show grounding linkbacks)
- Have a backup plan if Teams misbehaves: switch to the Copilot Studio Test pane

### E2. Demo flow (~5 minutes)

| Step | Action | Demo point |
|---|---|---|
| 1 | Ask a **direct factual question** that has a clear single-chunk answer | Show citation + linkback opens the source |
| 2 | Ask a **paraphrased semantic question** | Prove retrieval isn't keyword matching |
| 3 | Ask a **multi-document question** | Show synthesis + multiple citations |
| 4 | Ask a **deliberately out-of-corpus question** | Show graceful fallback ("I don't have that") |
| 5 | (Optional) Show the **pipeline / indexer status** in the Fabric / Azure portal | Prove this is a productionizable pattern |

Keep each demo question rehearsed; do not improvise live without a dry run.

### E3. Backup answers

For the live demo, have **rehearsed answer text** ready for each question in case the agent returns something unexpected. Always be ready to gracefully acknowledge a miss and move on.

---

## F — Regression checklist

Before any production change (chunking, schema, agent config, model version):

- [ ] Re-run pipeline functional tests (A1–A5)
- [ ] Re-run index quality smoke tests (B1–B4)
- [ ] Re-run golden-set retrieval (C2) and compare metrics to last baseline
- [ ] Run a few demo-script questions (E2 sample)
- [ ] If any metric degrades by > 5 %: **roll back** and investigate before re-deploying

---

## Test harness layout (suggestion)

Treat the testing harness as a living artifact in the repo or in the Fabric workspace:

```
/tests
├── golden_qa.json           # the golden Q&A set
├── run_retrieval_eval.py    # the C harness
├── run_semantic_ab.py       # the D harness
├── pipeline_smoke.ipynb     # the A test notebook
├── index_smoke.http         # the B REST samples (VS Code REST Client format)
└── results/
    └── 2026-05-21-baseline.json   # historical baselines for regression comparison
```

---

## G — Document-level security tests

Validates **chunk-level access trimming** (the GA security-filter approach — see [01-architecture.md § Document-level access control](01-architecture.md#document-level-chunk-level-access-control)). Each chunk carries a `group_ids` field of Entra group object IDs; a query-time `$filter` returns only chunks the caller's groups are allowed to see. This is the **runnable "working example"** of per-chunk security against the AI Search API — independent of any Copilot Studio filter injection.

**Preconditions**
- Index has the `group_ids` field (`Collection(Edm.String)`, filterable) from [post_deploy_search.py](../scripts/post_deploy_search.py).
- At least two chunks indexed: one restricted to a group (e.g. `GROUP_HR = "11111111-1111-1111-1111-111111111111"`), one open (`group_ids: []`).
- Set `$SEARCH` to the service endpoint and acquire a bearer token (`az account get-access-token --resource https://search.azure.com`).

### G1. In-group caller sees the restricted chunk

```bash
# Caller IS a member of GROUP_HR → restricted chunk is returned.
TOKEN=$(az account get-access-token --resource https://search.azure.com --query accessToken -o tsv)
CALLER_GROUPS="11111111-1111-1111-1111-111111111111"   # caller's Entra group IDs (comma-separated)

curl -s -X POST "$SEARCH/indexes/documents-rag/docs/search?api-version=2024-07-01" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d "{
        \"search\": \"*\",
        \"filter\": \"group_ids/any(g: search.in(g, '$CALLER_GROUPS')) or group_ids/any() eq false\",
        \"select\": \"id,doc_id,group_ids\"
      }" | jq '.value[].id'
```

**Pass:** the restricted chunk's `id` appears in the results (plus any open chunks).

### G2. Out-of-group caller is trimmed

```bash
# Caller is NOT a member of GROUP_HR → restricted chunk is trimmed, open chunk still returned.
CALLER_GROUPS="99999999-9999-9999-9999-999999999999"   # unrelated group

curl -s -X POST "$SEARCH/indexes/documents-rag/docs/search?api-version=2024-07-01" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d "{
        \"search\": \"*\",
        \"filter\": \"group_ids/any(g: search.in(g, '$CALLER_GROUPS')) or group_ids/any() eq false\",
        \"select\": \"id,doc_id,group_ids\"
      }" | jq '.value[].id'
```

**Pass:** the restricted chunk's `id` is **absent**; the open chunk (`group_ids: []`) is still present.

> **Filter explained.** `group_ids/any(g: search.in(g, '<caller groups>'))` returns chunks sharing at least one group with the caller. `group_ids/any() eq false` admits **open** chunks (empty `group_ids` = visible to all). Drop the second clause if every chunk must be explicitly group-scoped (deny-by-default).

### G3. Empty-permission default behaves as intended

Confirm a chunk written with `group_ids: []` is treated as open (G1/G2 both return it). If your security model is deny-by-default, change the chunk pipeline to always populate `group_ids` and remove the `group_ids/any() eq false` clause; then re-run G1/G2 and confirm `[]` chunks are trimmed for everyone.

---

## When to re-run what

| Trigger | Tests to run |
|---|---|
| Initial deployment | A + B + C + D + E |
| New corpus uploaded | A + B + C |
| Chunking strategy change | A + B + C + D |
| Index schema change | B + C |
| Security model / `group_ids` change | G + B |
| Embedding model change | B + C + D |
| Agent prompt / config change | E |
| Quarterly health check | C + B |

---

*Last updated: 2026-05-21*
