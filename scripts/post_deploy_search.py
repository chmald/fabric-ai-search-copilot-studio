"""
post_deploy_search.py — Configure Azure AI Search after the Bicep deployment.

Bicep provisions the Search SERVICE; this script creates the index / data source / indexer.
The Search index types in ARM/Bicep do not cleanly express integrated vectorizer config +
semantic configuration + indexer field mappings, so we use the REST control plane instead.

Auth model
==========
Admin keys are DISABLED on the AI Search service (`disableLocalAuth: true` in Bicep).
This script authenticates with an Entra ID bearer token via `DefaultAzureCredential`.

The caller identity must have these roles on the AI Search service (assigned
automatically when `deployerPrincipalId` is set on the Bicep deployment):

  * Search Service Contributor    — create/update index, datasource, indexer
  * Search Index Data Contributor — read $count, run sample queries, see indexer status

When running locally, `DefaultAzureCredential` resolves to your `az login` user.
In CI/CD, it resolves to the pipeline's federated workload identity / service principal.

What this script does
=====================
1. Reads deployment outputs from --ids (default: demo-ids.local.json)
2. Creates (or updates) the search index `idx-rag-documents`:
     - text + vector + metadata fields (per docs/01-architecture.md schema)
     - integrated `azureOpenAI` vectorizer pointed at the Foundry embedding deployment
       (this vectorizer handles QUERY-time text→vector conversion when Copilot Studio
        sends a text query — it does NOT generate vectors at index time)
     - semantic configuration `semantic-default`
3. Creates (or updates) the data source `ds-chunks` using a managed-identity ResourceId
   connection string to the storage account's `chunks/` container
4. Creates (or updates) the skillset `skill-rag-embeddings` with an
   `AzureOpenAIEmbeddingSkill` that generates the per-chunk embedding at INDEX time.
   Without this skill, the indexer commits documents with a null `content_vector`,
   the index reports `vectorIndexSize: 0`, and Copilot Studio vector queries return
   nothing. See docs/06-troubleshooting.md § 4.1.
5. Creates (or updates) the indexer `ixr-chunks` with a 5-minute schedule, the
   skillset attached, and an `outputFieldMapping` that writes the skill's embedding
   output to the index's `content_vector` field
6. Optionally runs the indexer manually (--run-indexer)
7. In --verify mode: hits the index $count + a semantic test query + indexer status
   + service stats (confirms vectorIndexSize > 0 when documents > 0)

The script is idempotent — safe to re-run if a previous run failed partway.

Usage
=====
    python post_deploy_search.py --ids demo-ids.local.json
    python post_deploy_search.py --ids demo-ids.local.json --verify
    python post_deploy_search.py --ids demo-ids.local.json --run-indexer
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path
from typing import Any

import requests
from azure.core.credentials import AccessToken
from azure.identity import DefaultAzureCredential

SEARCH_API_VERSION = "2024-07-01"
SEARCH_AAD_SCOPE = "https://search.azure.com/.default"


# ---------- helpers ----------------------------------------------------------------


def load_ids(path: Path) -> dict[str, Any]:
    if not path.exists():
        sys.exit(f"[FATAL] IDs file not found: {path}\n"
                 f"Run `pwsh ./infra/deploy.ps1` first (or set --ids to your file path).")
    return json.loads(path.read_text(encoding="utf-8"))


class SearchTokenProvider:
    """Lazy + cached bearer token for the AI Search data plane.

    Tokens are valid for ~1 hour; we refresh ~5 min before expiry.
    """

    def __init__(self, credential: DefaultAzureCredential) -> None:
        self._credential = credential
        self._token: AccessToken | None = None

    def auth_header(self) -> dict[str, str]:
        now = time.time()
        if self._token is None or self._token.expires_on - now < 300:
            self._token = self._credential.get_token(SEARCH_AAD_SCOPE)
        return {"Authorization": f"Bearer {self._token.token}"}


def _check_response(method: str, url: str, r: requests.Response) -> None:
    if r.status_code in (200, 201, 202, 204):
        return
    if r.status_code in (401, 403):
        hint = (
            "\n[HINT] Auth failed. Confirm the caller has BOTH 'Search Service Contributor'\n"
            "       and 'Search Index Data Contributor' on the AI Search service.\n"
            "       The Bicep deployment grants these when -deployerPrincipalId is set.\n"
            "       Manual grant:\n"
            "         az role assignment create --assignee <your-object-id> \\\n"
            "           --role 'Search Service Contributor' --scope <search-resource-id>\n"
            "         az role assignment create --assignee <your-object-id> \\\n"
            "           --role 'Search Index Data Contributor' --scope <search-resource-id>"
        )
    else:
        hint = ""
    print(f"[FAIL] {method} {url}\n  status {r.status_code}\n  body  {r.text}{hint}")
    r.raise_for_status()


def search_put(search_endpoint: str, tokens: SearchTokenProvider, resource_kind: str,
               name: str, body: dict[str, Any]) -> None:
    url = f"{search_endpoint}/{resource_kind}/{name}?api-version={SEARCH_API_VERSION}"
    headers = {**tokens.auth_header(), "Content-Type": "application/json"}
    r = requests.put(url, headers=headers, data=json.dumps(body), timeout=60)
    _check_response("PUT", url, r)


def search_get(search_endpoint: str, tokens: SearchTokenProvider, path: str) -> dict[str, Any]:
    url = f"{search_endpoint}/{path}{'&' if '?' in path else '?'}api-version={SEARCH_API_VERSION}"
    r = requests.get(url, headers=tokens.auth_header(), timeout=30)
    _check_response("GET", url, r)
    return r.json() if r.text else {}


def search_post(search_endpoint: str, tokens: SearchTokenProvider, path: str,
                body: dict[str, Any]) -> dict[str, Any]:
    url = f"{search_endpoint}/{path}{'&' if '?' in path else '?'}api-version={SEARCH_API_VERSION}"
    headers = {**tokens.auth_header(), "Content-Type": "application/json"}
    r = requests.post(url, headers=headers, data=json.dumps(body), timeout=60)
    _check_response("POST", url, r)
    return r.json() if r.text else {}


# ---------- index / datasource / indexer payloads ----------------------------------


def index_payload(ids: dict[str, Any]) -> dict[str, Any]:
    return {
        "name": ids["searchIndexName"],
        "fields": [
            {"name": "id",            "type": "Edm.String", "key": True, "filterable": True},
            {"name": "doc_id",        "type": "Edm.String", "filterable": True, "facetable": True, "retrievable": True},
            {"name": "chunk_id",      "type": "Edm.Int32",  "retrievable": True},
            {"name": "content",       "type": "Edm.String", "searchable": True, "analyzer": "en.microsoft", "retrievable": True},
            {"name": "content_vector","type": "Collection(Edm.Single)", "searchable": True, "retrievable": False,
             "dimensions": 3072 if "large" in ids.get("embeddingModel", "").lower() else 1536,
             "vectorSearchProfile": "default-vector-profile"},
            {"name": "doc_type",      "type": "Edm.String", "filterable": True, "facetable": True, "retrievable": True},
            {"name": "source_uri",    "type": "Edm.String", "retrievable": True},
            {"name": "page_start",    "type": "Edm.Int32",  "retrievable": True},
            {"name": "page_end",      "type": "Edm.Int32",  "retrievable": True},
            {"name": "ingest_ts",     "type": "Edm.DateTimeOffset", "filterable": True, "sortable": True, "retrievable": True},
            {"name": "group_ids",     "type": "Collection(Edm.String)", "filterable": True, "retrievable": True},
            {"name": "metadata",      "type": "Edm.String", "retrievable": True},
        ],
        "vectorSearch": {
            "algorithms": [
                {"name": "hnsw-default", "kind": "hnsw",
                 "hnswParameters": {"m": 4, "efConstruction": 400, "efSearch": 500, "metric": "cosine"}}
            ],
            "vectorizers": [
                {
                    "name": "aif-vectorizer",
                    "kind": "azureOpenAI",
                    "azureOpenAIParameters": {
                        "resourceUri": ids["foundryOpenAIEndpoint"],
                        "deploymentId": ids["embeddingDeployment"],
                        "modelName": ids["embeddingModel"],
                        # authIdentity=null => use the search service's system-assigned MI
                        "authIdentity": None,
                    },
                }
            ],
            "profiles": [
                {"name": "default-vector-profile", "algorithm": "hnsw-default", "vectorizer": "aif-vectorizer"}
            ],
        },
        "semantic": {
            "defaultConfiguration": "semantic-default",
            "configurations": [
                {
                    "name": "semantic-default",
                    "prioritizedFields": {
                        "titleField": {"fieldName": "doc_id"},
                        "prioritizedContentFields": [{"fieldName": "content"}],
                        "prioritizedKeywordsFields": [{"fieldName": "doc_type"}],
                    },
                }
            ],
        },
    }


def datasource_payload(ids: dict[str, Any]) -> dict[str, Any]:
    storage_resource_id = (
        f"/subscriptions/{ids.get('subscriptionId', '<sub>')}"
        f"/resourceGroups/{ids['resourceGroup']}"
        f"/providers/Microsoft.Storage/storageAccounts/{ids['storageAccount']}"
    )
    return {
        "name": ids["searchDataSourceName"],
        "type": "azureblob",
        "credentials": {
            "connectionString": f"ResourceId={storage_resource_id};"
        },
        "container": {"name": ids["chunksContainer"]},
    }


def skillset_name(ids: dict[str, Any]) -> str:
    """Skillset name — honors `searchSkillsetName` in ids file, else default."""
    return ids.get("searchSkillsetName", "skill-rag-embeddings")


def skillset_payload(ids: dict[str, Any]) -> dict[str, Any]:
    """Skillset with a single AzureOpenAIEmbeddingSkill.

    The skill runs at INDEX time and writes the embedding to /document/content_vector_embedding.
    The indexer's outputFieldMappings (see `indexer_payload`) wire that to the index's
    `content_vector` field.

    Auth: the skill calls the Foundry OpenAI endpoint using the search service's
    system-assigned managed identity (authIdentity=None). The MI must have
    'Cognitive Services OpenAI User' on the Foundry resource — NOT the similarly
    named 'Cognitive Services User' role, which doesn't grant OpenAI data-plane
    access. See docs/06-troubleshooting.md § 4.1.
    """
    is_large = "large" in ids.get("embeddingModel", "").lower()
    return {
        "name": skillset_name(ids),
        "description": (
            "Generate vector embeddings for chunk content via the Foundry embedding "
            "deployment. Required for index-time vectorization — the vectorizer on the "
            "index handles QUERY-time only."
        ),
        "skills": [
            {
                "@odata.type": "#Microsoft.Skills.Text.AzureOpenAIEmbeddingSkill",
                "name": "embed-content",
                "description": "Vectorize the chunk text",
                "context": "/document",
                "resourceUri": ids["foundryOpenAIEndpoint"],
                "deploymentId": ids["embeddingDeployment"],
                "modelName": ids["embeddingModel"],
                "dimensions": 3072 if is_large else 1536,
                "inputs": [{"name": "text", "source": "/document/content"}],
                "outputs": [{"name": "embedding", "targetName": "content_vector_embedding"}],
                # authIdentity=None => use search service's system-assigned MI
                "authIdentity": None,
            }
        ],
    }


def indexer_payload(ids: dict[str, Any]) -> dict[str, Any]:
    return {
        "name": ids["searchIndexerName"],
        "dataSourceName": ids["searchDataSourceName"],
        "targetIndexName": ids["searchIndexName"],
        "skillsetName": skillset_name(ids),
        "parameters": {"configuration": {"parsingMode": "json"}},
        "fieldMappings": [
            {"sourceFieldName": "id",         "targetFieldName": "id"},
            {"sourceFieldName": "doc_id",     "targetFieldName": "doc_id"},
            {"sourceFieldName": "chunk_id",   "targetFieldName": "chunk_id"},
            {"sourceFieldName": "content",    "targetFieldName": "content"},
            {"sourceFieldName": "doc_type",   "targetFieldName": "doc_type"},
            {"sourceFieldName": "source_uri", "targetFieldName": "source_uri"},
            {"sourceFieldName": "page_start", "targetFieldName": "page_start"},
            {"sourceFieldName": "page_end",   "targetFieldName": "page_end"},
            {"sourceFieldName": "ingest_ts",  "targetFieldName": "ingest_ts"},
            {"sourceFieldName": "metadata",   "targetFieldName": "metadata"},
        ],
        # Wires the skillset's embedding output into the index's content_vector field.
        "outputFieldMappings": [
            {
                "sourceFieldName": "/document/content_vector_embedding",
                "targetFieldName": "content_vector",
            }
        ],
        "schedule": {"interval": "PT5M"},
    }


# ---------- orchestration ---------------------------------------------------------


def configure(ids: dict[str, Any], tokens: SearchTokenProvider) -> None:
    endpoint = ids["searchEndpoint"]

    print(f"[..] Creating/updating index: {ids['searchIndexName']}")
    search_put(endpoint, tokens, "indexes", ids["searchIndexName"], index_payload(ids))
    print(f"[OK] Index '{ids['searchIndexName']}' created (or updated).")

    print(f"[..] Creating/updating data source: {ids['searchDataSourceName']}")
    search_put(endpoint, tokens, "datasources", ids["searchDataSourceName"], datasource_payload(ids))
    print(f"[OK] Data source '{ids['searchDataSourceName']}' created "
          f"(managed-identity connection to {ids['storageAccount']}/{ids['chunksContainer']}).")

    sk_name = skillset_name(ids)
    print(f"[..] Creating/updating skillset: {sk_name}")
    search_put(endpoint, tokens, "skillsets", sk_name, skillset_payload(ids))
    print(f"[OK] Skillset '{sk_name}' created (AzureOpenAIEmbeddingSkill → content_vector).")

    print(f"[..] Creating/updating indexer: {ids['searchIndexerName']}")
    search_put(endpoint, tokens, "indexers", ids["searchIndexerName"], indexer_payload(ids))
    print(f"[OK] Indexer '{ids['searchIndexerName']}' created "
          f"(schedule: PT5M, skillset: {sk_name}).")


def run_indexer(ids: dict[str, Any], tokens: SearchTokenProvider) -> None:
    endpoint = ids["searchEndpoint"]
    print(f"[..] Triggering manual indexer run: {ids['searchIndexerName']}")
    url = f"{endpoint}/indexers/{ids['searchIndexerName']}/run?api-version={SEARCH_API_VERSION}"
    r = requests.post(url, headers=tokens.auth_header(), timeout=30)
    if r.status_code in (202, 204):
        print("[OK] Indexer run triggered. Status will be visible in the portal in ~30s.")
    else:
        print(f"[WARN] Indexer run returned {r.status_code}: {r.text}")


def verify(ids: dict[str, Any], tokens: SearchTokenProvider) -> int:
    endpoint = ids["searchEndpoint"]
    errors = 0

    # 1. Index exists + doc count
    try:
        count = search_get(endpoint, tokens, f"indexes/{ids['searchIndexName']}/docs/$count?")
        if isinstance(count, dict):
            count_val = count.get("@odata.count", count.get("value", "?"))
        else:
            count_val = count
        print(f"[OK] Index exists. Document count: {count_val}  "
              f"(will populate after Fabric pipeline writes chunks to {ids['chunksContainer']})")
    except Exception as e:
        print(f"[FAIL] Index check: {e}")
        errors += 1

    # 2. Sample semantic query
    try:
        body = {
            "search": "test query",
            "queryType": "semantic",
            "semanticConfiguration": "semantic-default",
            "vectorQueries": [{"kind": "text", "text": "test query", "fields": "content_vector", "k": 5}],
            "select": "id,doc_id",
            "top": 3,
            "captions": "extractive",
        }
        result = search_post(endpoint, tokens, f"indexes/{ids['searchIndexName']}/docs/search?", body)
        n = len(result.get("value", []))
        if n == 0:
            print(f"[OK] Sample query succeeded (0 results — expected on empty index).")
        else:
            top = result["value"][0]
            score = top.get("@search.rerankerScore")
            if score is not None:
                print(f"[OK] Sample query succeeded. {n} result(s); semantic ranker score: {score:.2f}")
            else:
                print(f"[WARN] Sample query returned {n} result(s) but no rerankerScore — "
                      f"check semantic ranker is enabled on the service (Standard S1+ required).")
                errors += 1
    except Exception as e:
        print(f"[FAIL] Sample query: {e}")
        errors += 1

    # 3. Indexer status
    try:
        status = search_get(endpoint, tokens, f"indexers/{ids['searchIndexerName']}/status?")
        last = status.get("lastResult", {})
        s = last.get("status", "?")
        if s in ("success", "transientFailure"):
            print(f"[OK] Indexer '{ids['searchIndexerName']}' last status: {s}  "
                  f"(transientFailure is normal on first run with empty container)")
        else:
            print(f"[WARN] Indexer status: {s}  errors: {last.get('errors', [])}")
            errors += 1
    except Exception as e:
        print(f"[FAIL] Indexer status check: {e}")
        errors += 1

    # 4. Service stats — confirm vectorIndexSize > 0 whenever documentCount > 0.
    # Catches the "silent vectorizer failure" mode where the indexer reports success
    # but vectors aren't actually being generated (missing skillset, missing role,
    # role-name confusion). See docs/06-troubleshooting.md § 4.1.
    try:
        stats = search_get(endpoint, tokens, "servicestats?")
        counters = stats.get("counters", {})
        doc_count = counters.get("documentCount", {}).get("usage", 0)
        vec_size = counters.get("vectorIndexSize", {}).get("usage", 0)
        if doc_count == 0:
            print(f"[OK] Service stats: documentCount=0, vectorIndexSize=0 "
                  f"(expected on empty index — run the Fabric pipeline to ingest chunks).")
        elif vec_size > 0:
            print(f"[OK] Service stats: documentCount={doc_count}, vectorIndexSize={vec_size} bytes "
                  f"(vectors are populating correctly).")
        else:
            print(f"[FAIL] Service stats: documentCount={doc_count} but vectorIndexSize=0. "
                  f"Documents are indexed but vectors are NOT being generated. "
                  f"This is silent vectorizer failure — see docs/06-troubleshooting.md § 4.1.")
            errors += 1
    except Exception as e:
        print(f"[FAIL] Service stats check: {e}")
        errors += 1

    return errors


# ---------- main ------------------------------------------------------------------


def main() -> int:
    ap = argparse.ArgumentParser(description="Configure AI Search index/datasource/indexer post-Bicep")
    ap.add_argument("--ids", type=Path, default=Path("demo-ids.local.json"),
                    help="Path to deployment outputs JSON (default: demo-ids.local.json)")
    ap.add_argument("--run-indexer", action="store_true", help="Trigger a manual indexer run after config")
    ap.add_argument("--verify", action="store_true", help="Run smoke tests instead of configuration")
    args = ap.parse_args()

    ids = load_ids(args.ids)
    credential = DefaultAzureCredential()
    tokens = SearchTokenProvider(credential)

    # subscriptionId is not strictly required for bearer-token data-plane calls, but the
    # datasource ResourceId connection string needs it. Fall back to azure-cli context if
    # the IDs file didn't capture it.
    if "subscriptionId" not in ids:
        try:
            from subprocess import check_output
            # shell=True is required on Windows so that `az` (actually az.cmd) resolves.
            ids["subscriptionId"] = check_output(
                "az account show --query id -o tsv",
                text=True, shell=True,
            ).strip()
        except Exception as ex:
            sys.exit(
                "[FATAL] subscriptionId missing from ids file and `az account show` failed: "
                f"{ex!r}. Add a top-level \"subscriptionId\" key to the ids file or run "
                "`az login` / `az account set --subscription <id>` first."
            )

    if args.verify:
        errors = verify(ids, tokens)
        if errors:
            print(f"\n[FAIL] {errors} verification check(s) failed.")
            return 1
        print("\n[OK] All verification checks passed.")
        return 0

    configure(ids, tokens)

    if args.run_indexer:
        # short delay so the indexer service has the new datasource committed
        time.sleep(5)
        run_indexer(ids, tokens)

    return 0


if __name__ == "__main__":
    sys.exit(main())
