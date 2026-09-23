import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../models/script_document.dart';
import '../models/script_model.dart';
import '../state/library_cubit.dart';
import '../utils/app_theme.dart';
import '../utils/constants.dart';
import '../widgets/speed_control.dart';
import 'recording_screen.dart';

/// Script editor. [pause] and [breath] markers are highlighted inline and
/// become cue holds in the prompter.
class EditorScreen extends StatefulWidget {
  const EditorScreen({super.key, required this.script});

  final ScriptModel script;

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  late final TextEditingController _title =
      TextEditingController(text: widget.script.title);
  late final _MarkerTextController _content =
      _MarkerTextController(text: widget.script.content);
  late int _wpm = widget.script.scrollSpeed;
  late double _fontSize = widget.script.fontSize;
  final FocusNode _contentFocus = FocusNode();

  Timer? _autosave;
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    _title.addListener(_changed);
    _content.addListener(_changed);
  }

  void _changed() {
    if (!mounted) return;
    setState(() => _dirty = true);
    _autosave?.cancel();
    _autosave = Timer(const Duration(seconds: 2), _save);
  }

  Future<void> _save() async {
    if (!_dirty) return;
    final script = widget.script
      ..title = _title.text.trim().isEmpty ? 'Untitled script' : _title.text.trim()
      ..content = _content.text
      ..scrollSpeed = _wpm
      ..fontSize = _fontSize;
    await context.read<LibraryCubit>().save(script);
    if (mounted) setState(() => _dirty = false);
  }

  void _insertMarker(String tag) {
    final text = _content.text;
    final selection = _content.selection;
    final start = selection.isValid ? selection.start : text.length;
    final end = selection.isValid ? selection.end : text.length;
    final before = start > 0 && text[start - 1] != ' ' && text[start - 1] != '\n' ? ' ' : '';
    final insert = '$before[$tag] ';
    _content.value = TextEditingValue(
      text: text.replaceRange(start, end, insert),
      selection: TextSelection.collapsed(offset: start + insert.length),
    );
    _contentFocus.requestFocus();
  }

  Future<void> _openStudio() async {
    _dirty = true;
    await _save();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => RecordingScreen(script: widget.script)),
    );
    if (mounted) {
      setState(() {
        _wpm = widget.script.scrollSpeed;
        _fontSize = widget.script.fontSize;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final document = ScriptDocument.parse(_content.text);
    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) return;
        _autosave?.cancel();
        final cubit = context.read<LibraryCubit>();
        if (_content.text.trim().isEmpty && _title.text.trim().isEmpty) {
          // Discard a new script the user never wrote anything into.
          cubit.delete(widget.script);
        } else {
          _save();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Edit script'),
          actions: [
            if (_dirty)
              const Padding(
                padding: EdgeInsets.only(right: 4),
                child: Center(
                  child: Text('Saving…', style: TextStyle(color: AppColors.textSecondary)),
                ),
              ),
            IconButton(
              tooltip: 'Open studio',
              onPressed: document.wordCount == 0 ? null : _openStudio,
              icon: const Icon(Icons.videocam_rounded, color: AppColors.accent),
            ),
          ],
        ),
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: TextField(
                  controller: _title,
                  textCapitalization: TextCapitalization.sentences,
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                  decoration: const InputDecoration(hintText: 'Title'),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    ActionChip(
                      avatar: const Icon(Icons.pause, size: 16, color: AppColors.marker),
                      label: const Text('[pause]'),
                      onPressed: () => _insertMarker('pause'),
                    ),
                    const SizedBox(width: 8),
                    ActionChip(
                      avatar: const Icon(Icons.air, size: 16, color: AppColors.marker),
                      label: const Text('[breath]'),
                      onPressed: () => _insertMarker('breath'),
                    ),
                    const Spacer(),
                    Text(
                      '${document.wordCount} words · '
                      '${formatDuration(document.estimateDuration(_wpm))}',
                      style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: TextField(
                    controller: _content,
                    focusNode: _contentFocus,
                    maxLines: null,
                    expands: true,
                    textAlignVertical: TextAlignVertical.top,
                    keyboardType: TextInputType.multiline,
                    textCapitalization: TextCapitalization.sentences,
                    style: const TextStyle(fontSize: 17, height: 1.5),
                    decoration: const InputDecoration(
                      hintText: 'Write or paste your script…\n\n'
                          'Use [pause] and [breath] to add cues.',
                    ),
                  ),
                ),
              ),
              Container(
                color: AppColors.card,
                padding: const EdgeInsets.only(top: 8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SpeedControl(
                      wpm: _wpm,
                      onChanged: (v) => setState(() => _wpm = v),
                      onChangeEnd: (_) => _changed(),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Row(
                        children: [
                          const Icon(Icons.format_size, size: 16, color: AppColors.textSecondary),
                          const SizedBox(width: 6),
                          Text(
                            'Prompter text ${_fontSize.round()}',
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          Expanded(
                            child: Slider(
                              value: _fontSize,
                              min: TeleprompterConstants.minFontSize,
                              max: TeleprompterConstants.maxFontSize,
                              onChanged: (v) => setState(() => _fontSize = v),
                              onChangeEnd: (_) => _changed(),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _autosave?.cancel();
    _title.dispose();
    _content.dispose();
    _contentFocus.dispose();
    super.dispose();
  }
}

/// Colors [pause]/[breath]/[note] markers while typing.
class _MarkerTextController extends TextEditingController {
  _MarkerTextController({super.text});

  static final RegExp _marker = RegExp(r'\[[^\[\]\n]{1,40}\]');

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    // Keep IME composing underline behaviour intact.
    if (withComposing && value.isComposingRangeValid) {
      return super.buildTextSpan(context: context, style: style, withComposing: withComposing);
    }
    final children = <TextSpan>[];
    var cursor = 0;
    for (final match in _marker.allMatches(text)) {
      if (match.start > cursor) {
        children.add(TextSpan(text: text.substring(cursor, match.start)));
      }
      children.add(
        TextSpan(
          text: match.group(0),
          style: const TextStyle(
            color: AppColors.marker,
            fontWeight: FontWeight.w700,
            backgroundColor: Color(0x1A7FD4FF),
          ),
        ),
      );
      cursor = match.end;
    }
    if (cursor < text.length) children.add(TextSpan(text: text.substring(cursor)));
    return TextSpan(style: style, children: children);
  }
}
