import 'dart:async';
import 'dart:convert';

/// Decodes newline-delimited JSON objects without assuming byte or line
/// boundaries match transport chunks.
final class NdjsonDecoder
    extends StreamTransformerBase<List<int>, Map<String, dynamic>> {
  const NdjsonDecoder({this.maxLineBytes = 1024 * 1024})
    : assert(maxLineBytes > 0);

  final int maxLineBytes;

  @override
  Stream<Map<String, dynamic>> bind(Stream<List<int>> stream) =>
      _decode(stream);

  Stream<Map<String, dynamic>> _decode(Stream<List<int>> stream) async* {
    var lineNumber = 0;
    final lineBytes = <int>[];

    await for (final chunk in stream) {
      for (final byte in chunk) {
        if (byte == 0x0a) {
          lineNumber++;
          final bytes = lineBytes.isNotEmpty && lineBytes.last == 0x0d
              ? lineBytes.sublist(0, lineBytes.length - 1)
              : List<int>.of(lineBytes);
          lineBytes.clear();
          final value = _decodeLine(bytes, lineNumber);
          if (value != null) yield value;
          continue;
        }

        if (lineBytes.length >= maxLineBytes) {
          throw NdjsonLineTooLongException(
            lineNumber: lineNumber + 1,
            maxLineBytes: maxLineBytes,
          );
        }
        lineBytes.add(byte);
      }
    }

    if (lineBytes.isNotEmpty) {
      lineNumber++;
      final value = _decodeLine(lineBytes, lineNumber);
      if (value != null) yield value;
    }
  }

  Map<String, dynamic>? _decodeLine(List<int> bytes, int lineNumber) {
    String line;
    try {
      line = utf8.decode(bytes);
      if (line.trim().isEmpty) return null;
      final value = jsonDecode(line);
      if (value is! Map) {
        throw const FormatException('Expected a JSON object');
      }
      return Map<String, dynamic>.from(value);
    } on FormatException catch (error) {
      throw NdjsonDecodeException(
        lineNumber: lineNumber,
        line: _safeSource(bytes),
        cause: error,
      );
    }
  }

  static String _safeSource(List<int> bytes) =>
      utf8.decode(bytes, allowMalformed: true);
}

final class NdjsonLineTooLongException implements FormatException {
  const NdjsonLineTooLongException({
    required this.lineNumber,
    required this.maxLineBytes,
  });

  final int lineNumber;
  final int maxLineBytes;

  @override
  String get message => 'NDJSON line $lineNumber exceeds $maxLineBytes bytes';

  @override
  int? get offset => null;

  @override
  String? get source => null;

  @override
  String toString() => message;
}

final class NdjsonDecodeException implements FormatException {
  NdjsonDecodeException({
    required this.lineNumber,
    required this.line,
    required this.cause,
  });

  final int lineNumber;
  final String line;
  final FormatException cause;

  @override
  String get message => 'Invalid NDJSON object on line $lineNumber';

  @override
  int? get offset => cause.offset;

  @override
  String? get source => line;

  @override
  String toString() => '$message: ${cause.message}';
}
