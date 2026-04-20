import '../../core/errors.dart';
import '../../core/logger.dart';
import '../../core/result.dart';
import '../memory_repository.dart';
import '../profile_builder.dart';

/// Daily job that rebuilds the always-on profile summary when the
/// in-repository cache is marked stale.
///
/// The profile can also rebuild lazily on the next query (see
/// [ProfileBuilder.current]); this job just makes sure the rebuild
/// happens while the device is idle and the user isn't waiting.
class ProfileRefreshJob {
  ProfileRefreshJob({
    required this.repository,
    required this.profileBuilder,
    AppLogger? logger,
  }) : _logger = logger ?? AppLogger();

  final MemoryRepository repository;
  final ProfileBuilder profileBuilder;
  final AppLogger _logger;

  /// Returns true if a rebuild happened, false if the cache wasn't
  /// stale.
  Future<Result<bool, AppError>> run() async {
    try {
      final cacheR = await repository.loadProfileSummary();
      if (cacheR.isErr) {
        return Err<bool, AppError>(cacheR.errOrNull!);
      }
      final cache = cacheR.okOrNull!;
      if (!cache.isStale) {
        return const Ok<bool, AppError>(false);
      }
      final r = await profileBuilder.rebuild();
      if (r.isErr) {
        return Err<bool, AppError>(r.errOrNull!);
      }
      return const Ok<bool, AppError>(true);
    } on Object catch (e, st) {
      _logger.error('ProfileRefreshJob run failed',
          error: e, stackTrace: st);
      return Err<bool, AppError>(
        UnknownError('profile refresh job failed',
            cause: e, stackTrace: st),
      );
    }
  }
}
