import 'package:flutter/material.dart';

import '../../core/db/repositories/entity_mention_repository.dart';

/// Horizontally-scrolling strip of chips for the entity mentions on a
/// voice log detail page.
class EntityChips extends StatelessWidget {
  const EntityChips({super.key, required this.mentions});

  final List<EntityMentionView> mentions;

  @override
  Widget build(BuildContext context) {
    if (mentions.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: mentions.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final m = mentions[i];
          return Chip(
            label: Text(m.text),
            avatar: Text(_iconFor(m.type)),
            visualDensity: VisualDensity.compact,
          );
        },
      ),
    );
  }

  String _iconFor(String type) {
    switch (type) {
      case 'PERSON':
        return '@';
      case 'PLACE':
        return '#';
      case 'PROJECT':
        return '>';
      case 'DURATION':
      case 'TIME':
        return '~';
      case 'NUMBER':
        return '=';
      default:
        return '·';
    }
  }
}
