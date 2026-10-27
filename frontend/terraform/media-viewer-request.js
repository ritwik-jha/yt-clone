// CloudFront Function, viewer request, on the edge distribution's /media/*
// behaviour (cloudfront.tf). Runs on every manifest and segment request.
//
// 1. Refuses what could stretch a signed cookie to another video. The
//    cookie's policy Resource is https://*/<folder>/* (backend
//    app/media_signing.py), and `*` spans slashes, so a query string or an
//    odd path could make another video's URL end in this video's folder.
//    Media keys are plain: letters, digits, "-", "_", "." and "/".
// 2. Strips /media so the S3 key is the path the transcoder wrote.
//
// The policy matches the path with and without /media, so it doesn't matter
// whether CloudFront checks the cookies before or after this function.
// Keep in step with _media() in backend/tests/support/server.py.
function handler(event) {
  var request = event.request;
  var uri = request.uri;
  if (
    Object.keys(request.querystring).length > 0 ||
    !/^\/media\/[A-Za-z0-9._\-\/]+$/.test(uri) ||
    /(^|\/)\.\.?(\/|$)/.test(uri)
  ) {
    return { statusCode: 400, statusDescription: 'Bad Request' };
  }
  request.uri = uri.substring('/media'.length);
  return request;
}
