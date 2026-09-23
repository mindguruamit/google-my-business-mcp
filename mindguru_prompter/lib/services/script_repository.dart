import 'package:hive_flutter/hive_flutter.dart';
import 'package:uuid/uuid.dart';

import '../models/script_model.dart';
import '../utils/constants.dart';

/// Offline-first script storage (Hive) plus small studio settings.
class ScriptRepository {
  ScriptRepository._(this._scripts, this._settings);

  static const Uuid _uuid = Uuid();

  final Box<ScriptModel> _scripts;
  final Box<dynamic> _settings;

  static Future<ScriptRepository> open() async {
    if (!Hive.isAdapterRegistered(2)) Hive.registerAdapter(CueMarkerAdapter());
    if (!Hive.isAdapterRegistered(1)) Hive.registerAdapter(ScriptModelAdapter());
    final scripts = await Hive.openBox<ScriptModel>(StorageKeys.scriptsBox);
    final settings = await Hive.openBox<dynamic>(StorageKeys.settingsBox);
    return ScriptRepository._(scripts, settings);
  }

  Box<ScriptModel> get box => _scripts;

  List<ScriptModel> all() {
    final list = _scripts.values.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return list;
  }

  ScriptModel? byId(String id) => _scripts.get(id);

  Future<ScriptModel> create({
    required String title,
    required String content,
    String? driveFileId,
  }) async {
    final now = DateTime.now();
    final script = ScriptModel(
      id: _uuid.v4(),
      title: title.trim().isEmpty ? 'Untitled script' : title.trim(),
      content: content,
      createdAt: now,
      updatedAt: now,
      driveFileId: driveFileId,
    );
    await _scripts.put(script.id, script);
    return script;
  }

  Future<void> save(ScriptModel script) async {
    script.syncMarkers();
    await _scripts.put(script.id, script);
  }

  Future<void> delete(String id) => _scripts.delete(id);

  T setting<T>(String key, T fallback) {
    final value = _settings.get(key);
    return value is T ? value : fallback;
  }

  Future<void> putSetting(String key, Object? value) => _settings.put(key, value);

  /// First launch: a sample script that shows off markers and voice tracking.
  Future<void> seedIfEmpty() async {
    if (setting<bool>(StorageKeys.seeded, false)) return;
    if (_scripts.isEmpty) {
      await create(
        title: 'Welcome to MindGuru Prompter',
        content: '''Namaste, and welcome to MindGuru Prompter. [pause]

This is your personal studio. Tap play and the words will glide up at your chosen speed. [breath]

Or switch on VoiceTrack, the little ear icon, and simply start speaking. The script follows your voice, word by word. If you go back and repeat a line, the prompter goes back with you. [pause]

Keep your eyes near the lime dot at the top. That is where the lens is, so your audience feels you are talking straight to them. [breath]

The mind follows the body, and the body follows the nervous system. Breathe, slow down, and let your message land. [pause]

When you are ready, tap the lime button and record.''',
      );
    }
    await putSetting(StorageKeys.seeded, true);
  }
}
