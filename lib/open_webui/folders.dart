import 'client.dart';

/// Server-owned hierarchy and prompts. There is no parallel local folder tree.
final class WebUiFolders {
  const WebUiFolders(this.session);
  final WebUiSession session;
  Future<List<Map<String, dynamic>>> list() async {
    final lease = session.capture();
    final owned = await session.client.request(
      'GET',
      'api/v1/folders/',
      lease: lease,
    ) as List;
    final shared = await session.client.request(
      'GET',
      'api/v1/folders/shared',
      lease: lease,
    ) as List;
    return {
      for (final value in [...shared, ...owned])
        (value as Map)['id'] as String: Map<String, dynamic>.from(value),
    }.values.toList();
  }

  Future<Map<String, dynamic>> get(String id) async =>
      Map<String, dynamic>.from(
        await session.client.request(
          'GET',
          'api/v1/folders/${Uri.encodeComponent(id)}',
          lease: session.capture(),
        ) as Map,
      );
  Future<void> save({
    String? id,
    String? parentId,
    required String name,
    required String instructions,
  }) async {
    if (name.trim().isEmpty) throw const WebUiException('Enter a folder name.');
    await session.client.request(
      'POST',
      id == null
          ? 'api/v1/folders/'
          : 'api/v1/folders/${Uri.encodeComponent(id)}/update',
      body: {
        'name': name.trim(),
        'data': {'system_prompt': instructions},
        if (id == null) 'parent_id': parentId,
      },
      lease: session.capture(),
    );
  }

  Future<void> move(String id, String? parentId) async {
    await session.client.request(
      'POST',
      'api/v1/folders/${Uri.encodeComponent(id)}/update/parent',
      body: {'parent_id': parentId},
      lease: session.capture(),
    );
  }

  Future<void> deleteKeepingChats(String id) async {
    await session.client.request(
      'DELETE',
      'api/v1/folders/${Uri.encodeComponent(id)}',
      query: {'delete_contents': 'false'},
      lease: session.capture(),
    );
  }

  Future<void> moveChat(String chatId, String? folderId) async {
    await session.client.request(
      'POST',
      'api/v1/chats/${Uri.encodeComponent(chatId)}/folder',
      body: {'folder_id': folderId},
      lease: session.capture(),
    );
  }

  Future<({List<Map<String, dynamic>> chats, bool more})> chats(
    Map<String, dynamic> folder,
    int page,
  ) async {
    final shared = folder['user_id'] != session.identity.userId;
    final id = Uri.encodeComponent(folder['id'] as String);
    final value = await session.client.request(
      'GET',
      shared
          ? 'api/v1/folders/$id/shared/chats'
          : 'api/v1/chats/folder/$id/list',
      query: {'page': '$page'},
      lease: session.capture(),
    );
    final rows = shared ? (value as Map)['chats'] as List : value as List;
    return (
      chats: rows.map((v) => Map<String, dynamic>.from(v as Map)).toList(),
      more: shared ? (value as Map)['has_more'] == true : rows.length >= 10,
    );
  }
}
