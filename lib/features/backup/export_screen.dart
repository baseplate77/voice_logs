import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/db/providers.dart';
import 'backup_snapshot.dart';
import 'backup_writer.dart';

/// Settings → Export encrypted backup.
///
/// Asks for a passphrase (twice — to catch typos), runs the snapshot →
/// ZIP → AES-GCM → file pipeline, then hands the file to the system
/// share sheet. The file lives in the app's temp directory; users save
/// it to Files / iCloud / a local folder via that sheet.
class ExportBackupScreen extends ConsumerStatefulWidget {
  const ExportBackupScreen({super.key});

  @override
  ConsumerState<ExportBackupScreen> createState() => _ExportBackupScreenState();
}

class _ExportBackupScreenState extends ConsumerState<ExportBackupScreen> {
  final _pass1 = TextEditingController();
  final _pass2 = TextEditingController();
  final _exportButtonKey = GlobalKey();
  bool _busy = false;
  String? _statusMessage;
  BackupWriteResult? _result;
  String? _error;

  /// The share sheet on iPad presents as a popover and refuses a zero
  /// origin rect. We anchor it to the Export button when possible, and
  /// fall back to a non-zero rect at the top-left so it at least opens.
  Rect _sharePositionOrigin() {
    final ctx = _exportButtonKey.currentContext;
    final box = ctx?.findRenderObject() as RenderBox?;
    if (box != null && box.hasSize) {
      return box.localToGlobal(Offset.zero) & box.size;
    }
    return const Rect.fromLTWH(0, 0, 1, 1);
  }

  @override
  void dispose() {
    _pass1.dispose();
    _pass2.dispose();
    super.dispose();
  }

  Future<void> _export() async {
    final pass = _pass1.text;
    if (pass.isEmpty) {
      setState(() => _error = 'Enter a passphrase.');
      return;
    }
    if (pass != _pass2.text) {
      setState(() => _error = "Passphrases don't match.");
      return;
    }
    if (pass.length < 8) {
      setState(() => _error = 'Use at least 8 characters.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _result = null;
      _statusMessage = 'Snapshotting database…';
    });
    try {
      final db = ref.read(voxSynthDatabaseProvider);
      final docsPath = ref.read(appDocumentsPathProvider);
      final snapshot = await readSnapshot(db: db, docsPath: docsPath);

      if (!mounted) return;
      setState(() => _statusMessage = 'Encrypting…');

      final tempDir = await getTemporaryDirectory();
      final stamp = DateTime.now().toIso8601String().replaceAll(':', '-');
      final outPath = p.join(tempDir.path, 'voxsynth-$stamp.voxsynth');
      final result = await writeBackup(
        snapshot: snapshot,
        passphrase: pass,
        outputPath: outPath,
      );

      if (!mounted) return;
      setState(() {
        _result = result;
        _statusMessage = 'Ready to share.';
      });

      // ignore: deprecated_member_use
      await Share.shareXFiles(
        [XFile(outPath, mimeType: 'application/octet-stream')],
        subject: 'VoxSynth encrypted backup',
        text:
            'VoxSynth encrypted backup. Open this in VoxSynth and '
            'enter your passphrase to restore.',
        sharePositionOrigin: _sharePositionOrigin(),
      );
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Export failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Export encrypted backup')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Text(
              'Your passphrase is the only way to decrypt this file. '
              "Store it somewhere safe — we can't recover it.",
              style: TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _pass1,
              autocorrect: false,
              obscureText: true,
              enabled: !_busy,
              decoration: const InputDecoration(
                labelText: 'Passphrase',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _pass2,
              autocorrect: false,
              obscureText: true,
              enabled: !_busy,
              decoration: const InputDecoration(
                labelText: 'Confirm passphrase',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 24),
            FilledButton(
              key: _exportButtonKey,
              onPressed: _busy ? null : _export,
              child: Text(_busy ? 'Working…' : 'Export'),
            ),
            const SizedBox(height: 16),
            if (_statusMessage != null && _busy)
              Row(
                children: [
                  const SizedBox.square(
                    dimension: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 10),
                  Expanded(child: Text(_statusMessage!)),
                ],
              ),
            if (_result != null && !_busy) _ResultCard(result: _result!),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
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

class _ResultCard extends StatelessWidget {
  const _ResultCard({required this.result});
  final BackupWriteResult result;

  @override
  Widget build(BuildContext context) {
    final sizeMb = (result.totalBytes / (1024 * 1024)).toStringAsFixed(1);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Backup created',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
            ),
            const SizedBox(height: 6),
            Text(
              '${result.logCount} logs, ${result.audioFileCount} audio files',
            ),
            Text('Size: $sizeMb MB'),
            const SizedBox(height: 4),
            Text(
              p.basename(result.filePath),
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ignore: unused_element
File _existsCheck(String path) => File(path);
