import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/features/ask/ask_stream_guard.dart';

void main() {
  group('AskStreamGuard', () {
    test('passes through ordinary varied text', () {
      final guard = AskStreamGuard();
      const text =
          'The voice log describes a coffee meeting with Shivani about '
          'Project Atlas. The deadline is Friday and the notes are pending.';
      expect(guard.inspect(text), isNull);
    });

    test('trips on the exact phrase-loop pattern from the bug screenshot', () {
      final guard = AskStreamGuard();
      // Six-word phrase repeated more than three times consecutively.
      const loop =
          'This editing process involves an actor as an actor. '
          'This editing process involves an actor as an actor. '
          'This editing process involves an actor as an actor. '
          'This editing process involves an actor as an actor.';
      expect(guard.inspect(loop), AskStreamGuardTrip.repetition);
    });

    test('trips on a short three-word loop', () {
      final guard = AskStreamGuard();
      const loop = 'No new info. No new info. No new info. No new info.';
      expect(guard.inspect(loop), AskStreamGuardTrip.repetition);
    });

    test('does not trip on a single non-loop repeat', () {
      final guard = AskStreamGuard();
      const text =
          'Coffee with Shivani is the first topic. Coffee with Shivani is '
          'also mentioned in a later log entry as a follow-up.';
      // "Coffee with Shivani" appears twice — below the repeat threshold.
      expect(guard.inspect(text), isNull);
    });

    test('trips on hitting the hard character cap', () {
      final guard = AskStreamGuard(maxAnswerChars: 200);
      final long = 'a' * 250;
      expect(guard.inspect(long), AskStreamGuardTrip.charCap);
    });

    test('ignores punctuation and case when matching loops', () {
      final guard = AskStreamGuard();
      const loop =
          'Atlas, Atlas, Atlas, Atlas. Atlas atlas atlas atlas? '
          'ATLAS ATLAS ATLAS ATLAS!';
      expect(guard.inspect(loop), AskStreamGuardTrip.repetition);
    });

    test('truncation marker is well-formed Markdown', () {
      expect(AskStreamGuard.truncationMarker, contains('truncated'));
      // Italic markdown wraps in underscores.
      expect(AskStreamGuard.truncationMarker, contains('_'));
    });
  });
}
