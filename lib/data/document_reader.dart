import 'dart:convert';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:pdfrx/pdfrx.dart';

import '../domain/document_attachment.dart';

typedef DocumentPicker = Future<XFile?> Function();
typedef PdfInitializer = Future<void> Function();

final class DocumentContent {
  DocumentContent({
    required this.name,
    required this.mimeType,
    required this.text,
    required List<int> bytes,
  }) : bytes = List<int>.unmodifiable(bytes);

  final String name;
  final String mimeType;
  final String text;
  final List<int> bytes;
}

final class DocumentReadException implements Exception {
  const DocumentReadException(this.message);

  final String message;

  @override
  String toString() => message;
}

final class DocumentReader {
  DocumentReader({DocumentPicker? picker, PdfInitializer? initializePdf})
    : _picker = picker ?? _pickDocument,
      _initializePdf = initializePdf ?? pdfrxFlutterInitialize;

  final DocumentPicker _picker;
  final PdfInitializer _initializePdf;

  Future<DocumentContent?> pick() async {
    final file = await _picker();
    if (file == null) return null;

    _mimeTypeForName(file.name);
    final length = await file.length();
    _checkFileSize(length);
    final bytes = await file.readAsBytes();
    _checkFileSize(bytes.length);
    return extract(bytes: bytes, name: file.name);
  }

  Future<DocumentContent> extract({
    required List<int> bytes,
    required String name,
  }) async {
    final safeName = _validateName(name);
    _checkFileSize(bytes.length);
    final mimeType = _mimeTypeForName(safeName);

    if (mimeType != 'application/pdf') {
      try {
        final text = utf8.decode(bytes, allowMalformed: false);
        _checkExtractedTextSize(text);
        return DocumentContent(
          name: safeName,
          mimeType: mimeType,
          text: text,
          bytes: bytes,
        );
      } on FormatException {
        throw const DocumentReadException(
          'This text document is not valid UTF-8. Save it as UTF-8 and try again.',
        );
      }
    }

    return _extractPdf(bytes: bytes, name: safeName);
  }

  Future<DocumentContent> _extractPdf({
    required List<int> bytes,
    required String name,
  }) async {
    if (bytes.length < 5 ||
        bytes[0] != 0x25 ||
        bytes[1] != 0x50 ||
        bytes[2] != 0x44 ||
        bytes[3] != 0x46 ||
        bytes[4] != 0x2d) {
      throw const DocumentReadException(
        'This file does not have a valid PDF header. Choose a PDF file or rename it with the correct extension.',
      );
    }

    PdfDocument? document;
    try {
      await _initializePdf();
      document = await PdfDocument.openData(
        Uint8List.fromList(bytes),
        sourceName: name,
      );
      if (document.isEncrypted) {
        throw const DocumentReadException(
          'Encrypted PDFs are not supported. Remove the password and try again.',
        );
      }
      if (document.permissions?.allowsCopying == false) {
        throw const DocumentReadException(
          'This PDF does not allow text extraction. Choose a PDF that permits copying.',
        );
      }

      final pageTexts = <String>[];
      var extractedBytes = 0;
      for (final page in document.pages) {
        final pageText = (await page.loadText())?.fullText.trim() ?? '';
        if (pageText.isEmpty) continue;
        final separatorBytes = pageTexts.isEmpty ? 0 : 2;
        extractedBytes += separatorBytes + utf8.encode(pageText).length;
        if (extractedBytes > DocumentAttachment.maxExtractedTextBytes) {
          throw const DocumentReadException(
            'The extracted PDF text exceeds the 64 KiB limit. Choose a shorter document.',
          );
        }
        pageTexts.add(pageText);
      }
      if (pageTexts.isEmpty) {
        throw const DocumentReadException(
          'No extractable text was found in this PDF. Scanned PDFs require OCR before attaching.',
        );
      }
      return DocumentContent(
        name: name,
        mimeType: 'application/pdf',
        text: pageTexts.join('\n\n'),
        bytes: bytes,
      );
    } on DocumentReadException {
      rethrow;
    } on PdfPasswordException {
      throw const DocumentReadException(
        'Encrypted PDFs are not supported. Remove the password and try again.',
      );
    } on PdfException {
      throw const DocumentReadException(
        'This PDF could not be read. Check that it is not damaged and try again.',
      );
    } on Object {
      throw const DocumentReadException(
        'PDF text extraction is unavailable. Restart MobileLlama and try again.',
      );
    } finally {
      await document?.dispose();
    }
  }

  static void _checkFileSize(int length) {
    if (length > DocumentAttachment.maxFileBytes) {
      throw const DocumentReadException('Documents must be 8 MiB or smaller.');
    }
  }

  static void _checkExtractedTextSize(String text) {
    if (utf8.encode(text).length > DocumentAttachment.maxExtractedTextBytes) {
      throw const DocumentReadException(
        'Extracted document text must be 64 KiB or smaller.',
      );
    }
  }

  static String _validateName(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty ||
        trimmed != name ||
        trimmed.contains('/') ||
        trimmed.contains('\\') ||
        trimmed.contains('\u0000')) {
      throw const DocumentReadException(
        'The document name is invalid. Choose a file with a plain file name.',
      );
    }
    return trimmed;
  }

  static String _mimeTypeForName(String name) {
    final lowerName = name.toLowerCase();
    if (lowerName.endsWith('.pdf')) return 'application/pdf';
    if (lowerName.endsWith('.txt')) return 'text/plain';
    if (lowerName.endsWith('.md')) return 'text/markdown';
    throw const DocumentReadException(
      'Choose a PDF, TXT, or Markdown (.md) document.',
    );
  }

  static Future<XFile?> _pickDocument() => openFile(
    acceptedTypeGroups: const <XTypeGroup>[
      XTypeGroup(
        label: 'Documents',
        extensions: <String>['pdf', 'txt', 'md'],
        mimeTypes: <String>['application/pdf', 'text/plain', 'text/markdown'],
        uniformTypeIdentifiers: <String>['com.adobe.pdf', 'public.text'],
      ),
    ],
  );
}
