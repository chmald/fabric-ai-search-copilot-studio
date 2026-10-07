"""Configuration guard (hard-rule #18): every knob a user can set is documented in
docs/13-configuration-reference.md, and infra/azd.bicep passes every main.bicep
parameter through to the shared template."""

from __future__ import annotations

import ast
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CONFIG_DOC = ROOT / "docs" / "13-configuration-reference.md"
AZD_PARAMETERS = ROOT / "infra" / "azd.parameters.json"
AZD_BICEP = ROOT / "infra" / "azd.bicep"
MAIN_BICEP = ROOT / "infra" / "main.bicep"
DEPLOY_PS1 = ROOT / "infra" / "deploy.ps1"
PY_SOURCES = [ROOT / "scripts", ROOT / "webapp" / "app"]


def config_text() -> str:
    return CONFIG_DOC.read_text(encoding="utf-8")


def azd_parameter_variables() -> set[str]:
    data = json.loads(AZD_PARAMETERS.read_text(encoding="utf-8"))
    variables: set[str] = set()
    for item in data["parameters"].values():
        value = item["value"]
        match = re.fullmatch(r"\$\{([A-Z0-9_]+)(?:=[^}]*)?\}", value)
        assert match, f"azd parameter value is not a single quoted substitution: {value}"
        variables.add(match.group(1))
    return variables


def bicep_outputs(path: Path) -> set[str]:
    return set(re.findall(r"(?m)^output\s+([A-Za-z0-9_]+)\s+", path.read_text(encoding="utf-8")))


def bicep_params(path: Path) -> set[str]:
    return set(re.findall(r"(?m)^param\s+([A-Za-z][A-Za-z0-9_]*)\s+", path.read_text(encoding="utf-8")))


def azd_main_module_params() -> set[str]:
    text = AZD_BICEP.read_text(encoding="utf-8")
    match = re.search(r"module\s+main\s+'main\.bicep'\s*=\s*\{.*?\n\s*params:\s*\{(?P<body>.*?)\n\s*\}\n\}", text, re.S)
    assert match, "could not find the main.bicep module params in infra/azd.bicep"
    return set(re.findall(r"(?m)^\s*([A-Za-z][A-Za-z0-9_]*)\s*:", match.group("body")))


def hook_env_vars() -> set[str]:
    variables: set[str] = set()
    for path in (ROOT / "infra" / "hooks").glob("*.ps1"):
        text = path.read_text(encoding="utf-8")
        variables.update(re.findall(r'Get-EnvValue\s+-Name\s+["\']([A-Z0-9_]+)["\']', text))
        variables.update(re.findall(r"\$env:([A-Z0-9_]+)", text))
    return variables


def deploy_ps1_parameters() -> set[str]:
    text = DEPLOY_PS1.read_text(encoding="utf-8")
    block = re.search(r"\[CmdletBinding\(\)\]\s*param\((?P<body>.*?)\n\)", text, re.S)
    assert block, "could not find the deploy.ps1 param block"
    return set(re.findall(r"\$([A-Za-z]+)\s*(?:=|,|\n|$)", block.group("body")))


def python_files():
    for base in PY_SOURCES:
        yield from base.rglob("*.py")


def python_env_vars() -> set[str]:
    variables: set[str] = set()
    for path in python_files():
        tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
        for node in ast.walk(tree):
            if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute):
                is_environ_get = (node.func.attr == "get" and isinstance(node.func.value, ast.Attribute)
                                  and node.func.value.attr == "environ")
                if (is_environ_get or node.func.attr == "getenv") and node.args and isinstance(node.args[0], ast.Constant):
                    value = node.args[0].value
                    if isinstance(value, str) and re.fullmatch(r"[A-Z0-9_]+", value):
                        variables.add(value)
    return variables


def python_cli_flags() -> set[str]:
    flags: set[str] = set()
    for path in python_files():
        flags.update(re.findall(r"add_argument\(\s*\"(--[a-z0-9-]+)\"", path.read_text(encoding="utf-8")))
    return flags


def template_demo_ids_keys() -> set[str]:
    data = json.loads((ROOT / "demo-ids.template.json").read_text(encoding="utf-8"))
    keys = {k for k in data if not k.startswith("_")}
    keys.update(k for k in data["corpus"] if not k.startswith("_"))
    return keys


def python_demo_ids_keys() -> set[str]:
    """String keys read from the ids dict (ids.get("x") / ids["x"] / setting(ids, "x"))."""
    keys: set[str] = set()
    for path in (ROOT / "scripts").glob("*.py"):
        text = path.read_text(encoding="utf-8")
        keys.update(re.findall(r"ids\.get\(\s*['\"]([A-Za-z]+)['\"]", text))
        keys.update(re.findall(r"ids\[\s*['\"]([A-Za-z]+)['\"]\s*\]", text))
        keys.update(re.findall(r"setting\(\s*ids\s*,\s*['\"]([A-Za-z]+)['\"]", text))
    return keys


def assert_documented(terms: set[str], label: str) -> None:
    assert terms, f"no {label} found - the extractor is broken"
    text = config_text()
    missing = sorted(t for t in terms if t not in text)
    assert not missing, f"{label} missing from docs/13-configuration-reference.md: {', '.join(missing)}"


def test_azd_parameter_variables_are_documented():
    assert_documented(azd_parameter_variables(), "azd parameter variables")


def test_azd_outputs_are_documented():
    assert_documented(bicep_outputs(AZD_BICEP), "azd.bicep outputs")


def test_main_bicep_parameters_are_documented():
    assert_documented(bicep_params(MAIN_BICEP), "main.bicep parameters")


def test_hook_env_vars_are_documented():
    assert_documented(hook_env_vars(), "hook environment variables")


def test_deploy_ps1_parameters_are_documented():
    assert_documented({f"-{p}" for p in deploy_ps1_parameters()}, "deploy.ps1 parameters")


def test_python_env_vars_are_documented():
    assert_documented(python_env_vars(), "Python environment variables")


def test_python_cli_flags_are_documented():
    assert_documented(python_cli_flags(), "Python CLI flags")


def test_demo_ids_keys_are_documented():
    assert_documented(template_demo_ids_keys() | python_demo_ids_keys(), "demo-ids keys")


def test_azd_bicep_passes_every_main_bicep_parameter():
    missing = sorted(bicep_params(MAIN_BICEP) - azd_main_module_params())
    assert not missing, f"infra/azd.bicep does not pass main.bicep params: {', '.join(missing)}"


def test_azd_parameter_values_are_quoted_substitutions():
    raw = AZD_PARAMETERS.read_text(encoding="utf-8")
    assert not re.search(r'"value":\s*\$\{', raw), "unquoted ${VAR} in azd.parameters.json - azd parses JSON before substituting"


def test_azd_outputs_are_upper_snake_case():
    bad = sorted(o for o in bicep_outputs(AZD_BICEP) if not re.fullmatch(r"[A-Z0-9_]+", o))
    assert not bad, f"azd.bicep outputs must be UPPER_SNAKE_CASE: {', '.join(bad)}"


def test_gitignore_excludes_azd_state():
    assert ".azure/" in (ROOT / ".gitignore").read_text(encoding="utf-8").splitlines()
