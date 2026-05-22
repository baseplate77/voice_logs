import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:iconsax/iconsax.dart';

import '../../app_theme.dart';
import '../../core/db/providers.dart';
import '../actions/action_screen.dart';
import '../backup/export_screen.dart';
import '../backup/import_screen.dart';
import '../benchmark/device_benchmark_screen.dart';
import '../eval/refine_eval_screen.dart';
import '../home/auto_record_provider.dart';
import '../memory/memory_screen.dart';
import 'entities_screen.dart';
import 'shortcuts_setup_screen.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      backgroundColor: VoxAppColors.canvas,
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 20.w),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(height: 20.h),
              _buildHeader(context),
              SizedBox(height: 20.h),
              Expanded(
                child: ListView(
                  padding: EdgeInsets.only(bottom: 32.h),
                  children: [
                    const _SectionLabel(label: 'GENERAL'),
                    SizedBox(height: 8.h),
                    _SettingsCard(
                      children: [
                        _AutoRecordTile(),
                        const _CardDivider(),
                        _SettingsTile(
                          icon: Iconsax.flash_1,
                          title: 'Quick access',
                          subtitle: 'Siri, Action Button, Lock Screen',
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => const ShortcutsSetupScreen(),
                            ),
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: 20.h),
                    const _SectionLabel(label: 'DATA'),
                    SizedBox(height: 8.h),
                    _SettingsCard(
                      children: [
                        _SettingsTile(
                          icon: Iconsax.task_square,
                          title: 'Action Inbox',
                          subtitle: 'Tasks, reminders, follow-ups',
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => const ActionScreen(),
                            ),
                          ),
                        ),
                        const _CardDivider(),
                        _SettingsTile(
                          icon: Iconsax.lamp_charge,
                          title: 'Memory',
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => const MemoryScreen(),
                            ),
                          ),
                        ),
                        const _CardDivider(),
                        _SettingsTile(
                          icon: Iconsax.people,
                          title: 'Entities',
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => const EntitiesScreen(),
                            ),
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: 20.h),
                    const _SectionLabel(label: 'BACKUP'),
                    SizedBox(height: 8.h),
                    _SettingsCard(
                      children: [
                        _SettingsTile(
                          icon: Iconsax.export_1,
                          title: 'Export backup',
                          subtitle: 'Encrypted logs, audio, memories',
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => const ExportBackupScreen(),
                            ),
                          ),
                        ),
                        const _CardDivider(),
                        _SettingsTile(
                          icon: Iconsax.import_1,
                          title: 'Import backup',
                          subtitle: 'Merge a .voxsynth file',
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => const ImportBackupScreen(),
                            ),
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: 20.h),
                    const _SectionLabel(label: 'DEVELOPER'),
                    SizedBox(height: 8.h),
                    _SettingsCard(
                      children: [
                        _SettingsTile(
                          icon: Iconsax.cpu,
                          title: 'Device benchmark',
                          subtitle: 'Test AI model speed',
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => const DeviceBenchmarkScreen(),
                            ),
                          ),
                        ),
                        const _CardDivider(),
                        _SettingsTile(
                          icon: Iconsax.code,
                          title: 'Refine eval',
                          subtitle: 'Run on 50-case fixture',
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => const RefineEvalScreen(),
                            ),
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: 24.h),
                    _DeleteAllTile(ref: ref),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Row(
      children: [
        GestureDetector(
          onTap: () => Navigator.of(context).pop(),
          child: Container(
            width: 38.w,
            height: 38.h,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8.r),
              border: Border.all(color: VoxAppColors.outline, width: 1.w),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.03),
                  blurRadius: 3.r,
                  offset: Offset(0.w, 1.5.h),
                ),
              ],
            ),
            child: Icon(
              Icons.chevron_left_rounded,
              color: VoxAppColors.ink,
              size: 22.r,
            ),
          ),
        ),
        SizedBox(width: 16.w),
        Text(
          'SETTINGS',
          style: TextStyle(
            fontFamily: 'JetBrainsMono',
            fontSize: 16.sp,
            fontWeight: FontWeight.w900,
            letterSpacing: 1.2,
            color: VoxAppColors.ink,
          ),
        ),
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(left: 4.w),
      child: Text(
        label,
        style: TextStyle(
          fontFamily: 'JetBrainsMono',
          fontSize: 12.sp,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.6,
          color: VoxAppColors.muted,
        ),
      ),
    );
  }
}

class _SettingsCard extends StatelessWidget {
  const _SettingsCard({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: VoxAppColors.surface,
        borderRadius: BorderRadius.circular(16.r),
        border: Border.all(color: VoxAppColors.outline),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 6.r,
            offset: Offset(0.w, 3.h),
          ),
        ],
      ),
      child: Column(children: children),
    );
  }
}

class _CardDivider extends StatelessWidget {
  const _CardDivider();

  @override
  Widget build(BuildContext context) {
    return Divider(
      height: 1.h,
      thickness: 1.h,
      color: VoxAppColors.outline,
      indent: 52.w,
    );
  }
}

class _SettingsTile extends StatelessWidget {
  const _SettingsTile({
    required this.icon,
    required this.title,
    this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16.r),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 14.h),
        child: Row(
          children: [
            Icon(icon, size: 20.r, color: VoxAppColors.accent),
            SizedBox(width: 16.w),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontFamily: 'JetBrainsMono',
                      fontSize: 14.sp,
                      fontWeight: FontWeight.w600,
                      color: VoxAppColors.ink,
                    ),
                  ),
                  if (subtitle != null)
                    Padding(
                      padding: EdgeInsets.only(top: 2.h),
                      child: Text(
                        subtitle!,
                        style: TextStyle(
                          fontSize: 12.sp,
                          color: VoxAppColors.muted,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              size: 20.r,
              color: VoxAppColors.muted,
            ),
          ],
        ),
      ),
    );
  }
}

class _AutoRecordTile extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(autoRecordEnabledProvider);
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 10.h),
      child: Row(
        children: [
          Icon(Iconsax.microphone, size: 20.r, color: VoxAppColors.accent),
          SizedBox(width: 16.w),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Record on launch',
                  style: TextStyle(
                    fontFamily: 'JetBrainsMono',
                    fontSize: 14.sp,
                    fontWeight: FontWeight.w600,
                    color: VoxAppColors.ink,
                  ),
                ),
                Padding(
                  padding: EdgeInsets.only(top: 2.h),
                  child: Text(
                    'Start recording when the app opens',
                    style: TextStyle(
                      fontSize: 12.sp,
                      color: VoxAppColors.muted,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Switch.adaptive(
            value: enabled,
            onChanged: (_) =>
                ref.read(autoRecordEnabledProvider.notifier).toggle(),
          ),
        ],
      ),
    );
  }
}

class _DeleteAllTile extends StatelessWidget {
  const _DeleteAllTile({required this.ref});
  final WidgetRef ref;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => _confirmDeleteAll(context),
      child: Container(
        padding: EdgeInsets.symmetric(vertical: 14.h),
        decoration: BoxDecoration(
          color: VoxAppColors.surface,
          borderRadius: BorderRadius.circular(16.r),
          border: Border.all(color: VoxAppColors.accent.withValues(alpha: 0.2)),
        ),
        child: Center(
          child: Text(
            'DELETE ALL LOGS',
            style: TextStyle(
              fontFamily: 'JetBrainsMono',
              fontSize: 14.sp,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.0,
              color: VoxAppColors.accent,
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _confirmDeleteAll(BuildContext context) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16.r),
          side: const BorderSide(color: VoxAppColors.outline),
        ),
        title: Text(
          'DELETE EVERYTHING?',
          style: TextStyle(
            fontFamily: 'JetBrainsMono',
            fontWeight: FontWeight.bold,
            fontSize: 16.sp,
          ),
        ),
        content: const Text(
          'This erases every voice log, transcript, and entity. '
          'Audio files on disk are untouched — they can be cleared '
          'via the OS.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text(
              'CANCEL',
              style: TextStyle(
                color: VoxAppColors.muted,
                fontFamily: 'JetBrainsMono',
              ),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text(
              'DELETE',
              style: TextStyle(
                color: VoxAppColors.accent,
                fontWeight: FontWeight.bold,
                fontFamily: 'JetBrainsMono',
              ),
            ),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    if (!context.mounted) return;
    final repo = ref.read(voiceLogRepositoryProvider);
    await repo.deleteAll();
  }
}
