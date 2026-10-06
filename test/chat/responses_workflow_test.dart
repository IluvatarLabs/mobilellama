import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobollama/data/settings_store.dart';
import 'package:mobollama/domain/message.dart';

import '../support/chat_fixture.dart';

void main() {
  test('Responses replay survives a portable restore and incomplete output stays recoverable', () async {
    final source = ChatFixture();
    final restored = ChatFixture();
    await source.open();
    await restored.open();
    addTearDown(source.close);
    addTearDown(restored.close);
    final profile = ServerProfile(
      id: 'responses',
      name: 'Responses',
      protocol: ServerProtocol.openAiCompatible,
      compatibleApi: CompatibleApi.responses,
      baseUrl: 'https://api.test/prefix',
    );
    final annotation = {
      'type': 'url_citation',
      'url': 'https://example.test/source',
      'title': 'Evidence',
      'start_index': 0,
      'end_index': 8,
    };
    final output = [
      {
        'type': 'reasoning',
        'id': 'reason-1',
        'summary': [],
        'encrypted_content': 'opaque-continuation',
      },
      {
        'type': 'message',
        'id': 'answer-1',
        'role': 'assistant',
        'status': 'completed',
        'phase': 'final_answer',
        'content': [
          {
            'type': 'output_text',
            'text': 'Complete answer.',
            'annotations': [
              {
                'type': 'url_citation',
                'url': 'https://example.test/source',
                'title': 'Evidence',
                'start_index': 0,
                'end_index': 8,
              },
            ],
          },
        ],
      },
    ];
    List<String> frames(Map<String, dynamic> request) => [
      'data: ${jsonEncode({'type': 'response.output_text.annotation.added', 'item_id': 'answer-1', 'content_index': 0, 'annotation_index': 0, 'annotation': annotation})}\n\n',
      'data: ${jsonEncode({'type': 'response.output_text.delta', 'delta': 'Complete '})}\n\n',
      'data: ${jsonEncode({
        'type': 'response.completed',
        'response': {
          'status': 'completed',
          'store': false,
          'output': output,
          'usage': {'input_tokens': 7, 'output_tokens': 3},
        },
      })}\n\n',
    ];
    source.compatibleFrames = frames;
    restored.compatibleFrames = frames;
    for (final fixture in [source, restored]) {
      await fixture.controller.initialize();
      expect(
        (await fixture.controller.saveAndConnectServerProfile(profile))
            .connection!
            .succeeded,
        isTrue,
      );
    }
    expect(await source.controller.send('First question'), isTrue);
    expect(source.controller.messages.last.content, 'Complete answer.');
    expect(source.controller.messages.last.sources.single.title, 'Evidence');
    final backup = await source.controller.exportBackup();
    expect(await restored.controller.importBackup(backup), 1);
    await restored.controller.openConversation(
      restored.controller.history.single.id,
    );
    expect(
      restored.controller.messages.last.sources.single.url,
      'https://example.test/source',
    );
    expect(await restored.controller.send('Continue after restore'), isTrue);
    final request = restored.requests.last;
    expect(request['store'], isFalse);
    expect(request.containsKey('previous_response_id'), isFalse);
    expect((request['input'] as List).sublist(1, 3), output);
    expect(
      (request['input'] as List).last['content'][0]['text'],
      'Continue after restore',
    );
    restored.compatibleFrames = (_) => [
      'data: {"type":"response.output_text.delta","delta":"Useful partial"}\n\n',
    ];
    await restored.controller.send('Interrupted turn');
    expect(restored.controller.messages.last.content, 'Useful partial');
    expect(
      restored.controller.messages.last.status,
      isNot(MessageStatus.complete),
    );
    restored.compatibleFrames = (_) => [
      'data: {"type":"response.output_text.delta","delta":"Keep this partial"}\n\n',
      'data: {"type":"response.failed","response":{"status":"failed","output":[]}}\n\n',
    ];
    await restored.controller.send('Failure after content');
    expect(restored.controller.messages.last.content, 'Keep this partial');
    expect(
      restored.controller.messages.last.status,
      isNot(MessageStatus.complete),
    );
  });
}
