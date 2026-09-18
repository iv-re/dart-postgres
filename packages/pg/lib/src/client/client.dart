/// @docImport 'dart:io';
/// @docImport 'package:pg/src/client/exception.dart';
library;

import 'dart:async';

import 'package:ctx/ctx.dart';
import 'package:pg/src/client/cancel_token.dart';
import 'package:pg/src/client/config.dart';
import 'package:pg/src/client/connection.dart';
import 'package:pg/src/client/copy.dart';
import 'package:pg/src/client/copy_out.dart';
import 'package:pg/src/client/notification.dart';
import 'package:pg/src/client/pipeline.dart';
import 'package:pg/src/client/portal.dart';
import 'package:pg/src/client/rows.dart';
import 'package:pg/src/client/session.dart';
import 'package:pg/src/client/statement.dart';
import 'package:pg/src/client/statement_cache.dart';
import 'package:pg/src/client/transaction.dart';

/// A client representing a single PostgreSQL connection.
///
/// Create instances via [PgClient.connect]. The client caches prepared
/// statements (LRU, default capacity 100) and automatically closes evicted
/// statements on the server.
///
/// Always call [close] when done to release the TCP socket.
class PgClient implements PgSession {
  PgClient._(
    this._connection, {
    int statementCacheCapacity = 100,
  }) : _statementCache = PgStatementCache(capacity: statementCacheCapacity);

  final PgConnection _connection;
  final PgStatementCache _statementCache;

  /// Whether the client connection is open and active.
  bool get isConnected => !_connection.isClosed;

  /// Token for out-of-band query cancellation via [PgCancelToken.cancel].
  PgCancelToken get cancelToken => _connection.cancelToken;

  /// Server-initiated notification stream (PostgreSQL `LISTEN` / `NOTIFY`).
  Stream<PgNotification> get notifications => _connection.notifications;

  /// Current backend transaction status (`idle`, `inTransaction`, `failed`).
  PgTransactionStatus get transactionStatus => _connection.transactionStatus;

  /// Establishes a new TCP connection to the PostgreSQL server described by
  /// [config].
  ///
  /// Throws [SocketException] on network failure or [PgException] on
  /// authentication error.
  static Future<PgClient> connect(
    PgConfig config, {
    int statementCacheCapacity = 100,
  }) async {
    final connection = await PgConnection.open(config);
    return PgClient._(
      connection,
      statementCacheCapacity: statementCacheCapacity,
    );
  }

  @override
  Future<PgRows> simpleQuery(
    String sql, {
    Context? ctx,
  }) {
    return _connection.simpleQuery(sql, ctx: ctx);
  }

  @override
  Future<PgRows> query(
    String sql,
    List<Object?> params, {
    PgQueryMode? mode,
    Context? ctx,
  }) {
    switch (mode ?? _connection.config.queryMode) {
      case .simple:
        if (params.isNotEmpty) {
          throw ArgumentError(
            'Simple Query Protocol does not support parameters.',
          );
        }
        return _connection.simpleQuery(sql, ctx: ctx);

      case .unnamed:
        return _connection.query(sql, params, ctx: ctx);

      case .prepared:
        if (params.isEmpty) {
          return _connection.simpleQuery(sql, ctx: ctx);
        }
        final statement = prepare(sql, ctx: ctx);
        if (statement is PgStatement) {
          return _connection.execute(statement, params, ctx: ctx);
        }
        return statement.then(
          (stmt) => _connection.execute(stmt, params, ctx: ctx),
        );
    }
  }

  @override
  Future<PgRowStream> queryStream(
    String sql,
    List<Object?> params, {
    PgQueryMode? mode,
    Context? ctx,
  }) async {
    switch (mode ?? _connection.config.queryMode) {
      case .simple:
        if (params.isNotEmpty) {
          throw ArgumentError(
            'Simple Query Protocol does not support parameters.',
          );
        }
        return _connection.queryStream(sql, const [], mode: .simple, ctx: ctx);

      case .unnamed:
        return _connection.queryStream(sql, params, ctx: ctx);

      case .prepared:
        if (params.isEmpty) {
          return _connection.queryStream(
            sql,
            const [],
            mode: .simple,
            ctx: ctx,
          );
        }
        final statement = await prepare(sql, ctx: ctx);
        return _connection.executeStream(statement, params, ctx: ctx);
    }
  }

  @override
  FutureOr<PgStatement> prepare(
    String sql, {
    String? name,
    Context? ctx,
  }) {
    final cached = _statementCache.get(sql);
    if (cached != null) return cached;

    final stmtName = name ?? PgStatementCache.computeStatementName(sql);
    return _connection.prepare(sql, name: stmtName, ctx: ctx).then((stmt) {
      if (_statementCache.put(sql, stmt) case final evicted?) {
        unawaited(_connection.closeStatement(evicted, ctx: ctx));
      }
      return stmt;
    });
  }

  @override
  Future<PgRows> execute(
    PgStatement statement,
    List<Object?> params, {
    Context? ctx,
  }) {
    return _connection.execute(statement, params, ctx: ctx);
  }

  @override
  Future<PgRowStream> executeStream(
    PgStatement statement,
    List<Object?> params, {
    Context? ctx,
  }) {
    return _connection.executeStream(statement, params, ctx: ctx);
  }

  @override
  Future<PgPortal> bind(
    PgStatement statement,
    List<Object?> params, {
    String? name,
    Context? ctx,
  }) {
    return _connection.bind(statement, params, name: name, ctx: ctx);
  }

  @override
  Future<PgRows> queryPortal(
    PgPortal portal, {
    int maxRows = 0,
    Context? ctx,
  }) {
    return _connection.queryPortal(portal, maxRows: maxRows, ctx: ctx);
  }

  @override
  Future<PgRowStream> queryPortalStream(
    PgPortal portal, {
    int maxRows = 0,
    Context? ctx,
  }) {
    return _connection.queryPortalStream(portal, maxRows: maxRows, ctx: ctx);
  }

  @override
  Future<void> closePortal(
    PgPortal portal, {
    Context? ctx,
  }) {
    return _connection.closePortal(portal, ctx: ctx);
  }

  @override
  Future<T> transaction<T>(
    Future<T> Function(PgTransaction tx) block, {
    PgIsolationLevel? isolationLevel,
    bool readOnly = false,
    bool deferrable = false,
    Context? ctx,
  }) {
    return PgTransaction.run(
      this,
      block,
      isolationLevel: isolationLevel,
      readOnly: readOnly,
      deferrable: deferrable,
      ctx: ctx,
    );
  }

  @override
  Future<List<PgRows>> pipeline(
    void Function(PgPipeline p) buildPipeline, {
    Context? ctx,
  }) {
    return _connection.pipeline(buildPipeline, ctx: ctx);
  }

  @override
  Future<PgCopyInSink> copyIn(
    String sql, {
    Context? ctx,
  }) {
    return _connection.copyIn(sql, ctx: ctx);
  }

  @override
  Future<PgCopyOutStream> copyOut(
    String sql, {
    Context? ctx,
  }) {
    return _connection.copyOut(sql, ctx: ctx);
  }

  /// Closes the connection and releases resources.
  Future<void> close() {
    _statementCache.clear();
    return _connection.close();
  }
}
