import secrets

from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPBasic, HTTPBasicCredentials

from .settings import BUILD_AUTH_USER, settings

security = HTTPBasic()


def authenticated(credentials: HTTPBasicCredentials = Depends(security)) -> None:
    correct_username = secrets.compare_digest(
        credentials.username,
        settings.api_admin_user,
    )
    correct_password = secrets.compare_digest(
        credentials.password,
        settings.api_admin_passwd,
    )
    if not (correct_username and correct_password):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Incorrect user name or password",
            headers={"WWW-Authenticate": "Basic"},
        )


optional_security = HTTPBasic(auto_error=False)


def _is_admin(credentials: HTTPBasicCredentials | None) -> bool:
    if credentials is None:
        return False
    return secrets.compare_digest(
        credentials.username, settings.api_admin_user
    ) and secrets.compare_digest(credentials.password, settings.api_admin_passwd)


def can_see_repo(repo: str, credentials: HTTPBasicCredentials | None) -> bool:
    """Isolated repos are visible to the admin and to their own build user
    (BUILD_AUTH_USER + Settings.build_auth_password); every other repo to anyone."""
    if not settings.is_isolated(repo):
        return True
    if _is_admin(credentials):
        return True
    return (
        credentials is not None
        and secrets.compare_digest(credentials.username, BUILD_AUTH_USER)
        and secrets.compare_digest(
            credentials.password, settings.build_auth_password(repo)
        )
    )


def viewer(
    credentials: HTTPBasicCredentials | None = Depends(optional_security),
) -> HTTPBasicCredentials | None:
    return credentials
