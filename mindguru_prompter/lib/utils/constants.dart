import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

/// Brand palette. Dark studio look, lime accent.
class AppColors {
  AppColors._();

  static const Color background = Color(0xFF0F1115);
  static const Color card = Color(0xFF1C1F26);
  static const Color cardHigh = Color(0xFF262A33);
  static const Color accent = Color(0xFFA7F050);
  static const Color recording = Color(0xFFFF3B30);
  static const Color focus = Color(0xFFFFD60A);
  static const Color textPrimary = Colors.white;
  static const Color textSecondary = Color(0xFF9AA0AA);
  static const Color disabled = Color(0xFF4A4F59);
  static const Color marker = Color(0xFF7FD4FF);
}

/// Recording resolutions offered in the studio.
///
/// The Flutter camera plugin only exposes presets, so each resolution maps to
/// the closest [ResolutionPreset]. There is no 1440p preset in CameraX or
/// AVFoundation, so [qhd1440] records through the 4K preset (with
/// "lower quality" fallback on devices without 4K).
enum VideoResolution {
  hd720('720p', 'HD', 1280, 720, ResolutionPreset.high),
  fhd1080('1080p', 'FHD', 1920, 1080, ResolutionPreset.veryHigh),
  qhd1440('1440p', 'QHD', 2560, 1440, ResolutionPreset.ultraHigh),
  uhd4k('4K', 'UHD', 3840, 2160, ResolutionPreset.ultraHigh),
  uhd8k('8K', 'UHD', 7680, 4320, ResolutionPreset.max);

  const VideoResolution(
    this.label,
    this.tier,
    this.width,
    this.height,
    this.preset,
  );

  final String label;
  final String tier;
  final int width;
  final int height;
  final ResolutionPreset preset;

  int get pixels => width * height;

  /// Recommended H.264/HEVC bitrate (bits per second) for [fps].
  /// Roughly YouTube's upload recommendations, scaled for frame rate.
  int bitrateFor(int fps) {
    final base = switch (this) {
      VideoResolution.hd720 => 8000000,
      VideoResolution.fhd1080 => 16000000,
      VideoResolution.qhd1440 => 32000000,
      VideoResolution.uhd4k => 50000000,
      VideoResolution.uhd8k => 100000000,
    };
    return fps > 30 ? (base * 1.5).round() : base;
  }

  static VideoResolution fromName(String? name) {
    return VideoResolution.values.firstWhere(
      (r) => r.name == name,
      orElse: () => VideoResolution.fhd1080,
    );
  }
}

/// Frame rates exposed in the FPS selector.
enum FrameRate {
  fps24(24),
  fps30(30),
  fps60(60),
  fps120(120);

  const FrameRate(this.value);

  final int value;

  String get label => '${value}fps';

  static FrameRate fromValue(int? value) {
    return FrameRate.values.firstWhere(
      (f) => f.value == value,
      orElse: () => FrameRate.fps30,
    );
  }
}

class CameraConstants {
  CameraConstants._();

  static const double minExposure = -2.0;
  static const double maxExposure = 2.0;
  static const double minZoom = 1.0;
  static const double maxZoom = 10.0;

  /// 8K sensors on phones top out at 30fps in every shipping device.
  static const int max8kFps = 30;

  /// Resolutions up to this one may use 60/120fps (hardware permitting).
  static const VideoResolution highFrameRateCeiling = VideoResolution.qhd1440;

  static const String deviceChannel = 'com.mindguru.prompter/device';
  static const String pipChannel = 'com.mindguru.prompter/pip';
  static const String galleryAlbum = 'MindGuru Prompter';
}

class TeleprompterConstants {
  TeleprompterConstants._();

  static const int minWpm = 80;
  static const int maxWpm = 250;
  static const int defaultWpm = 140;
  static const double defaultFontSize = 34;
  static const double minFontSize = 18;
  static const double maxFontSize = 72;

  /// 60fps ticker.
  static const Duration tick = Duration(milliseconds: 16);

  static const double minAdaptiveFactor = 0.5;
  static const double maxAdaptiveFactor = 2.0;

  /// How long the prompter holds on a cue marker.
  static const Duration pauseHold = Duration(milliseconds: 1500);
  static const Duration breathHold = Duration(milliseconds: 800);

  static const double overlayHeight = 300;
  static const double overlayOpacity = 0.55;

  /// Vertical position of the reading line inside the prompter box (0..1).
  static const double readingLine = 0.30;
}

class VoiceConstants {
  VoiceConstants._();

  static const Duration sessionLength = Duration(minutes: 30);

  /// Number of trailing recognized words used as the search query.
  static const int queryWords = 6;

  /// Search window around the current position (in words).
  static const int backWindow = 80;
  static const int forwardWindow = 120;

  /// Offline Vosk models are resolved at runtime from the official catalogue
  /// (https://alphacephei.com/vosk/models/model-list.json) by locale. These
  /// small models are the fallback if the catalogue can't be reached.
  /// Each is ~40–50 MB, downloaded once and cached on the device.
  static const Map<String, String> voskFallbackModels = {
    'en-us': 'https://alphacephei.com/vosk/models/vosk-model-small-en-us-0.15.zip',
    'en-in': 'https://alphacephei.com/vosk/models/vosk-model-small-en-in-0.4.zip',
    'hi': 'https://alphacephei.com/vosk/models/vosk-model-small-hi-0.22.zip',
  };
}

class StorageKeys {
  StorageKeys._();

  static const String scriptsBox = 'scripts';
  static const String settingsBox = 'settings';
  static const String resolution = 'resolution';
  static const String fps = 'fps';
  static const String mirror = 'mirror';
  static const String stabilization = 'stabilization';
  static const String voiceLocale = 'voiceLocale';
  static const String voiceOffline = 'voiceOffline';
  static const String seeded = 'seeded';
}
