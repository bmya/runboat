import asyncio

import pytest
from pytest_mock import MockerFixture

from runboat.controller import Controller
from runboat.github import CommitInfo


@pytest.mark.asyncio
async def test_deploy_commit_dedups_concurrent_same_commit(
    mocker: MockerFixture,
) -> None:
    """Two near-simultaneous events for the same commit (GitHub retry, or
    upstream-fanout landing next to a push) must create exactly ONE build.

    The deployment_watcher lags behind Build.deploy, so the in-memory db is
    still empty when the second event arrives; the in-flight slug guard is what
    prevents the duplicate.
    """
    ctrl = Controller()
    deploy = mocker.patch(
        "runboat.controller.Build.deploy", new=mocker.AsyncMock()
    )
    commit_info = CommitInfo(
        repo="oca/mis-builder",
        target_branch="15.0",
        pr=None,
        git_commit="abcde",
    )

    await asyncio.gather(
        ctrl.deploy_commit(commit_info),
        ctrl.deploy_commit(commit_info),
    )

    deploy.assert_called_once_with(commit_info)
