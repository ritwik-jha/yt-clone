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
    from datetime import datetime, timezone

    from app.config import get_settings
    from app.models import User, Video, VideoStatus, Visibility
    from tests.support.fakes import fake_redis

    r = fake_redis()
    monkeypatch.setattr(cache, "redis_client", lambda: r)
    monkeypatch.setattr(get_settings(), "thumbnails_cdn_domain", "thumbs.test")
    monkeypatch.setattr(get_settings(), "media_base_url", "/media")
    at = datetime(2026, 1, 1, tzinfo=timezone.utc)
    video = Video(
        id=seed_data.VIDEOS[0].id, title="t", thumbnail_s3_key="thumbnails/t",
        dash_manifest_s3_key="v/dash/manifest.mpd", hls_manifest_s3_key="v/dash/master.m3u8",
        views_count=3, created_at=at, visibility=Visibility.PUBLIC, status=VideoStatus.COMPLETED,
        user=User(id=seed_data.ALICE.id, name="A", created_at=at),
    )
    cache.put_video(video)
    cached = cache.get_video(video.id)
    assert (cached.thumbnail_url, cached.manifest_url, cached.hls_url) == (
        "https://thumbs.test/thumbnails/t", "/media/v/dash/manifest.mpd", "/media/v/dash/master.m3u8",
    )
    # URLs are built on read: a new media base applies to cached entries.
    monkeypatch.setattr(get_settings(), "media_base_url", "https://cdn.example/m")
    assert cache.get_video(video.id).hls_url == "https://cdn.example/m/v/dash/master.m3u8"
    cache.drop_video(video.id)
    assert cache.get_video(video.id) is None


def test_cache_entries_in_the_old_url_form_miss(monkeypatch):
    from tests.support.fakes import fake_redis

    r = fake_redis()
    monkeypatch.setattr(cache, "redis_client", lambda: r)
    video_id = seed_data.VIDEOS[0].id
    r.hset(cache._key(video_id), mapping={"id": str(video_id), "manifest_url": "https://old/x"})
    assert cache.get_video(video_id) is None
