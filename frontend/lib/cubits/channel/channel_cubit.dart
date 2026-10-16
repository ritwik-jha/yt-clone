import '../../models/video.dart';
import '../../services/video_service.dart';
import '../feed/feed_cubit.dart';

/// A channel's listed videos. [creator] is set from the first page that
/// loads, before its state is emitted.
class ChannelCubit extends FeedCubit {
  ChannelCubit._(super.fetch, {super.limit}) : super.withFetcher();

  factory ChannelCubit(
    VideoService videos,
    String userId, {
    VideoSort sort = VideoSort.latest,
    int limit = 24,
  }) {
    late final ChannelCubit cubit;
    cubit = ChannelCubit._((page, limit) async {
      final channel = await videos.channel(
        userId,
        page: page,
        limit: limit,
        sort: sort,
      );
      cubit.creator = channel.creator;
      return channel.videos;
    }, limit: limit);
    return cubit;
  }

  Creator? creator;
}
