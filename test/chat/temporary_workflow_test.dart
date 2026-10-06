import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:mobollama/data/document_reader.dart';

import 'package:flutter_test/flutter_test.dart';

import '../support/chat_fixture.dart';

void main() {
  test('temporary history stays isolated; explicit Save retains messages and draft media after the session ends', () async {
    final directory = await Directory.systemTemp.createTemp(
      'temporary-document-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final document = await File('${directory.path}/draft.txt')
        .writeAsString('Document draft bytes');
    final parent = ChatFixture()
      ..documentReader = DocumentReader(
        picker: () async => XFile(document.path),
      );
    final memory = ChatFixture();
    await parent.open(version: 13);
    await memory.open(version: 13);
    addTearDown(parent.close);
    addTearDown(memory.close);
    await parent.seed('ordinary');
    await parent.controller.initialize();
    await parent.controller.openConversation('ordinary');
    parent.controller.setDraftText('Original unsent draft');
    await parent.controller.flushDrafts();
    final preferences = Map.of(parent.preferences.values);
    final secrets = Map.of(parent.secrets.values);
    final temp = await parent.controller.temporaryController(
      store: memory.store,
      images: memory.images,
    );
    expect(temp.chatSync, isNull);
    expect(temp.messages, isEmpty);
    await temp.send('A temporary question');
    await temp.selectModel('gemma3:4b');
    temp.setDraftText('Keep this unsent follow-up');
    final bytes = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a6XkAAAAASUVORK5CYII=',
    );
    await temp.pickImage(imageBytes: bytes);
    await temp.pickDocument();
    expect(temp.pendingDocuments, hasLength(1), reason: temp.errorMessage);
    await temp.pauseForBackground();
    expect(parent.controller.messages.first.content, 'Saved conversation');
    expect(parent.controller.draftText, 'Original unsent draft');
    expect(
      await parent.controller.exportBackup(),
      isNot(contains('A temporary question')),
    );
    expect(parent.preferences.values, preferences);
    expect(parent.secrets.values, secrets);
    final saved = await temp.saveTemporaryTo(parent.controller);
    expect(await temp.saveTemporaryTo(parent.controller), saved);
    expect(parent.controller.history.length, 2);
    await temp.shutdown();
    temp.dispose();
    memory.images.bytesByReference.clear();
    expect(parent.controller.messages.first.content, 'A temporary question');
    expect(parent.controller.draftText, 'Keep this unsent follow-up');
    expect(
      parent.images.bytesByReference[parent
          .controller
          .pendingDocuments
          .single
          .reference],
      utf8.encode('Document draft bytes'),
    );
    expect(
      parent.images.bytesByReference[parent
          .controller
          .pendingImageReferences
          .single],
      bytes,
    );
    await parent.controller.shutdown();
    parent.controller.dispose();
    parent.createController();
    await parent.controller.initialize();
    await parent.controller.openConversation(saved);
    expect(parent.controller.draftText, 'Keep this unsent follow-up');
    expect(parent.controller.messages.first.content, 'A temporary question');
    await parent.controller.openConversation('ordinary');
    expect(parent.controller.draftText, 'Original unsent draft');
  });

  test('discarded queued work cannot enter a later temporary session or ordinary history', () async {
    final parent = ChatFixture();
    final memory = ChatFixture();
    final nextMemory = ChatFixture();
    await parent.open();
    await memory.open();
    await nextMemory.open();
    addTearDown(parent.close);
    addTearDown(memory.close);
    addTearDown(nextMemory.close);
    await parent.controller.initialize();
    final temp = await parent.controller.temporaryController(
      store: memory.store,
      images: memory.images,
    );
    parent.holdResponse = true;
    final sending = temp.send('Discarded question');
    while (parent.responseControls.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(await temp.send('Discarded queued follow-up'), isTrue);
    expect(temp.queuedPrompts, isNotEmpty);
    temp.setDraftText('Discarded draft');
    await temp.pauseForBackground();
    await temp.shutdown();
    temp.dispose();
    await sending;
    final next = await parent.controller.temporaryController(
      store: nextMemory.store,
      images: nextMemory.images,
    );
    expect(next.messages, isEmpty);
    expect(next.draftText, isEmpty);
    expect(next.queuedPrompts, isEmpty);
    expect(parent.controller.history, isEmpty);
    expect(
      await parent.controller.exportBackup(),
      isNot(contains('Discarded')),
    );
    await next.shutdown();
    next.dispose();
  });
}
