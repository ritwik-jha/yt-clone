# AGENTS.md — frontend (Flutter)

Flutter client (Android + iOS) for the video platform. Read `PLAN.md` first;
`README.md` has the run commands, layout, and milestone status.

- The backend code in `../backend/app/` is the API contract. Don't copy request
  shapes from `../docs/*guide*.md` (PLAN §3 lists every divergence).
- Services throw only `ApiException`. Cubits and pages branch on `code`, never
  on `detail` text (PLAN D16).
- Never log tokens, presigned URLs, or auth response bodies. Keep the `s3` Dio
  free of interceptors.
- Dark, YouTube-like styling lives in `lib/core/theme.dart` (`YtColors`);
  don't hard-code colours in pages.
- Before pushing: `dart format lib test`, `flutter analyze`, `flutter test`.
