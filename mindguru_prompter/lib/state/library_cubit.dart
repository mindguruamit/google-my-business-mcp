import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../models/script_model.dart';
import '../services/script_import_service.dart';
import '../services/script_repository.dart';

class LibraryState extends Equatable {
  const LibraryState({
    this.scripts = const [],
    this.busy = false,
    this.message,
    this.revision = 0,
  });

  final List<ScriptModel> scripts;
  final bool busy;

  /// One-shot user message (import errors etc.).
  final String? message;

  /// Bumps on every change; ScriptModel is mutable so list identity alone
  /// isn't enough for Equatable.
  final int revision;

  LibraryState copyWith({
    List<ScriptModel>? scripts,
    bool? busy,
    String? message,
    bool clearMessage = false,
  }) {
    return LibraryState(
      scripts: scripts ?? this.scripts,
      busy: busy ?? this.busy,
      message: clearMessage ? null : message ?? this.message,
      revision: revision + 1,
    );
  }

  @override
  List<Object?> get props => [revision, busy, message];
}

class LibraryCubit extends Cubit<LibraryState> {
  LibraryCubit(this.repository, {ScriptImportService? importer})
      : importer = importer ?? ScriptImportService(),
        super(LibraryState(scripts: repository.all()));

  final ScriptRepository repository;
  final ScriptImportService importer;

  void refresh() => emit(state.copyWith(scripts: repository.all()));

  Future<ScriptModel> create({String title = '', String content = ''}) async {
    final script = await repository.create(title: title, content: content);
    refresh();
    return script;
  }

  Future<void> save(ScriptModel script) async {
    await repository.save(script);
    refresh();
  }

  Future<void> delete(ScriptModel script) async {
    await repository.delete(script.id);
    refresh();
  }

  Future<ScriptModel?> importFromDevice() async {
    emit(state.copyWith(busy: true, clearMessage: true));
    try {
      final imported = await importer.importFromDevice();
      if (imported == null) {
        emit(state.copyWith(busy: false));
        return null;
      }
      final script = await repository.create(
        title: imported.title,
        content: imported.content,
      );
      emit(state.copyWith(
        busy: false,
        scripts: repository.all(),
        message: 'Imported "${script.title}"',
      ));
      return script;
    } catch (e) {
      emit(state.copyWith(busy: false, message: 'Import failed: $e'));
      return null;
    }
  }

  Future<List<DriveFileInfo>> listDriveFiles({String? search}) async {
    emit(state.copyWith(busy: true, clearMessage: true));
    try {
      final files = await importer.listDriveFiles(search: search);
      emit(state.copyWith(busy: false));
      return files;
    } catch (e) {
      emit(state.copyWith(busy: false, message: 'Google Drive: $e'));
      return const [];
    }
  }

  Future<ScriptModel?> importFromDrive(DriveFileInfo file) async {
    emit(state.copyWith(busy: true, clearMessage: true));
    try {
      final imported = await importer.importFromGoogleDrive(file);
      final script = await repository.create(
        title: imported.title,
        content: imported.content,
        driveFileId: imported.driveFileId,
      );
      emit(state.copyWith(
        busy: false,
        scripts: repository.all(),
        message: 'Imported "${script.title}" from Drive',
      ));
      return script;
    } catch (e) {
      emit(state.copyWith(busy: false, message: 'Drive import failed: $e'));
      return null;
    }
  }

  void clearMessage() => emit(state.copyWith(clearMessage: true));
}
