import 'dart:convert';
import 'dart:io';

import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../chat/chat_controller.dart';
import 'attachment_reference_codec.dart';

final class LocalImageAttachmentStore implements ImageAttachmentStore {
  const LocalImageAttachmentStore(this._root, this._picker);

  final Directory _root;
  final ImagePicker _picker;
  AttachmentReferenceCodec get referenceCodec =>
      RootedAttachmentReferenceCodec(_root.path);

  static Future<LocalImageAttachmentStore> at(Directory root) async {
    await root.create(recursive: true);
    return LocalImageAttachmentStore(root, ImagePicker());
  }

  static Future<LocalImageAttachmentStore> create() async {
    final documents = await getApplicationDocumentsDirectory();
    final root = Directory(path.join(documents.path, 'chat-images'));
    await root.create(recursive: true);
    return LocalImageAttachmentStore(root, ImagePicker());
  }

  @override
  Future<String?> pickAndCopy({
    required String conversationId,
    bool camera = false,
  }) async {
    final picked = await _picker.pickImage(
      source: camera ? ImageSource.camera : ImageSource.gallery,
      maxWidth: 2048,
      maxHeight: 2048,
      imageQuality: 88,
    );
    if (picked == null) return null;
    final directory = _conversationDirectory(conversationId);
    await directory.create(recursive: true);
    final rawExtension = path.extension(picked.name).toLowerCase();
    final extension = RegExp(r'^\.[a-z0-9]{1,8}$').hasMatch(rawExtension)
        ? rawExtension
        : '.img';
    final target = File(
      path.join(directory.path, '${const Uuid().v4()}$extension'),
    );
    await File(picked.path).copy(target.path);
    if (await target.length() > ChatController.maxImageBytes) {
      await target.delete();
      throw const ChatRequestLimitException(
        'The selected image is larger than 8 MB after resizing.',
      );
    }
    return target.path;
  }

  @override
  Future<String> readAsBase64(String reference) async {
    final file = _validatedFile(reference);
    return base64Encode(await file.readAsBytes());
  }

  @override
  Future<String> writeBytes({
    required String conversationId,
    required List<int> bytes,
    required String sourceName,
    String? storageId,
  }) async {
    if (bytes.isEmpty || bytes.length > ChatController.maxImageBytes) {
      throw const FormatException('Backup image is empty or exceeds 8 MB.');
    }
    final directory = _conversationDirectory(conversationId);
    await directory.create(recursive: true);
    final extension = path.extension(sourceName).toLowerCase();
    final suffix = RegExp(r'^\.[a-z0-9]{1,8}$').hasMatch(extension)
        ? extension
        : '.img';
    if (storageId != null &&
        !RegExp(r'^intake-[a-f0-9]{64}$').hasMatch(storageId)) {
      throw const FormatException('Invalid shared attachment identity.');
    }
    final file = File(
      path.join(directory.path, '${storageId ?? const Uuid().v4()}$suffix'),
    );
    try {
      await file.writeAsBytes(bytes, flush: true);
      return file.path;
    } on Object {
      if (await file.exists()) await file.delete();
      rethrow;
    }
  }

  /// Called before any controller starts. Only share-import files participate;
  /// ordinary picker, backup, and sync files retain their existing lifecycle.
  Future<void> reclaimAbandonedIntakeFiles(
    Future<bool> Function(String) isRetained,
  ) async {
    await for (final entity in _root.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is File &&
          path.basename(entity.path).startsWith('intake-') &&
          !await isRetained(entity.path)) {
        await entity.delete();
      }
    }
  }

  @override
  Future<int> sizeInBytes(String reference) async {
    final stat = await _validatedFile(reference).stat();
    if (stat.type != FileSystemEntityType.file) {
      throw FileSystemException('Image file is missing.', reference);
    }
    return stat.size;
  }

  @override
  Future<void> deleteReference(String reference) async {
    final file = _validatedFile(reference);
    if (await file.exists()) await file.delete();
  }

  @override
  Future<void> deleteConversation(String conversationId) async {
    final directory = _conversationDirectory(conversationId);
    if (await directory.exists()) await directory.delete(recursive: true);
  }

  Directory _conversationDirectory(String conversationId) {
    final segment = base64Url
        .encode(utf8.encode(conversationId))
        .replaceAll('=', '');
    return Directory(path.join(_root.path, segment));
  }

  File _validatedFile(String reference) {
    final normalizedRoot = path.normalize(path.absolute(_root.path));
    final normalizedReference = path.normalize(path.absolute(reference));
    if (!path.isWithin(normalizedRoot, normalizedReference)) {
      throw ArgumentError('Image reference is outside app storage.');
    }
    return File(normalizedReference);
  }
}
