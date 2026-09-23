import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';

import '../models/script_document.dart';
import '../services/floating_service.dart';
import '../services/teleprompter_engine.dart';
import '../utils/app_theme.dart';
import '../utils/constants.dart';
import '../widgets/teleprompter_view.dart';

/// Root widget of the Android floating window. Runs in its own Flutter
/// engine (entry point `overlayMain` in main.dart), so it gets its script
/// from a JSON file plus live messages over the overlay channel.
class FloatingPrompterApp extends StatelessWidget {
  const FloatingPrompterApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      color: Colors.transparent,
      home: const Material(
        type: MaterialType.transparency,
        child: FloatingPrompter(),
      ),
    );
  }
}

class FloatingPrompter extends StatefulWidget {
  const FloatingPrompter({super.key});

  @override
  State<FloatingPrompter> createState() => _FloatingPrompterState();
}

class _FloatingPrompterState extends State<FloatingPrompter> {
  final TeleprompterEngine _engine = TeleprompterEngine();
  StreamSubscription<dynamic>? _messages;

  ScriptDocument? _document;
  String _scriptId = '';
  String _title = '';
  double _fontSize = 22;
  bool _mirror = false;

  @override
  void initState() {
    super.initState();
    _messages = FlutterOverlayWindow.overlayListener.listen(_onMessage);
    _loadFromFile();
  }

  Future<void> _loadFromFile() async {
    try {
      final file = await FloatingMessage.payloadPath();
      if (await file.exists()) {
        _apply(jsonDecode(await file.readAsString()) as Map<String, dynamic>);
      }
    } catch (e) {
      debugPrint('Floating prompter could not read script: $e');
    }
  }

  void _onMessage(dynamic raw) {
    try {
      final message = raw is String
          ? jsonDecode(raw) as Map<String, dynamic>
          : Map<String, dynamic>.from(raw as Map);
      switch (message['type']) {
        case FloatingMessage.script:
          _apply(message);
        case FloatingMessage.control:
          _control(message['action'] as String?, message['value']);
      }
    } catch (e) {
      debugPrint('Floating prompter ignored message: $e');
    }
  }

  void _apply(Map<String, dynamic> payload) {
    final id = payload['id'] as String? ?? '';
    final content = payload['content'] as String? ?? '';
    // The app sends the same script a few times while the engine boots.
    if (id == _scriptId && _document?.raw == content) return;

    final document = ScriptDocument.parse(content);
    final wpm = (payload['wpm'] as num?)?.toInt() ?? TeleprompterConstants.defaultWpm;
    final fontSize = (payload['fontSize'] as num?)?.toDouble() ??
        TeleprompterConstants.defaultFontSize;

    _engine
      ..load(wordCount: document.wordCount, markers: document.markers)
      ..setSpeed(wpm)
      ..seek((payload['progress'] as num?)?.toDouble() ?? 0);

    setState(() {
      _scriptId = id;
      _title = payload['title'] as String? ?? '';
      _document = document;
      // The window is small, so scale the studio font down.
      _fontSize = (fontSize * 0.62).clamp(16.0, 34.0);
      _mirror = payload['mirror'] == true;
    });
  }

  void _control(String? action, Object? value) {
    switch (action) {
      case FloatingMessage.play:
        _engine.play();
      case FloatingMessage.pause:
        _engine.pause();
      case FloatingMessage.speed:
        if (value is num) setState(() => _engine.setSpeed(value.toInt()));
      case FloatingMessage.mirror:
        setState(() => _mirror = value == true);
      case FloatingMessage.seek:
        if (value is num) _engine.seek(value.toDouble());
    }
  }

  void _changeSpeed(int delta) {
    setState(() => _engine.setSpeed(_engine.wpm + delta));
  }

  @override
  Widget build(BuildContext context) {
    final document = _document;
    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.78),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.accent.withValues(alpha: 0.4)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          _toolbar(),
          Expanded(
            child: document == null
                ? const Center(
                    child: Text(
                      'Waiting for script…',
                      style: TextStyle(color: AppColors.textSecondary),
                    ),
                  )
                : TeleprompterView(
                    document: document,
                    engine: _engine,
                    fontSize: _fontSize,
                    mirror: _mirror,
                    readingLine: 0.25,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _toolbar() {
    return Container(
      height: 36,
      color: AppColors.card.withValues(alpha: 0.9),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          const Icon(Icons.drag_indicator, size: 18, color: AppColors.textSecondary),
          Expanded(
            child: Text(
              _title.isEmpty ? 'MindGuru Prompter' : _title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
            ),
          ),
          _MiniButton(icon: Icons.remove, onTap: () => _changeSpeed(-10)),
          Text(
            '${_engine.wpm}',
            style: const TextStyle(fontSize: 11, color: AppColors.accent, fontWeight: FontWeight.w700),
          ),
          _MiniButton(icon: Icons.add, onTap: () => _changeSpeed(10)),
          ValueListenableBuilder<bool>(
            valueListenable: _engine.playing,
            builder: (context, playing, _) => _MiniButton(
              icon: playing ? Icons.pause : Icons.play_arrow,
              color: AppColors.accent,
              onTap: _engine.toggle,
            ),
          ),
          _MiniButton(
            icon: Icons.flip,
            color: _mirror ? AppColors.accent : Colors.white,
            onTap: () => setState(() => _mirror = !_mirror),
          ),
          _MiniButton(icon: Icons.close, onTap: FlutterOverlayWindow.closeOverlay),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _messages?.cancel();
    _engine.dispose();
    super.dispose();
  }
}

class _MiniButton extends StatelessWidget {
  const _MiniButton({required this.icon, required this.onTap, this.color = Colors.white});

  final IconData icon;
  final VoidCallback onTap;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return InkResponse(
      onTap: onTap,
      radius: 18,
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Icon(icon, size: 18, color: color),
      ),
    );
  }
}
