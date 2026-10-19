import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobollama/data/share_intake.dart';

import '../support/chat_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('shared items survive partial import and restart without replacing or duplicating drafts', () async {
    final f = ChatFixture();
    await f.open();
    addTearDown(f.close);
    final directory = await Directory.systemTemp.createTemp(
      'mobilellama-intake-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final removed = <String>[];
    const channel = MethodChannel('app.mobollama/intake');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'remove') {
            removed.add(call.arguments['id'] as String);
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    await f.controller.initialize();
    await f.controller.selectModel('gemma3:4b');
    f.controller.setDraftText('My existing draft');
    await f.controller.pickImage();
    final existingImage = f.controller.pendingImageReference;
    final intake = ShareIntake({
      'id': 'stable-intake',
      'root': directory.path,
      'items': [
        {
          'kind': 'text',
          'name': 'Shared URL',
          'text': 'https://example.test/article',
        },
        {'kind': 'image', 'name': 'Screenshot', 'file': 'image.png'},
        {'kind': 'image', 'name': 'Later screenshot', 'file': 'later.png'},
      ],
    });
    await File('${directory.path}/later.png').writeAsBytes([4, 5, 6]);
    final errors = await f.controller.importSharedContent(
      intake,
      newDraft: true,
    );
    expect(errors, hasLength(1));
    final sharedChat = f.controller.conversation!.id;
    expect(f.controller.draftText, 'https://example.test/article');
    expect(removed, isEmpty);
    expect(f.requests, isEmpty);
    await f.controller.shutdown();
    f.controller.dispose();
    f.createController();
    await f.controller.initialize();
    expect(f.controller.draftText, 'My existing draft');
    expect(f.controller.pendingImageReference, existingImage);
    expect(f.controller.sharedIntakeDraftScope(intake.id), sharedChat);
    await File('${directory.path}/image.png').writeAsBytes([1, 2, 3]);
    expect(
      await f.controller.importSharedContent(intake, newDraft: true),
      isEmpty,
    );
    expect(f.controller.draftText, 'https://example.test/article');
    expect(f.controller.pendingImageReferences, hasLength(2));
    expect(
      f.controller.pendingImageReferences.map(
        (r) => f.images.bytesByReference[r],
      ),
      [
        [1, 2, 3],
        [4, 5, 6],
      ],
    );
    expect(removed, ['stable-intake']);
    expect(
      await f.controller.importSharedContent(intake, newDraft: true),
      isEmpty,
    );
    expect(f.controller.conversation!.id, sharedChat);
    expect(f.controller.draftText, 'https://example.test/article');
    expect(f.controller.pendingImageReferences, hasLength(2));
    expect(f.requests, isEmpty);

    // A file copied before a failed receipt/draft transaction is not left
    // visible or orphaned, and restart retries in the committed destination.
    final retainedFiles = Set<String>.of(f.images.bytesByReference.keys);
    final second = ShareIntake({
      'id': 'second-intake',
      'root': directory.path,
      'items': [
        {'kind': 'image', 'name': 'Another screenshot', 'file': 'image.png'},
      ],
    });
    await f.database.execute(
      "CREATE TRIGGER reject_intake BEFORE INSERT ON intake_receipts BEGIN SELECT RAISE(ABORT, 'disk full'); END",
    );
    expect(
      await f.controller.importSharedContent(second, newDraft: true),
      isNotEmpty,
    );
    final retryChat = f.controller.conversation!.id;
    expect(f.controller.pendingImageReferences, isEmpty);
    expect(f.images.bytesByReference.keys.toSet(), retainedFiles);
    await f.database.execute('DROP TRIGGER reject_intake');
    await f.controller.shutdown();
    f.controller.dispose();
    f.createController();
    await f.controller.initialize();
    expect(
      await f.controller.importSharedContent(second, newDraft: true),
      isEmpty,
    );
    expect(f.controller.conversation!.id, retryChat);
    expect(f.controller.pendingImageReferences, hasLength(1));
    expect(f.images.bytesByReference.length, retainedFiles.length + 1);

    final discarded = ShareIntake({
      'id': 'discarded-intake',
      'root': directory.path,
      'items': [
        {'kind': 'text', 'name': 'Text', 'text': 'Keep this valid text'},
        {'kind': 'image', 'name': 'Missing screenshot', 'file': 'missing.png'},
      ],
    });
    expect(
      await f.controller.importSharedContent(discarded, newDraft: true),
      isNotEmpty,
    );
    await f.controller.discardSharedContent(discarded);
    expect(f.controller.draftText, 'Keep this valid text');
    expect(f.controller.sharedIntakeDraftScope(discarded.id), isNull);
    expect(removed, contains(discarded.id));
    final wholeDraft = ShareIntake({
      'id': 'whole-draft',
      'root': directory.path,
      'items': [
        {'kind': 'text', 'name': 'Text', 'text': 'Discard all of this'},
        {'kind': 'image', 'name': 'Missing screenshot', 'file': 'missing.png'},
      ],
    });
    await f.controller.importSharedContent(wholeDraft, newDraft: true);
    await f.controller.discardCurrentDraft();
    expect(removed, contains(wholeDraft.id));
    await f.controller.shutdown();
    f.controller.dispose();
    f.createController();
    await f.controller.initialize();
    expect(f.controller.sharedIntakeDraftScope(discarded.id), isNull);
    expect(f.controller.sharedIntakeDraftScope(wholeDraft.id), isNull);
  });
}
