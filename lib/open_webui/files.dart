import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'client.dart';

/// Pending server uploads never enter the direct-chat attachment store.
final class WebUiFiles {
  const WebUiFiles(this.root);
  final Directory root;
  static Future<WebUiFiles> create() async => WebUiFiles(
    Directory(
      path.join((await getApplicationSupportDirectory()).path, 'WebUiFiles'),
    ),
  );
  Directory account(String server, String userId) => Directory(
    path.join(
      root.path,
      sha256.convert(utf8.encode(jsonEncode([server, userId]))).toString(),
    ),
  );

  Future<Map<String, dynamic>> stage(
    WebUiLease lease,
    String name,
    List<int> bytes,
  ) async {
    lease.check();
    if (bytes.isEmpty || bytes.length > 8 * 1024 * 1024) {
      throw const WebUiException('Choose a nonempty file of up to 8 MB.');
    }
    final directory = account(lease.identity.server, lease.identity.userId);
    await directory.create(recursive: true);
    lease.check();
    final id = const Uuid().v4();
    final safeName = path
        .basename(name)
        .replaceAll(RegExp(r'[\x00-\x1f/\\:]'), '_');
    final file = File(path.join(directory.path, '$id-$safeName'));
    await file.writeAsBytes(bytes, flush: true);
    try {
      lease.check();
    } on Object {
      await file.delete();
      rethrow;
    }
    return {
      'localId': id,
      'name': safeName,
      'path': file.path,
      'state': 'pending',
      'mime': mime(safeName),
    };
  }

  Future<List<int>> read(WebUiLease lease, String reference) async {
    lease.check();
    final directory = account(lease.identity.server, lease.identity.userId);
    if (!path.isWithin(directory.path, reference) ||
        path.dirname(reference) != directory.path) {
      throw const WebUiException(
        'The staged file does not belong to this account.',
      );
    }
    final file = File(reference);
    if (await file.length() > 8 * 1024 * 1024) {
      throw const WebUiException('This file exceeds 8 MB.');
    }
    final bytes = await file.readAsBytes();
    lease.check();
    return bytes;
  }

  Future<void> reclaimAbandoned(WebUiLease lease, Set<String> retained) async {
    final directory = account(lease.identity.server, lease.identity.userId);
    if (!await directory.exists()) return;
    await for (final entry in directory.list(followLinks: false)) {
      lease.check();
      if (entry is File && !retained.contains(entry.path)) await entry.delete();
    }
  }

  Future<void> clearAccount(String server, String userId) async {
    final directory = account(server, userId);
    if (await directory.exists()) await directory.delete(recursive: true);
  }

  Future<void> discard(WebUiLease lease, String reference) async {
    lease.check();
    final directory = account(lease.identity.server, lease.identity.userId);
    if (path.dirname(reference) != directory.path) return;
    final file = File(reference);
    if (await file.exists()) await file.delete();
  }

  static String mime(String name) =>
      switch (path.extension(name).toLowerCase()) {
        '.pdf' => 'application/pdf',
        '.txt' => 'text/plain',
        '.md' => 'text/markdown',
        '.png' => 'image/png',
        '.jpg' || '.jpeg' => 'image/jpeg',
        '.webp' => 'image/webp',
        '.gif' => 'image/gif',
        '.csv' => 'text/csv',
        '.json' => 'application/json',
        _ => 'application/octet-stream',
      };
}
