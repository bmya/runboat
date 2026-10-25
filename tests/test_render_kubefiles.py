from typing import Any

import pytest
import yaml  # type: ignore[import-untyped]

from runboat.github import CommitInfo
from runboat.k8s import (
    DeploymentMode,
    _render_kubefiles,
    htpasswd_sha,
    make_deployment_vars,
)
from runboat.settings import BuildSettings, settings

EXPECTED = """\
resources:
  - pvc.yaml
  - deployment.yaml
  - service.yaml
  - ingress_odoo.yaml
  - ingress_mailhog.yaml

namespace: runboat-builds

namePrefix: "build-name-"

labels:
  - pairs:
      runboat/build: "build-name"
    includeSelectors: true
    includeTemplates: true

commonAnnotations:
  runboat/repo: "oca/mis-builder"
  runboat/target-branch: "15.0"
  runboat/pr: ""
  runboat/git-commit: "abcdef123456789"

images:
  - name: odoo
    newName: "ghcr.io/oca/oca-ci"
    newTag: "py3.8-odoo15.0"
  - name: mailhog
    newName: "mailhog/mailhog"
    newTag: "latest"

secretGenerator:
  - name: odoosecretenv
    literals:
      - PGPASSWORD=thepgpassword

configMapGenerator:
  - name: odooenv
    literals:
      - PGDATABASE=build-name
      - ADDONS_DIR=/mnt/data/odoo-addons-dir
      - RUNBOAT_GIT_REPO=oca/mis-builder
      - RUNBOAT_GIT_REF=abcdef123456789
      - RUNBOAT_GIT_TARGET_BRANCH=15.0
      - RUNBOAT_ISOLATED=0
  - name: runboat-scripts
    files:
      - runboat-fetch.sh
      - runboat-clone-and-install.sh
      - runboat-initialize.sh
      - runboat-cleanup.sh
      - runboat-start.sh
      - runboat-test.sh

generatorOptions:
  disableNameSuffixHash: true

patches:
  - target:
      kind: PersistentVolumeClaim
      name: data
    patch: |-
      - op: replace
        path: /spec/storageClassName
        value: my-storage-class
  - target:
      kind: Ingress
      name: odoo
    patch: |-
      - op: replace
        path: /spec/rules/0/host
        value: build-slug.runboat.odoo-community.org
  - target:
      kind: Ingress
      name: mailhog
    patch: |-
      - op: replace
        path: /spec/rules/0/host
        value: build-slug.mail.runboat.odoo-community.org
"""


def test_render_kubefiles() -> None:
    build_settings = BuildSettings(image="ghcr.io/oca/oca-ci:py3.8-odoo15.0")
    kubefiles_path = settings.build_default_kubefiles_path
    deployment_vars = make_deployment_vars(
        mode=DeploymentMode.deployment,
        build_name="build-name",
        slug="build-slug",
        commit_info=CommitInfo(
            repo="oca/mis-builder",
            target_branch="15.0",
            pr=None,
            git_commit="abcdef123456789",
        ),
        build_settings=build_settings,
    )
    with _render_kubefiles(kubefiles_path, deployment_vars) as tmp_path:
        assert (tmp_path / "kustomization.yaml").is_file()
        assert (tmp_path / "deployment.yaml").is_file()
        kustomization = (tmp_path / "kustomization.yaml").read_text()
        assert kustomization.strip() == EXPECTED.strip()


def _render(
    mode: DeploymentMode,
    repo: str = "oca/mis-builder",
    build_settings: BuildSettings | None = None,
) -> Any:
    deployment_vars = make_deployment_vars(
        mode=mode,
        build_name="build-name",
        slug="build-slug",
        commit_info=CommitInfo(
            repo=repo, target_branch="15.0", pr=None, git_commit="abcdef123456789"
        ),
        build_settings=build_settings
        or BuildSettings(image="ghcr.io/oca/oca-ci:py3.8-odoo15.0"),
    )
    with _render_kubefiles(settings.build_default_kubefiles_path, deployment_vars) as p:
        return yaml.safe_load((p / "kustomization.yaml").read_text())


def _literals(kustomization: Any, generator: str, name: str) -> list[str]:
    for g in kustomization.get(generator) or []:
        if g["name"] == name:
            return list(g.get("literals") or [])
    return []


def _names(kustomization: Any, generator: str) -> set[str]:
    return {g["name"] for g in kustomization.get(generator) or []}


def test_initialize_has_fetch_job_and_token_only_there(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(settings, "build_fetch_secret_env", {"GITHUB_TOKEN": "ghp_x"})
    k = _render(DeploymentMode.initialize)
    assert "fetch.yaml" in k["resources"]
    assert "GITHUB_TOKEN=ghp_x" in _literals(k, "secretGenerator", "fetchsecretenv")
    assert not any(
        lit.startswith("GITHUB_TOKEN=")
        for lit in _literals(k, "secretGenerator", "odoosecretenv")
    )
    nonce = _literals(k, "configMapGenerator", "initnonce")
    assert nonce and nonce[0].startswith("RUNBOAT_INIT_NONCE=")


def test_legacy_token_in_build_secret_env_moves_to_fetch(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Configuration older than the fetch job: the token must still not reach
    the pods that run the code."""
    monkeypatch.setattr(
        settings, "build_secret_env", {"PGPASSWORD": "pw", "GITHUB_TOKEN": "ghp_old"}
    )
    k = _render(DeploymentMode.initialize)
    assert _literals(k, "secretGenerator", "odoosecretenv") == ["PGPASSWORD=pw"]
    assert "GITHUB_TOKEN=ghp_old" in _literals(k, "secretGenerator", "fetchsecretenv")
    k = _render(DeploymentMode.deployment)
    assert _literals(k, "secretGenerator", "odoosecretenv") == ["PGPASSWORD=pw"]
    assert "fetchsecretenv" not in _names(k, "secretGenerator")


def test_not_isolated_has_no_policy_nor_auth() -> None:
    k = _render(DeploymentMode.deployment)
    assert "networkpolicy.yaml" not in k["resources"]
    assert "basicauth.yaml" not in k["resources"]
    assert "RUNBOAT_ISOLATED=0" in _literals(k, "configMapGenerator", "odooenv")


def test_isolated_deployment(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(settings, "isolated_repos", ["Acme/Addons"])
    monkeypatch.setattr(
        settings, "build_env", {"PGHOST": "10.0.0.30", "PGPORT": "5433"}
    )
    k = _render(DeploymentMode.deployment, repo="acme/addons")
    assert {"networkpolicy.yaml", "basicauth.yaml"} <= set(k["resources"])
    assert "RUNBOAT_ISOLATED=1" in _literals(k, "configMapGenerator", "odooenv")
    users = _literals(k, "secretGenerator", "basicauth")
    assert users == [
        "users=" + htpasswd_sha("runboat", settings.build_auth_password("acme/addons"))
    ]
    middlewares = [p for p in k["patches"] if "router.middlewares" in p["patch"]]
    assert {p["target"]["name"] for p in middlewares} == {"odoo", "mailhog"}
    assert all(
        "runboat-builds-build-name-basicauth@kubernetescrd" in p["patch"]
        for p in middlewares
    )


def test_isolated_policy_allows_only_postgres(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(settings, "isolated_repos", ["acme/addons"])
    monkeypatch.setattr(
        settings, "build_env", {"PGHOST": "10.0.0.30", "PGPORT": "5433"}
    )
    deployment_vars = make_deployment_vars(
        mode=DeploymentMode.test,
        build_name="build-name",
        slug="build-slug",
        commit_info=CommitInfo(
            repo="acme/addons", target_branch="15.0", pr=None, git_commit="abc"
        ),
        build_settings=BuildSettings(image="ghcr.io/oca/oca-ci:py3.8-odoo15.0"),
    )
    with _render_kubefiles(settings.build_default_kubefiles_path, deployment_vars) as p:
        policy = yaml.safe_load((p / "networkpolicy.yaml").read_text())
    assert policy["spec"]["policyTypes"] == ["Egress"]
    assert policy["spec"]["egress"] == [
        {
            "to": [{"ipBlock": {"cidr": "10.0.0.30/32"}}],
            "ports": [{"protocol": "TCP", "port": 5433}],
        }
    ]
    assert policy["spec"]["podSelector"]["matchExpressions"] == [
        {"key": "runboat/job-kind", "operator": "NotIn", "values": ["fetch"]}
    ]


def test_isolated_requires_pghost_ip(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(settings, "isolated_repos", ["acme/addons"])
    monkeypatch.setattr(settings, "build_env", {"PGHOST": "postgres.local"})
    with pytest.raises(ValueError):
        _render(DeploymentMode.deployment, repo="acme/addons")


def test_build_auth_password_per_repo() -> None:
    a = settings.build_auth_password("acme/addons")
    assert a == settings.build_auth_password("ACME/Addons")
    assert a != settings.build_auth_password("acme/other")
