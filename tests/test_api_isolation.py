"""Builds of isolated repos: hidden from the public API, readable with the
repo's own build credentials or the admin's."""

from collections.abc import Iterator

import pytest
from fastapi.testclient import TestClient
from pytest_mock import MockerFixture
from test_db import _make_build

from runboat.app import app
from runboat.controller import controller
from runboat.settings import settings

client = TestClient(app)

ISOLATED = "acme/addons"


@pytest.fixture(autouse=True)
def _builds(mocker: MockerFixture, monkeypatch: pytest.MonkeyPatch) -> Iterator[None]:
    monkeypatch.setattr(settings, "isolated_repos", [ISOLATED])
    public = _make_build("public-build", repo="oca/mis-builder")
    private = _make_build("private-build", repo=ISOLATED)
    by_name = {b.name: b for b in (public, private)}
    mocker.patch.object(controller.db, "search", return_value=[public, private])

    async def get_build(name: str, db_only: bool = True) -> object:
        return by_name.get(name)

    mocker.patch.object(controller, "get_build", side_effect=get_build)
    mocker.patch("runboat.models.Build.init_log", return_value="the log")
    yield


def _auth_for(repo: str) -> tuple[str, str]:
    return ("runboat", settings.build_auth_password(repo))


def test_list_hides_isolated_builds() -> None:
    names = [b["name"] for b in client.get("/api/v1/builds").json()]
    assert names == ["public-build"]


def test_list_shows_them_to_their_repo_and_admin() -> None:
    for auth in (
        _auth_for(ISOLATED),
        (settings.api_admin_user, settings.api_admin_passwd),
    ):
        names = [b["name"] for b in client.get("/api/v1/builds", auth=auth).json()]
        assert names == ["public-build", "private-build"]


def test_other_repo_password_does_not_open_it() -> None:
    names = [
        b["name"]
        for b in client.get("/api/v1/builds", auth=_auth_for("acme/other")).json()
    ]
    assert names == ["public-build"]


@pytest.mark.parametrize(
    "method,path",
    [
        ("get", "/api/v1/builds/private-build"),
        ("get", "/api/v1/builds/private-build/init-log"),
        ("get", "/api/v1/builds/private-build/log"),
        ("get", "/api/v1/builds/private-build/test-log"),
        ("post", "/api/v1/builds/private-build/start"),
        ("post", "/api/v1/builds/private-build/stop"),
        ("post", "/api/v1/builds/private-build/reset"),
    ],
)
def test_isolated_build_endpoints_need_credentials(method: str, path: str) -> None:
    r = getattr(client, method)(path)
    assert r.status_code == 401
    assert r.headers["www-authenticate"] == "Basic"


def test_isolated_init_log_with_credentials() -> None:
    r = client.get("/api/v1/builds/private-build/init-log", auth=_auth_for(ISOLATED))
    assert r.status_code == 200


def test_public_build_stays_public() -> None:
    assert client.get("/api/v1/builds/public-build/init-log").status_code == 200


def test_pr_info_only_for_configured_repos() -> None:
    assert client.get("/api/v1/pr-info?repo=bmya/secret&pr=1").status_code == 404
