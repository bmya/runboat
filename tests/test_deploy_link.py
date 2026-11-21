from test_db import _make_build

from runboat.settings import settings


def test_deploy_links_are_https() -> None:
    # Con un link http://, Chrome lo sube a HTTPS; si el build recién
    # arrancado tarda en responder (el registry se carga con el primer
    # request), cae a HTTP y muestra «Este sitio no admite una conexión
    # segura». Los builds se sirven con el wildcard TLS de Traefik.
    build = _make_build()
    assert build.deploy_link == f"https://{build.slug}.{settings.build_domain}"
    assert (
        build.deploy_link_mailhog
        == f"https://{build.slug}.mail.{settings.build_domain}"
    )
