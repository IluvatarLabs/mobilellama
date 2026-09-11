import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import '../../lib/ollama/ndjson_decoder.dart';

void main() {
  test(
    'decodes JSON split across arbitrary bytes and UTF-8 code units',
    () async {
      final bytes = utf8.encode(
        '{"message":{"content":"hé"}}\n'
        '\n'
        '{"done":true}',
      );
      final chunks = <List<int>>[
        bytes.sublist(0, 5),
        bytes.sublist(5, 26),
        bytes.sublist(26, 27),
        bytes.sublist(27, bytes.length - 2),
        bytes.sublist(bytes.length - 2),
      ];

      final values = await Stream.fromIterable(chunks)
          .transform(const NdjsonDecoder())
          .toList();

      expect(values, hasLength(2));
      expect((values.first['message'] as Map)['content'], 'hé');
      expect(values.last['done'], isTrue);
    },
  );

  test('reports the physical line and source for malformed NDJSON', () async {
    final stream = Stream<List<int>>.value(utf8.encode('{}\n\nnot-json\n'))
        .transform(const NdjsonDecoder());

    await expectLater(
      stream.toList(),
      throwsA(
        isA<NdjsonDecodeException>()
            .having((error) => error.lineNumber, 'lineNumber', 3)
            .having((error) => error.source, 'source', 'not-json'),
      ),
    );
  });
}
