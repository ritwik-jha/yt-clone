"""Fast checks that need neither a server nor a database."""

import base64
import hashlib
import hmac

import pytest
from pydantic import ValidationError

from app import cache
from app.config import Settings
from app.crypto import secret_hash
from app.schemas import SaveVideoRequest, SignUpRequest, UpdateVideoRequest
from tests.support import seed_data


def test_secret_hash_matches_cognito_formula():
    expected = base64.b64encode(
        hmac.new(b"secret", b"a@b.comclient", hashlib.sha256).digest()
    ).decode()
    assert secret_hash("a@b.com", "client", "secret") == expected


def test_signup_lowercases_email_and_checks_strength():
    req = SignUpRequest(name="  Ann  ", email="Ann@Example.COM", password="Passw0rd!")
    assert (req.name, req.email) == ("Ann", "ann@example.com")
    with pytest.raises(ValidationError, match="special character"):
        SignUpRequest(name="Ann", email="a@b.com", password="Passw0rd1")


def test_update_request_rejects_null_title_but_clears_blank_description():
    assert UpdateVideoRequest(description="").description is None
    with pytest.raises(ValidationError):
        UpdateVideoRequest(title=None)


def test_save_request_uppercases_visibility():
    req = SaveVideoRequest(title="t", s3_key="k", thumbnail_s3_key="t", visibility="unlisted")
    assert req.visibility.value == "UNLISTED"


def test_database_url_replaces_db_settings(monkeypatch):
    for name in ("DATABASE_URL", "DB_HOST", "DB_NAME", "DB_USER"):
        monkeypatch.delenv(name, raising=False)
    Settings(database_url="sqlite:///x.db").require_database()
    with pytest.raises(RuntimeError, match="DB_HOST"):
        Settings(_env_file=None).require_database()


def test_seed_feed_is_public_completed_newest_first():
    assert [v.key for v in seed_data.FEED] == ["mountains", "guitar", "cooking", "timelapse"]


def test_cache_round_trip_with_fake_redis(monkeypatch):
    from tests.support.fakes import fake_redis
    from app.schemas import CreatorDetail, VideoDetail

    r = fake_redis()
    monkeypatch.setattr(cache, "redis_client", lambda: r)
    video = VideoDetail(
        id=seed_data.VIDEOS[0].id, title="t", thumbnail_url="https://x/t",
        views_count=3, created_at="2026-01-01T00:00:00Z", visibility="PUBLIC",
        status="COMPLETED",
        creator=CreatorDetail(id=seed_data.ALICE.id, name="A", created_at="2026-01-01T00:00:00Z"),
    )
    cache.put_video(video)
    assert cache.get_video(video.id) == video
    cache.drop_video(video.id)
    assert cache.get_video(video.id) is None
