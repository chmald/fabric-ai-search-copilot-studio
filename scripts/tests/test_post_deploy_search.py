"""
Smoke tests for post_deploy_search.py.

These do NOT hit Azure. They exercise the pure-Python payload builders to catch
schema regressions (field name typos, dimensionality mismatches, missing semantic
config) before the script runs against a live deployment.

Run:
    pytest scripts/tests/ -q
"""

import sys
from pathlib import Path

# Make scripts/ importable when running pytest from the repo root.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import post_deploy_search as pds  # noqa: E402


SAMPLE_IDS = {
    "subscriptionId": "00000000-0000-0000-0000-000000000000",
    "resourceGroup": "rg-rag-dev-eastus2",
    "storageAccount": "stragdeveastus2",
    "chunksContainer": "chunks",
    "searchService": "srch-rag-dev-eastus2",
    "searchEndpoint": "https://srch-rag-dev-eastus2.search.windows.net",
    "searchIndexName": "idx-rag-documents",
    "searchDataSourceName": "ds-chunks",
    "searchIndexerName": "ixr-chunks",
    "foundryOpenAIEndpoint": "https://aif-rag-dev-eastus2.openai.azure.com",
    "embeddingDeployment": "embedding",
    "embeddingModel": "text-embedding-3-large",
    "chatDeployment": "chat",
    "chatModel": "gpt-4o",
}


# ---------- index payload ---------------------------------------------------------


def test_index_payload_name():
    payload = pds.index_payload(SAMPLE_IDS)
    assert payload["name"] == "idx-rag-documents"


def test_index_payload_has_required_fields():
    payload = pds.index_payload(SAMPLE_IDS)
    field_names = {f["name"] for f in payload["fields"]}
    required = {"id", "doc_id", "chunk_id", "content", "content_vector",
                "doc_type", "source_uri", "page_start", "page_end", "ingest_ts",
                "group_ids", "metadata"}
    assert required.issubset(field_names), f"Missing fields: {required - field_names}"


def test_index_payload_group_ids_is_filterable_string_collection():
    """v1.2 chunk-level security trimming: group_ids must be a filterable
    Collection(Edm.String) so query-time $filter trimming works."""
    payload = pds.index_payload(SAMPLE_IDS)
    group_ids = next(f for f in payload["fields"] if f["name"] == "group_ids")
    assert group_ids["type"] == "Collection(Edm.String)"
    assert group_ids.get("filterable") is True


def test_index_payload_key_field_is_id():
    payload = pds.index_payload(SAMPLE_IDS)
    key_fields = [f for f in payload["fields"] if f.get("key")]
    assert len(key_fields) == 1 and key_fields[0]["name"] == "id"


def test_index_payload_vector_dim_matches_embedding_model_large():
    ids = {**SAMPLE_IDS, "embeddingModel": "text-embedding-3-large"}
    payload = pds.index_payload(ids)
    vec_field = next(f for f in payload["fields"] if f["name"] == "content_vector")
    assert vec_field["dimensions"] == 3072, "text-embedding-3-large is 3072-dim"


def test_index_payload_vector_dim_matches_embedding_model_small():
    ids = {**SAMPLE_IDS, "embeddingModel": "text-embedding-3-small"}
    payload = pds.index_payload(ids)
    vec_field = next(f for f in payload["fields"] if f["name"] == "content_vector")
    assert vec_field["dimensions"] == 1536, "text-embedding-3-small is 1536-dim"


def test_index_payload_vectorizer_points_at_foundry():
    payload = pds.index_payload(SAMPLE_IDS)
    vectorizers = payload["vectorSearch"]["vectorizers"]
    assert len(vectorizers) == 1
    v = vectorizers[0]
    assert v["kind"] == "azureOpenAI"
    assert v["azureOpenAIParameters"]["resourceUri"].endswith(".openai.azure.com")
    assert v["azureOpenAIParameters"]["deploymentId"] == "embedding"
    assert v["azureOpenAIParameters"]["modelName"] == "text-embedding-3-large"
    # authIdentity=None means "use system-assigned managed identity"
    assert v["azureOpenAIParameters"]["authIdentity"] is None


def test_index_payload_vector_profile_wires_vectorizer():
    payload = pds.index_payload(SAMPLE_IDS)
    profile_name = next(f for f in payload["fields"] if f["name"] == "content_vector")["vectorSearchProfile"]
    profile = next(p for p in payload["vectorSearch"]["profiles"] if p["name"] == profile_name)
    assert profile["vectorizer"] == "aif-vectorizer"


def test_index_payload_semantic_config_present():
    payload = pds.index_payload(SAMPLE_IDS)
    assert payload["semantic"]["defaultConfiguration"] == "semantic-default"
    configs = payload["semantic"]["configurations"]
    assert len(configs) == 1
    pf = configs[0]["prioritizedFields"]
    assert pf["titleField"]["fieldName"] == "doc_id"
    assert pf["prioritizedContentFields"][0]["fieldName"] == "content"


# ---------- datasource payload ----------------------------------------------------


def test_datasource_uses_managed_identity_connection_string():
    payload = pds.datasource_payload(SAMPLE_IDS)
    cs = payload["credentials"]["connectionString"]
    assert cs.startswith("ResourceId="), "Must use managed-identity-style connection string"
    assert "/Microsoft.Storage/storageAccounts/stragdeveastus2" in cs


def test_datasource_container_is_chunks():
    payload = pds.datasource_payload(SAMPLE_IDS)
    assert payload["container"]["name"] == "chunks"


# ---------- indexer payload -------------------------------------------------------


def test_indexer_field_mappings_round_trip():
    payload = pds.indexer_payload(SAMPLE_IDS)
    src = {m["sourceFieldName"] for m in payload["fieldMappings"]}
    tgt = {m["targetFieldName"] for m in payload["fieldMappings"]}
    # 1:1 mapping for everything except content_vector (filled by the skillset via
    # outputFieldMappings, not by a regular fieldMapping).
    assert "content" in src and "content" in tgt
    assert "content_vector" not in src and "content_vector" not in tgt, \
        "content_vector must NOT be in fieldMappings; it's filled via outputFieldMappings"


def test_indexer_schedule_is_5min():
    payload = pds.indexer_payload(SAMPLE_IDS)
    assert payload["schedule"]["interval"] == "PT5M"


def test_indexer_references_skillset():
    payload = pds.indexer_payload(SAMPLE_IDS)
    assert payload["skillsetName"] == "skill-rag-embeddings", \
        "Indexer must reference the skillset — without it, content_vector stays null " \
        "and Copilot Studio returns no results (silent vectorizer failure)."


def test_indexer_skillset_name_overridable():
    ids = {**SAMPLE_IDS, "searchSkillsetName": "my-custom-skillset"}
    payload = pds.indexer_payload(ids)
    assert payload["skillsetName"] == "my-custom-skillset"


def test_indexer_has_output_field_mapping_for_content_vector():
    payload = pds.indexer_payload(SAMPLE_IDS)
    ofm = payload["outputFieldMappings"]
    assert len(ofm) >= 1
    cv_mapping = next((m for m in ofm if m["targetFieldName"] == "content_vector"), None)
    assert cv_mapping is not None, "Missing outputFieldMapping for content_vector"
    assert cv_mapping["sourceFieldName"] == "/document/content_vector_embedding", \
        "sourceFieldName must match the skill's targetName under /document"


# ---------- skillset payload ------------------------------------------------------


def test_skillset_name_default():
    assert pds.skillset_name(SAMPLE_IDS) == "skill-rag-embeddings"


def test_skillset_name_overridable():
    ids = {**SAMPLE_IDS, "searchSkillsetName": "my-custom-skillset"}
    assert pds.skillset_name(ids) == "my-custom-skillset"


def test_skillset_payload_has_aoai_embedding_skill():
    payload = pds.skillset_payload(SAMPLE_IDS)
    assert len(payload["skills"]) == 1
    skill = payload["skills"][0]
    assert skill["@odata.type"] == "#Microsoft.Skills.Text.AzureOpenAIEmbeddingSkill"
    assert skill["resourceUri"].endswith(".openai.azure.com")
    assert skill["deploymentId"] == "embedding"
    assert skill["modelName"] == "text-embedding-3-large"
    # authIdentity=None => use system-assigned managed identity
    assert skill["authIdentity"] is None


def test_skillset_payload_input_is_content_field():
    payload = pds.skillset_payload(SAMPLE_IDS)
    skill = payload["skills"][0]
    assert skill["inputs"][0]["name"] == "text"
    assert skill["inputs"][0]["source"] == "/document/content"


def test_skillset_payload_output_target_matches_indexer_mapping():
    """The skill output targetName must match the indexer's outputFieldMapping source."""
    skill_payload = pds.skillset_payload(SAMPLE_IDS)
    indexer_pl = pds.indexer_payload(SAMPLE_IDS)
    skill_output_target = skill_payload["skills"][0]["outputs"][0]["targetName"]
    expected_source = f"/document/{skill_output_target}"
    cv_mapping = next(m for m in indexer_pl["outputFieldMappings"]
                      if m["targetFieldName"] == "content_vector")
    assert cv_mapping["sourceFieldName"] == expected_source, (
        f"Skill writes to /document/{skill_output_target} but indexer reads from "
        f"{cv_mapping['sourceFieldName']} — these must match or content_vector stays null."
    )


def test_skillset_dimensions_match_embedding_model():
    large_ids = {**SAMPLE_IDS, "embeddingModel": "text-embedding-3-large"}
    small_ids = {**SAMPLE_IDS, "embeddingModel": "text-embedding-3-small"}
    assert pds.skillset_payload(large_ids)["skills"][0]["dimensions"] == 3072
    assert pds.skillset_payload(small_ids)["skills"][0]["dimensions"] == 1536


# ---------- chat-deployment-optional behavior ------------------------------------
# The locked design (Copilot Studio + AI Search hybrid index + integrated vectorizer)
# does NOT consume a chat completion model — Copilot Studio uses its own host model.
# infra/main.bicep defaults chatModelName to '' so the chat deployment is skipped;
# infra/deploy.ps1's deploymentSummary then emits chatDeployment="" and chatModel="".
# These tests verify that every payload builder still works when those fields are
# empty or missing, so a chat-disabled deploy never breaks the post-deploy script.


def _ids_without_chat():
    ids = {k: v for k, v in SAMPLE_IDS.items() if k not in {"chatDeployment", "chatModel"}}
    return ids


def test_index_payload_works_without_chat_fields():
    payload = pds.index_payload(_ids_without_chat())
    assert payload["name"] == "idx-rag-documents"


def test_indexer_payload_works_without_chat_fields():
    payload = pds.indexer_payload(_ids_without_chat())
    assert payload["name"] == "ixr-chunks"


def test_skillset_payload_works_without_chat_fields():
    payload = pds.skillset_payload(_ids_without_chat())
    assert payload["skills"][0]["deploymentId"] == "embedding"


def test_payloads_work_with_empty_chat_fields():
    """deploy.ps1 writes chatDeployment='' and chatModel='' when chat is skipped."""
    ids = {**SAMPLE_IDS, "chatDeployment": "", "chatModel": "", "chatDeployed": False}
    # All three builders must succeed without referencing the empty values.
    assert pds.index_payload(ids)["name"] == "idx-rag-documents"
    assert pds.indexer_payload(ids)["name"] == "ixr-chunks"
    assert pds.skillset_payload(ids)["skills"][0]["deploymentId"] == "embedding"
