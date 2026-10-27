# Private media delivery: signed cookies on one edge distribution

Status: built (`feature/signed-media-access`). This records why the streams
are delivered the way they are, and what that does and doesn't protect.

## 1. The problem

The processed bucket was already private: CloudFront read it through Origin
Access Control. But the playback distribution in front of it served any URL
to anyone. Video paths are random UUIDs, so nobody could guess them, but a
URL that leaked kept working:

- **Private videos.** The API hides a PRIVATE video from everyone but its
  owner (404), yet its stream URL played for anyone who had it: shared
  before it went private, or left in a browser history or a log.
- **Deleted videos** played until the edge cache expired.
- **Hotlinking.** Another site could embed the streams, and this project
  would pay for the bandwidth.

## 2. Options considered

| Option | Verdict |
|---|---|
| CloudFront signed URLs | A signature in the manifest's query string doesn't reach the segments, which players fetch by URLs relative to the manifest. It would need every playlist rewritten. |
| **CloudFront signed cookies** | **Chosen.** The browser sends them with every manifest and segment request. URLs don't change, so the API's Redis cache and CloudFront's cache are unaffected. |
| Own token check at the edge (CloudFront Functions or Lambda@Edge) | More flexible (e.g. bound to a user), but it's own crypto code to maintain for what signed cookies already do. |
| Referer or origin checks (WAF) | Easy to fake. Only useful as an extra layer. |
| DRM (Widevine, FairPlay, PlayReady) | The only defence against someone allowed to watch saving the video. It needs a licence service, transcoder changes and EME in the player. A non-goal until there is paid content. |

The API can only set cookies for its own site. Two ways to share a site with
the media:

- **A. One CloudFront distribution in front of everything** (built): the
  default behaviour goes to the web app's ALB (nginx, which proxies the API),
  and `/media/*` goes to the processed bucket. Everything is same-origin: no
  CORS, no custom domain, and the players need no credentials settings.
- B. A custom domain with `app.` and `media.` subdomains and cookies on the
  parent domain. That needs a certificate, credentialed CORS, and
  `withCredentials` in the players. Kept as the path for when the project
  gets a domain.

## 3. How it works

```
Browser ── https://<edge>.cloudfront.net ──► edge distribution (frontend/terraform/cloudfront.tf)
   │                                          ├─ /*        → ALB → nginx → app / API   (not cached)
   │                                          └─ /media/*  → viewer-request function
   │                                                         → signed-cookie check (backend's key group)
   │                                                         → S3 processed (OAC, cached)
   │
   ├─ GET  /video/{id}            hls_url = "/media/<id>/dash/master.m3u8"
   ├─ POST /video/{id}/playback   Set-Cookie: CloudFront-Policy / -Signature / -Key-Pair-Id
   │                              Path=/media/<id>/dash/; HttpOnly; Secure; Max-Age=3600
   └─ GET  /media/<id>/dash/...   with the cookies → 200 (without → 403)
```

- **Who gets cookies.** `POST /video/{id}/playback` runs the same visibility
  check as `GET /video/{id}`: anyone for PUBLIC and UNLISTED videos (signed
  in or not), only the owner for PRIVATE ones. The cookies are for the
  folder holding the video's manifests and segments, for
  `MEDIA_COOKIE_TTL_SECONDS` (an hour). The cookie `Path` is the same
  folder, so tabs playing different videos keep separate cookies.
- **Signing** (`backend/app/media_signing.py`). This is a CloudFront custom
  policy, `{"Statement":[{"Resource":"https://*/<folder>/*","Condition":{"DateLessThan":{"AWS:EpochTime":…}}}]}`,
  signed with RSA-SHA1 and base64-encoded in CloudFront's URL-safe alphabet.
- **Why the host is a wildcard, and the edge function.** The API sits behind
  nginx and the distribution and never learns the domain the viewer used, so
  the Resource can't name it. A `*` in a policy matches `/` too, so
  `https://*/<folder>/*` would also match
  `/media/<other>/master.m3u8?/<folder>/x`. The viewer-request function
  (`frontend/terraform/media-viewer-request.js`) therefore refuses (400):
  - any query string;
  - any path outside `[A-Za-z0-9._-/]` (`%` included);
  - dot segments.

  What still matches can only reach keys that contain `/<folder>/` after
  another video's prefix, and the transcoder writes none. The function then
  strips `/media`. The policy matches the path with and without `/media`, so
  it doesn't matter whether CloudFront checks the cookies before or after
  the function.
- **Keys** (`backend/terraform/media_signing.tf`). An RSA 2048 pair is made
  once with openssl (`DEPLOY_AWS.md` §4.1) and stored in SSM: the private
  half as a SecureString, injected into the API task as `MEDIA_PRIVATE_KEY`;
  the public half as a String, which Terraform reads into an
  `aws_cloudfront_public_key` and a key group. The private key never enters
  Terraform state. To rotate:
  1. Add a second key to the group.
  2. Switch `MEDIA_KEY_PAIR_ID` and the secret to the new key.
  3. Wait one TTL.
  4. Remove the old key.
- **The web app** (`frontend/lib/services/playback_access.dart`, the watch
  page):
  - It authorizes before opening the stream, and resolves the relative URL
    against the API's base URL.
  - It renews 5 minutes before expiry (at the earliest 30 seconds after the
    last renewal).
  - If the stream fails anyway, for example when the tab slept past the
    expiry, it renews and reopens at the same position, at most once a
    minute.
  - hls.js and dash.js send credentials, which only matters when the API is
    on another origin.
- **Caching.** The `/media/*` cache key leaves the cookies out. CloudFront
  checks the signature on every request, hit or miss, and the bytes are the
  same for every viewer. The API's `video:meta` cache now stores S3 keys and
  builds URLs on read, so a change of media base applies at once.

## 4. What it protects, and what it doesn't

| Case | Now |
|---|---|
| A leaked stream URL | Useless without cookies (403) |
| A PRIVATE video's stream, for anyone but the owner | No cookies are issued (404). Cookies issued while it was public still work until they expire (≤ 1 h) |
| A deleted video | No new cookies. Holders of cookies may get cached segments until the cookies expire |
| Hotlinking from another site | The cookies are host-only and `SameSite=Lax`, on this distribution. Another site can't make a browser send them, and a server that copies them gets one video for one hour |
| Someone allowed to watch saving the video | **Not prevented** (needs DRM, §2) |
| Thumbnails | Still public on their own distribution, like YouTube's. A PRIVATE video's thumbnail URL works if leaked |
| The ALB's `*.on.aws` URL | Still serves the app and API. It has no `/media/`, so nothing plays there |

## 5. Tests

- **Backend sanity** (`tests/sanity/test_media_signing.py`):
  - the pure helpers;
  - signatures verified with the public key;
  - expiry checked through the app;
  - the edge function run under node, compared with the test server's
    stand-in.
- **Backend integration** (`tests/integration/test_playback.py`): the test
  server's `/media/` checks the cookies as CloudFront does.
  - 403 without cookies, 200 with them;
  - cookies scoped to one video;
  - query strings and dot segments refused;
  - forged policies and wrong key ids refused;
  - who may stream which video.
- **Web app:** `PlaybackAccess` (renewal timing, failures), `VideoService`, and
  widget tests (authorize before open, retry once a minute).
- **E2E** (`integration_test/seeded_flow_test.dart`): the player's playlist
  request reaches the CDN stand-in with the cookies and gets a 200.
- **Deployed** (`scripts/deploy_smoke_test.py`, `DEPLOY_AWS.md` §6):
  - `/media/` is refused without cookies;
  - the cookie attributes;
  - the playlists, segment and manifest load with cookies;
  - cross-video cookies and query strings are refused;
  - PUBLIC and PRIVATE videos, signed out and as the owner;
  - the browser's watch page.
