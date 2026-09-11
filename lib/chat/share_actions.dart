import 'dart:convert';

import 'package:file_selector/file_selector.dart' as file_selector;
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart' as share_plus;

import '../domain/document_attachment.dart';

const int maxBackupImportBytes = 128 * 1024 * 1024;

class BackupFileTooLargeException implements Exception {
  const BackupFileTooLargeException(this.actualBytes);

  final int actualBytes;
}

Future<bool> shareResponse(BuildContext context, String text) => _share(
  context,
  share_plus.ShareParams(
    text: text,
    subject: 'MobileLlama response',
    sharePositionOrigin: _shareOrigin(context),
  ),
);

Future<bool> shareConversationMarkdown(
  BuildContext context, {
  required String title,
  required String markdown,
}) {
  final fileName = '${_safeFileName(title, fallback: 'conversation')}.md';
  return _share(
    context,
    share_plus.ShareParams(
      files: <share_plus.XFile>[
        share_plus.XFile.fromData(
          utf8.encode(markdown),
          mimeType: 'text/markdown',
        ),
      ],
      fileNameOverrides: <String>[fileName],
      subject: title,
      title: title,
      sharePositionOrigin: _shareOrigin(context),
    ),
  );
}

Future<bool> shareBackup(BuildContext context, String json) {
  final now = DateTime.now();
  final date =
      '${now.year.toString().padLeft(4, '0')}-'
      '${now.month.toString().padLeft(2, '0')}-'
      '${now.day.toString().padLeft(2, '0')}';
  final fileName = 'mobilellama-backup-$date.json';
  return _share(
    context,
    share_plus.ShareParams(
      files: <share_plus.XFile>[
        share_plus.XFile.fromData(
          utf8.encode(json),
          mimeType: 'application/json',
        ),
      ],
      fileNameOverrides: <String>[fileName],
      subject: 'MobileLlama chat backup',
      title: 'MobileLlama chat backup',
      sharePositionOrigin: _shareOrigin(context),
    ),
  );
}

Future<bool> shareDocument(BuildContext context, DocumentAttachment document) =>
    _share(
      context,
      share_plus.ShareParams(
        files: <share_plus.XFile>[
          share_plus.XFile(
            document.reference,
            mimeType: document.mimeType,
            name: document.name,
          ),
        ],
        fileNameOverrides: <String>[
          _safeFileName(document.name, fallback: 'document'),
        ],
        subject: document.name,
        title: document.name,
        sharePositionOrigin: _shareOrigin(context),
      ),
    );

Future<String?> pickBackupJson() async {
  const type = file_selector.XTypeGroup(
    label: 'MobileLlama backup',
    extensions: <String>['json'],
    mimeTypes: <String>['application/json'],
    uniformTypeIdentifiers: <String>['public.json'],
  );
  final selected = await file_selector.openFile(
    acceptedTypeGroups: const <file_selector.XTypeGroup>[type],
  );
  if (selected == null) return null;
  final length = await selected.length();
  if (length > maxBackupImportBytes) {
    throw BackupFileTooLargeException(length);
  }
  return selected.readAsString();
}

Future<bool> _share(BuildContext context, share_plus.ShareParams params) async {
  try {
    await share_plus.SharePlus.instance.share(params);
    return true;
  } on Object {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('The share sheet could not be opened.')),
      );
    }
    return false;
  }
}

Rect _shareOrigin(BuildContext context) {
  final renderObject = context.findRenderObject();
  if (renderObject is RenderBox && renderObject.hasSize) {
    return renderObject.localToGlobal(Offset.zero) & renderObject.size;
  }
  final size = MediaQuery.sizeOf(context);
  return Rect.fromCenter(
    center: Offset(size.width / 2, size.height / 2),
    width: 1,
    height: 1,
  );
}

String _safeFileName(String value, {required String fallback}) {
  final normalized = value
      .trim()
      .replaceAll(RegExp(r'[/\\:*?"<>|\x00-\x1F]'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll(RegExp(r'[. ]+$'), '');
  final usable = normalized.isEmpty ? fallback : normalized;
  return usable.length <= 80 ? usable : usable.substring(0, 80).trimRight();
}
