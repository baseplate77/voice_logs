import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../debug_providers.dart';

/// Per-module boot checklist.
///
/// The screen shows four rows — model assets, SQLCipher DB, ObjectBox
/// store, and vector index. Each row surfaces its full error text (no
/// truncation) and exposes a retry button that invalidates the
/// underlying provider + every downstream consumer. Once all rows are
/// green, [DebugHomeScreen] automatically swaps to the record body
/// because `coreRuntimeProvider` resolves.
class BootstrapStatusView extends ConsumerWidget {
  const BootstrapStatusView({super.key, this.error});

  final Object? error;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final progress = ref.watch(bootstrapProgressProvider);
    final paths = ref.watch(modelPathsProvider);
    final db = ref.watch(appDatabaseProvider);
    final objectbox = ref.watch(objectboxStoreProvider);
    final vectorIndex = ref.watch(vectorIndexProvider);

    final modules = <_Module>[
      _Module(
        label: 'Model assets',
        value: paths,
        onRetry: () => ref.invalidate(modelPathsProvider),
        progress: paths is AsyncData ? null : progress,
      ),
      _Module(
        label: 'Database (SQLCipher)',
        value: db,
        onRetry: () => ref.invalidate(appDatabaseProvider),
      ),
      _Module(
        label: 'ObjectBox vector store',
        value: objectbox,
        onRetry: () => ref.invalidate(objectboxStoreProvider),
      ),
      _Module(
        label: 'Vector index',
        value: vectorIndex,
        onRetry: () => ref.invalidate(vectorIndexProvider),
      ),
    ];

    final failedModule = modules.firstWhere(
      (m) => m.value is AsyncError,
      orElse: _Module.empty,
    );
    final hasFailure = failedModule.value is AsyncError;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Starting VoxSynth Debug',
                style: theme.textTheme.titleLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 6),
              Text(
                'First launch extracts ~2 GB of models. Heavy models '
                '(Parakeet, Gemma, E5) are loaded on demand, one at a '
                'time, during post-processing.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              for (final m in modules) _ModuleRow(module: m),
              const SizedBox(height: 12),
              if (hasFailure) _FailureDetail(module: failedModule),
              if (error != null && !hasFailure) ...[
                const SizedBox(height: 12),
                _ErrorBox(message: 'Startup failed: $error'),
              ],
              const SizedBox(height: 16),
              _RetryAllButton(
                onPressed: hasFailure
                    ? () {
                        ref
                          ..invalidate(modelPathsProvider)
                          ..invalidate(appDatabaseProvider)
                          ..invalidate(objectboxStoreProvider)
                          ..invalidate(vectorIndexProvider);
                      }
                    : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Module {
  const _Module({
    required this.label,
    required this.value,
    required this.onRetry,
    this.progress,
  });

  _Module.empty()
      : label = '',
        value = const AsyncLoading<Object>(),
        onRetry = _noop,
        progress = null;

  final String label;
  final AsyncValue<Object> value;
  final VoidCallback onRetry;
  final BootstrapProgressState? progress;
}

void _noop() {}

class _ModuleRow extends StatelessWidget {
  const _ModuleRow({required this.module});
  final _Module module;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (Widget leading, String status, Color color) = switch (module.value) {
      AsyncData() => (
          Icon(Icons.check_circle,
              color: theme.colorScheme.primary, size: 18),
          'ready',
          theme.colorScheme.primary,
        ),
      AsyncError() => (
          Icon(Icons.error_outline,
              color: theme.colorScheme.error, size: 18),
          'error',
          theme.colorScheme.error,
        ),
      _ => (
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 1.6),
          ),
          'loading…',
          theme.colorScheme.onSurfaceVariant,
        ),
    };

    final isError = module.value is AsyncError;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              SizedBox(width: 20, height: 20, child: Center(child: leading)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  module.label,
                  style: theme.textTheme.bodyMedium,
                ),
              ),
              Text(
                status,
                style: theme.textTheme.bodySmall?.copyWith(color: color),
              ),
              if (isError) ...[
                const SizedBox(width: 8),
                TextButton(
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, 28),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: module.onRetry,
                  child: const Text('Retry'),
                ),
              ],
            ],
          ),
          if (module.progress != null &&
              module.value is! AsyncData &&
              module.value is! AsyncError) ...[
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.only(left: 30),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  LinearProgressIndicator(
                    value: module.progress!.totalFiles == 0
                        ? null
                        : (module.progress!.fileIndex /
                                module.progress!.totalFiles)
                            .clamp(0.0, 1.0),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${module.progress!.currentFile} '
                    '(${module.progress!.fileIndex}/'
                    '${module.progress!.totalFiles})',
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontFamily: 'monospace',
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _FailureDetail extends StatelessWidget {
  const _FailureDetail({required this.module});
  final _Module module;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final value = module.value;
    if (value is! AsyncError) return const SizedBox.shrink();
    final errorText = value.error.toString();
    final stackText = value.stackTrace.toString();
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${module.label} failed',
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: theme.colorScheme.onErrorContainer,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Copy error',
                icon: const Icon(Icons.copy, size: 18),
                color: theme.colorScheme.onErrorContainer,
                onPressed: () => Clipboard.setData(
                  ClipboardData(text: '$errorText\n\n$stackText'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          SelectableText(
            errorText,
            style: theme.textTheme.bodySmall?.copyWith(
              fontFamily: 'monospace',
              color: theme.colorScheme.onErrorContainer,
            ),
          ),
          const SizedBox(height: 8),
          ExpansionTile(
            title: Text(
              'stack trace',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onErrorContainer,
              ),
            ),
            tilePadding: EdgeInsets.zero,
            childrenPadding: const EdgeInsets.symmetric(vertical: 4),
            iconColor: theme.colorScheme.onErrorContainer,
            collapsedIconColor: theme.colorScheme.onErrorContainer,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 180),
                child: SingleChildScrollView(
                  child: SelectableText(
                    stackText,
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontFamily: 'monospace',
                      color: theme.colorScheme.onErrorContainer,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ErrorBox extends StatelessWidget {
  const _ErrorBox({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: SelectableText(
        message,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onErrorContainer,
        ),
      ),
    );
  }
}

class _RetryAllButton extends StatelessWidget {
  const _RetryAllButton({required this.onPressed});
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: const Icon(Icons.refresh, size: 18),
      label: const Text('Retry all'),
    );
  }
}
