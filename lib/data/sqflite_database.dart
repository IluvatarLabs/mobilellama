import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart' as sqflite;

import 'attachment_reference_codec.dart';
import 'conversation_store.dart';

final class SqfliteDatabaseAdapter implements SqliteDatabase {
  SqfliteDatabaseAdapter(sqflite.Database database)
    : _executor = database,
      _database = database;

  SqfliteDatabaseAdapter._(this._executor) : _database = null;

  final sqflite.DatabaseExecutor _executor;
  final sqflite.Database? _database;

  @override
  Future<void> execute(
    String sql, [
    List<Object?> parameters = const <Object?>[],
  ]) => _executor.execute(sql, parameters);

  @override
  Future<List<Map<String, Object?>>> query(
    String sql, [
    List<Object?> parameters = const <Object?>[],
  ]) => _executor.rawQuery(sql, parameters);

  @override
  Future<T> transaction<T>(Future<T> Function(SqliteDatabase database) action) {
    final database = _database;
    if (database == null) return action(this);
    return database.transaction(
      (transaction) => action(SqfliteDatabaseAdapter._(transaction)),
    );
  }
}

final class OpenConversationDatabase {
  const OpenConversationDatabase._(this.store, this._database);

  final ConversationStore store;
  final sqflite.Database _database;

  Future<void> close() => _database.close();
}

Future<OpenConversationDatabase> openConversationDatabase({
  required String legacyServerProfileId,
  String? databasePath,
  AttachmentReferenceCodec referenceCodec =
      const IdentityAttachmentReferenceCodec(),
}) async {
  final resolvedPath =
      databasePath ??
      path.join(await sqflite.getDatabasesPath(), 'mobollama.db');
  final database = await sqflite.openDatabase(
    resolvedPath,
    onConfigure: (database) => database.execute('PRAGMA foreign_keys = ON'),
  );
  final adapter = SqfliteDatabaseAdapter(database);
  final store = ConversationStore(adapter, referenceCodec: referenceCodec);

  try {
    final versionRows = await adapter.query('PRAGMA user_version');
    final versionValue = versionRows.single.values.single;
    final fromVersion = versionValue is num ? versionValue.toInt() : 0;
    await store.migrate(
      fromVersion: fromVersion,
      legacyServerProfileId: legacyServerProfileId,
    );
    return OpenConversationDatabase._(store, database);
  } catch (_) {
    await database.close();
    rethrow;
  }
}
