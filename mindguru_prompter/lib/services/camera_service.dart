import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../utils/constants.dart';

/// What one physical/logical camera can record, as reported by the OS.
class LensCapabilities {
  const LensCapabilities({
    required this.id,
    required this.direction,
    required this.maxFpsBySize,
    required this.highSpeedFpsBySize,
    required this.profiles,
    required this.videoStabilization,
    required this.opticalStabilization,
    required this.hdr10Bit,
  });

  factory LensCapabilities.fromMap(Map<dynamic, dynamic> map) {
    Map<String, int> readSizes(Object? raw) {
      final result = <String, int>{};
      if (raw is List) {
        for (final entry in raw) {
          if (entry is Map) {
            final w = (entry['width'] as num).toInt();
            final h = (entry['height'] as num).toInt();
            final fps = (entry['maxFps'] as num).toInt();
            final key = _sizeKey(w, h);
            result[key] = fps > (result[key] ?? 0) ? fps : result[key]!;
          }
        }
      }
      return result;
    }

    return LensCapabilities(
      id: map['id']?.toString() ?? '',
      direction: switch (map['facing']) {
        'front' => CameraLensDirection.front,
        'external' => CameraLensDirection.external,
        _ => CameraLensDirection.back,
      },
      maxFpsBySize: readSizes(map['videoSizes']),
      highSpeedFpsBySize: readSizes(map['highSpeedSizes']),
      profiles: Map<String, bool>.from(
        (map['profiles'] as Map?)?.map((k, v) => MapEntry('$k', v == true)) ??
            const {},
      ),
      videoStabilization: map['videoStabilization'] == true,
      opticalStabilization: map['opticalStabilization'] == true,
      hdr10Bit: map['hdr10Bit'] == true,
    );
  }

  /// Builds capabilities from a known device profile (used when the native
  /// query is unavailable).
  factory LensCapabilities.fromProfile(
    CameraLensDirection direction,
    Map<VideoResolution, int> maxFps, {
    int highSpeed1080 = 0,
    bool hdr10Bit = false,
  }) {
    return LensCapabilities(
      id: direction.name,
      direction: direction,
      maxFpsBySize: {
        for (final e in maxFps.entries) _sizeKey(e.key.width, e.key.height): e.value,
      },
      highSpeedFpsBySize: highSpeed1080 > 0
          ? {_sizeKey(1920, 1080): highSpeed1080}
          : const {},
      profiles: {
        for (final e in maxFps.entries) e.key.name: true,
      },
      videoStabilization: true,
      opticalStabilization: direction == CameraLensDirection.back,
      hdr10Bit: hdr10Bit,
    );
  }

  final String id;
  final CameraLensDirection direction;

  /// "WxH" -> max fps for a normal recording session.
  final Map<String, int> maxFpsBySize;

  /// "WxH" -> max fps for a constrained high-speed session (slow-mo).
  final Map<String, int> highSpeedFpsBySize;

  /// Encoder profiles the device declares (CamcorderProfile on Android).
  final Map<String, bool> profiles;

  final bool videoStabilization;
  final bool opticalStabilization;
  final bool hdr10Bit;

  static String _sizeKey(int w, int h) => w >= h ? '${w}x$h' : '${h}x$w';

  bool supports(VideoResolution resolution) {
    // The recorder has no 1440p quality; it records through the 4K preset.
    if (resolution == VideoResolution.qhd1440) {
      return supports(VideoResolution.uhd4k) ||
          maxFpsBySize.containsKey(_sizeKey(2560, 1440));
    }
    final declared = profiles[resolution.name];
    if (declared != null) return declared;
    return maxFpsBySize.containsKey(_sizeKey(resolution.width, resolution.height));
  }

  int maxFpsFor(VideoResolution resolution) {
    final target = resolution == VideoResolution.qhd1440
        ? VideoResolution.uhd4k
        : resolution;
    final fps = maxFpsBySize[_sizeKey(target.width, target.height)];
    if (fps != null) return fps;
    return supports(resolution) ? 30 : 0;
  }

  int highSpeedFpsFor(VideoResolution resolution) {
    return highSpeedFpsBySize[_sizeKey(resolution.width, resolution.height)] ?? 0;
  }

  VideoResolution get maxResolution {
    for (final r in VideoResolution.values.reversed) {
      if (supports(r)) return r;
    }
    return VideoResolution.hd720;
  }
}

/// Device-level capabilities: identity plus per-direction lens info.
class DeviceCapabilities {
  const DeviceCapabilities({
    required this.manufacturer,
    required this.model,
    required this.marketName,
    required this.lenses,
    required this.fromNativeQuery,
  });

  final String manufacturer;
  final String model;
  final String marketName;
  final Map<CameraLensDirection, LensCapabilities> lenses;

  /// False when we fell back to a built-in device profile.
  final bool fromNativeQuery;

  static final RegExp _spaces = RegExp(r'[\s_-]+');

  String get _identity =>
      '$manufacturer $model $marketName'.toLowerCase().replaceAll(_spaces, '');

  bool get isVivoX200FE =>
      _identity.contains('x200fe') &&
      (manufacturer.toLowerCase().contains('vivo') || _identity.contains('vivo'));

  bool get isSamsung8kFlagship =>
      manufacturer.toLowerCase().contains('samsung') &&
      RegExp(r's2[2-9]|s3\d').hasMatch(_identity);

  LensCapabilities? lens(CameraLensDirection direction) =>
      lenses[direction] ?? lenses.values.firstOrNull;

  bool supports8K(CameraLensDirection direction) =>
      lens(direction)?.supports(VideoResolution.uhd8k) ?? false;

  VideoResolution maxResolution(CameraLensDirection direction) =>
      lens(direction)?.maxResolution ?? VideoResolution.fhd1080;

  String get displayName => marketName.isNotEmpty ? marketName : '$manufacturer $model';

  /// Built-in profiles for known devices, used only when the native query
  /// fails. Runtime Camera2/AVFoundation data always wins.
  static DeviceCapabilities profileFor({
    required String manufacturer,
    required String model,
    required String marketName,
  }) {
    final probe = DeviceCapabilities(
      manufacturer: manufacturer,
      model: model,
      marketName: marketName,
      lenses: const {},
      fromNativeQuery: false,
    );

    if (probe.isVivoX200FE) {
      // vivo X200 FE: 4K@30/60 rear and front, 1080p@120, no 8K.
      final lenses = {
        CameraLensDirection.back: LensCapabilities.fromProfile(
          CameraLensDirection.back,
          {
            VideoResolution.hd720: 60,
            VideoResolution.fhd1080: 60,
            VideoResolution.uhd4k: 60,
          },
          highSpeed1080: 120,
        ),
        CameraLensDirection.front: LensCapabilities.fromProfile(
          CameraLensDirection.front,
          {
            VideoResolution.hd720: 60,
            VideoResolution.fhd1080: 60,
            VideoResolution.uhd4k: 60,
          },
        ),
      };
      return DeviceCapabilities(
        manufacturer: manufacturer,
        model: model,
        marketName: marketName,
        lenses: lenses,
        fromNativeQuery: false,
      );
    }

    if (probe.isSamsung8kFlagship) {
      final lenses = {
        CameraLensDirection.back: LensCapabilities.fromProfile(
          CameraLensDirection.back,
          {
            VideoResolution.hd720: 60,
            VideoResolution.fhd1080: 60,
            VideoResolution.uhd4k: 60,
            VideoResolution.uhd8k: 30,
          },
          highSpeed1080: 120,
          hdr10Bit: true,
        ),
        CameraLensDirection.front: LensCapabilities.fromProfile(
          CameraLensDirection.front,
          {
            VideoResolution.hd720: 60,
            VideoResolution.fhd1080: 60,
            VideoResolution.uhd4k: 60,
          },
        ),
      };
      return DeviceCapabilities(
        manufacturer: manufacturer,
        model: model,
        marketName: marketName,
        lenses: lenses,
        fromNativeQuery: false,
      );
    }

    // Conservative default: every modern phone does 1080p30.
    final generic = {
      VideoResolution.hd720: 30,
      VideoResolution.fhd1080: 30,
    };
    return DeviceCapabilities(
      manufacturer: manufacturer,
      model: model,
      marketName: marketName,
      lenses: {
        CameraLensDirection.back:
            LensCapabilities.fromProfile(CameraLensDirection.back, generic),
        CameraLensDirection.front:
            LensCapabilities.fromProfile(CameraLensDirection.front, generic),
      },
      fromNativeQuery: false,
    );
  }
}

/// FPS rules: 8K is capped at 30fps; 120fps only at QHD or lower and only
/// where the hardware reports it; 60fps where the lens reaches 60 at that
/// resolution.
List<FrameRate> allowedFrameRatesFor(VideoResolution res, LensCapabilities? lens) {
  final deviceMax = lens?.maxFpsFor(res) ?? 30;
  final highSpeed = lens?.highSpeedFpsFor(res) ?? 0;

  return FrameRate.values.where((f) {
    if (res == VideoResolution.uhd8k) return f.value <= CameraConstants.max8kFps;
    if (f == FrameRate.fps120) {
      return res.index <= CameraConstants.highFrameRateCeiling.index &&
          (highSpeed >= 120 || deviceMax >= 120);
    }
    if (f == FrameRate.fps60) return deviceMax >= 60;
    return true;
  }).toList();
}

/// Full camera studio on top of the `camera` plugin, with capability
/// detection through a platform channel (Camera2 on Android, AVFoundation
/// on iOS).
class ProCameraService extends ChangeNotifier {
  ProCameraService({
    VideoResolution resolution = VideoResolution.fhd1080,
    FrameRate fps = FrameRate.fps30,
    bool stabilization = true,
  }) {
    _resolution = resolution;
    _fps = fps;
    _stabilization = stabilization;
  }

  static const MethodChannel _channel = MethodChannel(CameraConstants.deviceChannel);

  CameraController? _controller;
  List<CameraDescription> _cameras = const [];
  CameraDescription? _camera;
  DeviceCapabilities? _capabilities;

  VideoResolution _resolution = VideoResolution.fhd1080;
  FrameRate _fps = FrameRate.fps30;
  bool _stabilization = true;
  bool _hdr = false;
  List<VideoStabilizationMode> _stabilizationModes = const [];

  double _exposure = 0;
  double _minExposure = CameraConstants.minExposure;
  double _maxExposure = CameraConstants.maxExposure;
  double _exposureStep = 0.1;
  double _zoom = 1;
  double _minZoom = CameraConstants.minZoom;
  double _maxZoom = CameraConstants.maxZoom;

  bool _initializing = false;
  bool _recording = false;
  DateTime? _recordingStartedAt;
  String? _error;
  String? _notice;
  String? _lastSavedPath;
  bool _disposed = false;
  Future<void>? _pendingConfigure;

  CameraController? get controller => _controller;
  bool get isReady => _controller?.value.isInitialized ?? false;
  bool get isInitializing => _initializing;
  bool get isRecording => _recording;
  DateTime? get recordingStartedAt => _recordingStartedAt;
  String? get error => _error;
  String? get notice => _notice;
  String? get lastSavedPath => _lastSavedPath;
  DeviceCapabilities? get capabilities => _capabilities;

  VideoResolution get resolution => _resolution;
  FrameRate get fps => _fps;
  bool get stabilization => _stabilization;
  bool get stabilizationSupported =>
      _stabilizationModes.any((m) => m != VideoStabilizationMode.off);
  bool get hdr => _hdr;
  bool get hdrCapable => _currentLens?.hdr10Bit ?? false;

  double get exposure => _exposure;
  double get minExposure => _minExposure;
  double get maxExposure => _maxExposure;
  double get zoom => _zoom;
  double get minZoom => _minZoom;
  double get maxZoom => _maxZoom;

  CameraLensDirection get lensDirection =>
      _camera?.lensDirection ?? CameraLensDirection.back;
  bool get canSwitchCamera =>
      _cameras.any((c) => c.lensDirection == CameraLensDirection.front) &&
      _cameras.any((c) => c.lensDirection == CameraLensDirection.back);

  LensCapabilities? get _currentLens => _capabilities?.lens(lensDirection);

  bool get supports8K => _capabilities?.supports8K(lensDirection) ?? false;
  bool get isVivoX200FE => _capabilities?.isVivoX200FE ?? false;

  bool isResolutionSupported(VideoResolution r) => _currentLens?.supports(r) ?? r.index <= 1;

  /// Frame rates the selector should enable for [r] on the current lens.
  List<FrameRate> allowedFrameRates([VideoResolution? r]) =>
      allowedFrameRatesFor(r ?? _resolution, _currentLens);

  /// Queries the device and returns the capability model. On vivo X200 FE the
  /// max is UHD 4K (4K60); on 8K flagships (e.g. Samsung S25 Ultra) it's 8K.
  Future<DeviceCapabilities> getDeviceCapabilities() async {
    if (_capabilities != null) return _capabilities!;
    var manufacturer = '';
    var model = '';
    var marketName = '';
    try {
      final info = await _channel.invokeMapMethod<String, dynamic>('getDeviceInfo');
      manufacturer = info?['manufacturer'] as String? ?? '';
      model = info?['model'] as String? ?? '';
      marketName = info?['marketName'] as String? ?? '';

      final raw = await _channel.invokeListMethod<dynamic>('getCameraCapabilities');
      final lenses = <CameraLensDirection, LensCapabilities>{};
      for (final entry in raw ?? const []) {
        final lens = LensCapabilities.fromMap(entry as Map);
        final existing = lenses[lens.direction];
        // Keep the most capable camera per direction (the logical camera).
        if (existing == null ||
            lens.maxResolution.index > existing.maxResolution.index ||
            (lens.maxResolution == existing.maxResolution &&
                lens.maxFpsFor(lens.maxResolution) >
                    existing.maxFpsFor(existing.maxResolution))) {
          lenses[lens.direction] = lens;
        }
      }
      if (lenses.isNotEmpty) {
        _capabilities = DeviceCapabilities(
          manufacturer: manufacturer,
          model: model,
          marketName: marketName,
          lenses: lenses,
          fromNativeQuery: true,
        );
        return _capabilities!;
      }
    } on PlatformException catch (e) {
      debugPrint('Capability query failed: ${e.message}');
    } on MissingPluginException {
      debugPrint('Capability channel not available on this platform');
    }
    _capabilities = DeviceCapabilities.profileFor(
      manufacturer: manufacturer,
      model: model,
      marketName: marketName,
    );
    return _capabilities!;
  }

  Future<void> initialize() async {
    if (_initializing) return;
    _initializing = true;
    _error = null;
    _notify();

    final statuses = await [Permission.camera, Permission.microphone].request();
    if (!(statuses[Permission.camera]?.isGranted ?? false)) {
      _error = 'Camera permission is required for the studio.';
      _initializing = false;
      _notify();
      return;
    }
    if (!(statuses[Permission.microphone]?.isGranted ?? false)) {
      _notice = 'Microphone denied: videos will record without sound.';
    }

    try {
      _cameras = await availableCameras();
      if (_cameras.isEmpty) {
        _error = 'No camera found on this device.';
        return;
      }
      await getDeviceCapabilities();
      _camera = _pickCamera(_camera?.lensDirection ?? CameraLensDirection.back);
      _clampSelectionToDevice();
      await _configure();
    } on CameraException catch (e) {
      _error = _describe(e);
    } finally {
      _initializing = false;
      _notify();
    }
  }

  CameraDescription _pickCamera(CameraLensDirection direction) {
    final matching = _cameras.where((c) => c.lensDirection == direction).toList();
    if (matching.isEmpty) return _cameras.first;
    // Prefer the main wide lens; the ultrawide on vivo X200 FE is 1080p30 only.
    return matching.firstWhere(
      (c) => c.lensType == CameraLensType.wide,
      orElse: () => matching.first,
    );
  }

  void _clampSelectionToDevice() {
    if (!isResolutionSupported(_resolution)) {
      _resolution = _capabilities?.maxResolution(lensDirection) ?? VideoResolution.fhd1080;
      if (_resolution == VideoResolution.uhd8k) _resolution = VideoResolution.uhd4k;
    }
    final allowed = allowedFrameRates();
    if (!allowed.contains(_fps)) {
      _fps = allowed.lastWhere(
        (f) => f.value <= _fps.value,
        orElse: () => FrameRate.fps30,
      );
    }
  }

  /// Serializes controller rebuilds so rapid chip taps can't race.
  Future<void> _configure() {
    final previous = _pendingConfigure ?? Future<void>.value();
    final next = previous.then((_) => _buildController());
    _pendingConfigure = next.catchError((_) {});
    return next;
  }

  Future<void> _buildController({bool isRetry = false}) async {
    final camera = _camera;
    if (camera == null || _disposed) return;

    final old = _controller;
    _controller = null;
    _notify();
    await old?.dispose();

    final controller = CameraController(
      camera,
      _resolution.preset,
      enableAudio: await Permission.microphone.isGranted,
      fps: _fps.value,
      videoBitrate: _resolution.bitrateFor(_fps.value),
      imageFormatGroup: Platform.isIOS ? ImageFormatGroup.bgra8888 : null,
    );

    try {
      await controller.initialize();
    } on CameraException catch (e) {
      await controller.dispose();
      // High frame rates can fail to bind on some HALs; fall back to 30fps.
      if (!isRetry && _fps.value > 30) {
        _notice = '${_fps.label} not available at ${_resolution.label} '
            'on this lens – using 30fps.';
        _fps = FrameRate.fps30;
        return _buildController(isRetry: true);
      }
      _error = _describe(e);
      _notify();
      return;
    }

    if (_disposed) {
      await controller.dispose();
      return;
    }
    _controller = controller;

    await _loadRanges(controller);
    await _applyStabilization(controller);
    if (Platform.isIOS) {
      await controller.prepareForVideoRecording();
    }
    _notify();
  }

  Future<void> _loadRanges(CameraController controller) async {
    try {
      final results = await Future.wait([
        controller.getMinZoomLevel(),
        controller.getMaxZoomLevel(),
        controller.getMinExposureOffset(),
        controller.getMaxExposureOffset(),
        controller.getExposureOffsetStepSize(),
      ]);
      _minZoom = results[0].clamp(CameraConstants.minZoom, CameraConstants.maxZoom);
      _maxZoom = results[1].clamp(_minZoom, CameraConstants.maxZoom);
      _minExposure = results[2].clamp(CameraConstants.minExposure, 0.0);
      _maxExposure = results[3].clamp(0.0, CameraConstants.maxExposure);
      _exposureStep = results[4] > 0 ? results[4] : 0.1;

      _zoom = _zoom.clamp(_minZoom, _maxZoom);
      _exposure = _exposure.clamp(_minExposure, _maxExposure);
      await controller.setZoomLevel(_zoom);
      await controller.setExposureOffset(_exposure);
      await controller.setFocusMode(FocusMode.auto);
    } on CameraException catch (e) {
      debugPrint('Range query failed: ${e.description}');
    }
  }

  Future<void> _applyStabilization(CameraController controller) async {
    try {
      _stabilizationModes =
          (await controller.getSupportedVideoStabilizationModes()).toList();
      if (stabilizationSupported) {
        await controller.setVideoStabilizationMode(
          _stabilization ? VideoStabilizationMode.level2 : VideoStabilizationMode.off,
        );
      }
    } on CameraException catch (e) {
      debugPrint('Stabilization not applied: ${e.description}');
    } on UnimplementedError {
      _stabilizationModes = const [];
    }
  }

  /// Selects a resolution. Unsupported ones (8K on vivo X200 FE) are ignored.
  /// Auto-limits fps: 8K forces ≤30fps; QHD and lower may use 60/120.
  Future<void> setResolution(VideoResolution resolution) async {
    if (_recording || resolution == _resolution) return;
    if (!isResolutionSupported(resolution)) {
      _notice = '${resolution.label} is not supported on this device – '
          'max ${_capabilities?.maxResolution(lensDirection).label ?? '4K'}.';
      _notify();
      return;
    }
    _resolution = resolution;
    final allowed = allowedFrameRates(resolution);
    if (resolution == VideoResolution.uhd8k && _fps.value > CameraConstants.max8kFps) {
      _fps = FrameRate.fps30;
      _notice = '8K is limited to 30fps – FPS set to 30.';
    } else if (!allowed.contains(_fps)) {
      _fps = allowed.lastWhere((f) => f.value <= _fps.value, orElse: () => FrameRate.fps30);
      _notice = '${resolution.label} supports up to ${allowed.last.label} here – '
          'FPS set to ${_fps.value}.';
    }
    await _configure();
  }

  Future<void> setFps(FrameRate fps) async {
    if (_recording || fps == _fps) return;
    if (!allowedFrameRates().contains(fps)) {
      _notice = '${fps.label} is not available at ${_resolution.label}.';
      _notify();
      return;
    }
    _fps = fps;
    await _configure();
  }

  /// Exposure compensation in EV, clamped to -2..+2 and the device range.
  Future<void> setExposure(double offset) async {
    final controller = _controller;
    final clamped = offset.clamp(_minExposure, _maxExposure);
    final stepped = ((clamped / _exposureStep).round() * _exposureStep)
        .clamp(_minExposure, _maxExposure);
    _exposure = stepped;
    _notify();
    if (controller == null || !isReady) return;
    try {
      _exposure = await controller.setExposureOffset(stepped);
    } on CameraException catch (e) {
      debugPrint('Exposure failed: ${e.description}');
    }
  }

  /// Zoom 1x..10x, clamped to what the lens reports.
  Future<void> setZoom(double level) async {
    final controller = _controller;
    _zoom = level.clamp(_minZoom, _maxZoom);
    _notify();
    if (controller == null || !isReady) return;
    try {
      await controller.setZoomLevel(_zoom);
    } on CameraException catch (e) {
      debugPrint('Zoom failed: ${e.description}');
    }
  }

  /// Tap to focus + expose. [point] is normalized (0..1) in preview space.
  Future<void> setFocusPoint(Offset point) async {
    final controller = _controller;
    if (controller == null || !isReady) return;
    final normalized = Offset(point.dx.clamp(0.0, 1.0), point.dy.clamp(0.0, 1.0));
    try {
      if (controller.value.focusPointSupported) {
        await controller.setFocusPoint(normalized);
      }
      if (controller.value.exposurePointSupported) {
        await controller.setExposurePoint(normalized);
      }
    } on CameraException catch (e) {
      debugPrint('Focus failed: ${e.description}');
    }
  }

  Future<void> switchCamera() async {
    if (_recording || !canSwitchCamera) return;
    final nextDirection = lensDirection == CameraLensDirection.back
        ? CameraLensDirection.front
        : CameraLensDirection.back;
    _camera = _pickCamera(nextDirection);
    _zoom = 1;
    _clampSelectionToDevice();
    await _configure();
  }

  Future<void> setStabilization(bool enabled) async {
    _stabilization = enabled;
    _notify();
    final controller = _controller;
    if (controller != null && isReady) await _applyStabilization(controller);
  }

  /// HDR preference. The Flutter camera plugin records 8-bit SDR; 10-bit HLG
  /// capture isn't exposed by CameraX/AVFoundation through the plugin. The
  /// toggle is kept (and persisted) and the UI says so honestly.
  void setHdr(bool enabled) {
    _hdr = enabled;
    _notice = enabled
        ? (hdrCapable
            ? 'HDR: this lens supports 10-bit HLG, but the Flutter camera '
                'plugin records SDR. The phone\'s own tone mapping still applies.'
            : 'HDR video is not reported by this lens.')
        : null;
    _notify();
  }

  void clearNotice() {
    _notice = null;
    _notify();
  }

  Future<void> startRecording() async {
    final controller = _controller;
    if (controller == null || !isReady || _recording) return;
    try {
      await controller.startVideoRecording();
      _recording = true;
      _recordingStartedAt = DateTime.now();
      _error = null;
      await WakelockPlus.enable();
    } on CameraException catch (e) {
      _error = _describe(e);
    }
    _notify();
  }

  /// Stops recording, moves the file into the app's Videos folder and copies
  /// it to the gallery album. Returns the saved path.
  Future<String?> stopRecording() async {
    final controller = _controller;
    if (controller == null || !_recording) return null;
    try {
      final file = await controller.stopVideoRecording();
      _recording = false;
      _recordingStartedAt = null;
      _notify();

      final dir = Directory(
        p.join((await getApplicationDocumentsDirectory()).path, 'Videos'),
      );
      await dir.create(recursive: true);
      final stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(RegExp(r'[:.]'), '-')
          .substring(0, 19);
      final extension = p.extension(file.path).isEmpty ? '.mp4' : p.extension(file.path);
      final target = p.join(dir.path, 'MindGuru_${_resolution.label}_$stamp$extension');
      await file.saveTo(target);

      try {
        if (!await Gal.hasAccess(toAlbum: true)) {
          await Gal.requestAccess(toAlbum: true);
        }
        await Gal.putVideo(target, album: CameraConstants.galleryAlbum);
        _notice = 'Saved to gallery › ${CameraConstants.galleryAlbum}';
      } on GalException catch (e) {
        _notice = 'Saved in app storage (gallery: ${e.type.message})';
      }
      _lastSavedPath = target;
      return target;
    } on CameraException catch (e) {
      _recording = false;
      _error = _describe(e);
      return null;
    } finally {
      await WakelockPlus.disable();
      _notify();
    }
  }

  /// Releases the camera when the app goes to background.
  Future<void> pauseSession() async {
    if (_recording) await stopRecording();
    final old = _controller;
    _controller = null;
    _notify();
    await old?.dispose();
  }

  Future<void> resumeSession() async {
    if (_initializing || _controller != null || _camera == null) return;
    await _configure();
  }

  String _describe(CameraException e) => switch (e.code) {
        'CameraAccessDenied' ||
        'CameraAccessDeniedWithoutPrompt' ||
        'CameraAccessRestricted' =>
          'Camera access denied. Enable it in Settings.',
        'AudioAccessDenied' ||
        'AudioAccessDeniedWithoutPrompt' ||
        'AudioAccessRestricted' =>
          'Microphone access denied. Enable it in Settings.',
        _ => e.description ?? e.code,
      };

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    final controller = _controller;
    _controller = null;
    controller?.dispose();
    WakelockPlus.disable();
    super.dispose();
  }
}
