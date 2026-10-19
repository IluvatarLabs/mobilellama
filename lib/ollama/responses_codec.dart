import 'dart:convert';

import 'ollama_client.dart';
import '../domain/source_reference.dart';

/// Stateless Responses encoding. Provider items are retained verbatim, in
/// order; display text is never used to reconstruct opaque continuation state.
final class ResponsesCodec {
  ResponsesCodec(this.model);
  final String model;
  final _items = <int, Map<String, dynamic>>{};
  OllamaChatChunk? _terminal;

  static Map<String, dynamic> request(
    OllamaChatRequest request,
    String Function(String) imageDataUrl,
  ) {
    final input = <Map<String, dynamic>>[];
    final instructions = <String>[];
    for (final message in request.messages) {
      if (message.role == OllamaRole.system) {
        instructions.add(message.content);
      } else if (message.providerItems.isNotEmpty) {
        input.addAll(message.providerItems);
      } else if (message.role == OllamaRole.tool) {
        input.add({
          'type': 'function_call_output',
          'call_id': message.toolCallId,
          'output': message.content,
        });
      } else {
        if (message.content.isNotEmpty || message.images.isNotEmpty) {
          input.add({
            'role': message.role.name,
            'content': [
              if (message.content.isNotEmpty)
                {
                  'type': message.role == OllamaRole.assistant
                      ? 'output_text'
                      : 'input_text',
                  'text': message.content,
                },
              for (final image in message.images)
                {'type': 'input_image', 'image_url': imageDataUrl(image)},
            ],
          });
        }
        for (final call in message.toolCalls) {
          input.add({
            'type': 'function_call',
            'call_id': call.id,
            'name': call.name,
            'arguments': jsonEncode(call.arguments),
          });
        }
      }
    }
    final options = request.validatedOptions;
    return {
      'model': request.model,
      'stream': true,
      'store': false,
      'instructions': instructions.join('\n\n'),
      'input': input,
      if (request.tools.isNotEmpty)
        'tools': [
          for (final tool in request.tools)
            {
              'type': 'function',
              'name': tool.name,
              'description': tool.description,
              'parameters': tool.parameters,
              'strict': false,
            },
        ],
      if (request.think != null)
        'reasoning': {'effort': request.think! ? 'high' : 'none'},
      if (options['temperature'] != null) 'temperature': options['temperature'],
      if (options['top_p'] != null) 'top_p': options['top_p'],
      if (options['num_predict'] != null)
        'max_output_tokens': options['num_predict'],
    };
  }

  OllamaChatChunk? accept(Map<String, dynamic> event) {
    if (_terminal != null) {
      throw const OllamaStreamException(
        'Responses emitted data after completion.',
      );
    }
    final type = event['type'];
    switch (type) {
      case 'response.output_text.delta':
      case 'response.refusal.delta':
        return _chunk(content: _text(event['delta']));
      case 'response.reasoning_summary_text.delta':
      case 'response.reasoning_text.delta':
        return _chunk(thinking: _text(event['delta']));
      case 'response.output_text.annotation.added':
        final annotation = event['annotation'];
        if (annotation == null) return null;
        if (annotation is! Map) {
          throw const OllamaStreamException('Invalid Responses annotation.');
        }
        final source = SourceReference.fromAnnotation(
          annotation,
          '${event['item_id']}:${event['content_index']}:${event['annotation_index']}',
        );
        return source == null ? null : _chunk(sources: [source]);
      case 'response.output_item.done':
        final index = event['output_index'];
        final item = event['item'];
        if (index is! int || item is! Map) {
          throw const OllamaStreamException(
            'Invalid completed Responses item.',
          );
        }
        _items[index] = Map<String, dynamic>.from(item);
        return _chunk(items: _orderedItems);
      case 'response.completed':
      case 'response.incomplete':
      case 'response.failed':
        final raw = event['response'];
        if (raw is! Map || raw['output'] is! List) {
          throw const OllamaStreamException(
            'Responses terminal event is missing its output.',
          );
        }
        final response = Map<String, dynamic>.from(raw);
        if (response['store'] == true) {
          throw const OllamaStreamException(
            'This endpoint did not honor stateless Responses mode (store:false).',
          );
        }
        final output = (response['output'] as List)
            .map((item) => Map<String, dynamic>.from(item as Map))
            .toList();
        final calls = <OllamaToolCall>[];
        final text = StringBuffer();
        for (final item in output) {
          if (item['type'] == 'message') {
            for (final part in item['content'] as List? ?? const []) {
              if (part['type'] == 'output_text') {
                text.write(_text(part['text']));
              }
              if (part['type'] == 'refusal') text.write(_text(part['refusal']));
            }
          } else if (item['type'] == 'function_call') {
            final id = item['call_id'];
            final name = item['name'];
            final arguments = jsonDecode(_text(item['arguments']));
            if (id is! String ||
                id.isEmpty ||
                name is! String ||
                arguments is! Map) {
              throw const OllamaStreamException(
                'Invalid Responses function call.',
              );
            }
            calls.add(
              OllamaToolCall(
                id: id,
                name: name,
                arguments: Map<String, dynamic>.from(arguments),
                index: calls.length,
              ),
            );
          }
        }
        final usage = response['usage'] as Map?;
        _terminal = OllamaChatChunk(
          model: response['model'] as String? ?? model,
          message: OllamaChatMessage(
            role: OllamaRole.assistant,
            content: '',
            toolCalls: calls,
            providerItems: output,
            sources: SourceReference.fromProviderItems(output),
          ),
          authoritativeContent: type == 'response.completed' || text.isNotEmpty
              ? text.toString()
              : null,
          done: true,
          doneReason: type == 'response.completed'
              ? (calls.isEmpty ? 'stop' : 'tool_calls')
              : (response['incomplete_details'] as Map?)?['reason']
                        as String? ??
                    'failed',
          promptEvalCount: usage?['input_tokens'] as int?,
          evalCount: usage?['output_tokens'] as int?,
        );
        return null;
      case 'error':
        throw OllamaStreamException(
          'Responses error: ${event['message'] ?? 'request failed'}',
        );
      case 'response.created':
      case 'response.queued':
      case 'response.in_progress':
      case 'response.output_item.added':
      case 'response.content_part.added':
      case 'response.content_part.done':
      case 'response.output_text.done':
      case 'response.refusal.done':
      case 'response.reasoning_summary_part.added':
      case 'response.reasoning_summary_part.done':
      case 'response.reasoning_summary_text.done':
      case 'response.reasoning_part.added':
      case 'response.reasoning_part.done':
      case 'response.reasoning_text.done':
      case 'response.function_call_arguments.delta':
      case 'response.function_call_arguments.done':
        return null;
      default:
        throw OllamaStreamException('Unsupported Responses event: $type');
    }
  }

  List<Map<String, dynamic>> get _orderedItems => [
    for (final index in _items.keys.toList()..sort()) _items[index]!,
  ];
  OllamaChatChunk _chunk({
    String content = '',
    String thinking = '',
    List<Map<String, dynamic>> items = const [],
    List<SourceReference> sources = const [],
  }) => OllamaChatChunk(
    model: model,
    message: OllamaChatMessage(
      role: OllamaRole.assistant,
      content: content,
      thinking: thinking,
      providerItems: items,
      sources: sources,
    ),
    done: false,
  );
  OllamaChatChunk finish() =>
      _terminal ??
      (throw const OllamaStreamException(
        'Responses stream ended without a terminal event. The partial answer is retained.',
      ));
  static String _text(Object? value) => value is String
      ? value
      : (throw const OllamaStreamException('Responses text must be a string.'));
}
