import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/providers.dart';
import '../../core/result.dart';
import '../../core/worker/providers.dart';
import '../detail/log_detail_screen.dart';
import '../memory/memory_retriever.dart';
import '../memory/memory_types.dart';
import '../search/hybrid_retriever.dart';
import 'ask_assistant.dart';
import 'ask_chat_bubble.dart';
import 'ask_chat_message.dart';
import 'ask_composer.dart';
import 'ask_empty_state.dart';

/// Screen for asking questions over local voice-log and memory context.
class AskScreen extends ConsumerStatefulWidget {
  const AskScreen({super.key});

  @override
  ConsumerState<AskScreen> createState() => _AskScreenState();
}

class _AskScreenState extends ConsumerState<AskScreen> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  final _messages = <AskChatMessage>[];
  bool _loading = false;

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final question = _controller.text.trim();
    FocusScope.of(context).unfocus();
    if (question.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Type a question first.')));
      return;
    }
    if (_loading) return;

    final userMessage = AskChatMessage.user(question);
    final assistantId = 'assistant_${DateTime.now().microsecondsSinceEpoch}';
    setState(() {
      _loading = true;
      _controller.clear();
      _messages
        ..add(userMessage)
        ..add(
          AskChatMessage.assistant(
            id: assistantId,
            text: 'Retrieving relevant memories and voice logs…',
            streaming: true,
          ),
        );
    });
    _scrollToBottom();

    final vecStore = ref.read(vecStoreProvider);
    await vecStore.load();
    if (!mounted) return;

    final db = ref.read(voxSynthDatabaseProvider);
    final embedder = ref.read(embedderProvider);
    final memoryRetriever = MemoryRetriever(
      db: db,
      repository: ref.read(memoryRepositoryProvider),
      embedder: embedder,
    );
    final logRetriever = HybridRetriever(
      db: db,
      embedder: embedder,
      vecStore: vecStore,
    );
    final assistant = AskAssistant(
      runner: ref.read(llmRunnerProvider),
      searchMemories: memoryRetriever.search,
      searchLogs: logRetriever.search,
    );

    var receivedDelta = false;
    await for (final result in assistant.askStream(question)) {
      if (!mounted) return;
      switch (result) {
        case Ok(:final value):
          switch (value) {
            case AskContextReady(:final memoryHits, :final logHits):
              _updateAssistant(
                assistantId,
                text:
                    'Found ${memoryHits.length + logHits.length} relevant context item(s). Composing answer…',
                memoryHits: memoryHits,
                logHits: logHits,
                streaming: true,
              );
            case AskAnswerDelta(:final text):
              _updateAssistant(
                assistantId,
                text: receivedDelta ? null : '',
                append: text,
                streaming: true,
              );
              receivedDelta = true;
            case AskAnswerDone(:final answer):
              _updateAssistant(
                assistantId,
                text: answer.answer,
                memoryHits: answer.memoryHits,
                logHits: answer.logHits,
                streaming: false,
              );
          }
        case Err(:final error):
          _updateAssistant(
            assistantId,
            text:
                'I could not complete that question.\n\n'
                '${error.message}',
            streaming: false,
          );
      }
      _scrollToBottom();
    }

    if (!mounted) return;
    setState(() => _loading = false);
    _scrollToBottom();
  }

  void _updateAssistant(
    String id, {
    String? text,
    String? append,
    List<MemoryHit>? memoryHits,
    List<SearchHit>? logHits,
    required bool streaming,
  }) {
    setState(() {
      final index = _messages.indexWhere((message) => message.id == id);
      if (index < 0) return;
      final current = _messages[index];
      _messages[index] = current.copyWith(
        text: '${text ?? current.text}${append ?? ''}',
        memoryHits: memoryHits ?? current.memoryHits,
        logHits: logHits ?? current.logHits,
        streaming: streaming,
      );
    });
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Ask')),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: _messages.isEmpty
                  ? const AskEmptyState()
                  : ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                      itemCount: _messages.length,
                      itemBuilder: (context, index) {
                        return AskChatBubble(
                          message: _messages[index],
                          onOpenLog: (logId) => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => LogDetailScreen(logId: logId),
                            ),
                          ),
                        );
                      },
                    ),
            ),
            AskComposer(
              controller: _controller,
              loading: _loading,
              onSubmit: _submit,
            ),
          ],
        ),
      ),
    );
  }
}
