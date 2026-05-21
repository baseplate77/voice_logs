import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../core/db/providers.dart';
import '../../core/db/repositories/canonical_entity_repository.dart';
import '../entity/entity_detail_screen.dart';

/// Read-only list of canonical entities, sorted by mention frequency.
/// Merge / rename / delete actions are deferred to Phase 6 polish —
/// the canonicalizer itself already works; the UI exposes what exists.
class EntitiesScreen extends ConsumerWidget {
  const EntitiesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entitiesAsync = ref.watch(canonicalEntitiesProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Entities')),
      body: entitiesAsync.when(
        data: (rows) {
          if (rows.isEmpty) {
            return const Center(child: Text('No entities extracted yet.'));
          }
          return ListView.separated(
            itemCount: rows.length,
            separatorBuilder: (_, _) => Divider(height: 1.h),
            itemBuilder: (_, i) {
              final e = rows[i];
              return ListTile(
                title: Text(e.displayName),
                subtitle: Text(e.type),
                trailing: Text('${e.mentionCount}'),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => EntityDetailScreen(entityId: e.id),
                  ),
                ),
              );
            },
          );
        },
        loading: () =>
            const Center(child: CircularProgressIndicator.adaptive()),
        error: (e, _) => Center(child: Text('Error: $e')),
      ),
    );
  }
}

/// Reactive stream of canonical entities.
final canonicalEntitiesProvider = StreamProvider<List<CanonicalEntityView>>((
  ref,
) {
  final db = ref.watch(voxSynthDatabaseProvider);
  return CanonicalEntityRepository(db).watchAll();
});
