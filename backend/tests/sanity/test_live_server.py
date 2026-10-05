"""Health of the backend started by the pipeline (needs API_BASE_URL)."""

from tests.support import seed_data


def test_healthz(anon):
    r = anon.get("/healthz")
    assert r.status_code == 200 and r.json() == {"status": "ok"}


def test_live_server_reads_the_seeded_database(anon):
    body = anon.get("/video/feed", params={"limit": 50}).json()
    assert body["total"] == len(seed_data.FEED)
    assert [i["title"] for i in body["items"]] == [v.title for v in seed_data.FEED]
