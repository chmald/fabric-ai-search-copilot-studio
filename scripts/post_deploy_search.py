"""
post_deploy_search.py — Configure Azure AI Search after the Bicep deployment.

Bicep provisions the Search SERVICE; this script creates the index / data source / indexer.
The Search index types in ARM/Bicep do not cleanly express integrated vectorizer config +
semantic configuration + indexer field mappings, so we use the REST control plane instead.

What this script does
=====================
1. Reads deployment outputs from --ids (default: demo-ids.local.json)
2. Creates (or updates) the search index `idx-rag-documents`:
     - text + vector + metadata fields (per docs/01-architecture.md schema)
     - integrated `azureOpenAI` vectorizer pointed at the Foundry embedding deployment
     - semantic configuration `semantic-default`
3. Creates (or updates) the data source `ds-chunks` using a managed-identity ResourceId
   connection string to the storage account's `chunks/` container
4. Creates (or updates) the indexer `ixr-chunks` with a 5-minute schedule
5. Optionally runs the indexer manually (--run-indexer)
6. In --verify mode: hits the index $count + a semantic test query + indexer status

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
from azure.identity import DefaultAzureCredential

SEARCH_API_VERSION = "2024-07-01"


# ---------- helpers ----------------------------------------------------------------


def load_ids(path: Path) -> dict[str, Any]:
    if not path.exists():
        sys.exit(f"[FATAL] IDs file not found: {path}\n"
                 f"Run `pwsh ./infra/deploy.ps1` first (or set --ids to your file path).")
    return json.loads(path.read_text(encoding="utf-8"))


def search_admin_key(credential: DefaultAzureCredential, search_service_name: str,
                     subscription_id: str, resource_group: str) -> str:
    """Pull a primary admin key via ARM (uses the caller's Azure identity).

    AI Search supports AAD auth on the data plane, but the index/datasource/indexer
    PUT endpoints require an admin key OR a search service contributor RBAC role.
    Using the admin key path keeps this script independent of RBAC propagation timing.
    """
    arm_token = credential.get_token("https://management.azure.com/.default").token
    url = (f"https://management.azure.com/subscriptions/{subscription_id}"
           f"/resourceGroups/{resource_group}/providers/Microsoft.Search"
           f"/searchServices/{search_service_name}/listAdminKeys?api-version=2023-11-01")
    r = requests.post(url, headers={"Authorization": f"Bearer {arm_token}"}, timeout=30)
    r.raise_for_status()
    return r.json()["primaryKey"]


def search_put(search_endpoint: str, key: str, resource_kind: str, name: str,
               body: dict[str, Any]) -> None:
    url = f"{search_endpoint}/{resource_kind}/{name}?api-version={SEARCH_API_VERSION}"
    r = requests.put(url, headers={"api-key": key, "Content-Type": "application/json"},
                     data=json.dumps(body), timeout=60)
    if r.status_code not in (200, 201, 204):
        print(f"[FAIL] PUT {url}\n  status {r.status_code}\n  body  {r.text}")
        r.raise_for_status()


def search_get(search_endpoint: str, key: str, path: str) -> dict[str, Any]:
    url = f"{search_endpoint}/{path}{'&' if '?' in path else '?'}api-version={SEARCH_API_VERSION}"
    r = requests.get(url, headers={"api-key": key}, timeout=30)
    r.raise_for_status()
    return r.json() if r.text else {}


def search_post(search_endpoint: str, key: str, path: str, body: dict[str, Any]) -> dict[str, Any]:
    url = f"{search_endpoint}/{path}{'&' if '?' in path else '?'}api-version={SEARCH_API_VERSION}"
    r = requests.post(url, headers={"api-key": key, "Content-Type": "application/json"},
                      data=json.dumps(body), timeout=60)
    r.raise_for_status()
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


def indexer_payload(ids: dict[str, Any]) -> dict[str, Any]:
    return {
        "name": ids["searchIndexerName"],
        "dataSourceName": ids["searchDataSourceName"],
        "targetIndexName": ids["searchIndexName"],
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
        "schedule": {"interval": "PT5M"},
    }


# ---------- orchestration ---------------------------------------------------------


def configure(ids: dict[str, Any], key: str) -> None:
    endpoint = ids["searchEndpoint"]

    print(f"[..] Creating/updating index: {ids['searchIndexName']}")
    search_put(endpoint, key, "indexes", ids["searchIndexName"], index_payload(ids))
    print(f"[OK] Index '{ids['searchIndexName']}' created (or updated).")

    print(f"[..] Creating/updating data source: {ids['searchDataSourceName']}")
    search_put(endpoint, key, "datasources", ids["searchDataSourceName"], datasource_payload(ids))
    print(f"[OK] Data source '{ids['searchDataSourceName']}' created "
          f"(managed-identity connection to {ids['storageAccount']}/{ids['chunksContainer']}).")

    print(f"[..] Creating/updating indexer: {ids['searchIndexerName']}")
    search_put(endpoint, key, "indexers", ids["searchIndexerName"], indexer_payload(ids))
    print(f"[OK] Indexer '{ids['searchIndexerName']}' created (schedule: PT5M).")


def run_indexer(ids: dict[str, Any], key: str) -> None:
    endpoint = ids["searchEndpoint"]
    print(f"[..] Triggering manual indexer run: {ids['searchIndexerName']}")
    url = f"{endpoint}/indexers/{ids['searchIndexerName']}/run?api-version={SEARCH_API_VERSION}"
    r = requests.post(url, headers={"api-key": key}, timeout=30)
    if r.status_code in (202, 204):
        print("[OK] Indexer run triggered. Status will be visible in the portal in ~30s.")
    else:
        print(f"[WARN] Indexer run returned {r.status_code}: {r.text}")


def verify(ids: dict[str, Any], key: str) -> int:
    endpoint = ids["searchEndpoint"]
    errors = 0

    # 1. Index exists + doc count
    try:
        count = search_get(endpoint, key, f"indexes/{ids['searchIndexName']}/docs/$count?")
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
        result = search_post(endpoint, key, f"indexes/{ids['searchIndexName']}/docs/search?", body)
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
        status = search_get(endpoint, key, f"indexers/{ids['searchIndexerName']}/status?")
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

    # Some IDs (subscription, resource group) may not be in the deployment outputs;
    # fall back to azure-cli for context if missing.
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

    key = search_admin_key(credential, ids["searchService"], ids["subscriptionId"], ids["resourceGroup"])

    if args.verify:
        errors = verify(ids, key)
        if errors:
            print(f"\n[FAIL] {errors} verification check(s) failed.")
            return 1
        print("\n[OK] All verification checks passed.")
        return 0

    configure(ids, key)

    if args.run_indexer:
        # short delay so the indexer service has the new datasource committed
        time.sleep(5)
        run_indexer(ids, key)

    return 0


if __name__ == "__main__":
    sys.exit(main())
