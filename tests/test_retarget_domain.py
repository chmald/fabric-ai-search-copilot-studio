"""Retarget the pattern at a clearly different domain using ONLY the corpus block
(hard-rule #14) and assert every AI Search payload follows it and nothing from the
default / example domain survives."""

import copy
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))

import post_deploy_search as pds  # noqa: E402

BASE_IDS = {
    "subscriptionId": "00000000-0000-0000-0000-000000000000",
    "resourceGroup": "rg-kb-dev-eastus2",
    "storageAccount": "stkbdeveastus2",
    "chunksContainer": "chunks",
    "searchService": "srch-kb-dev-eastus2",
    "searchEndpoint": "https://srch-kb-dev-eastus2.search.windows.net",
    "searchIndexName": "idx-rag-documents",
    "searchDataSourceName": "ds-chunks",
    "searchIndexerName": "ixr-chunks",
    "foundryOpenAIEndpoint": "https://aif-kb-dev-eastus2.openai.azure.com",
    "embeddingDeployment": "embedding",
    "embeddingModel": "text-embedding-3-large",
}

FIELD_SERVICE_CORPUS = {
    "displayName": "Field service manuals",
    "searchIndexName": "idx-field-manuals",
    "searchSkillsetName": "skill-field-manuals",
    "contentAnalyzer": "de.microsoft",
    "embeddingDimensions": 1024,
    "indexerSchedule": "PT1H",
    "searchApiVersion": "2026-04-01",
}


def retargeted():
    ids = copy.deepcopy(BASE_IDS)
    ids["corpus"] = dict(FIELD_SERVICE_CORPUS)
    return pds.resolve_settings(ids)


def all_payloads(ids):
    return {
        "index": pds.index_payload(ids),
        "skillset": pds.skillset_payload(ids),
        "indexer": pds.indexer_payload(ids),
        "datasource": pds.datasource_payload(ids),
    }


def test_corpus_block_drives_every_payload():
    ids = retargeted()
    p = all_payloads(ids)
    assert p["index"]["name"] == "idx-field-manuals"
    content = next(f for f in p["index"]["fields"] if f["name"] == "content")
    assert content["analyzer"] == "de.microsoft"
    vector = next(f for f in p["index"]["fields"] if f["name"] == "content_vector")
    assert vector["dimensions"] == 1024
    assert p["skillset"]["name"] == "skill-field-manuals"
    assert p["skillset"]["skills"][0]["dimensions"] == 1024
    assert p["indexer"]["targetIndexName"] == "idx-field-manuals"
    assert p["indexer"]["skillsetName"] == "skill-field-manuals"
    assert p["indexer"]["schedule"]["interval"] == "PT1H"
    assert pds.setting(ids, "searchApiVersion") == "2026-04-01"


def test_nothing_from_the_default_domain_survives_a_retarget():
    blob = json.dumps(all_payloads(retargeted()))
    for leftover in ("idx-rag-documents", "skill-rag-embeddings", "en.microsoft", "PT5M"):
        assert leftover not in blob, f"default value {leftover!r} survived the retarget"


def test_scoped_constants_stay_fixed_across_domains():
    """Names scoped inside the index (vector profile, algorithm, semantic config) are
    neutral constants - renaming them per domain only creates drift."""
    default = pds.index_payload(pds.resolve_settings(copy.deepcopy(BASE_IDS)))
    other = pds.index_payload(retargeted())
    assert default["vectorSearch"]["profiles"] == other["vectorSearch"]["profiles"]
    assert default["semantic"]["defaultConfiguration"] == other["semantic"]["defaultConfiguration"]


def test_empty_corpus_values_fall_back_to_defaults():
    ids = copy.deepcopy(BASE_IDS)
    ids["corpus"] = {"searchIndexName": "", "embeddingDimensions": None, "indexerSchedule": None}
    ids = pds.resolve_settings(ids)
    assert pds.index_payload(ids)["name"] == "idx-rag-documents"
    assert pds.embedding_dimensions(ids) == 3072
    assert pds.indexer_payload(ids)["schedule"]["interval"] == "PT5M"
