import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../models/script_model.dart';
import '../services/script_import_service.dart';
import '../state/library_cubit.dart';
import '../utils/app_theme.dart';
import '../utils/constants.dart';
import 'editor_screen.dart';
import 'recording_screen.dart';

class LibraryScreen extends StatelessWidget {
  const LibraryScreen({super.key});

  Future<void> _openEditor(BuildContext context, [ScriptModel? script]) async {
    final cubit = context.read<LibraryCubit>();
    final target = script ?? await cubit.create();
    if (!context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => EditorScreen(script: target)),
    );
    cubit.refresh();
  }

  Future<void> _openStudio(BuildContext context, ScriptModel script) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => RecordingScreen(script: script)),
    );
    if (context.mounted) context.read<LibraryCubit>().refresh();
  }

  Future<void> _import(BuildContext context, _ImportSource source) async {
    final cubit = context.read<LibraryCubit>();
    ScriptModel? script;
    switch (source) {
      case _ImportSource.device:
        script = await cubit.importFromDevice();
      case _ImportSource.drive:
        final files = await cubit.listDriveFiles();
        if (!context.mounted || files.isEmpty) return;
        final picked = await showModalBottomSheet<DriveFileInfo>(
          context: context,
          isScrollControlled: true,
          builder: (_) => _DrivePicker(files: files),
        );
        if (picked == null) return;
        script = await cubit.importFromDrive(picked);
    }
    if (script != null && context.mounted) await _openEditor(context, script);
  }

  Future<bool> _confirmDelete(BuildContext context, ScriptModel script) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete script?'),
        content: Text('"${script.title}" will be removed from this device.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.recording),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  @override
  Widget build(BuildContext context) {
    return BlocListener<LibraryCubit, LibraryState>(
      listenWhen: (a, b) => b.message != null && a.message != b.message,
      listener: (context, state) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(state.message!)));
        context.read<LibraryCubit>().clearMessage();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Row(
            children: [
              Icon(Icons.subtitles_outlined, color: AppColors.accent),
              SizedBox(width: 10),
              Text('MindGuru Prompter'),
            ],
          ),
          actions: [
            PopupMenuButton<_ImportSource>(
              tooltip: 'Import script',
              icon: const Icon(Icons.file_download_outlined),
              color: AppColors.cardHigh,
              onSelected: (source) => _import(context, source),
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: _ImportSource.device,
                  child: ListTile(
                    leading: Icon(Icons.folder_open),
                    title: Text('From device'),
                    subtitle: Text('TXT · PDF · DOCX · RTF'),
                  ),
                ),
                PopupMenuItem(
                  value: _ImportSource.drive,
                  child: ListTile(
                    leading: Icon(Icons.add_to_drive),
                    title: Text('From Google Drive'),
                    subtitle: Text('Docs · TXT · PDF · DOCX'),
                  ),
                ),
              ],
            ),
            const SizedBox(width: 4),
          ],
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(3),
            child: BlocBuilder<LibraryCubit, LibraryState>(
              buildWhen: (a, b) => a.busy != b.busy,
              builder: (context, state) => state.busy
                  ? const LinearProgressIndicator(minHeight: 3, color: AppColors.accent)
                  : const SizedBox(height: 3),
            ),
          ),
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () => _openEditor(context),
          icon: const Icon(Icons.add),
          label: const Text('New script', style: TextStyle(fontWeight: FontWeight.w700)),
        ),
        body: BlocBuilder<LibraryCubit, LibraryState>(
          builder: (context, state) {
            if (state.scripts.isEmpty) {
              return const _EmptyLibrary();
            }
            return ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
              itemCount: state.scripts.length,
              separatorBuilder: (_, _) => const SizedBox(height: 12),
              itemBuilder: (context, index) {
                final script = state.scripts[index];
                return Dismissible(
                  key: ValueKey(script.id),
                  direction: DismissDirection.endToStart,
                  confirmDismiss: (_) => _confirmDelete(context, script),
                  onDismissed: (_) => context.read<LibraryCubit>().delete(script),
                  background: Container(
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.only(right: 24),
                    decoration: BoxDecoration(
                      color: AppColors.recording.withValues(alpha: 0.85),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: const Icon(Icons.delete_outline, color: Colors.white),
                  ),
                  child: _ScriptCard(
                    script: script,
                    onTap: () => _openEditor(context, script),
                    onPlay: () => _openStudio(context, script),
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}

enum _ImportSource { device, drive }

class _ScriptCard extends StatelessWidget {
  const _ScriptCard({
    required this.script,
    required this.onTap,
    required this.onPlay,
  });

  final ScriptModel script;
  final VoidCallback onTap;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) {
    final document = script.document;
    final preview = document.words.take(24).map((w) => w.text).join(' ');
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 12, 16),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      script.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      preview.isEmpty ? 'Empty script – tap to write' : preview,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: AppColors.textSecondary, height: 1.35),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        _Pill(icon: Icons.speed, text: '${script.scrollSpeed} WPM'),
                        _Pill(
                          icon: Icons.timer_outlined,
                          text: formatDuration(document.estimateDuration(script.scrollSpeed)),
                        ),
                        _Pill(icon: Icons.notes, text: '${document.wordCount} words'),
                        if (script.driveFileId != null)
                          const _Pill(icon: Icons.add_to_drive, text: 'Drive'),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                tooltip: 'Open studio',
                iconSize: 30,
                style: IconButton.styleFrom(
                  backgroundColor: AppColors.accent,
                  foregroundColor: Colors.black,
                  fixedSize: const Size(56, 56),
                ),
                onPressed: document.wordCount == 0 ? null : onPlay,
                icon: const Icon(Icons.play_arrow_rounded),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: AppColors.accent),
          const SizedBox(width: 4),
          Text(text, style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
        ],
      ),
    );
  }
}

class _EmptyLibrary extends StatelessWidget {
  const _EmptyLibrary();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.subtitles_outlined, size: 64, color: AppColors.accent),
            SizedBox(height: 16),
            Text(
              'No scripts yet',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
            ),
            SizedBox(height: 8),
            Text(
              'Write a new script or import one from your phone or Google Drive.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}

class _DrivePicker extends StatelessWidget {
  const _DrivePicker({required this.files});

  final List<DriveFileInfo> files;

  IconData _icon(DriveFileInfo f) {
    if (f.isGoogleDoc) return Icons.description;
    if (f.mimeType.contains('pdf')) return Icons.picture_as_pdf;
    if (f.mimeType.contains('word')) return Icons.article;
    return Icons.text_snippet;
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.95,
      builder: (context, controller) => Column(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Row(
              children: [
                Icon(Icons.add_to_drive, color: AppColors.accent),
                SizedBox(width: 10),
                Text(
                  'Import from Google Drive',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              controller: controller,
              itemCount: files.length,
              itemBuilder: (context, index) {
                final file = files[index];
                final modified = file.modifiedTime;
                return ListTile(
                  leading: Icon(_icon(file), color: AppColors.accent),
                  title: Text(file.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: modified == null
                      ? null
                      : Text(
                          'Modified ${modified.toLocal().toString().substring(0, 16)}',
                          style: const TextStyle(color: AppColors.textSecondary),
                        ),
                  onTap: () => Navigator.pop(context, file),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
