#!/usr/bin/env python3
"""Integration test for a deployed stack, run through the web app's URL.

Everything goes through the frontend origin, the way the browser does it:
the static app, the API behind the frontend's nginx proxy, the auth cookies,
presigned uploads to S3, the transcoding pipeline, and playback from
CloudFront. It creates a throwaway account and video and removes both at the
end (unless --keep).

    python3 scripts/deploy_smoke_test.py https://<frontend> \
        --user-pool-id <pool> --region <region> [--browser]

Confirming the sign-up: real Cognito emails a code, so by default the test
confirms the account with `AdminConfirmSignUp` (needs boto3 and AWS
credentials). Against the local test server pass --otp 123456 instead.

Options:
  --skip-transcode  stop after the upload is saved (no pipeline locally)
  --keep            leave the test video and account in place
  --browser         also load the app in headless Chromium (needs the
                    `playwright` Python package and its Chromium)
  --chromium PATH   browser binary for --browser instead of Playwright's own
  --artifacts DIR   where screenshots and the JSON report go

Needs: python3 with httpx (backend/requirements-dev.txt), ffmpeg.
Exits non-zero on the first failed check.
"""

from __future__ import annotations

import argparse
import json
import secrets
import shutil
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urljoin, urlparse

import httpx

RESULTS: list[dict] = []


class CheckFailed(Exception):
    pass


def check(name: str, ok: bool, detail: str = "") -> None:
    RESULTS.append({"check": name, "ok": bool(ok), "detail": detail})
    mark = "\033[32mPASS\033[0m" if ok else "\033[31mFAIL\033[0m"
    print(f"  {mark} {name}" + (f" ({detail})" if detail else ""), flush=True)
    if not ok:
        raise CheckFailed(name)


def expect(r: httpx.Response, status: int, name: str) -> httpx.Response:
    detail = f"HTTP {r.status_code}"
    if r.status_code != status:
        detail += f": {r.text[:300]}"
    check(name, r.status_code == status, detail)
    return r


def section(title: str) -> None:
    print(f"\n== {title}", flush=True)


def make_media(workdir: Path) -> tuple[Path, Path]:
    """A 6-second H.264/AAC MP4 and a JPEG thumbnail, made with ffmpeg."""
    if not shutil.which("ffmpeg"):
        raise SystemExit("ffmpeg is required to make the test video")
    video = workdir / "smoke.mp4"
    thumb = workdir / "smoke.jpg"
    subprocess.run(
        ["ffmpeg", "-loglevel", "error", "-y",
         "-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=30",
         "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
         "-t", "6", "-c:v", "libx264", "-pix_fmt", "yuv420p",
         "-c:a", "aac", "-movflags", "+faststart", str(video)],
        check=True,
    )
    subprocess.run(
        ["ffmpeg", "-loglevel", "error", "-y", "-i", str(video),
         "-frames:v", "1", "-vf", "scale=640:-2", str(thumb)],
        check=True,
    )
    return video, thumb


def confirm_with_cognito(pool_id: str, region: str, email: str) -> None:
    import boto3  # only needed for real Cognito

    boto3.client("cognito-idp", region_name=region).admin_confirm_sign_up(
        UserPoolId=pool_id, Username=email
    )


def delete_cognito_user(pool_id: str, region: str, email: str) -> None:
    import boto3

    boto3.client("cognito-idp", region_name=region).admin_delete_user(
        UserPoolId=pool_id, Username=email
    )


def static_checks(web: httpx.Client) -> None:
    section("Static app")
    r = expect(web.get("/_health"), 200, "container health check /_health")
    r = expect(web.get("/"), 200, "GET / serves the app")
    check("index.html boots Flutter", "flutter_bootstrap.js" in r.text)
    r = expect(web.get("/watch", params={"v": "00000000-0000-0000-0000-000000000000"}),
               200, "deep link /watch falls back to index.html")
    check("deep link body is the app", "flutter_bootstrap.js" in r.text)
    for path in ("/upload", "/channel/00000000-0000-0000-0000-000000000000/videos"):
        r = expect(web.get(path), 200, f"app route {path} is the app, not the API")
        check(f"{path} body is the app", "flutter_bootstrap.js" in r.text)
    expect(web.get("/main.dart.js"), 200, "main.dart.js")
    for path in ("/vendor/hls.js-1.5.20/hls.min.js", "/vendor/dashjs-4.7.4/dash.all.min.js"):
        r = expect(web.get(path), 200, f"player library {path}")
        check(f"{path} is JavaScript", "javascript" in r.headers.get("content-type", ""))


def api_checks(web: httpx.Client) -> None:
    section("API through the frontend origin")
    r = expect(web.get("/healthz"), 200, "GET /healthz (proxied)")
    check("API reports ok", r.json().get("status") == "ok", r.text[:100])
    r = expect(web.get("/video/feed", params={"limit": 5}), 200, "GET /video/feed")
    check("feed is JSON with items", isinstance(r.json().get("items"), list))
    expect(web.get("/video/feed", params={"sort": "popular", "limit": 5}), 200,
           "GET /video/feed?sort=popular")
    expect(web.get("/video/search", params={"q": "zz-no-such-video"}), 200, "GET /video/search")
    expect(web.get("/auth/me"), 401, "GET /auth/me without cookies is 401")
    # nginx answers an unproxied path with index.html (200), so a JSON 401
    # proves /history reaches the API.
    r = expect(web.get("/history"), 401, "GET /history without cookies is 401 (proxied)")
    check("/history answers JSON missing_access_token",
          r.headers.get("content-type", "").startswith("application/json")
          and r.json().get("code") == "missing_access_token", r.text[:100])


def browser_checks(url: str, artifacts: Path, video_id: str | None, playable: bool,
                   chromium: str | None) -> None:
    section("Browser (headless Chromium)")
    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        raise SystemExit("--browser needs: pip install playwright && python -m playwright install chromium")

    errors: list[str] = []
    with sync_playwright() as p:
        browser = p.chromium.launch(executable_path=chromium)
        page = browser.new_page(viewport={"width": 1440, "height": 900})
        page.on("pageerror", lambda e: errors.append(str(e)))

        with page.expect_response(lambda r: "/video/feed" in r.url, timeout=90_000) as feed:
            page.goto(url, wait_until="load")
        check("home page loads the feed", feed.value.status == 200, f"HTTP {feed.value.status}")
        page.wait_for_selector("flutter-view, flt-glass-pane", state="attached", timeout=60_000)
        page.wait_for_timeout(3000)
        page.screenshot(path=str(artifacts / "home.png"))
        check("Flutter app rendered", True, str(artifacts / "home.png"))

        if video_id and playable:
            with page.expect_response(lambda r: r.url.endswith("master.m3u8"), timeout=90_000) as hls:
                page.goto(urljoin(url, f"/watch?v={video_id}"), wait_until="load")
            check("watch page fetches the HLS playlist from CloudFront",
                  hls.value.status == 200, f"HTTP {hls.value.status}")
            page.wait_for_timeout(5000)
            page.screenshot(path=str(artifacts / "watch.png"))
        browser.close()
    check("no uncaught page errors", not errors, "; ".join(errors)[:300])


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("url", help="frontend URL, e.g. https://xxxx.ecs.ap-south-1.on.aws")
    ap.add_argument("--user-pool-id")
    ap.add_argument("--region")
    ap.add_argument("--otp", help="verification code (local test server: 123456)")
    ap.add_argument("--skip-transcode", action="store_true")
    ap.add_argument("--keep", action="store_true")
    ap.add_argument("--browser", action="store_true")
    ap.add_argument("--transcode-timeout", type=int, default=900, help="seconds (default 900)")
    ap.add_argument("--artifacts", default="deploy-artifacts")
    ap.add_argument("--chromium", help="Chromium/Chrome binary for --browser (default: Playwright's)")
    args = ap.parse_args()
    if not args.otp and not (args.user_pool_id and args.region):
        ap.error("pass --user-pool-id and --region (real Cognito) or --otp (local)")

    url = args.url.rstrip("/")
    origin = "{0.scheme}://{0.netloc}".format(urlparse(url))
    https = url.startswith("https://")
    artifacts = Path(args.artifacts)
    artifacts.mkdir(parents=True, exist_ok=True)

    stamp = time.strftime("%Y%m%d%H%M%S") + secrets.token_hex(2)
    email = f"deploy-smoke+{stamp}@example.com"
    password = f"Sm0ke-{secrets.token_hex(6)}Aa!"
    title = f"Deploy smoke {stamp}"

    web = httpx.Client(base_url=url, timeout=30, follow_redirects=False)
    cdn = httpx.Client(timeout=30, headers={"Origin": origin})
    video_id: str | None = None
    signed_up = False
    playable = False
    started = time.time()
    try:
        static_checks(web)
        api_checks(web)

        section("Sign up, confirm, sign in")
        expect(web.post("/auth/signup", json={"name": "Deploy Smoke", "email": email,
                                               "password": password}), 200, "POST /auth/signup")
        signed_up = True
        if args.otp:
            expect(web.post("/auth/verify-otp", json={"email": email, "otp": args.otp}),
                   200, "POST /auth/verify-otp")
        else:
            confirm_with_cognito(args.user_pool_id, args.region, email)
            check("AdminConfirmSignUp", True)
        r = expect(web.post("/auth/login", json={"email": email, "password": password}),
                   200, "POST /auth/login")
        # Login also clears the legacy /auth/refresh cookie (Max-Age=0);
        # keep only the cookies it sets.
        cookies = {c.split("=", 1)[0]: c.lower() for c in r.headers.get_list("set-cookie")
                   if "max-age=0" not in c.lower()}
        check("access_token cookie set", "access_token" in cookies)
        refresh_attrs = [a.strip() for a in cookies.get("refresh_token", "").split(";")]
        check("refresh_token cookie scoped to /auth", "path=/auth" in refresh_attrs)
        check("auth cookies are HttpOnly",
              all("httponly" in v for k, v in cookies.items() if k in ("access_token", "refresh_token")))
        if https:
            check("auth cookies are Secure",
                  all("secure" in v for k, v in cookies.items() if k in ("access_token", "refresh_token")))
        check("cookies are host-only (no Domain)", not any("domain=" in v for v in cookies.values()))
        me = expect(web.get("/auth/me"), 200, "GET /auth/me with cookies").json()
        check("/auth/me is the new account", me.get("email") == email)
        expect(web.post("/auth/refresh"), 200, "POST /auth/refresh")

        section("Upload")
        with tempfile.TemporaryDirectory() as tmp:
            video, thumb = make_media(Path(tmp))
            vurl = expect(web.get("/upload/video/url"), 200, "GET /upload/video/url").json()
            turl = expect(web.get("/upload/video/url/thumbnail"), 200,
                          "GET /upload/video/url/thumbnail").json()
            pre = cdn.options(vurl["url"], headers={
                "Access-Control-Request-Method": "PUT",
                "Access-Control-Request-Headers": "content-type",
            })
            check("raw bucket allows the browser's CORS preflight",
                  pre.status_code == 200 and pre.headers.get("access-control-allow-origin") in ("*", origin),
                  f"HTTP {pre.status_code}")
            r = cdn.put(vurl["url"], content=video.read_bytes(),
                        headers={"Content-Type": "video/mp4"}, timeout=300)
            expect(r, 200, f"PUT video to S3 ({video.stat().st_size} bytes)")
            r = cdn.put(turl["url"], content=thumb.read_bytes(), headers={"Content-Type": "image/jpeg"})
            expect(r, 200, "PUT thumbnail to S3")
        saved = expect(web.post("/upload/video/save", json={
            "title": title, "description": "Created by scripts/deploy_smoke_test.py",
            "s3_key": vurl["video_id"], "thumbnail_s3_key": turl["thumbnail_id"],
            "visibility": "PUBLIC",
        }), 201, "POST /upload/video/save").json()
        video_id = saved["id"]
        check("saved video starts PENDING", saved.get("status") == "PENDING", saved.get("status", ""))
        mine = expect(web.get("/video/mine"), 200, "GET /video/mine").json()
        check("Your videos lists it", any(v["id"] == video_id for v in mine["items"]))

        if not args.skip_transcode:
            section("Transcode (S3 -> SQS -> Lambda -> Fargate -> SQS -> poller)")
            deadline = time.time() + args.transcode_timeout
            last = None
            while True:
                p = expect(web.get(f"/video/{video_id}/progress"), 200, "progress") if last is None \
                    else web.get(f"/video/{video_id}/progress")
                body = p.json() if p.status_code == 200 else {}
                state = (body.get("status"), body.get("percent"))
                if state != last:
                    print(f"     status={state[0]} percent={state[1]}", flush=True)
                    last = state
                if body.get("status") in ("COMPLETED", "FAILED") or time.time() > deadline:
                    break
                time.sleep(10)
            check("transcode COMPLETED", body.get("status") == "COMPLETED",
                  f"status={body.get('status')} after {int(time.time() - started)}s")

            section("Playback")
            d = expect(web.get(f"/video/{video_id}"), 200, "GET /video/{id}").json()
            check("hls_url, manifest_url and duration set",
                  bool(d.get("hls_url") and d.get("manifest_url") and d.get("duration_seconds")),
                  f"duration={d.get('duration_seconds')}")
            r = expect(cdn.get(d["hls_url"]), 200, "HLS master playlist from CloudFront")
            check("master playlist is HLS", r.text.startswith("#EXTM3U"))
            check("CloudFront adds CORS to playlists", "access-control-allow-origin" in r.headers)
            media = next(l for l in r.text.splitlines() if l and not l.startswith("#"))
            r = expect(cdn.get(urljoin(d["hls_url"], media)), 200, f"media playlist {media}")
            seg = next(l for l in r.text.splitlines() if l and not l.startswith("#"))
            expect(cdn.get(urljoin(urljoin(d["hls_url"], media), seg)), 200, f"first segment {seg}")
            r = expect(cdn.get(d["manifest_url"]), 200, "DASH manifest from CloudFront")
            check("manifest is DASH", "<MPD" in r.text)
            r = expect(cdn.get(d["thumbnail_url"]), 200, "thumbnail from its CloudFront")
            check("thumbnail is an image", r.headers.get("content-type", "").startswith("image/"))
            playable = True

            section("Listings")
            feed = expect(web.get("/video/feed", params={"limit": 50}), 200, "GET /video/feed").json()
            check("feed lists the new video", any(v["id"] == video_id for v in feed["items"]))
            s = expect(web.get("/video/search", params={"q": stamp}), 200, "GET /video/search").json()
            check("search finds it by title", any(v["id"] == video_id for v in s["items"]))
            ch = expect(web.get(f"/video/channel/{me['id']}"), 200, "GET /video/channel/{user}").json()
            check("channel lists it", any(v["id"] == video_id for v in ch["items"]))
            expect(web.post(f"/video/{video_id}/view"), 204, "POST /video/{id}/view")

        r = expect(web.patch(f"/video/{video_id}", json={"title": title + " (edited)"}),
                   200, "PATCH /video/{id}")
        check("title updated", r.json().get("title") == title + " (edited)")

        section("Watch history")
        h = expect(web.get("/history"), 200, "GET /history").json()
        check("a new account has no history", h.get("items") == [], json.dumps(h)[:100])
        if playable:
            watched = datetime.now(timezone.utc).isoformat()
            r = expect(web.post("/history/progress", json={"entries": [
                {"video_id": video_id, "position_seconds": 1, "watched_at": watched},
            ]}), 200, "POST /history/progress").json()
            check("progress saved", r["results"][0]["result"] == "saved", json.dumps(r)[:200])
            h = expect(web.get("/history"), 200, "GET /history").json()
            check("history lists the video", [i["video"]["id"] for i in h["items"]] == [video_id])
            expect(web.delete("/history"), 204, "DELETE /history")
            h = expect(web.get("/history"), 200, "GET /history").json()
            check("cleared history is empty", h.get("items") == [])

        if args.browser:
            browser_checks(url, artifacts, video_id, playable, args.chromium)
        ok = True
    except CheckFailed:
        ok = False
    finally:
        if not args.keep:
            section("Cleanup")
            if video_id:
                r = web.delete(f"/video/{video_id}")
                print(f"  DELETE /video/{video_id}: HTTP {r.status_code}")
            web.post("/auth/logout")
            if signed_up and args.user_pool_id and args.region:
                try:
                    delete_cognito_user(args.user_pool_id, args.region, email)
                    print(f"  deleted Cognito user {email} (its users row stays: there is no API to remove it)")
                except Exception as e:  # cleanup must not hide the result
                    print(f"  could not delete Cognito user {email}: {e}")
        web.close()
        cdn.close()

    passed = sum(r["ok"] for r in RESULTS)
    report = {"url": url, "ok": ok, "passed": passed, "total": len(RESULTS),
              "seconds": int(time.time() - started), "video_id": video_id,
              "kept": args.keep, "checks": RESULTS}
    (artifacts / "smoke-report.json").write_text(json.dumps(report, indent=2))
    print(f"\n{'PASSED' if ok else 'FAILED'}: {passed}/{len(RESULTS)} checks in "
          f"{report['seconds']}s. Report: {artifacts / 'smoke-report.json'}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
