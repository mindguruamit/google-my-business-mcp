import 'package:hive/hive.dart';

import '../utils/constants.dart';
import 'script_document.dart';

enum CueType { pause, breath, note }

/// A cue inside the script. [position] is the index of the spoken word the
/// cue sits in front of, so the engine can hold right before that word.
class CueMarker {
  const CueMarker({
    required this.position,
    required this.type,
    required this.label,
  });

  factory CueMarker.fromTag(String tag, {required int position}) {
    final lower = tag.toLowerCase();
    final type = switch (lower) {
      'pause' => CueType.pause,
      'breath' || 'breathe' => CueType.breath,
      _ => CueType.note,
    };
    return CueMarker(position: position, type: type, label: tag);
  }

  final int position;
  final CueType type;
  final String label;

  /// How long the prompter waits here while auto-scrolling.
  Duration get hold => switch (type) {
        CueType.pause => TeleprompterConstants.pauseHold,
        CueType.breath => TeleprompterConstants.breathHold,
        CueType.note => Duration.zero,
      };

  Map<String, dynamic> toJson() => {
        'position': position,
        'type': type.name,
        'label': label,
      };

  factory CueMarker.fromJson(Map<String, dynamic> json) => CueMarker(
        position: json['position'] as int,
        type: CueType.values.byName(json['type'] as String),
        label: json['label'] as String,
      );
}

class ScriptModel extends HiveObject {
  ScriptModel({
    required this.id,
    required this.title,
    required this.content,
    required this.createdAt,
    DateTime? updatedAt,
    this.scrollSpeed = TeleprompterConstants.defaultWpm,
    this.fontSize = TeleprompterConstants.defaultFontSize,
    List<CueMarker>? markers,
    this.driveFileId,
  })  : updatedAt = updatedAt ?? createdAt,
        markers = markers ?? ScriptDocument.parse(content).markers;

  String id;
  String title;
  String content;
  DateTime createdAt;
  DateTime updatedAt;

  /// Words per minute.
  int scrollSpeed;
  double fontSize;
  List<CueMarker> markers;
  String? driveFileId;

  ScriptDocument get document => ScriptDocument.parse(content);

  int get wordCount => document.wordCount;

  Duration get estimatedDuration => document.estimateDuration(scrollSpeed);

  /// Re-parses [content] and refreshes [markers]. Call after editing.
  void syncMarkers() {
    markers = document.markers;
    updatedAt = DateTime.now();
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'content': content,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'scrollSpeed': scrollSpeed,
        'fontSize': fontSize,
        'markers': markers.map((m) => m.toJson()).toList(),
        'driveFileId': driveFileId,
      };

  factory ScriptModel.fromJson(Map<String, dynamic> json) => ScriptModel(
        id: json['id'] as String,
        title: json['title'] as String,
        content: json['content'] as String,
        createdAt: DateTime.parse(json['createdAt'] as String),
        updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? ''),
        scrollSpeed: (json['scrollSpeed'] as num?)?.toInt() ??
            TeleprompterConstants.defaultWpm,
        fontSize: (json['fontSize'] as num?)?.toDouble() ??
            TeleprompterConstants.defaultFontSize,
        markers: (json['markers'] as List<dynamic>?)
            ?.map((m) => CueMarker.fromJson(Map<String, dynamic>.from(m as Map)))
            .toList(),
        driveFileId: json['driveFileId'] as String?,
      );
}

/// Hand-written adapters, so no build_runner step is needed.
class CueMarkerAdapter extends TypeAdapter<CueMarker> {
  @override
  final int typeId = 2;

  @override
  CueMarker read(BinaryReader reader) {
    final position = reader.readInt();
    final typeIndex = reader.readByte();
    final label = reader.readString();
    return CueMarker(
      position: position,
      type: CueType.values[typeIndex.clamp(0, CueType.values.length - 1)],
      label: label,
    );
  }

  @override
  void write(BinaryWriter writer, CueMarker obj) {
    writer
      ..writeInt(obj.position)
      ..writeByte(obj.type.index)
      ..writeString(obj.label);
  }
}

class ScriptModelAdapter extends TypeAdapter<ScriptModel> {
  @override
  final int typeId = 1;

  @override
  ScriptModel read(BinaryReader reader) {
    final fieldCount = reader.readByte();
    final fields = <int, dynamic>{
      for (var i = 0; i < fieldCount; i++) reader.readByte(): reader.read(),
    };
    final createdAt = fields[3] as DateTime;
    return ScriptModel(
      id: fields[0] as String,
      title: fields[1] as String,
      content: fields[2] as String,
      createdAt: createdAt,
      scrollSpeed: (fields[4] as int?) ?? TeleprompterConstants.defaultWpm,
      fontSize: (fields[5] as double?) ?? TeleprompterConstants.defaultFontSize,
      markers: (fields[6] as List?)?.cast<CueMarker>(),
      driveFileId: fields[7] as String?,
      updatedAt: (fields[8] as DateTime?) ?? createdAt,
    );
  }

  @override
  void write(BinaryWriter writer, ScriptModel obj) {
    writer
      ..writeByte(9)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.title)
      ..writeByte(2)
      ..write(obj.content)
      ..writeByte(3)
      ..write(obj.createdAt)
      ..writeByte(4)
      ..write(obj.scrollSpeed)
      ..writeByte(5)
      ..write(obj.fontSize)
      ..writeByte(6)
      ..write(obj.markers)
      ..writeByte(7)
      ..write(obj.driveFileId)
      ..writeByte(8)
      ..write(obj.updatedAt);
  }
}
