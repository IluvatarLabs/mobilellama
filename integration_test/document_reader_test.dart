import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mobollama/data/document_reader.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native PDF extraction and image-only rejection', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Text('Checking document support')),
      ),
    );
    final reader = DocumentReader();
    final result = await reader.extract(
      bytes: _pdfWithText('MobileLlama native PDF evidence'),
      name: 'evidence.pdf',
    );
    expect(result.text, contains('MobileLlama native PDF evidence'));
    expect(result.mimeType, 'application/pdf');
    await expectLater(
      reader.extract(bytes: _pdfWithText(''), name: 'image-only.pdf'),
      throwsA(
        isA<DocumentReadException>().having(
          (error) => error.message,
          'message',
          contains('No extractable text'),
        ),
      ),
    );
    await expectLater(
      reader.extract(bytes: base64Decode(_encryptedPdf), name: 'encrypted.pdf'),
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

// MIT-licensed pdfrx_engine test fixture; see docs/licenses/pdfrx.txt.
const _encryptedPdf =
    'JVBERi0xLjMKJeLjz9MKMSAwIG9iago8PAovUHJvZHVjZXIgPDc0YTI4NjYwMjNhNWEwM2M1NzcwM2Q3YTc0MDBmMDM3NzJmZjU1NDA4MjQwYmQ1ZmYzM2ZjNjNlNmVlMmVkYWM+Ci9UaXRsZSA8NGI3MDg1MzNhMGIxZTAzNmVmNmUxOTkwZjM0ODhiYzAwYzRjZGFkYmVjMjYxYmUxZWZiOWM3N2EzYzY0YjcwMzU5MDI3OTBjMjVkYjM0ZDFkY2ZhMDQ2NTVlZjAxYzc2Pgo+PgplbmRvYmoKMiAwIG9iago8PAovVHlwZSAvUGFnZXMKL0NvdW50IDEKL0tpZHMgWyA0IDAgUiBdCj4+CmVuZG9iagozIDAgb2JqCjw8Ci9UeXBlIC9DYXRhbG9nCi9QYWdlcyAyIDAgUgo+PgplbmRvYmoKNCAwIG9iago8PAovVHlwZSAvUGFnZQovUmVzb3VyY2VzIDw8Cj4+Ci9NZWRpYUJveCBbIDAuMCAwLjAgMjAwIDEwMCBdCi9QYXJlbnQgMiAwIFIKPj4KZW5kb2JqCjUgMCBvYmoKPDwKL1YgNQovUiA2Ci9MZW5ndGggMjU2Ci9QIDQyOTQ5NjcyOTIKL0ZpbHRlciAvU3RhbmRhcmQKL08gPGFmYzE2ZTJhOGJhNDNhMTI2MGQwZWY0ODdjMzIzMTg4YzcwYzk3NjA1YTQxYzQ0MGI3NTczNDIzYWU1YTgzMWM5OGY4YzIyNWFiZGZjNTA5Y2MwOGVkZWNmMGNlZjJiYz4KL1UgPDdlNTMyMTk3NmRmNjhmNTA3MGQzOTA1NTQ0ODVkZGY3ZTBhYTM4MGVmNzQ0NmE3MjA2NDczM2Y0NzQ4ZmQ2ZWJlMWRiMGYwZjM0YzlkZGE5Y2QxNTY0N2RjMzZmNTg2Nz4KL0NGIDw8Ci9TdGRDRiA8PAovQXV0aEV2ZW50IC9Eb2NPcGVuCi9DRk0gL0FFU1YzCi9MZW5ndGggMzIKPj4KPj4KL1N0bUYgL1N0ZENGCi9TdHJGIC9TdGRDRgovT0UgPGQ4ZTYyNDI0NWNmZTQ5ODRiMzhmNjQ5M2Q2YzQ4YmYyNzFkMGM2OTVhNGY4OTkyOTRhOTZhM2I5ZjdlZmYyNTk+Ci9VRSA8YjRkMmUzNTJiMTI5ZDQ1NjQ4NmQ5OWVlNjNiNTBjMDA5YmM5MTMxODY4OTBhYWJkOTI4YmIxN2YwOGVkZWM1Yz4KL1Blcm1zIDwwYWIzMDAyMGYwOTA5MzliMzJiZTk0Y2JhNTdmMzQ0ND4KPj4KZW5kb2JqCnhyZWYKMCA2CjAwMDAwMDAwMDAgNjU1MzUgZiAKMDAwMDAwMDAxNSAwMDAwMCBuIAowMDAwMDAwMjE5IDAwMDAwIG4gCjAwMDAwMDAyNzggMDAwMDAgbiAKMDAwMDAwMDMyNyAwMDAwMCBuIAowMDAwMDAwNDIxIDAwMDAwIG4gCnRyYWlsZXIKPDwKL1NpemUgNgovUm9vdCAzIDAgUgovSW5mbyAxIDAgUgovSUQgWyA8NjEzMTY1NjQ2MTMzNjQzNjMyNjM2MzM0NjQzMDMyNjIzMzY1MzEzMjYzNjU2MjM2NjI2NTY1MzM2NjMyNjIzND4gPDYxMzE2NTY0NjEzMzY0MzYzMjYzNjMzNDY0MzAzMjYyMzM2NTMxMzI2MzY1NjIzNjYyNjU2NTMzNjYzMjYyMzQ+IF0KL0VuY3J5cHQgNSAwIFIKPj4Kc3RhcnR4cmVmCjk3NgolJUVPRgo=';
