import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Enforces the CLAUDE.md non-negotiable: no network calls for core
/// features. A Dart lint rule would be purer but requires `custom_lint`
/// wiring; a source-walk test is enough for Phase 0.
///
/// If `lib/sync/` is introduced later, it is exempt from the ban (that's
/// where any network code belongs).
void main() {
  test('no network packages imported outside lib/sync/', () async {
    const banned = <String>[
      'package:http/',
      'package:dio/',
      'package:web_socket_channel/',
      'package:grpc/',
      'package:socket_io_client/',
    ];

    final libDir = Directory('lib');
    expect(libDir.existsSync(), isTrue, reason: 'lib/ must exist');

    final offenders = <String>[];
    final sep = Platform.pathSeparator;
    final syncSegment = '${sep}sync$sep';

    await for (final entity in libDir.list(recursive: true)) {
      if (entity is! File) continue;
      if (!entity.path.endsWith('.dart')) continue;
      if (entity.path.contains(syncSegment)) continue;

      final content = await entity.readAsString();
      for (final needle in banned) {
        if (content.contains(needle)) {
          offenders.add('${entity.path} imports $needle');
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason: 'Banned network imports found:\n  ${offenders.join("\n  ")}',
    );
  });
}
