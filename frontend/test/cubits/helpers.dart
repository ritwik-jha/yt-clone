import 'package:mocktail/mocktail.dart';
import 'package:ytp_app/models/video.dart';
import 'package:ytp_app/services/auth_service.dart';
import 'package:ytp_app/services/upload_video_service.dart';
import 'package:ytp_app/services/video_service.dart';

class MockAuthService extends Mock implements AuthService {}

class MockVideoService extends Mock implements VideoService {}

class MockUploadService extends Mock implements UploadVideoService {}

Video makeVideo(
  String id, {
  VideoStatus? status,
  int views = 0,
  VideoVisibility? visibility,
  String creatorId = 'u1',
}) => Video(
  id: id,
  title: 'Video $id',
  thumbnailUrl: 'https://cdn/t.jpg',
  manifestUrl: 'https://cdn/$id/manifest.mpd',
  hlsUrl: 'https://cdn/$id/master.m3u8',
  viewsCount: views,
  creator: Creator(id: creatorId, name: 'Ada'),
  createdAt: DateTime(2026, 1, 1),
  status: status,
  visibility: visibility,
);
