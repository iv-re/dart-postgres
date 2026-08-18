import 'dart:async';

import 'package:ctx/ctx.dart';
import 'package:pg/src/client/config.dart';
import 'package:pg/src/client/connection.dart';
import 'package:pg/src/client/copy.dart';
import 'package:pg/src/client/copy_out.dart';
import 'package:pg/src/client/pipeline.dart';
import 'package:pg/src/client/portal.dart';
import 'package:pg/src/client/rows.dart';
import 'package:pg/src/client/session.dart';
import 'package:pg/src/client/statement.dart';
import 'package:pg/src/client/utils.dart';

/// PostgreSQL transaction isolation levels.
enum PgIsolationLevel {
  readCommitted('READ COMMITTED'),
  repeatableRead('REPEATABLE READ'),
  serializable('SERIALIZABLE');

  const PgIsolationLevel(this.sql);

  /// The SQL clause name for the isolation level.
  final String sql;
}

/// Transaction status reported by the PostgreSQL backend.
enum PgTransactionStatus {
  /// 'I' (0x49): Not in a transaction block.
  idle,

  /// 'T' (0x54): In an active transaction block.
  inTransaction,

  /// 'E' (0x45): In a failed transaction block (all queries rejected until
  /// rollback).
  failed;

  /// Decodes a 1-byte backend status indicator ('I', 'T', 'E').
  static PgTransactionStatus fromCode(int code) {
    return switch (code) {
      0x54 => inTransaction, // 'T'
      0x45 => failed, // 'E'
      _ => idle, // 'I'
    };
  }
}

/// A PostgreSQL transaction with savepoint-based nesting.
///
/// Created via [PgSession.transaction] or manually via [begin]. Supports
/// nested transactions through auto-incrementing savepoints (`sp_1`,
/// `sp_2`, …). All query methods throw [StateError] after [commit] or
/// [rollback].
class PgTransaction implements PgSession {
  PgTransaction(
    this._session, {
    this.isNested = false,
    this.savepointName,
  });

  final PgSession _session;

  /// Whether this transaction is a nested transaction (savepoint).
  final bool isNested;

  /// The name of the savepoint if this is a nested transaction.
  final String? savepointName;

  bool _isCompleted = false;
  bool _started = false;
  int _savepointCounter = 0;

  /// Whether the transaction has committed or rolled back.
  bool get isCompleted => _isCompleted;

  /// Returns the current transaction status from the underlying session.
  PgTransactionStatus get status {
    if (_session case final PgConnection conn) {
      return conn.transactionStatus;
    }
    return _isCompleted ? .idle : .inTransaction;
  }

  /// Begins the transaction (or creates a nested savepoint if already active).
  ///
  /// First call issues `BEGIN` with the given [isolationLevel], [readOnly],
  /// and [deferrable] options. Subsequent calls create a savepoint instead.
  Future<PgTransaction> begin({
    PgIsolationLevel? isolationLevel,
    bool readOnly = false,
    bool deferrable = false,
    Context? ctx,
  }) async {
    if (isNested || _started) {
      final num = ++_savepointCounter;
      final spName = 'sp_$num';
      await savepoint(spName, ctx: ctx);
      return PgTransaction(_session, isNested: true, savepointName: spName)
        .._started = true;
    }
    _started = true;
    final parts = ['BEGIN'];
    if (isolationLevel case final level?) {
      parts.add('ISOLATION LEVEL ${level.sql}');
    }
    if (readOnly) {
      parts.add('READ ONLY');
    }
    if (deferrable) {
      parts.add('DEFERRABLE');
    }
    await _session.simpleQuery('${parts.join(' ')};', ctx: ctx);
    return this;
  }

  /// Commits the transaction (or releases the savepoint if nested).
  ///
  /// Throws [StateError] if already completed.
  Future<void> commit({Context? ctx}) async {
    _checkActive();
    if (isNested && savepointName != null) {
      await releaseSavepoint(savepointName!, ctx: ctx);
    } else {
      await _session.simpleQuery('COMMIT;', ctx: ctx);
    }
    _isCompleted = true;
  }

  /// Rolls back the transaction (or to the savepoint if nested).
  ///
  /// No-op if already completed — safe to call in `finally` blocks.
  Future<void> rollback({Context? ctx}) async {
    if (_isCompleted) return;
    if (isNested && savepointName != null) {
      await rollbackToSavepoint(savepointName!, ctx: ctx);
    } else {
      await _session.simpleQuery('ROLLBACK;', ctx: ctx);
    }
    _isCompleted = true;
  }

  /// Executes a nested transaction block using a savepoint.
  @override
  Future<T> transaction<T>(
    Future<T> Function(PgTransaction tx) block, {
    PgIsolationLevel? isolationLevel,
    bool readOnly = false,
    bool deferrable = false,
    Context? ctx,
  }) async {
    final nested = await begin(
      isolationLevel: isolationLevel,
      readOnly: readOnly,
      deferrable: deferrable,
      ctx: ctx,
    );
    try {
      final result = await block(nested);
      await nested.commit(ctx: ctx);
      return result;
    } catch (e) {
      await nested.rollback(ctx: ctx);
      rethrow;
    }
  }

  /// Creates a transaction savepoint with sanitized identifier.
  Future<void> savepoint(String name, {Context? ctx}) async {
    _checkActive();
    await _session.simpleQuery(
      'SAVEPOINT ${escapeIdentifier(name)};',
      ctx: ctx,
    );
  }

  /// Releases a transaction savepoint with sanitized identifier.
  Future<void> releaseSavepoint(String name, {Context? ctx}) async {
    _checkActive();
    await _session.simpleQuery(
      'RELEASE SAVEPOINT ${escapeIdentifier(name)};',
      ctx: ctx,
    );
  }

  /// Rolls back to a transaction savepoint with sanitized identifier.
  Future<void> rollbackToSavepoint(String name, {Context? ctx}) async {
    _checkActive();
    await _session.simpleQuery(
      'ROLLBACK TO SAVEPOINT ${escapeIdentifier(name)};',
      ctx: ctx,
    );
  }

  @override
  Future<PgRows> simpleQuery(
    String sql, {
    Context? ctx,
  }) {
    _checkActive();
    return _session.simpleQuery(sql, ctx: ctx);
  }

  @override
  Future<PgRows> query(
    String sql,
    List<Object?> params, {
    PgQueryMode? mode,
    Context? ctx,
  }) {
    _checkActive();
    return _session.query(sql, params, mode: mode, ctx: ctx);
  }

  @override
  Future<PgRowStream> queryStream(
    String sql,
    List<Object?> params, {
    PgQueryMode? mode,
    Context? ctx,
  }) {
    _checkActive();
    return _session.queryStream(sql, params, mode: mode, ctx: ctx);
  }

  @override
  FutureOr<PgStatement> prepare(
    String sql, {
    String? name,
    Context? ctx,
  }) {
    _checkActive();
    return _session.prepare(sql, name: name, ctx: ctx);
  }

  @override
  Future<PgRows> execute(
    PgStatement statement,
    List<Object?> params, {
    Context? ctx,
  }) {
    _checkActive();
    return _session.execute(statement, params, ctx: ctx);
  }

  @override
  Future<PgRowStream> executeStream(
    PgStatement statement,
    List<Object?> params, {
    Context? ctx,
  }) {
    _checkActive();
    return _session.executeStream(statement, params, ctx: ctx);
  }

  @override
  Future<PgPortal> bind(
    PgStatement statement,
    List<Object?> params, {
    String? name,
    Context? ctx,
  }) {
    _checkActive();
    return _session.bind(statement, params, name: name, ctx: ctx);
  }

  @override
  Future<PgRows> queryPortal(
    PgPortal portal, {
    int maxRows = 0,
    Context? ctx,
  }) {
    _checkActive();
    return _session.queryPortal(portal, maxRows: maxRows, ctx: ctx);
  }

  @override
  Future<PgRowStream> queryPortalStream(
    PgPortal portal, {
    int maxRows = 0,
    Context? ctx,
  }) {
    _checkActive();
    return _session.queryPortalStream(portal, maxRows: maxRows, ctx: ctx);
  }

  @override
  Future<void> closePortal(
    PgPortal portal, {
    Context? ctx,
  }) {
    _checkActive();
    return _session.closePortal(portal, ctx: ctx);
  }

  @override
  Future<List<PgRows>> pipeline(
    void Function(PgPipeline p) buildPipeline, {
    Context? ctx,
  }) {
    _checkActive();
    return _session.pipeline(buildPipeline, ctx: ctx);
  }

  @override
  Future<PgCopyInSink> copyIn(
    String sql, {
    Context? ctx,
  }) {
    _checkActive();
    return _session.copyIn(sql, ctx: ctx);
  }

  @override
  Future<PgCopyOutStream> copyOut(
    String sql, {
    Context? ctx,
  }) {
    _checkActive();
    return _session.copyOut(sql, ctx: ctx);
  }

  void _checkActive() {
    if (_isCompleted) {
      throw StateError('Transaction is already completed');
    }
  }
}
