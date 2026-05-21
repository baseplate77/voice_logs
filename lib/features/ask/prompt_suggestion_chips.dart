import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../core/db/providers.dart';
import '../../core/db/repositories/prompt_suggestion_repository.dart';
import 'prompt_suggestion_selector.dart';

/// Tap-to-ask suggestion chip row rendered above the Ask composer when no
/// conversation has started yet.
///
/// Holds onto its own [PromptSuggestionSelector] result for the lifetime of
/// the screen so the same chips stay visible while the user is reading them.
/// Re-rolls only when the underlying pool meaningfully changes (a new chip
/// is added or one is removed). Tap auto-submits via [onChipTapped] and the
/// repository's usage counter is bumped so the next session reflects it.
class PromptSuggestionChips extends ConsumerStatefulWidget {
  const PromptSuggestionChips({
    super.key,
    required this.onChipTapped,
    this.limit = 5,
  });

  final ValueChanged<PromptSuggestionView> onChipTapped;
  final int limit;

  @override
  ConsumerState<PromptSuggestionChips> createState() =>
      _PromptSuggestionChipsState();
}

class _PromptSuggestionChipsState extends ConsumerState<PromptSuggestionChips> {
  static const _selector = PromptSuggestionSelector();

  List<PromptSuggestionView>? _picked;
  Set<String> _lastPoolIds = {};

  void _rollIfPoolChanged(List<PromptSuggestionView> pool) {
    final ids = pool.map((s) => s.id).toSet();
    if (_picked != null && _setEq(ids, _lastPoolIds)) return;
    _lastPoolIds = ids;
    _picked = _selector.pick(pool, now: DateTime.now(), limit: widget.limit);
  }

  bool _setEq(Set<String> a, Set<String> b) =>
      a.length == b.length && a.containsAll(b);

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(promptSuggestionsStreamProvider);
    return async.when(
      data: (pool) {
        if (pool.isEmpty) return const SizedBox.shrink();
        _rollIfPoolChanged(pool);
        final picked = _picked ?? [];
        if (picked.isEmpty) return const SizedBox.shrink();
        return _ChipRow(
          suggestions: picked,
          onTap: (s) {
            final repo = ref.read(promptSuggestionRepositoryProvider);
            // Fire-and-forget — usage tracking should never block submit.
            repo.bumpUsage(s.id);
            widget.onChipTapped(s);
          },
        );
      },
      loading: SizedBox.shrink,
      error: (_, _) => const SizedBox.shrink(),
    );
  }
}

class _ChipRow extends StatelessWidget {
  const _ChipRow({required this.suggestions, required this.onTap});

  final List<PromptSuggestionView> suggestions;
  final ValueChanged<PromptSuggestionView> onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 640),
      child: Wrap(
        alignment: WrapAlignment.center,
        runAlignment: WrapAlignment.center,
        spacing: 10,
        runSpacing: 10,
        children: [
          for (final suggestion in suggestions)
            ActionChip(
              avatar: Icon(
                Icons.auto_awesome,
                size: 16.r,
                color: theme.colorScheme.primary,
              ),
              label: Text(suggestion.chipText),
              labelStyle: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.onSurface,
              ),
              backgroundColor: theme.colorScheme.surface,
              side: BorderSide(color: theme.colorScheme.outlineVariant),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18.r),
              ),
              padding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 8.h),
              onPressed: () => onTap(suggestion),
            ),
        ],
      ),
    );
  }
}
