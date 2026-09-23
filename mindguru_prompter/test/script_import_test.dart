import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mindguru_prompter/services/script_import_service.dart';

void main() {
  test('RTF: strips control words, keeps paragraphs and escapes', () {
    const rtf = r'{\rtf1\ansi{\fonttbl{\f0 Arial;}}{\colortbl;\red0\green0\blue0;}'
        r"\f0\fs24 Hello \b world\b0 !\par Caf\'e9 \u8212? done\par}";
    final text = ScriptImportService.rtfToText(rtf);
    expect(text, contains('Hello world!'));
    expect(text, contains('Café — done'));
    expect(text, isNot(contains('Arial')));
  });

  test('DOCX: reads paragraphs from word/document.xml', () {
    const xml = '<?xml version="1.0" encoding="UTF-8"?>'
        '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
        '<w:body>'
        '<w:p><w:r><w:t>First line</w:t></w:r></w:p>'
        '<w:p><w:r><w:t xml:space="preserve">Second </w:t></w:r><w:r><w:t>line</w:t></w:r></w:p>'
        '</w:body></w:document>';
    final archive = Archive()..addFile(ArchiveFile.string('word/document.xml', xml));
    final bytes = Uint8List.fromList(ZipEncoder().encode(archive));

    final text = ScriptImportService.docxToText(bytes);
    expect(text.trim(), 'First line\nSecond line');
  });

  test('TXT: tidies whitespace', () {
    final bytes = Uint8List.fromList(utf8.encode('Line one  \r\n\r\n\r\n\r\nLine two'));
    expect(ScriptImportService.extractText(bytes, 'script.txt'), 'Line one\n\nLine two');
  });

  test('empty files are rejected', () {
    expect(
      () => ScriptImportService.extractText(Uint8List(0), 'empty.txt'),
      throwsA(isA<ScriptImportException>()),
    );
  });
}
