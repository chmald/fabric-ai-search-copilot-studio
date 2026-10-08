"""Reusability guards (structural reusability + customer-facing wording).

The shared baseline - IaC, azd hooks, scripts, the web app and the ids-file template -
must stay domain-neutral. The pattern was first built for an HR document corpus; that
example lives only in docs (labelled as an example) and in samples/. If a domain term
leaks back into the baseline, retargeting the pattern stops being a config-only change.

The repo is also published for external readers, so private authoring-tool names and
internal sales/process jargon must not appear anywhere in the tree.
"""

import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

# Generic internal jargon (not secrets) that has no meaning to an external reader.
INTERNAL_TERMS = re.compile(
    r"demo-pattern-authoring|azure-architecture-diagrams|daily[_ ]?driver|"
    r"\b(MCAPS|MCEM|MSX|TPID|CSAM|ATU|STU|CSU|CAIP|MACC)\b|hard[- ]rules?\s*#|authoring gates?|"
    r"hands-on-keyboard|\bHoK\b|technical close plan|solution play|azure consumed revenue|"
    r"tech elevate|cloud accelerate factory|microsoft\.sharepoint\.com|viva engage|"
    r"internal-only|microsoft-internal|not for customer distribution|solution engineers?",
    re.IGNORECASE,
)
TEXT_SUFFIXES = {".md", ".py", ".ps1", ".bicep", ".json", ".yml", ".yaml", ".txt", ".csv",
                 ".drawio", ".toml", ".ini", ".cfg", ".dockerfile", ".gitignore", ""}
SKIP_DIRS = {".git", ".azure", ".venv", "venv", "node_modules", "__pycache__", ".pytest_cache"}

EXAMPLE_DOMAIN_TERMS = re.compile(
    r"\b(hr|human[ -]resources?|employees?|payroll|benefits|offer[ -]letters?|severance|"
    r"compensation|onboarding)\b",
    re.IGNORECASE,
)

BASELINE_GLOBS = [
    "azure.yaml",
    "infra/*.bicep",
    "infra/modules/*.bicep",
    "infra/*.parameters.json",
    "infra/hooks/*.ps1",
    "infra/deploy.ps1",
    "scripts/*.py",
    "scripts/*.ps1",
    "webapp/app/*.py",
]

# Resource names / scoped identifiers that must stay neutral constants.
NEUTRAL_DEFAULTS = {
    "searchIndexName": "idx-rag-documents",
    "searchSkillsetName": "skill-rag-embeddings",
}


def baseline_files():
    for pattern in BASELINE_GLOBS:
        yield from sorted(ROOT.glob(pattern))


def test_baseline_files_exist():
    assert list(baseline_files()), "no baseline files matched - check BASELINE_GLOBS"


def test_no_example_domain_terms_in_shared_baseline():
    leaks = []
    for path in baseline_files():
        for n, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            match = EXAMPLE_DOMAIN_TERMS.search(line)
            if match:
                leaks.append(f"{path.relative_to(ROOT)}:{n}: {match.group(0)!r}")
    assert not leaks, "example-domain terms leaked into the shared baseline:\n" + "\n".join(leaks)


def test_template_corpus_block_is_domain_neutral():
    template = json.loads((ROOT / "demo-ids.template.json").read_text(encoding="utf-8"))
    corpus = template["corpus"]
    blob = json.dumps({k: v for k, v in corpus.items() if not k.startswith("_")})
    match = EXAMPLE_DOMAIN_TERMS.search(blob)
    assert match is None, f"corpus defaults contain an example-domain term: {match.group(0)!r}"
    for key, expected in NEUTRAL_DEFAULTS.items():
        assert corpus[key] == expected, f"corpus.{key} default changed from the neutral {expected!r}"


def test_template_is_marked_as_template():
    template = json.loads((ROOT / "demo-ids.template.json").read_text(encoding="utf-8"))
    assert template.get("_template") is True
    assert "_note" in template
    assert "corpus" in template["_meta"]["manualSections"]


def test_no_internal_terminology():
    hits = []
    for path in sorted(ROOT.rglob("*")):
        rel = path.relative_to(ROOT)
        if (not path.is_file() or set(rel.parts) & SKIP_DIRS or path.name == Path(__file__).name
                or (path.suffix.lower() not in TEXT_SUFFIXES and path.name not in {"Dockerfile"})):
            continue
        text = path.read_text(encoding="utf-8", errors="ignore")
        text = re.sub(r"data:image/[a-z+]+;?[A-Za-z0-9+/=,;]*", "", text)  # embedded icon data
        for n, line in enumerate(text.splitlines(), 1):
            match = INTERNAL_TERMS.search(line)
            if match:
                hits.append(f"{rel}:{n}: {match.group(0)!r}")
    assert not hits, "internal terminology found in the published tree:\n" + "\n".join(hits)
