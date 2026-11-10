from app import build_response


def test_healthz():
    assert build_response("/healthz", env={}) == (200, {"status": "ok"})


def test_root_reads_config_from_env():
    status, body = build_response(
        "/", env={"GREETING": "hola", "FEATURE_NEW_UI": "true", "APP_VERSION": "dev-1"}
    )
    assert status == 200
    assert body == {"greeting": "hola", "feature_new_ui": True, "version": "dev-1"}


def test_defaults_when_config_missing():
    _, body = build_response("/", env={})
    assert body["greeting"] == "hello"
    assert body["feature_new_ui"] is False


def test_unknown_path():
    assert build_response("/nope", env={})[0] == 404
