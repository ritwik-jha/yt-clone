/// `Page<T>` from the API contract. Named `PageResult` so it doesn't clash
/// with Flutter's navigator `Page`.
class PageResult<T> {
  const PageResult({
    required this.total,
    required this.page,
    required this.limit,
    required this.items,
  });

  final int total;
  final int page;
  final int limit;
  final List<T> items;

  bool get hasMore => page * limit < total;

  factory PageResult.fromJson(
    Map<String, dynamic> j,
    T Function(Map<String, dynamic>) parse,
  ) => PageResult(
    total: j['total'] as int,
    page: j['page'] as int,
    limit: j['limit'] as int,
    items: [
      for (final e in j['items'] as List<dynamic>)
        parse(e as Map<String, dynamic>),
    ],
  );
}
