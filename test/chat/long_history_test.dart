import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobollama/domain/message.dart';

import '../support/chat_fixture.dart';

void main() {
  test('a 1000-message chat opens a window while find, export and next-turn context retain history', () async {
    final f = ChatFixture();
    await f.open();
    addTearDown(f.close);
    await f.store.createConversation(
      id: 'long',
      serverProfileId: 'home',
      selectedModel: 'gemma3:4b',
      systemPrompt: 'Keep context',
    );
    for (var i = 0; i < 1000; i++) {
      await f.store.appendMessage(
        id: 'm$i',
        conversationId: 'long',
        role: i.isEven ? MessageRole.user : MessageRole.assistant,
        status: MessageStatus.complete,
        content: i == 0 ? 'EARLY_CONTEXT' : 'message $i',
        imageReferences: i == 950 ? ['image://representative'] : const [],
      );
    }
    f.images.bytesByReference['image://representative'] = [1, 2, 3];
    await f.controller.initialize();
    await f.controller.openConversation('long');
    expect(f.controller.messages, hasLength(50));
    expect(f.controller.messages.first.id, 'm950');
    expect(f.controller.messages.first.imageReferences, [
      'image://representative',
    ]);
    expect(f.controller.hasOlderMessages, isTrue);
    await f.controller.loadOlderMessages();
    expect(f.controller.messages, hasLength(100));
    expect(f.controller.messages.first.id, 'm900');
    final exported = jsonDecode(await f.controller.exportBackup()) as Map;
    expect(
      (exported['conversations'] as List).single['messages'],
      hasLength(1000),
    );
    final hits = await f.controller.searchConversations('EARLY_CONTEXT');
    expect(hits.single.conversation.id, 'long');
    await f.controller.prepareFindInChat();
    expect(f.controller.transcriptMessages.first.content, 'EARLY_CONTEXT');
    await f.controller.newConversation();
    await f.controller.openConversation('long');
    expect(f.controller.messages, hasLength(50));
    expect(await f.controller.send('Continue'), isTrue);
    final sent = f.requests.last['messages'] as List;
    // Existing 128-message request budget still applies; the 50-row UI window does not.
    expect(sent, hasLength(128));
    expect(sent[1]['content'], 'message 874');
    expect(sent.last['content'], 'Continue');
    expect(f.controller.transcriptMessages, hasLength(50));
  });
}
