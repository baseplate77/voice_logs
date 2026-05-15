import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/core/db/database.dart';
import 'package:voxsynth/core/db/repositories/ask_chat_repository.dart';
import 'package:voxsynth/core/result.dart';
import 'package:voxsynth/features/ask/ask_chat_message.dart';
import 'package:voxsynth/features/search/hybrid_retriever.dart';

void main() {
  late VoxSynthDatabase db;
  late AskChatRepository repo;

  setUp(() {
    db = VoxSynthDatabase(NativeDatabase.memory());
    repo = AskChatRepository(db);
  });

  tearDown(() => db.close());

  test(
    'creates a thread and restores messages with source snapshots',
    () async {
      final created = await repo.createThread(
        title: 'What did I say about Atlas?',
      );
      expect(created, isA<Ok<AskThreadView, AskChatStorageError>>());
      final thread = (created as Ok<AskThreadView, AskChatStorageError>).value;
      expect(thread.title, 'What did I say about Atlas');

      final user = AskChatMessage.user('What did I say about Atlas?');
      const hit = SearchHit(
        logId: 'log_1',
        fusedScore: 0.7,
        matchedVia: {MatchSource.fts},
        snippet: 'Atlas needs a revised launch plan.',
        logTitle: 'Atlas launch plan',
      );
      final assistant = AskChatMessage.assistant(
        id: 'assistant_1',
        text: 'Atlas needs a revised launch plan. [L1]',
        streaming: false,
      ).copyWith(logHits: const [hit]);

      await repo.saveMessage(threadId: thread.id, message: user);
      await repo.saveMessage(threadId: thread.id, message: assistant);

      final messages = await repo.messagesForThread(thread.id);
      expect(messages, hasLength(2));
      expect(messages.first.role, AskChatRole.user);
      expect(messages.last.text, contains('Atlas'));
      expect(messages.last.logHits.single.logId, 'log_1');
      expect(messages.last.logHits.single.logTitle, 'Atlas launch plan');
    },
  );

  test('messagesForThread preserves insertion order even when '
      'user + assistant share a millisecond', () async {
    final created =
        (await repo.createThread(title: 'Race'))
            as Ok<AskThreadView, AskChatStorageError>;
    final threadId = created.value.id;

    // Fire both saves without an await between them so they almost
    // certainly share the same millisecond.
    final user = AskChatMessage.user('Question');
    final assistant = AskChatMessage.assistant(
      id: 'assistant_race',
      text: 'Answer',
      streaming: false,
    );
    await Future.wait([
      repo.saveMessage(threadId: threadId, message: user),
      repo.saveMessage(threadId: threadId, message: assistant),
    ]);

    final messages = await repo.messagesForThread(threadId);
    expect(messages, hasLength(2));
    expect(messages.first.role, AskChatRole.user);
    expect(messages.last.role, AskChatRole.assistant);
  });

  test('deleteThread removes the thread and cascades its messages', () async {
    final created =
        (await repo.createThread(title: 'Doomed'))
            as Ok<AskThreadView, AskChatStorageError>;
    final threadId = created.value.id;
    await repo.saveMessage(
      threadId: threadId,
      message: AskChatMessage.user('first'),
    );

    final delResult = await repo.deleteThread(threadId);
    expect(delResult, isA<Ok<void, AskChatStorageError>>());
    expect(await repo.latestThread(), isNull);
    expect(await repo.messagesForThread(threadId), isEmpty);
  });

  test('reloaded messages drop the streaming flag', () async {
    final created =
        (await repo.createThread(title: 'Streaming'))
            as Ok<AskThreadView, AskChatStorageError>;
    final threadId = created.value.id;
    final assistant = AskChatMessage.assistant(
      id: 'assistant_stream',
      text: 'partial…',
      streaming: true,
    );
    await repo.saveMessage(threadId: threadId, message: assistant);

    final reloaded = await repo.messagesForThread(threadId);
    expect(reloaded.single.streaming, isFalse);
  });

  test('watchThreads emits newest updated thread first', () async {
    final a =
        (await repo.createThread(title: 'Older'))
            as Ok<AskThreadView, AskChatStorageError>;
    await Future<void>.delayed(const Duration(milliseconds: 2));
    final b =
        (await repo.createThread(title: 'Newer'))
            as Ok<AskThreadView, AskChatStorageError>;

    await repo.saveMessage(
      threadId: a.value.id,
      message: AskChatMessage.user('touch older'),
    );

    final threads = await repo.watchThreads().first;
    expect(threads.first.id, a.value.id);
    expect(threads.map((t) => t.id), contains(b.value.id));
  });
}
