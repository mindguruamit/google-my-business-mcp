import 'dart:async';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../models/script_document.dart';
import '../models/script_model.dart';
import '../services/camera_service.dart';
import '../services/floating_service.dart';
import '../services/script_repository.dart';
import '../services/teleprompter_engine.dart';
import '../services/voice_track_service.dart';
import '../state/library_cubit.dart';
import '../utils/app_theme.dart';
import '../utils/constants.dart';
import '../widgets/resolution_selector.dart';
import '../widgets/speed_control.dart';
import '../widgets/studio_widgets.dart';
import '../widgets/teleprompter_view.dart';

/// The studio: full-screen camera, pro controls, and the teleprompter.
class RecordingScreen extends StatefulWidget {
  const RecordingScreen({super.key, required this.script});

  final ScriptModel script;

  @override
  State<RecordingScreen> createState() => _RecordingScreenState();
}

class _RecordingScreenState extends State<RecordingScreen> with WidgetsBindingObserver {
  late final ScriptRepository _repository = context.read<LibraryCubit>().repository;
  late final ProCameraService _camera;
  late final TeleprompterEngine _engine;
  late final VoiceTrackService _voice;
  late final ScriptDocument _document;

  late bool _mirror;
  late double _fontSize;
  late int _wpm;
  bool _showEyeGuide = true;

  Offset? _focusPosition;
  double _zoomAtScaleStart = 1;
  String? _lastShownNotice;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

    final script = widget.script;
    _document = ScriptDocument.parse(script.content);
    _wpm = script.scrollSpeed;
    _fontSize = script.fontSize;
    _mirror = _repository.setting<bool>(StorageKeys.mirror, false);

    _camera = ProCameraService(
      resolution: VideoResolution.fromName(
        _repository.setting<String?>(StorageKeys.resolution, null),
      ),
      fps: FrameRate.fromValue(_repository.setting<int?>(StorageKeys.fps, null)),
      stabilization: _repository.setting<bool>(StorageKeys.stabilization, true),
    )..addListener(_onCameraChanged);
    unawaited(_camera.initialize());

    _engine = TeleprompterEngine(wpm: _wpm)
      ..load(wordCount: _document.wordCount, markers: _document.markers);

    _voice = VoiceTrackService()
      ..attachEngine(_engine)
      ..loadScript(script.content)
      ..addListener(_onVoiceChanged);
    final locale = _repository.setting<String?>(StorageKeys.voiceLocale, null);
    if (locale != null) unawaited(_voice.setLocale(locale));
    if (_repository.setting<bool>(StorageKeys.voiceOffline, false)) {
      unawaited(_voice.setMode(VoiceEngineMode.offline));
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // `inactive` also fires for permission dialogs and the notification
    // shade, so only release the camera once the app is really hidden.
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        _engine.pause();
        unawaited(_voice.stopTracking());
        unawaited(_camera.pauseSession());
      case AppLifecycleState.resumed:
        unawaited(_camera.resumeSession());
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }

  void _onCameraChanged() {
    final notice = _camera.notice;
    if (notice != null && notice != _lastShownNotice && mounted) {
      _lastShownNotice = notice;
      _toast(notice);
    }
  }

  String? _lastVoiceError;
  void _onVoiceChanged() {
    final error = _voice.error;
    if (error != null && error != _lastVoiceError && mounted) {
      _lastVoiceError = error;
      _toast(error);
    }
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message), duration: const Duration(seconds: 3)));
  }

  // ---------------------------------------------------------------------------
  // Actions

  Future<void> _toggleRecording() async {
    HapticFeedback.mediumImpact();
    if (_camera.isRecording) {
      _engine.pause();
      final path = await _camera.stopRecording();
      if (path != null && mounted) {
        _toast(_camera.notice ?? 'Saved: $path');
      }
    } else {
      await _camera.startRecording();
      // Auto-scroll with the take unless VoiceTrack is steering.
      if (_camera.isRecording && !_voice.isTracking && !_engine.isPlaying) {
        _engine.play();
      }
    }
  }

  Future<void> _toggleVoice() async {
    HapticFeedback.selectionClick();
    await _voice.toggle();
  }

  Future<void> _float() async {
    final script = widget.script
      ..scrollSpeed = _wpm
      ..fontSize = _fontSize;
    final shown = await FloatingService.instance.showFloating(
      script,
      progress: _engine.progress,
      mirror: _mirror,
    );
    if (!mounted) return;
    _toast(
      shown
          ? 'Floating prompter is on – open Instagram, TikTok or YouTube.'
          : 'Allow "Display over other apps" to use the floating prompter.',
    );
  }

  void _setWpm(int wpm) {
    setState(() => _wpm = wpm);
    _engine.setSpeed(wpm);
  }

  Future<void> _persistScriptSettings() async {
    widget.script
      ..scrollSpeed = _wpm
      ..fontSize = _fontSize;
    await _repository.save(widget.script);
  }

  Future<void> _setResolution(VideoResolution resolution) async {
    await _camera.setResolution(resolution);
    await _repository.putSetting(StorageKeys.resolution, _camera.resolution.name);
    await _repository.putSetting(StorageKeys.fps, _camera.fps.value);
  }

  Future<void> _setFps(FrameRate fps) async {
    await _camera.setFps(fps);
    await _repository.putSetting(StorageKeys.fps, _camera.fps.value);
  }

  Future<void> _toggleStabilization() async {
    await _camera.setStabilization(!_camera.stabilization);
    await _repository.putSetting(StorageKeys.stabilization, _camera.stabilization);
  }

  Future<void> _toggleMirror() async {
    setState(() => _mirror = !_mirror);
    await _repository.putSetting(StorageKeys.mirror, _mirror);
  }

  Future<bool> _confirmLeaveWhileRecording() async {
    final leave = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Stop recording?'),
        content: const Text('The current take will be saved before leaving.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep recording'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Stop & leave'),
          ),
        ],
      ),
    );
    if (leave ?? false) {
      await _camera.stopRecording();
      return true;
    }
    return false;
  }

  // ---------------------------------------------------------------------------
  // Build

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (_camera.isRecording && !await _confirmLeaveWhileRecording()) return;
        await _persistScriptSettings();
        if (context.mounted) Navigator.of(context).pop();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: ListenableBuilder(
          listenable: Listenable.merge([_camera, _voice]),
          builder: (context, _) {
            return Stack(
              children: [
                Positioned.fill(child: _buildPreview()),
                if (_showEyeGuide && _camera.lensDirection == CameraLensDirection.front)
                  const EyeContactGuide(),
                if (_focusPosition != null) FocusIndicator(position: _focusPosition!),
                Positioned.fill(
                  child: SafeArea(
                    child: LayoutBuilder(
                      builder: (context, constraints) => Column(
                        children: [
                          _buildTopBar(),
                          const SizedBox(height: 6),
                          _buildCaptureControls(),
                          if (_voice.isTracking) ...[
                            const SizedBox(height: 8),
                            VoiceIndicator(
                              level: _voice.soundLevel,
                              lastWord: _voice.lastWord,
                              preparing: _voice.isPreparingOffline,
                            ),
                          ],
                          Expanded(child: _buildSideSliders()),
                          _buildPrompter(
                            math.min(
                              TeleprompterConstants.overlayHeight,
                              constraints.maxHeight * 0.36,
                            ),
                          ),
                          const SizedBox(height: 4),
                          SpeedControl(
                            wpm: _wpm,
                            adaptiveFactor: _voice.isTracking ? _engine.adaptiveFactor : 1,
                            onChanged: _setWpm,
                            onChangeEnd: (_) => _persistScriptSettings(),
                          ),
                          _buildBottomBar(),
                          const SizedBox(height: 8),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildPreview() {
    final controller = _camera.controller;
    if (_camera.error != null) {
      return _PreviewMessage(
        icon: Icons.videocam_off_outlined,
        text: _camera.error!,
        action: TextButton(onPressed: _camera.initialize, child: const Text('Retry')),
      );
    }
    if (controller == null || !controller.value.isInitialized) {
      return const Center(child: CircularProgressIndicator(color: AppColors.accent));
    }

    return LayoutBuilder(
      builder: (context, box) {
        final size = controller.value.previewSize;
        if (size == null) return CameraPreview(controller);

        // previewSize is landscape; the UI is portrait. Cover the screen.
        final previewW = math.min(size.width, size.height);
        final previewH = math.max(size.width, size.height);
        final scale = math.max(box.maxWidth / previewW, box.maxHeight / previewH);
        final shownW = previewW * scale;
        final shownH = previewH * scale;
        final dx = (box.maxWidth - shownW) / 2;
        final dy = (box.maxHeight - shownH) / 2;

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (details) {
            final local = details.localPosition;
            final point = Offset(
              ((local.dx - dx) / shownW).clamp(0.0, 1.0),
              ((local.dy - dy) / shownH).clamp(0.0, 1.0),
            );
            setState(() => _focusPosition = local);
            HapticFeedback.selectionClick();
            _camera.setFocusPoint(point);
          },
          onScaleStart: (_) => _zoomAtScaleStart = _camera.zoom,
          onScaleUpdate: (details) {
            if (details.pointerCount < 2) return;
            _camera.setZoom(_zoomAtScaleStart * details.scale);
          },
          child: ClipRect(
            child: OverflowBox(
              maxWidth: shownW,
              maxHeight: shownH,
              child: SizedBox(
                width: shownW,
                height: shownH,
                child: CameraPreview(controller),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildTopBar() {
    final caps = _camera.capabilities;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Column(
        children: [
          Row(
            children: [
              IconButton(
                onPressed: () => Navigator.of(context).maybePop(),
                icon: const Icon(Icons.arrow_back_ios_new, color: Colors.white),
              ),
              Expanded(
                child: Text(
                  widget.script.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                ),
              ),
              if (_camera.isRecording) _RecordingTimer(startedAt: _camera.recordingStartedAt),
              IconButton(
                tooltip: 'Prompter settings',
                onPressed: _openSettings,
                icon: const Icon(Icons.tune, color: Colors.white),
              ),
            ],
          ),
          if (caps != null && caps.isVivoX200FE)
            const _InfoBanner(text: 'vivo X200 FE detected: Max 4K60 optimized'),
        ],
      ),
    );
  }

  Widget _buildCaptureControls() {
    final caps = _camera.capabilities;
    final maxRes = caps?.maxResolution(_camera.lensDirection) ?? VideoResolution.uhd4k;
    final maxFps = caps?.lens(_camera.lensDirection)?.maxFpsFor(maxRes) ?? 30;
    final locked = _camera.isRecording;

    return Column(
      children: [
        ResolutionSelector(
          selected: _camera.resolution,
          isSupported: _camera.isResolutionSupported,
          onSelected: _setResolution,
          maxLabel: '${maxRes.label}$maxFps',
          enabled: !locked,
        ),
        const SizedBox(height: 6),
        SizedBox(
          height: 36,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              FpsSelector(
                selected: _camera.fps,
                allowed: _camera.allowedFrameRates(),
                onSelected: _setFps,
                enabled: !locked,
              ),
              const SizedBox(width: 10),
              StudioToggleChip(
                label: 'HDR',
                icon: Icons.hdr_on,
                selected: _camera.hdr,
                onTap: () => _camera.setHdr(!_camera.hdr),
                tooltip: _camera.hdrCapable
                    ? 'Lens supports 10-bit HLG; plugin records SDR'
                    : 'HDR video not reported by this lens',
              ),
              const SizedBox(width: 6),
              StudioToggleChip(
                label: 'Stabilize',
                icon: Icons.vibration,
                selected: _camera.stabilization && _camera.stabilizationSupported,
                enabled: _camera.stabilizationSupported && !locked,
                onTap: _toggleStabilization,
                tooltip: _camera.stabilizationSupported
                    ? 'Video stabilization'
                    : 'Stabilization not available on this lens',
              ),
              const SizedBox(width: 6),
              StudioToggleChip(
                label: 'Mirror',
                icon: Icons.flip,
                selected: _mirror,
                onTap: _toggleMirror,
                tooltip: 'Flip prompter text for beam-splitter glass',
              ),
              const SizedBox(width: 6),
              StudioToggleChip(
                label: 'Float',
                icon: Icons.picture_in_picture_alt,
                selected: false,
                onTap: _float,
                tooltip: 'Floating prompter over other apps',
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSideSliders() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        _VerticalSlider(
          label: '${_camera.zoom.toStringAsFixed(1)}x',
          icon: Icons.zoom_in,
          value: _camera.zoom,
          min: _camera.minZoom,
          max: math.max(_camera.minZoom + 0.1, _camera.maxZoom),
          onChanged: _camera.setZoom,
        ),
        const Spacer(),
        _VerticalSlider(
          label: '${_camera.exposure >= 0 ? '+' : ''}${_camera.exposure.toStringAsFixed(1)} EV',
          icon: Icons.exposure,
          value: _camera.exposure,
          min: _camera.minExposure,
          max: math.max(_camera.minExposure + 0.1, _camera.maxExposure),
          onChanged: _camera.setExposure,
          onReset: () => _camera.setExposure(0),
        ),
      ],
    );
  }

  Widget _buildPrompter(double height) {
    return Container(
      height: height,
      margin: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: TeleprompterConstants.overlayOpacity),
        borderRadius: BorderRadius.circular(18),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Positioned.fill(
            child: TeleprompterView(
              document: _document,
              engine: _engine,
              fontSize: _fontSize,
              mirror: _mirror,
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 0),
            ),
          ),
          Positioned(
            right: 10,
            top: 8,
            child: ValueListenableBuilder<CueMarker?>(
              valueListenable: _engine.activeCue,
              builder: (context, cue, _) => cue == null
                  ? const SizedBox.shrink()
                  : Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: AppColors.marker.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        cue.type == CueType.breath ? 'Breathe…' : 'Pause',
                        style: const TextStyle(color: AppColors.marker, fontWeight: FontWeight.w700),
                      ),
                    ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: StreamBuilder<double>(
              stream: _engine.scrollStream,
              builder: (context, snapshot) => LinearProgressIndicator(
                value: _engine.progress,
                minHeight: 3,
                color: AppColors.accent,
                backgroundColor: Colors.white12,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          ValueListenableBuilder<bool>(
            valueListenable: _engine.playing,
            builder: (context, playing, _) => StudioRoundButton(
              icon: playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
              tooltip: playing ? 'Pause prompter' : 'Play prompter',
              active: playing,
              onPressed: _engine.toggle,
            ),
          ),
          RecordButton(
            recording: _camera.isRecording,
            onPressed: _camera.isReady ? _toggleRecording : null,
          ),
          StudioRoundButton(
            icon: _voice.isTracking ? Icons.hearing : Icons.hearing_disabled,
            tooltip: _voice.isTracking ? 'Stop VoiceTrack' : 'VoiceTrack: follow my voice',
            active: _voice.isTracking,
            onPressed: _toggleVoice,
          ),
          StudioRoundButton(
            icon: Icons.cameraswitch_rounded,
            tooltip: 'Switch camera',
            onPressed:
                _camera.canSwitchCamera && !_camera.isRecording ? _camera.switchCamera : null,
          ),
        ],
      ),
    );
  }

  Future<void> _openSettings() async {
    if (!_voice.isAvailable) await _voice.initialize();
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheet) {
          void update(VoidCallback change) {
            setState(change);
            setSheet(() {});
          }

          final locales = [..._voice.locales]..sort((a, b) => a.name.compareTo(b.name));
          final selectedLocale =
              locales.any((l) => l.localeId == _voice.localeId) ? _voice.localeId : null;

          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Prompter settings',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 12),
                  Text('Text size ${_fontSize.round()}'),
                  Slider(
                    value: _fontSize,
                    min: TeleprompterConstants.minFontSize,
                    max: TeleprompterConstants.maxFontSize,
                    onChanged: (v) => update(() => _fontSize = v),
                    onChangeEnd: (_) => _persistScriptSettings(),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Eye-contact dot'),
                    subtitle: const Text('Lime dot under the front camera'),
                    value: _showEyeGuide,
                    onChanged: (v) => update(() => _showEyeGuide = v),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Offline VoiceTrack (Vosk)'),
                    subtitle: const Text(
                      'No internet while tracking. Downloads a ~50 MB model once.',
                    ),
                    value: _voice.mode == VoiceEngineMode.offline,
                    onChanged: (v) async {
                      await _voice.setMode(v ? VoiceEngineMode.offline : VoiceEngineMode.system);
                      await _repository.putSetting(StorageKeys.voiceOffline, v);
                      setSheet(() {});
                    },
                  ),
                  const SizedBox(height: 8),
                  const Text('VoiceTrack language'),
                  const SizedBox(height: 6),
                  DropdownButtonFormField<String>(
                    initialValue: selectedLocale,
                    isExpanded: true,
                    hint: Text(
                      locales.isEmpty ? 'System default' : '${locales.length} languages available',
                    ),
                    items: [
                      for (final l in locales)
                        DropdownMenuItem(value: l.localeId, child: Text(l.name)),
                    ],
                    onChanged: (id) async {
                      await _voice.setLocale(id);
                      await _repository.putSetting(StorageKeys.voiceLocale, id);
                      setSheet(() {});
                    },
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      OutlinedButton.icon(
                        onPressed: () {
                          _engine.seek(0);
                          Navigator.pop(context);
                        },
                        icon: const Icon(Icons.vertical_align_top),
                        label: const Text('Back to top'),
                      ),
                      const Spacer(),
                      Text(
                        '${_document.wordCount} words · '
                        '${formatDuration(_document.estimateDuration(_wpm))}',
                        style: const TextStyle(color: AppColors.textSecondary),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _camera
      ..removeListener(_onCameraChanged)
      ..dispose();
    _voice
      ..removeListener(_onVoiceChanged)
      ..dispose();
    _engine.dispose();
    super.dispose();
  }
}

class _RecordingTimer extends StatelessWidget {
  const _RecordingTimer({required this.startedAt});

  final DateTime? startedAt;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<int>(
      stream: Stream.periodic(const Duration(milliseconds: 500), (i) => i),
      builder: (context, _) {
        final elapsed = startedAt == null ? Duration.zero : DateTime.now().difference(startedAt!);
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: AppColors.recording,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.fiber_manual_record, size: 12, color: Colors.white),
              const SizedBox(width: 4),
              Text(
                formatDuration(elapsed),
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _InfoBanner extends StatelessWidget {
  const _InfoBanner({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(8, 2, 8, 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.accent.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.accent.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          const Icon(Icons.verified, size: 16, color: AppColors.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(color: AppColors.accent, fontWeight: FontWeight.w600, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

class _VerticalSlider extends StatelessWidget {
  const _VerticalSlider({
    required this.label,
    required this.icon,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.onReset,
  });

  final String label;
  final IconData icon;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;
  final VoidCallback? onReset;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final length = math.min(180.0, constraints.maxHeight - 48);
        if (length < 60) return const SizedBox(width: 48);
        return GestureDetector(
          onDoubleTap: onReset,
          child: Container(
            width: 48,
            padding: const EdgeInsets.symmetric(vertical: 6),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(24),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 18, color: Colors.white),
                SizedBox(
                  height: length,
                  child: RotatedBox(
                    quarterTurns: 3,
                    child: Slider(
                      value: value.clamp(min, max),
                      min: min,
                      max: max,
                      onChanged: onChanged,
                    ),
                  ),
                ),
                Text(
                  label,
                  style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _PreviewMessage extends StatelessWidget {
  const _PreviewMessage({required this.icon, required this.text, this.action});

  final IconData icon;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: AppColors.textSecondary),
            const SizedBox(height: 12),
            Text(text, textAlign: TextAlign.center),
            ?action,
          ],
        ),
      ),
    );
  }
}
