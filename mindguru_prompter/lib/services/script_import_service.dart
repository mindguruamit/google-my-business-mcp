import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:googleapis_auth/googleapis_auth.dart' as auth;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:xml/xml.dart';

class ImportedScript {
  const ImportedScript({
    required this.title,
    required this.content,
    this.driveFileId,
  });

  final String title;
  final String content;
  final String? driveFileId;
}

class DriveFileInfo {
  const DriveFileInfo({
    required this.id,
    required this.name,
    required this.mimeType,
    this.modifiedTime,
  });

  final String id;
  final String name;
  final String mimeType;
  final DateTime? modifiedTime;

  bool get isGoogleDoc => mimeType == ScriptImportService.googleDocMime;
}

class ScriptImportException implements Exception {
  ScriptImportException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Imports scripts from device files (txt, md, pdf, docx, rtf) and from
/// Google Drive (Google Docs, txt, pdf, docx).
class ScriptImportService {
  ScriptImportService({GoogleSignIn? signIn})
      : _signIn = signIn ?? GoogleSignIn.instance;

  final GoogleSignIn _signIn;
  bool _signInReady = false;

  static const List<String> supportedExtensions = ['txt', 'md', 'pdf', 'docx', 'rtf'];
  static const String googleDocMime = 'application/vnd.google-apps.document';
  static const List<String> _driveScopes = [drive.DriveApi.driveReadonlyScope];

  /// OAuth web client ID, passed at build time:
  /// `--dart-define=GOOGLE_SERVER_CLIENT_ID=xxxx.apps.googleusercontent.com`
  static const String _serverClientId = String.fromEnvironment('GOOGLE_SERVER_CLIENT_ID');

  // ---------------------------------------------------------------------------
  // Device

  /// Opens the system picker. Returns null if the user cancels.
  Future<ImportedScript?> importFromDevice() async {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: supportedExtensions,
      dialogTitle: 'Import script',
    );
    if (files.isEmpty) return null;
    final file = files.first;
    final bytes = await file.xFile.readAsBytes();
    final content = extractText(bytes, file.name);
    return ImportedScript(title: _titleFrom(file.name), content: content);
  }

  /// Extracts plain text from a file's bytes based on its extension.
  static String extractText(Uint8List bytes, String fileName) {
    final ext = p.extension(fileName).toLowerCase().replaceFirst('.', '');
    final text = switch (ext) {
      'pdf' => _pdfToText(bytes),
      'docx' => docxToText(bytes),
      'rtf' => rtfToText(utf8.decode(bytes, allowMalformed: true)),
      _ => utf8.decode(bytes, allowMalformed: true),
    };
    final cleaned = _tidy(text);
    if (cleaned.isEmpty) {
      throw ScriptImportException('No readable text found in $fileName');
    }
    return cleaned;
  }

  static String _pdfToText(Uint8List bytes) {
    final document = PdfDocument(inputBytes: bytes);
    try {
      return PdfTextExtractor(document).extractText();
    } finally {
      document.dispose();
    }
  }

  /// DOCX is a zip; the body lives in word/document.xml as w:p/w:r/w:t.
  static String docxToText(Uint8List bytes) {
    final archive = ZipDecoder().decodeBytes(bytes);
    final entry = archive.findFile('word/document.xml');
    if (entry == null) throw ScriptImportException('Not a valid .docx file');
    final xml = XmlDocument.parse(utf8.decode(entry.content, allowMalformed: true));

    final buffer = StringBuffer();
    for (final paragraph in xml.findAllElements('w:p')) {
      for (final node in paragraph.descendants.whereType<XmlElement>()) {
        switch (node.name.qualified) {
          case 'w:t':
            buffer.write(node.innerText);
          case 'w:tab':
            buffer.write('\t');
          case 'w:br' || 'w:cr':
            buffer.write('\n');
        }
      }
      buffer.write('\n');
    }
    return buffer.toString();
  }

  /// Minimal RTF → text: drops control words and groups like fonttbl,
  /// decodes \'hh and \uN escapes, keeps \par as newlines.
  static String rtfToText(String rtf) {
    const skipDestinations = {
      'fonttbl', 'colortbl', 'stylesheet', 'info', 'pict', 'header', 'footer',
      'headerl', 'headerr', 'footerl', 'footerr', 'listtable', 'listoverridetable',
      'themedata', 'colorschememapping', 'latentstyles', 'datastore', 'xmlnstbl',
      'rsidtbl', 'generator', 'mmathPr', 'object', 'fldinst',
    };
    final out = StringBuffer();
    final stack = <bool>[];
    var skipping = false;
    var ucSkip = 1;
    var i = 0;

    while (i < rtf.length) {
      final c = rtf[i];
      if (c == '{') {
        stack.add(skipping);
        i++;
      } else if (c == '}') {
        skipping = stack.isEmpty ? false : stack.removeLast();
        i++;
      } else if (c == '\\') {
        if (i + 1 >= rtf.length) break;
        final next = rtf[i + 1];
        if (next == '\\' || next == '{' || next == '}') {
          if (!skipping) out.write(next);
          i += 2;
        } else if (next == "'") {
          final hex = rtf.substring(i + 2, (i + 4).clamp(0, rtf.length));
          final code = int.tryParse(hex, radix: 16);
          if (!skipping && code != null) out.writeCharCode(code);
          i += 4;
        } else if (next == '*') {
          skipping = true;
          i += 2;
        } else if (next == '\n' || next == '\r') {
          if (!skipping) out.write('\n');
          i += 2;
        } else {
          final match = RegExp(r'([a-zA-Z]+)(-?\d+)? ?').matchAsPrefix(rtf, i + 1);
          if (match == null) {
            i += 2;
            continue;
          }
          final word = match.group(1)!;
          final param = int.tryParse(match.group(2) ?? '');
          i = match.end;
          if (skipDestinations.contains(word)) {
            skipping = true;
          } else if (skipping) {
            continue;
          } else if (word == 'par' || word == 'line' || word == 'sect' || word == 'page') {
            out.write('\n');
          } else if (word == 'tab') {
            out.write('\t');
          } else if (word == 'uc' && param != null) {
            ucSkip = param;
          } else if (word == 'u' && param != null) {
            out.writeCharCode(param < 0 ? param + 65536 : param);
            // Skip the ANSI fallback characters that follow \uN.
            var skip = ucSkip;
            while (skip > 0 && i < rtf.length) {
              if (rtf[i] == '\\' && i + 1 < rtf.length && rtf[i + 1] == "'") {
                i += 4;
              } else {
                i++;
              }
              skip--;
            }
          } else if (word == 'emdash') {
            out.write('—');
          } else if (word == 'endash') {
            out.write('–');
          } else if (word == 'lquote' || word == 'rquote') {
            out.write("'");
          } else if (word == 'ldblquote' || word == 'rdblquote') {
            out.write('"');
          }
        }
      } else {
        if (!skipping && c != '\r' && c != '\n') out.write(c);
        i++;
      }
    }
    return out.toString();
  }

  static String _tidy(String text) {
    return text
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .replaceAll(RegExp(r'[ \t]+\n'), '\n')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
  }

  static String _titleFrom(String fileName) {
    final base = p.basenameWithoutExtension(fileName).replaceAll(RegExp(r'[_-]+'), ' ');
    return base.isEmpty ? 'Imported script' : base;
  }

  // ---------------------------------------------------------------------------
  // Google Drive

  Future<auth.AuthClient> _driveClient() async {
    if (!_signInReady) {
      await _signIn.initialize(
        serverClientId: _serverClientId.isEmpty ? null : _serverClientId,
      );
      _signInReady = true;
    }

    GoogleSignInClientAuthorization? authorization =
        await _signIn.authorizationClient.authorizationForScopes(_driveScopes);
    if (authorization == null) {
      try {
        authorization = await _signIn.authorizationClient.authorizeScopes(_driveScopes);
      } on GoogleSignInException {
        // Some platforms need an authenticated user before authorizing.
        if (_signIn.supportsAuthenticate()) {
          final account = await _signIn.authenticate(scopeHint: _driveScopes);
          authorization = await account.authorizationClient.authorizeScopes(_driveScopes);
        } else {
          rethrow;
        }
      }
    }

    final credentials = auth.AccessCredentials(
      auth.AccessToken(
        'Bearer',
        authorization.accessToken,
        // Google access tokens live one hour; refresh a little early.
        DateTime.now().toUtc().add(const Duration(minutes: 55)),
      ),
      null,
      _driveScopes,
    );
    return auth.authenticatedClient(http.Client(), credentials, closeUnderlyingClient: true);
  }

  /// Lists recent script-like files in the user's Drive.
  Future<List<DriveFileInfo>> listDriveFiles({String? search}) async {
    final client = await _driveClient();
    try {
      final api = drive.DriveApi(client);
      final mimeFilter = [
        googleDocMime,
        'text/plain',
        'text/markdown',
        'application/pdf',
        'application/rtf',
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      ].map((m) => "mimeType='$m'").join(' or ');
      final nameFilter = (search == null || search.trim().isEmpty)
          ? ''
          : " and name contains '${search.replaceAll("'", r"\'")}'";

      final list = await api.files.list(
        q: '($mimeFilter) and trashed=false$nameFilter',
        orderBy: 'modifiedTime desc',
        pageSize: 50,
        $fields: 'files(id,name,mimeType,modifiedTime)',
      );
      return (list.files ?? const [])
          .where((f) => f.id != null && f.name != null)
          .map(
            (f) => DriveFileInfo(
              id: f.id!,
              name: f.name!,
              mimeType: f.mimeType ?? '',
              modifiedTime: f.modifiedTime,
            ),
          )
          .toList();
    } finally {
      client.close();
    }
  }

  /// Downloads a Drive file and converts it to a script.
  Future<ImportedScript> importFromGoogleDrive(DriveFileInfo file) async {
    final client = await _driveClient();
    try {
      final api = drive.DriveApi(client);
      final drive.Media? media;
      var fileName = file.name;
      if (file.isGoogleDoc) {
        media = await api.files.export(
          file.id,
          'text/plain',
          downloadOptions: drive.DownloadOptions.fullMedia,
        );
        fileName = '$fileName.txt';
      } else {
        media = await api.files.get(
          file.id,
          downloadOptions: drive.DownloadOptions.fullMedia,
        ) as drive.Media;
      }
      if (media == null) throw ScriptImportException('Drive returned no data');

      final builder = BytesBuilder(copy: false);
      await for (final chunk in media.stream) {
        builder.add(chunk);
      }
      final content = extractText(builder.takeBytes(), fileName);
      return ImportedScript(
        title: _titleFrom(file.name),
        content: content,
        driveFileId: file.id,
      );
    } finally {
      client.close();
    }
  }
}
