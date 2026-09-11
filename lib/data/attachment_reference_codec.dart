import 'package:path/path.dart' as path;

abstract interface class AttachmentReferenceCodec {
  String encode(String reference);

  String decode(String storedReference);
}

final class IdentityAttachmentReferenceCodec
    implements AttachmentReferenceCodec {
  const IdentityAttachmentReferenceCodec();

  @override
  String encode(String reference) => reference;

  @override
  String decode(String storedReference) => storedReference;
}

/// Stores paths relative to the app's current attachment root.
///
/// Older app versions stored absolute iOS container paths. iOS may relocate
/// that container during an update, so legacy paths are recovered from their
/// `Documents/chat-images` suffix and resolved under the current root.
final class RootedAttachmentReferenceCodec implements AttachmentReferenceCodec {
  RootedAttachmentReferenceCodec(String rootPath)
    : _root = _normalizeAbsoluteRoot(rootPath);

  final String _root;

  @override
  String encode(String reference) {
    final normalized = _normalizedReference(reference);
    if (!path.isAbsolute(normalized) || !path.isWithin(_root, normalized)) {
      throw const FormatException(
        'Attachment reference is outside app storage.',
      );
    }
    return _validateRelative(path.relative(normalized, from: _root));
  }

  @override
  String decode(String storedReference) {
    final normalized = _normalizedReference(storedReference);
    if (!path.isAbsolute(normalized)) return _resolveRelative(normalized);
    if (path.isWithin(_root, normalized)) return normalized;

    final components = path.split(normalized);
    var legacyBoundary = -1;
    for (var index = 0; index + 1 < components.length; index++) {
      if (components[index] == 'Documents' &&
          components[index + 1] == 'chat-images') {
        legacyBoundary = index + 2;
      }
    }
    if (legacyBoundary < 0 || legacyBoundary >= components.length) {
      throw const FormatException(
        'Attachment reference is outside app storage.',
      );
    }
    return _resolveRelative(path.joinAll(components.sublist(legacyBoundary)));
  }

  String _resolveRelative(String value) {
    final relative = _validateRelative(value);
    final resolved = path.normalize(path.join(_root, relative));
    if (!path.isWithin(_root, resolved)) {
      throw const FormatException('Attachment reference escapes app storage.');
    }
    return resolved;
  }

  static String _normalizeAbsoluteRoot(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty || !path.isAbsolute(trimmed)) {
      throw ArgumentError.value(value, 'rootPath', 'must be absolute');
    }
    final normalized = path.normalize(trimmed);
    if (path.basename(normalized) != 'chat-images') {
      throw ArgumentError.value(
        value,
        'rootPath',
        'must identify the chat-images directory',
      );
    }
    return normalized;
  }

  static String _normalizedReference(String value) {
    if (value.isEmpty || value != value.trim() || value.contains('\u0000')) {
      throw const FormatException('Attachment reference is invalid.');
    }
    if (path.split(value).contains('..')) {
      throw const FormatException('Attachment reference escapes app storage.');
    }
    return path.normalize(value);
  }

  static String _validateRelative(String value) {
    final normalized = path.normalize(value);
    if (normalized.isEmpty ||
        normalized == '.' ||
        path.isAbsolute(normalized) ||
        normalized == '..' ||
        normalized.startsWith('../')) {
      throw const FormatException('Attachment reference escapes app storage.');
    }
    return normalized;
  }
}
