import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../../core/db/providers.dart';
import '../../core/db/repositories/prompt_suggestion_repository.dart';
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
import 'ask_query_utils.dart';
import 'prompt_suggestion_chips.dart';
import 'snippet_locator.dart';

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
  String? _currentThreadId;
  bool _loading = false;
  bool _threadReady = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadLatestThread());
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _submitChip(PromptSuggestionView suggestion) {
    if (_loading || !_threadReady) return;
    _controller.text = suggestion.question;
    _submit();
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
    // Guard before any await. Without this, a double-tap on send (or a
    // chip tap fired while a submit is in flight) creates a second thread
    // because _ensureThread isn't reached synchronously.
    if (_loading) return;
    if (!_threadReady) return;
    setState(() => _loading = true);

    final threadId = await _ensureThread(question);
    if (threadId == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }

    final repo = ref.read(askChatRepositoryProvider);
    final userMessage = AskChatMessage.user(question);
    final assistantId = 'assistant_${DateTime.now().microsecondsSinceEpoch}';
    final assistantMessage = AskChatMessage.assistant(
      id: assistantId,
      text: 'Retrieving relevant memories and voice logs…',
      streaming: true,
    );
    setState(() {
      _controller.clear();
      _messages
        ..add(userMessage)
        ..add(assistantMessage);
    });
    await repo.saveMessage(threadId: threadId, message: userMessage);
    await repo.saveMessage(threadId: threadId, message: assistantMessage);
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
    final inferredFilters = inferAskSearchFilters(question);
    final assistant = AskAssistant(
      runner: ref.read(llmRunnerProvider),
      searchMemories: memoryRetriever.search,
      searchLogs: (query, {int limit = 10}) =>
          logRetriever.search(query, limit: limit, filters: inferredFilters),
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
              final current = _messageById(assistantId);
              if (current != null) {
                await repo.updateMessage(threadId: threadId, message: current);
              }
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
              final current = _messageById(assistantId);
              if (current != null) {
                await repo.updateMessage(threadId: threadId, message: current);
              }
          }
        case Err(:final error):
          _updateAssistant(
            assistantId,
            text:
                'I could not complete that question.\n\n'
                '${error.message}',
            streaming: false,
          );
          final current = _messageById(assistantId);
          if (current != null) {
            await repo.updateMessage(threadId: threadId, message: current);
          }
      }
      _scrollToBottom();
    }

    if (!mounted) return;
    setState(() => _loading = false);
    _scrollToBottom();
  }

  Future<void> _loadLatestThread() async {
    final repo = ref.read(askChatRepositoryProvider);
    final latest = await repo.latestThread();
    if (!mounted) return;
    if (latest == null) {
      setState(() => _threadReady = true);
      return;
    }
    final messages = await repo.messagesForThread(latest.id);
    if (!mounted) return;
    // Skip orphaned empty threads (e.g. createThread succeeded but the
    // very first saveMessage failed). Without this we'd restore the user
    // into a ghost conversation that has no body to look at.
    if (messages.isEmpty) {
      setState(() {
        _currentThreadId = null;
        _threadReady = true;
      });
      return;
    }
    setState(() {
      _currentThreadId = latest.id;
      _messages
        ..clear()
        ..addAll(messages);
      _threadReady = true;
    });
    _scrollToBottom();
  }

  Future<String?> _ensureThread(String firstQuestion) async {
    if (_currentThreadId != null) return _currentThreadId;
    final repo = ref.read(askChatRepositoryProvider);
    final created = await repo.createThread(title: firstQuestion);
    switch (created) {
      case Ok(:final value):
        setState(() => _currentThreadId = value.id);
        return value.id;
      case Err(:final error):
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(error.message)));
        }
        return null;
    }
  }

  AskChatMessage? _messageById(String id) {
    for (final message in _messages) {
      if (message.id == id) return message;
    }
    return null;
  }

  void _startNewChat() {
    if (_loading) return;
    setState(() {
      _currentThreadId = null;
      _messages.clear();
    });
  }

  Future<void> _showThreadHistory() async {
    final repo = ref.read(askChatRepositoryProvider);
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: StreamBuilder(
            stream: repo.watchThreads(),
            builder: (context, snapshot) {
              final threads = snapshot.data ?? [];
              if (threads.isEmpty) {
                return Padding(
                  padding: EdgeInsets.all(24.r),
                  child: const Center(child: Text('No Ask chats yet.')),
                );
              }
              return ListView.builder(
                itemCount: threads.length,
                itemBuilder: (context, index) {
                  final thread = threads[index];
                  return ListTile(
                    selected: thread.id == _currentThreadId,
                    leading: const Icon(Icons.chat_bubble_outline),
                    title: Text(
                      thread.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(_threadDate(thread.updatedAt)),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () async {
                        await repo.deleteThread(thread.id);
                        if (!mounted) return;
                        if (thread.id == _currentThreadId) _startNewChat();
                      },
                    ),
                    onTap: () async {
                      Navigator.of(context).pop();
                      await _openThread(thread.id);
                    },
                  );
                },
              );
            },
          ),
        );
      },
    );
  }

  Future<void> _openThread(String threadId) async {
    if (_loading) return;
    setState(() => _threadReady = false);
    final repo = ref.read(askChatRepositoryProvider);
    final messages = await repo.messagesForThread(threadId);
    if (!mounted) return;
    setState(() {
      _currentThreadId = threadId;
      _messages
        ..clear()
        ..addAll(messages);
      _threadReady = true;
    });
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

  Future<void> _openLogWithSeek(BuildContext context, SearchHit hit) async {
    final repo = ref.read(transcriptSegmentRepositoryProvider);
    final segments = await repo.findByLogId(hit.logId);
    final location = locateSnippet(snippet: hit.snippet, segments: segments);
    if (!context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => LogDetailScreen(
          logId: hit.logId,
          initialSeekMs: location?.startMs,
          highlightStartMs: location?.startMs,
          highlightEndMs: location?.endMs,
        ),
      ),
    );
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
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: colorScheme.surface,
      appBar: AppBar(
        title: const Text('Ask Journal'),
        centerTitle: true,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: colorScheme.surface,
        surfaceTintColor: Colors.transparent,
        actions: [
          IconButton(
            tooltip: 'New chat',
            onPressed: _loading ? null : _startNewChat,
            icon: const Icon(Icons.add_comment_outlined),
          ),
          IconButton(
            tooltip: 'Chat history',
            onPressed: _showThreadHistory,
            icon: const Icon(Icons.history),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: _messages.isEmpty
                  ? Center(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(20, 24, 20, 16),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const AskEmptyState(),
                            SizedBox(height: 26.h),
                            PromptSuggestionChips(onChipTapped: _submitChip),
                          ],
                        ),
                      ),
                    )
                  : ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
                      itemCount: _messages.length,
                      itemBuilder: (context, index) {
                        return AskChatBubble(
                          message: _messages[index],
                          onOpenLog: (hit) => _openLogWithSeek(context, hit),
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

String _threadDate(DateTime when) {
  final now = DateTime.now();
  final sameDay =
      now.year == when.year && now.month == when.month && now.day == when.day;
  final h = when.hour.toString().padLeft(2, '0');
  final m = when.minute.toString().padLeft(2, '0');
  if (sameDay) return 'Updated today at $h:$m';
  return 'Updated ${when.month}/${when.day} at $h:$m';
}
