import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../chat/chat_controller.dart';
import 'local_image_store.dart';
import 'sqflite_database.dart';
import 'conversation_store.dart';

/// Disk holds only session attachments. History, drafts, and queues use an
/// independent in-memory database which is never connected to CloudKit.
final class TemporaryChatSession {
  TemporaryChatSession._(this.controller, this._database, this._directory);
  final ChatController controller;
  final OpenConversationDatabase _database;
  final Directory _directory;
  Future<void>? _closing;
  static bool cleanupPending = false;

  static Future<Directory> _root() async => Directory(
    path.join((await getTemporaryDirectory()).path, 'MobileLlamaTemporary'),
  );

  /// Called only at process startup, before any temporary session exists.
  static Future<void> clearAbandoned() async {
    try {
      final root = await _root();
      if (await root.exists()) await root.delete(recursive: true);
      cleanupPending = false;
    } on Object {
      cleanupPending = true;
    }
  }

  static Future<TemporaryChatSession> open(ChatController parent) async {
    if (cleanupPending) {
      await clearAbandoned();
      if (cleanupPending) {
        throw const FileSystemException(
          'Previous temporary attachments could not be cleared. Try again after storage becomes available.',
        );
      }
    }
    final directory = Directory(
      path.join((await _root()).path, const Uuid().v4()),
    );
    final images = await LocalImageAttachmentStore.at(
      Directory(path.join(directory.path, 'chat-images')),
    );
    OpenConversationDatabase? database;
    try {
      database = await openConversationDatabase(
        legacyServerProfileId: parent.conversationProfile.id,
        databasePath: inMemoryDatabasePath,
        schemaVersion: parent.versionsEnabled
            ? ConversationStore.schemaVersion
            : 12,
        referenceCodec: images.referenceCodec,
      );
      final controller = await parent.temporaryController(
        store: database.store,
        images: images,
      );
      return TemporaryChatSession._(controller, database, directory);
    } catch (_) {
      await database?.close();
      if (await directory.exists()) await directory.delete(recursive: true);
      rethrow;
    }
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    try {
      await controller.shutdown();
    } finally {
      controller.dispose();
      try {
        await _database.close();
      } finally {
        try {
          if (await _directory.exists()) {
            await _directory.delete(recursive: true);
          }
        } on Object {
          cleanupPending = true;
        }
      }
    }
  }
}
