"""Video read/update/delete and upload endpoints against seeded SQLite rows."""

import re
import uuid

import httpx
import pytest

from tests.support import seed_data

V = seed_data.VIDEOS_BY_KEY


def test_feed_lists_public_completed_newest_first(anon):
    body = anon.get("/video/feed", params={"limit": 50}).json()
    assert body["total"] == len(seed_data.FEED)
    assert [i["id"] for i in body["items"]] == [str(v.id) for v in seed_data.FEED]
    first = body["items"][0]
    assert first["creator"] == {"id": str(seed_data.ALICE.id), "name": seed_data.ALICE.name}
    assert first["thumbnail_url"].startswith("https://thumbs.test/thumbnails/")
    assert first["hls_url"] == f"/media/{seed_data.FEED[0].stem}/master.m3u8"


def test_feed_pagination_and_limits(anon):
    page2 = anon.get("/video/feed", params={"page": 2, "limit": 3}).json()
    assert [i["id"] for i in page2["items"]] == [str(seed_data.FEED[3].id)]
    assert anon.get("/video/feed", params={"page": 9, "limit": 3}).json()["items"] == []
    for bad in ({"limit": 51}, {"page": 0}, {"limit": "x"}):
        r = anon.get("/video/feed", params=bad)
        assert (r.status_code, r.json()["code"]) == (400, "validation_error")


@pytest.mark.parametrize("key, anon_status", [
    ("mountains", 200), ("drafts", 200), ("diary", 404), ("rendering", 404), ("broken", 404),
])
def test_detail_visibility_rules(anon, alice, bob, key, anon_status):
    path = f"/video/{V[key].id}"
    owner, other = (alice, bob) if V[key].owner == "alice" else (bob, alice)
    assert anon.get(path).status_code == anon_status
    assert other.get(path).status_code == anon_status  # a non-owner sees what anyone sees
    detail = owner.get(path).json()
    assert (detail["status"], detail["visibility"]) == (V[key].status.value, V[key].visibility.value)


def test_detail_unknown_and_malformed_ids(anon):
    r = anon.get(f"/video/{uuid.uuid4()}")
    assert (r.status_code, r.json()["code"]) == (404, "video_not_found")
    assert anon.get("/video/not-a-uuid").status_code == 400


def test_my_videos_needs_auth_and_is_per_user(anon, alice, bob):
    assert anon.get("/video/mine").status_code == 401
    mine = alice.get("/video/mine", params={"limit": 50}).json()
    expected = sorted((v for v in seed_data.VIDEOS if v.owner == "alice"),
                      key=lambda v: v.created_at, reverse=True)
    assert [i["id"] for i in mine["items"]] == [str(v.id) for v in expected]
    assert bob.get("/video/mine").json()["total"] == sum(v.owner == "bob" for v in seed_data.VIDEOS)


def test_progress(anon, alice):
    assert anon.get(f"/video/{V['guitar'].id}/progress").json()["percent"] == 100
    r = alice.get(f"/video/{V['rendering'].id}/progress").json()
    assert (r["percent"], r["status"]) == (0, "PROCESSING")


def test_view_counting(anon, alice):
    def views() -> int:
        items = anon.get("/video/feed", params={"limit": 50}).json()["items"]
        return next(i["views_count"] for i in items if i["id"] == str(V["timelapse"].id))

    before = views()
    assert anon.post(f"/video/{V['timelapse'].id}/view").status_code == 204
    assert anon.post(f"/video/{V['timelapse'].id}/view").status_code == 204
    assert views() == before + 2
    r = alice.post(f"/video/{V['rendering'].id}/view")
    assert (r.status_code, r.json()["code"]) == (409, "video_not_ready")


def test_owner_edits_and_cache_is_dropped(anon, alice, bob):
    vid = V["cooking"].id
    assert anon.get(f"/video/{vid}").json()["title"] == V["cooking"].title  # now cached
    r = alice.patch(f"/video/{vid}", json={"title": "  Dal tadka, revised  ", "description": ""})
    assert r.status_code == 200
    assert (r.json()["title"], r.json()["description"]) == ("Dal tadka, revised", None)
    assert anon.get(f"/video/{vid}").json()["title"] == "Dal tadka, revised"

    assert bob.patch(f"/video/{vid}", json={"title": "hijack"}).status_code == 404
    assert alice.patch(f"/video/{vid}", json={"title": None}).status_code == 400
    assert alice.patch(f"/video/{vid}", json={"visibility": "secret"}).status_code == 400

    assert alice.patch(f"/video/{vid}", json={"visibility": "private"}).json()["visibility"] == "PRIVATE"
    feed_ids = [i["id"] for i in anon.get("/video/feed", params={"limit": 50}).json()["items"]]
    assert str(vid) not in feed_ids
    assert anon.get(f"/video/{vid}").status_code == 404
    # Put the seeded row back for the tests that follow.
    restore = {"title": V["cooking"].title, "description": "Seeded test video 'cooking'.", "visibility": "PUBLIC"}
    assert alice.patch(f"/video/{vid}", json=restore).status_code == 200


def test_upload_save_and_delete(alice, bob, anon):
    assert anon.get("/upload/video/url").status_code == 401
    up = alice.get("/upload/video/url").json()
    assert re.fullmatch(rf"videos/{seed_data.ALICE.sub}/[0-9a-f-]{{36}}\.mp4", up["video_id"])
    assert f"/test-raw/{up['video_id']}?" in up["url"]
    thumb_up = alice.get("/upload/video/url/thumbnail").json()
    thumb = thumb_up["thumbnail_id"]

    # The browser PUTs straight to the presigned URL, cross-origin, with the
    # Content-Type it was signed for; any other type is refused like S3 does.
    with httpx.Client(timeout=10) as browser:
        origin = {"Origin": "http://127.0.0.1:8090"}
        pre = browser.options(up["url"], headers={
            **origin, "Access-Control-Request-Method": "PUT",
            "Access-Control-Request-Headers": "content-type",
        })
        assert pre.status_code == 200
        r = browser.put(up["url"], content=b"\0" * 2048,
                        headers={**origin, "Content-Type": "video/mp4"})
        assert r.status_code == 200 and r.headers["etag"]
        assert browser.put(thumb_up["url"], content=b"jpg",
                           headers={"Content-Type": "image/png"}).status_code == 403
        assert browser.put(thumb_up["url"], content=b"jpg",
                           headers={"Content-Type": "image/jpeg"}).status_code == 200
        stored = browser.get(up["url"])
        assert (stored.headers["content-type"], stored.headers["x-size"]) == ("video/mp4", "2048")

    body = {"title": "Fresh upload", "description": "hi", "s3_key": up["video_id"],
            "thumbnail_s3_key": thumb, "visibility": "public"}
    r = bob.post("/upload/video/save", json=body)  # keys were minted for alice
    assert (r.status_code, r.json()["code"]) == (400, "invalid_s3_key")
    r = alice.post("/upload/video/save", json=body)
    assert r.status_code == 201
    saved = r.json()
    assert (saved["status"], saved["visibility"]) == ("PENDING", "PUBLIC")
    r = alice.post("/upload/video/save", json=body)
    assert (r.status_code, r.json()["code"]) == (409, "already_saved")

    mine = alice.get("/video/mine").json()
    assert mine["items"][0]["id"] == saved["id"]  # newest first
    assert anon.get(f"/video/{saved['id']}").status_code == 404  # still PENDING

    assert bob.delete(f"/video/{saved['id']}").status_code == 404
    assert alice.delete(f"/video/{saved['id']}").status_code == 204
    assert alice.get(f"/video/{saved['id']}").status_code == 404
    assert alice.delete(f"/video/{saved['id']}").status_code == 404


def test_cors_allows_the_web_app_with_credentials(anon):
    r = anon.options("/auth/login", headers={
        "Origin": "http://127.0.0.1:8090",
        "Access-Control-Request-Method": "POST",
        "Access-Control-Request-Headers": "content-type",
    })
    assert r.status_code == 200
    assert r.headers["access-control-allow-origin"] == "http://127.0.0.1:8090"
    assert r.headers["access-control-allow-credentials"] == "true"


def test_cors_rejects_origins_not_listed(anon):
    r = anon.options("/video/feed", headers={
        "Origin": "https://evil.example",
        "Access-Control-Request-Method": "GET",
    })
    assert r.status_code == 400
    assert "access-control-allow-origin" not in r.headers
    r = anon.get("/video/feed", headers={"Origin": "https://evil.example"})
    assert "access-control-allow-origin" not in r.headers


def test_feed_sorted_by_popularity(anon):
    items = anon.get("/video/feed", params={"limit": 50, "sort": "popular"}).json()["items"]
    expected = sorted(seed_data.FEED, key=lambda v: (v.views, v.created_at), reverse=True)
    assert [i["id"] for i in items] == [str(v.id) for v in expected]
    r = anon.get("/video/feed", params={"sort": "random"})
    assert (r.status_code, r.json()["code"]) == (400, "validation_error")


def test_search_matches_listed_videos_only(anon, alice):
    def titles(q, **params):
        r = anon.get("/video/search", params={"q": q, "limit": 50, **params})
        assert r.status_code == 200, r.text
        return [i["title"] for i in r.json()["items"]]

    assert titles("GUITAR") == ["Fingerstyle guitar basics"]
    # Every word must match, in the title or the description.
    assert titles("guitar basics") == ["Fingerstyle guitar basics"]
    assert titles("guitar night") == []
    assert titles("seeded 'guitar'") == ["Fingerstyle guitar basics"]
    # Description matches count; newest first like the feed.
    assert titles("seeded") == [v.title for v in seed_data.FEED]
    # Unlisted, private, and unfinished videos never show, even to the owner.
    for hidden in ("behind the scenes", "diary", "transcoding"):
        assert titles(hidden) == []
        assert alice.get("/video/search", params={"q": hidden}).json()["total"] == 0
    # LIKE wildcards are literal.
    assert titles("%") == []
    assert titles("_") == []
    for bad in ("", "x" * 101):
        r = anon.get("/video/search", params={"q": bad})
        assert (r.status_code, r.json()["code"]) == (400, "validation_error")
    r = anon.get("/video/search", params={"q": "   "})
    assert (r.status_code, r.json()["code"]) == (400, "empty_query")


def test_channel_lists_a_creators_listed_videos(anon, alice):
    r = anon.get(f"/video/channel/{seed_data.ALICE.id}", params={"limit": 50})
    assert r.status_code == 200
    body = r.json()
    assert body["creator"]["id"] == str(seed_data.ALICE.id)
    assert body["creator"]["name"] == seed_data.ALICE.name
    assert "email" not in body["creator"]
    listed = [v for v in seed_data.FEED if v.owner == "alice"]
    assert body["total"] == len(listed)
    assert [i["id"] for i in body["items"]] == [str(v.id) for v in listed]
    # The owner gets the same public view; their other videos are in /mine.
    assert alice.get(f"/video/channel/{seed_data.ALICE.id}", params={"limit": 50}).json() == body

    page = anon.get(f"/video/channel/{seed_data.ALICE.id}", params={"limit": 1, "page": 2}).json()
    assert [i["id"] for i in page["items"]] == [str(listed[1].id)]

    empty = anon.get(f"/video/channel/{seed_data.CAROL.id}").json()
    assert (empty["total"], empty["items"]) == (0, [])
    r = anon.get(f"/video/channel/{uuid.uuid4()}")
    assert (r.status_code, r.json()["code"]) == (404, "channel_not_found")
