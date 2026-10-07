"""Reusability guards (hard-rule #14).

The shared baseline - IaC, azd hooks, scripts, the web app and the ids-file template -
must stay domain-neutral. The pattern was first built for an HR document corpus; that
example lives only in docs (labelled as an example) and in samples/. If a domain term
leaks back into the baseline, retargeting the pattern stops being a config-only change.
"""

import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

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
