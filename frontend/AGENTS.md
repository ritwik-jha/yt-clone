# AGENTS.md — frontend (Flutter web)

Flutter **web** app for the video platform (the Android/iOS targets were
dropped). `README.md` has the layout, `SETUP.md` the run/build/deploy steps,
`PLAN.md` the original plan (its §16 records the move to web).

- The backend code in `../backend/app/` is the API contract. Don't copy request
  shapes from `../docs/guides/*.md` (PLAN §3 lists every divergence).
- Services throw only `ApiException`. Cubits and pages branch on `code`, never
  on `detail` text (PLAN D16).
- The session is two HttpOnly cookies the browser keeps and sends
  (`withCredentials`). The app never reads, stores, or logs a token. Never log
  presigned URLs or auth response bodies.
- Browser APIs go through `lib/platform/` (`Browser`, `PlayerController`),
  each with a `*_web.dart` implementation and a `*_stub.dart` for the VM, so
  widget tests run without a browser. Pages never import `package:web`.
- The look comes from the Figma mockups: colours and sizes are `YtColors` /
  `YtSizes` in `lib/core/theme.dart`. Don't hard-code colours in pages.
- URLs are real paths (`/watch?v=`, `/results?search_query=`,
  `/channel/<id>`); build them with `lib/app/routes.dart`, navigate with
  `context.go`. Pages that need a session are listed in
  `Routes.signedInOnly`; the router's `redirect` does the gating.
- Player libraries are vendored in `web/vendor/` (see its README), never
  loaded from a third-party CDN.
- Before pushing: `dart format lib test integration_test`, `flutter analyze`,
  `flutter test`, and `../scripts/run_pipeline.sh` for the browser E2E.
