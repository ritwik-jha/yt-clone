import 'page_result.dart';
import 'video.dart';

/// `GET /video/channel/{user_id}`: the creator and one page of their
/// listed (public, ready) videos.
class ChannelListing {
  const ChannelListing({required this.creator, required this.videos});

  final Creator creator;
  final PageResult<Video> videos;

  factory ChannelListing.fromJson(Map<String, dynamic> j) => ChannelListing(
    creator: Creator.fromJson(j['creator'] as Map<String, dynamic>),
    videos: PageResult.fromJson(j, Video.fromJson),
  );
}
