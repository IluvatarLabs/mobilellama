import 'dart:async';
import 'dart:convert';

final class SseDataDecoder
    extends StreamTransformerBase<List<int>, SseDataEvent> {
  const SseDataDecoder({
    required this.maxLineBytes,
    required this.maxEventBytes,
  });

  final int maxLineBytes;
  final int maxEventBytes;

  @override
  Stream<SseDataEvent> bind(Stream<List<int>> stream) => _decode(stream);

  Stream<SseDataEvent> _decode(Stream<List<int>> stream) async* {
    final lineBytes = <int>[];
    final dataLines = <String>[];
    var eventType = '';
    var eventBytes = 0;

    SseDataEvent? consumeLine(List<int> bytes) {
      final line = utf8.decode(bytes);
      if (line.isEmpty) {
        final event = dataLines.isEmpty
            ? null
            : SseDataEvent(
                type: eventType.isEmpty ? 'message' : eventType,
                data: dataLines.join('\n'),
              );
        dataLines.clear();
        eventType = '';
        eventBytes = 0;
        return event;
      }
      if (line.startsWith(':')) return null;

      final colon = line.indexOf(':');
      final field = colon < 0 ? line : line.substring(0, colon);
      var value = colon < 0 ? '' : line.substring(colon + 1);
      if (value.startsWith(' ')) value = value.substring(1);
      if (field == 'event') {
        eventType = value;
        return null;
      }
      if (field != 'data') return null;
      final addedBytes =
          utf8.encode(value).length + (dataLines.isEmpty ? 0 : 1);
      if (eventBytes + addedBytes > maxEventBytes) {
        throw SseLimitException('SSE event', maxEventBytes);
      }
      dataLines.add(value);
      eventBytes += addedBytes;
      return null;
    }

    await for (final chunk in stream) {
      for (final byte in chunk) {
        if (byte == 0x0a) {
          final bytes = lineBytes.isNotEmpty && lineBytes.last == 0x0d
              ? lineBytes.sublist(0, lineBytes.length - 1)
              : List<int>.of(lineBytes);
          lineBytes.clear();
          final event = consumeLine(bytes);
          if (event != null) yield event;
          continue;
        }
        if (lineBytes.length >= maxLineBytes) {
          throw SseLimitException('SSE line', maxLineBytes);
        }
        lineBytes.add(byte);
      }
    }

    if (lineBytes.isNotEmpty) {
      final bytes = lineBytes.last == 0x0d
          ? lineBytes.sublist(0, lineBytes.length - 1)
          : List<int>.of(lineBytes);
      final event = consumeLine(bytes);
      if (event != null) yield event;
    }
    if (dataLines.isNotEmpty) {
      yield SseDataEvent(
        type: eventType.isEmpty ? 'message' : eventType,
        data: dataLines.join('\n'),
      );
    }
  }
}

final class SseDataEvent {
  const SseDataEvent({required this.type, required this.data});

  final String type;
  final String data;
}

final class SseLimitException implements Exception {
  const SseLimitException(this.kind, this.maxBytes);

  final String kind;
  final int maxBytes;
}
