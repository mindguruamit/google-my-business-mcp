import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/script_model.dart';
import '../utils/constants.dart';

/// Message shapes shared between the app and the floating prompter.
class FloatingMessage {
  FloatingMessage._();

  static const String script = 'script';
  static const String control = 'control';
  static const String ready = 'ready';

  static const String play = 'play';
  static const String pause = 'pause';
  static const String speed = 'speed';
  static const String mirror = 'mirror';
  static const String seek = 'seek';

  static const String payloadFile = 'floating_script.json';

  static Future<File> payloadPath() async {
    final dir = await getApplicationSupportDirectory();
    return File(p.join(dir.path, payloadFile));
  }
}

/// Floating prompter above other apps (Instagram, TikTok, YouTube…).
///
/// Android: a draggable system overlay window via flutter_overlay_window,
/// rendering `overlayMain` from main.dart.
/// iOS: iOS does not allow drawing over other apps, so the script is rendered
/// into a Picture-in-Picture window (native, see TeleprompterPip in
/// ios/Runner/AppDelegate.swift).
class FloatingService {
  FloatingService._();

  static final FloatingService instance = FloatingService._();

  static const MethodChannel _pip = MethodChannel(CameraConstants.pipChannel);

  /// Requested window size in physical pixels (800×400), converted to dp and
  /// clamped to the screen for the overlay plugin.
  static const double widthPx = 800;
  static const double heightPx = 400;

  bool get isSupported => Platform.isAndroid || Platform.isIOS;

  Future<bool> hasPermission() async {
    if (Platform.isAndroid) return FlutterOverlayWindow.isPermissionGranted();
    if (Platform.isIOS) return await _pip.invokeMethod<bool>('isSupported') ?? false;
    return false;
  }

  /// Android opens the "Display over other apps" settings page.
  Future<bool> requestPermission() async {
    if (Platform.isAndroid) {
      if (await FlutterOverlayWindow.isPermissionGranted()) return true;
      return await FlutterOverlayWindow.requestPermission() ?? false;
    }
    return hasPermission();
  }

  Future<bool> isActive() async {
    if (Platform.isAndroid) return FlutterOverlayWindow.isActive();
    if (Platform.isIOS) return await _pip.invokeMethod<bool>('isActive') ?? false;
    return false;
  }

  Map<String, dynamic> _payload(
    ScriptModel script, {
    required double progress,
    required bool mirror,
  }) =>
      {
        'type': FloatingMessage.script,
        'id': script.id,
        'title': script.title,
        'content': script.content,
        'wpm': script.scrollSpeed,
        'fontSize': script.fontSize,
        'mirror': mirror,
        'progress': progress,
      };

  /// Shows the floating prompter with [script], starting at [progress].
  Future<bool> showFloating(
    ScriptModel script, {
    double progress = 0,
    bool mirror = false,
  }) async {
    if (!await requestPermission()) return false;
    final payload = _payload(script, progress: progress, mirror: mirror);

    // The overlay runs in its own Flutter engine; it reads this file on
    // start, then follows live updates over the message channel.
    final file = await FloatingMessage.payloadPath();
    await file.writeAsString(jsonEncode(payload));

    if (Platform.isAndroid) {
      if (await FlutterOverlayWindow.isActive()) {
        await FlutterOverlayWindow.closeOverlay();
      }
      final view = PlatformDispatcher.instance.views.first;
      final dpr = view.devicePixelRatio;
      final widthDp = (widthPx.clamp(0, view.physicalSize.width) / dpr).round();
      final heightDp = (heightPx / dpr).round();

      await FlutterOverlayWindow.showOverlay(
        width: widthDp,
        height: heightDp,
        alignment: OverlayAlignment.topCenter,
        enableDrag: true,
        flag: OverlayFlag.defaultFlag,
        positionGravity: PositionGravity.none,
        visibility: NotificationVisibility.visibilityPublic,
        overlayTitle: 'MindGuru Prompter',
        overlayContent: 'Floating prompter: ${script.title}',
      );
      // Belt and braces: the overlay engine may not be listening yet.
      for (final delay in const [300, 900, 1800]) {
        unawaited(
          Future<void>.delayed(Duration(milliseconds: delay), () => _send(payload)),
        );
      }
      return true;
    }

    if (Platform.isIOS) {
      try {
        return await _pip.invokeMethod<bool>('start', payload) ?? false;
      } on PlatformException catch (e) {
        debugPrint('PiP failed: ${e.message}');
        return false;
      }
    }
    return false;
  }

  Future<void> sendControl(String action, [Object? value]) async {
    final message = {'type': FloatingMessage.control, 'action': action, 'value': value};
    if (Platform.isAndroid) {
      await _send(message);
    } else if (Platform.isIOS) {
      await _pip.invokeMethod<void>('control', message);
    }
  }

  Future<void> _send(Map<String, dynamic> message) async {
    try {
      if (await FlutterOverlayWindow.isActive()) {
        await FlutterOverlayWindow.shareData(jsonEncode(message));
      }
    } catch (e) {
      debugPrint('Overlay message failed: $e');
    }
  }

  Future<void> close() async {
    if (Platform.isAndroid) {
      if (await FlutterOverlayWindow.isActive()) {
        await FlutterOverlayWindow.closeOverlay();
      }
    } else if (Platform.isIOS) {
      await _pip.invokeMethod<void>('stop');
    }
  }
}
