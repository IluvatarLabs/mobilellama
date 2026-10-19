import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobollama/data/document_reader.dart';
import 'package:mobollama/domain/document_attachment.dart';
import 'package:pdfrx/pdfrx.dart';

void main() {
  late Directory pdfCache;
  Object? pdfiumInitializationError;

  setUpAll(() async {
    pdfCache = await Directory.systemTemp.createTemp(
      'mobilellama-document-reader-pdfium-',
    );
    try {
      await pdfrxInitialize(tmpPath: pdfCache.path);
    } on Object catch (error) {
      pdfiumInitializationError = error;
    }
  });

  tearDownAll(() async {
    if (await pdfCache.exists()) await pdfCache.delete(recursive: true);
  });

  test('extracts strict UTF-8 text and markdown with MIME metadata', () async {
    final reader = DocumentReader();
    final text = await reader.extract(
      bytes: utf8.encode('Plain UTF-8 text: λ'),
      name: 'notes.TXT',
    );
    final markdown = await reader.extract(
      bytes: utf8.encode('# Heading'),
      name: 'notes.md',
    );

    expect(text.name, 'notes.TXT');
    expect(text.mimeType, 'text/plain');
    expect(text.text, 'Plain UTF-8 text: λ');
    expect(text.bytes, utf8.encode('Plain UTF-8 text: λ'));
    expect(markdown.mimeType, 'text/markdown');
    expect(markdown.text, '# Heading');
  });

  test(
    'picker returns selected bytes, handles cancel, and rejects large files',
    () async {
      final selectedFile = File('${pdfCache.path}/picked.txt');
      await selectedFile.writeAsString('Picked text');
      final selected = DocumentReader(
        picker: () async => XFile(selectedFile.path),
      );
      final cancelled = DocumentReader(picker: () async => null);
      final oversized = File('${pdfCache.path}/oversized.txt');
      await oversized.open(mode: FileMode.write).then((file) async {
        try {
          await file.truncate(DocumentAttachment.maxFileBytes + 1);
        } finally {
          await file.close();
        }
      });

      final content = await selected.pick();
      expect(content!.name, 'picked.txt');
      expect(content.text, 'Picked text');
      expect(await cancelled.pick(), isNull);
      await expectLater(
        DocumentReader(picker: () async => XFile(oversized.path)).pick(),
        throwsA(
          isA<DocumentReadException>().having(
            (error) => error.message,
            'message',
            contains('8 MiB'),
          ),
        ),
      );
    },
  );

  test(
    'rejects invalid UTF-8 and document size limits without truncating',
    () async {
      final reader = DocumentReader();

      await expectLater(
        reader.extract(bytes: const <int>[0xc3, 0x28], name: 'invalid.txt'),
        throwsA(
          isA<DocumentReadException>().having(
            (error) => error.message,
            'message',
            contains('not valid UTF-8'),
          ),
        ),
      );
      await expectLater(
        reader.extract(
          bytes: List<int>.filled(
            DocumentAttachment.maxExtractedTextBytes + 1,
            0x61,
          ),
          name: 'too-long.md',
        ),
        throwsA(
          isA<DocumentReadException>().having(
            (error) => error.message,
            'message',
            contains('64 KiB'),
          ),
        ),
      );
      await expectLater(
        reader.extract(
          bytes: List<int>.filled(DocumentAttachment.maxFileBytes + 1, 0x61),
          name: 'too-large.txt',
        ),
        throwsA(
          isA<DocumentReadException>().having(
            (error) => error.message,
            'message',
            contains('8 MiB'),
          ),
        ),
      );
    },
  );

  test('extracts text from an actual PDF through PDFium', () async {
    if (pdfiumInitializationError != null) {
      markTestSkipped(
        'PDFium is unavailable in this Flutter test runtime: '
        '$pdfiumInitializationError',
      );
      return;
    }
    final reader = DocumentReader(initializePdf: () async {});

    final content = await reader.extract(
      bytes: _pdfWithText('MobileLlama PDF evidence'),
      name: 'evidence.pdf',
    );

    expect(content.mimeType, 'application/pdf');
    expect(content.text, contains('MobileLlama PDF evidence'));
  });

  test(
    'rejects a PDF extension without PDF magic before initialization',
    () async {
      final reader = DocumentReader();
      await expectLater(
        reader.extract(bytes: utf8.encode('not a pdf'), name: 'invalid.pdf'),
        throwsA(
          isA<DocumentReadException>().having(
            (error) => error.message,
            'message',
            contains('valid PDF header'),
          ),
        ),
      );
    },
  );

  test('reports textless and encrypted PDFs actionably', () async {
    if (pdfiumInitializationError != null) {
      markTestSkipped(
        'PDFium is unavailable in this Flutter test runtime: '
        '$pdfiumInitializationError',
      );
      return;
    }
    final reader = DocumentReader(initializePdf: () async {});

    await expectLater(
      reader.extract(bytes: _pdfWithText(''), name: 'empty.pdf'),
      throwsA(
        isA<DocumentReadException>().having(
          (error) => error.message,
          'message',
          contains('No extractable text'),
        ),
      ),
    );

    final configuration = File('.dart_tool/package_config.json').absolute;
    final packages = jsonDecode(await configuration.readAsString()) as Map;
    final engine = (packages['packages'] as List).cast<Map>().singleWhere(
      (p) => p['name'] == 'pdfrx_engine',
    );
    final packageRoot = Directory.fromUri(
      configuration.uri.resolve(engine['rootUri'] as String),
    );
    final encryptedFixture = File(
      '${packageRoot.path}/test/assets/encrypted.pdf',
    );
    expect(await encryptedFixture.exists(), isTrue);
    await expectLater(
      reader.extract(
        bytes: await encryptedFixture.readAsBytes(),
        name: 'encrypted.pdf',
      ),
      throwsA(
        isA<DocumentReadException>().having(
          (error) => error.message,
          'message',
          contains('Encrypted PDFs are not supported'),
        ),
      ),
    );
  });
}

List<int> _pdfWithText(String text) {
  final escaped = text
      .replaceAll('\\', r'\\')
      .replaceAll('(', r'\(')
      .replaceAll(')', r'\)');
  final stream = 'BT /F1 18 Tf 72 720 Td ($escaped) Tj ET';
  final objects = <String>[
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] '
        '/Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>',
    '<< /Length ${latin1.encode(stream).length} >>\nstream\n$stream\nendstream',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
  ];
  final output = StringBuffer('%PDF-1.4\n');
  final offsets = <int>[];
  for (var index = 0; index < objects.length; index++) {
    offsets.add(latin1.encode(output.toString()).length);
    output
      ..writeln('${index + 1} 0 obj')
      ..writeln(objects[index])
      ..writeln('endobj');
  }
  final xrefOffset = latin1.encode(output.toString()).length;
  output
    ..writeln('xref')
    ..writeln('0 ${objects.length + 1}')
    ..writeln('0000000000 65535 f ');
  for (final offset in offsets) {
    output.writeln('${offset.toString().padLeft(10, '0')} 00000 n ');
  }
  output
    ..writeln('trailer')
    ..writeln('<< /Size ${objects.length + 1} /Root 1 0 R >>')
    ..writeln('startxref')
    ..writeln(xrefOffset)
    ..writeln('%%EOF');
  return latin1.encode(output.toString());
}
