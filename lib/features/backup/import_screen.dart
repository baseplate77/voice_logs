import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:path/path.dart' as p;

import '../../core/db/providers.dart';
import '../../core/logger.dart';
import 'backup_applier.dart';
import 'backup_crypto.dart';
import 'backup_format.dart';
import 'backup_reader.dart';

final _log = Logger('backup_import');

/// Settings → Import encrypted backup.
///
/// File picker → passphrase prompt → decrypt → apply merge-by-id. The
/// merge strategy was chosen during phase 5 design: existing logs win,
/// backup rows with new ids get added.
class ImportBackupScreen extends ConsumerStatefulWidget {
  const ImportBackupScreen({super.key});

  @override
  ConsumerState<ImportBackupScreen> createState() => _ImportBackupScreenState();
}

class _ImportBackupScreenState extends ConsumerState<ImportBackupScreen> {
  final _pass = TextEditingController();
  String? _selectedPath;
  bool _busy = false;
  String? _statusMessage;
  String? _error;
  BackupApplyReport? _report;

  @override
  void dispose() {
    _pass.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    final result = await FilePicker.platform.pickFiles();
    if (!mounted || result == null || result.files.isEmpty) return;
    setState(() {
      _selectedPath = result.files.single.path;
      _error = null;
      _report = null;
    });
  }

  Future<void> _import() async {
    final path = _selectedPath;
    if (path == null) {
      setState(() => _error = 'Select a backup file first.');
      return;
    }
    if (_pass.text.isEmpty) {
      setState(() => _error = 'Enter the passphrase used at export time.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _report = null;
      _statusMessage = 'Reading file…';
    });
    try {
      final decoded = await readBackup(path: path, passphrase: _pass.text);

      if (!mounted) return;
      setState(() => _statusMessage = 'Applying to database…');

      final db = ref.read(voxSynthDatabaseProvider);
      final docsPath = ref.read(appDocumentsPathProvider);
      final report = await applyBackup(
        backup: decoded,
        db: db,
        docsPath: docsPath,
      );

      _log.i(
        'Import applied: +${report.totalInserted} rows, '
        '${report.totalSkipped} skipped, '
        '${report.audioFilesRestored} audio files. '
        'voice_logs in DB after = ${report.voiceLogsInDbAfter}.',
      );

      if (!mounted) return;

      // Force every voice-log-derived stream to re-subscribe. drift's
      // typed insert triggers stream invalidation in theory, but
      // Riverpod's StreamProvider can hold a stale snapshot when the
      // consumer (home screen) was unmounted during the import — an
      // explicit invalidate guarantees a fresh select on resume.
      ref.invalidate(voiceLogsStreamProvider);
      ref.invalidate(actionItemsStreamProvider);
      ref.invalidate(memoryItemsStreamProvider);

      // Pull the first emission of the refreshed stream synchronously so
      // the home list is already populated by the time the user pops
      // back. Riverpod won't fire a new query until something subscribes;
      // reading `.future` is the trigger.
      try {
        final fresh = await ref.read(voiceLogsStreamProvider.future);
        _log.i('voiceLogsStreamProvider re-emitted with ${fresh.length} rows');
      } on Object catch (e, s) {
        _log.w('voiceLogsStreamProvider re-read failed', error: e, stack: s);
      }

      if (!mounted) return;
      setState(() {
        _report = report;
        _statusMessage = 'Done.';
      });
    } on BackupAuthError catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } on BackupFormatError catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } on BackupApplyError catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } on Object catch (e, s) {
      _log.w('Import failed', error: e, stack: s);
      if (!mounted) return;
      setState(() => _error = 'Import failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _doneAndReturnHome() {
    // Cheap defense-in-depth: invalidate one more time right before we
    // tear this route down. Anything subscribing further up the tree
    // (the home screen below us) gets a fresh select on resume.
    ref.invalidate(voiceLogsStreamProvider);
    ref.invalidate(actionItemsStreamProvider);
    ref.invalidate(memoryItemsStreamProvider);
    Navigator.of(context).popUntil((r) => r.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Import encrypted backup')),
      body: SafeArea(
        child: ListView(
          padding: EdgeInsets.all(20.r),
          children: [
            Text(
              'Pick a .voxsynth backup file, then enter the passphrase you '
              'set when you created it. Existing logs on this device are '
              'kept — only new rows are merged in.',
              style: TextStyle(fontSize: 14.sp),
            ),
            SizedBox(height: 20.h),
            OutlinedButton.icon(
              onPressed: _busy ? null : _pickFile,
              icon: const Icon(Icons.folder_open_outlined),
              label: Text(
                _selectedPath == null
                    ? 'Choose backup file'
                    : p.basename(_selectedPath!),
              ),
            ),
            SizedBox(height: 16.h),
            TextField(
              controller: _pass,
              autocorrect: false,
              obscureText: true,
              enabled: !_busy,
              decoration: const InputDecoration(
                labelText: 'Passphrase',
                border: OutlineInputBorder(),
              ),
            ),
            SizedBox(height: 24.h),
            FilledButton(
              onPressed: _busy ? null : _import,
              child: Text(_busy ? 'Working…' : 'Import'),
            ),
            SizedBox(height: 16.h),
            if (_statusMessage != null && _busy)
              Row(
                children: [
                  SizedBox.square(
                    dimension: 14,
                    child: CircularProgressIndicator(strokeWidth: 2.r),
                  ),
                  SizedBox(width: 10.w),
                  Expanded(child: Text(_statusMessage!)),
                ],
              ),
            if (_report != null && !_busy)
              _ReportCard(report: _report!, onDone: _doneAndReturnHome),
            if (_error != null)
              Padding(
                padding: EdgeInsets.only(top: 12.h),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ReportCard extends StatelessWidget {
  const _ReportCard({required this.report, required this.onDone});
  final BackupApplyReport report;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    report.tableCounts.forEach((table, count) {
      if (count.inserted == 0 && count.skipped == 0) return;
      rows.add(
        Padding(
          padding: EdgeInsets.symmetric(vertical: 2.h),
          child: Text(
            '$table: +${count.inserted} added, ${count.skipped} skipped',
            style: TextStyle(fontFamily: 'IBMPlexMono', fontSize: 12.sp),
          ),
        ),
      );
    });
    return Card(
      child: Padding(
        padding: EdgeInsets.all(16.r),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Import complete',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16.sp),
            ),
            SizedBox(height: 8.h),
            Text(
              '+${report.totalInserted} rows added • '
              '${report.totalSkipped} skipped',
            ),
            Text('${report.audioFilesRestored} audio files restored'),
            SizedBox(height: 4.h),
            Text(
              'Voice logs in DB now: ${report.voiceLogsInDbAfter}',
              style: TextStyle(
                fontSize: 12.sp,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontStyle: FontStyle.italic,
              ),
            ),
            Divider(height: 24.h),
            ...rows,
            SizedBox(height: 16.h),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: onDone,
                child: const Text('Done — go to home'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
