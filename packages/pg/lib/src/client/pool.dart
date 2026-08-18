import 'dart:async';
import 'dart:collection';

import 'package:ctx/ctx.dart';
import 'package:pg/src/client/client.dart';
import 'package:pg/src/client/config.dart';
import 'package:pg/src/client/copy.dart';
import 'package:pg/src/client/copy_out.dart';
import 'package:pg/src/client/executor.dart';
import 'package:pg/src/client/pipeline.dart';
import 'package:pg/src/client/rows.dart';
import 'package:pg/src/client/transaction.dart';

final class _PooledConnection {
  _PooledConnection(this.client)
    : createdAt = DateTime.timestamp(),
      lastUsedAt = DateTime.timestamp();

  final PgClient client;
  final DateTime createdAt;
  DateTime lastUsedAt;
}

final class _PoolSlots {
  _PoolSlots(this.maxSlots);

  final int maxSlots;
  int _allocatedSlots = 0;
  final Queue<Completer<void>> _waiters = Queue();
  bool _isClosed = false;

  int get waiterCount => _waiters.length;

  Future<void> acquire({Context? ctx}) {
    if (_isClosed) {
      throw StateError('PgPool is closed.');
    }

    final effectiveCtx = ctx ?? Context.current;
    if (effectiveCtx.error case final error?) {
      throw error;
    }

    if (_allocatedSlots < maxSlots) {
      _allocatedSlots++;
      return Future.value();
    }

    final completer = Completer<void>();
    if (!identical(effectiveCtx, const Context.empty())) {
      unawaited(
        effectiveCtx.done.then((_) {
          if (!completer.isCompleted) {
            _waiters.remove(completer);
            completer.completeError(
              effectiveCtx.error ?? const ContextCancelException(),
            );
          }
        }),
      );
    }

    _waiters.add(completer);
    return completer.future;
  }

  void release() {
    if (_isClosed) return;

    while (_waiters.isNotEmpty) {
      final waiter = _waiters.removeFirst();
      if (!waiter.isCompleted) {
        waiter.complete();
        return;
      }
    }

    if (_allocatedSlots > 0) {
      _allocatedSlots--;
    }
  }

  void close() {
    _isClosed = true;
    for (final w in _waiters) {
      if (!w.isCompleted) {
        w.completeError(StateError('PgPool was closed'));
      }
    }
    _waiters.clear();
  }
}

/// A connection pool managing multiple reusable [PgClient] connections.
///
/// Connections are opened lazily up to [maxConnections]. Idle connections
/// exceeding [idleTimeout] are reaped automatically, respecting
/// [minConnections]. All [PgExecutor] methods borrow a connection for the
/// duration of the call and return it to the pool afterwards.
///
/// Call [close] to drain all connections and reject pending waiters.
class PgPool implements PgExecutor {
  PgPool(
    this.config, {
    this.minConnections = 2,
    this.maxConnections = 10,
    this.idleTimeout = const Duration(minutes: 5),
    this.maxLifetime,
    this.healthCheckPeriod,
    this.beforeAcquire,
    this.afterRelease,
  }) : _slots = _PoolSlots(maxConnections) {
    if (minConnections < 0) {
      throw ArgumentError.value(
        minConnections,
        'minConnections',
        'Must be non-negative',
      );
    }
    if (maxConnections <= 0 || maxConnections < minConnections) {
      throw ArgumentError.value(
        maxConnections,
        'maxConnections',
        'Must be positive and greater than or equal to minConnections',
      );
    }
    _startReaper();
  }

  /// The connection configuration.
  final PgConfig config;

  /// The minimum total number of connections to maintain in the pool.
  final int minConnections;

  /// The maximum number of simultaneous connections allowed in the pool.
  final int maxConnections;

  /// The duration after which idle connections may be closed.
  final Duration idleTimeout;

  /// The maximum duration a connection may live before being retired.
  final Duration? maxLifetime;

  /// The duration after which an idle connection triggers a health check / ping,
  /// and the interval for background idle/lifetime maintenance.
  final Duration? healthCheckPeriod;

  /// Optional callback invoked before loaning a connection to the caller.
  /// If it returns `false` or throws, the connection is closed and discarded.
  final FutureOr<bool> Function(PgClient client)? beforeAcquire;

  /// Optional callback invoked when a connection is returned to the pool
  /// (e.g. to perform `DISCARD ALL` or `RESET ALL`).
  /// If it returns `false` or throws, the connection is closed and discarded.
  final FutureOr<bool> Function(PgClient client)? afterRelease;

  final _PoolSlots _slots;
  final List<_PooledConnection> _available = [];
  final Map<PgClient, _PooledConnection> _inUse = {};

  Timer? _reaperTimer;
  int _pendingConnects = 0;
  bool _isClosed = false;

  /// Returns the number of idle connections currently available in the pool.
  int get idleConnections => _available.length;

  /// Returns the number of connections currently borrowed and in use.
  int get inUseConnections => _inUse.length;

  /// Returns the number of callers waiting for an available connection.
  int get waiterCount => _slots.waiterCount;

  /// Returns the total number of connections (available + in-use + pending).
  int get totalConnections {
    return _available.length + _inUse.length + _pendingConnects;
  }

  /// Whether the pool has been closed.
  bool get isClosed => _isClosed;

  /// Borrows a [PgClient], executes [fn], and returns the client to the pool.
  ///
  /// This is the recommended way to run multi-step operations that need
  /// the same underlying connection (e.g. prepare + execute).
  Future<R> withClient<R>(
    FutureOr<R> Function(PgClient client) fn, {
    Context? ctx,
  }) async {
    final client = await _acquire(ctx: ctx);
    try {
      return await fn(client);
    } finally {
      await _release(client);
    }
  }

  Stream<T> _trackStream<T>(Stream<T> source, void Function() onDone) {
    var released = false;
    void releaseOnce() {
      if (!released) {
        released = true;
        onDone();
      }
    }

    late final StreamController<T> controller;
    controller = StreamController<T>(
      sync: true,
      onCancel: releaseOnce,
    );

    source.listen(
      controller.add,
      onError: (Object e, StackTrace st) {
        controller.addError(e, st);
        controller.close();
        releaseOnce();
      },
      onDone: () {
        controller.close();
        releaseOnce();
      },
      cancelOnError: false,
    );

    return controller.stream;
  }

  Future<PgRowStream> _acquireAndStream(
    Future<PgRowStream> Function(PgClient client) fn, {
    Context? ctx,
  }) async {
    final client = await _acquire(ctx: ctx);
    try {
      final inner = await fn(client);
      final stream = _trackStream(inner, () => unawaited(_release(client)));
      return PgRowStream(
        stream,
        fields: inner.fields,
        commandTag: inner.commandTag,
        hasMore: inner.hasMore,
      );
    } catch (e) {
      unawaited(_release(client));
      rethrow;
    }
  }

  Future<bool> _validateConnection(_PooledConnection conn) async {
    final now = DateTime.timestamp();
    if (maxLifetime case final maxLifetime?) {
      if (now.difference(conn.createdAt) > maxLifetime) {
        return false;
      }
    }

    if (beforeAcquire case final beforeAcquire?) {
      final shouldCheck =
          healthCheckPeriod == null ||
          now.difference(conn.lastUsedAt) > healthCheckPeriod!;
      if (shouldCheck) {
        try {
          final ok = await beforeAcquire(conn.client);
          if (!ok) return false;
        } catch (_) {
          return false;
        }
      }
    } else if (healthCheckPeriod case final healthCheckPeriod?) {
      if (now.difference(conn.lastUsedAt) > healthCheckPeriod) {
        try {
          await conn.client.simpleQuery('');
        } catch (_) {
          return false;
        }
      }
    }

    if (!conn.client.isConnected || conn.client.transactionStatus != .idle) {
      return false;
    }

    return true;
  }

  Future<PgClient> _acquire({Context? ctx}) async {
    if (_isClosed) {
      throw StateError('PgPool is closed.');
    }

    await _slots.acquire(ctx: ctx);

    final effectiveCtx = ctx ?? Context.current;
    if (effectiveCtx.error case final error?) {
      _slots.release();
      throw error;
    }

    try {
      while (_available.isNotEmpty) {
        final conn = _available.removeLast();
        if (await _validateConnection(conn)) {
          _inUse[conn.client] = conn;
          return conn.client;
        }
        unawaited(conn.client.close());
      }

      _pendingConnects++;
      try {
        final client = await PgClient.connect(config);
        if (effectiveCtx.error case final error?) {
          unawaited(client.close());
          throw error;
        }
        final conn = _PooledConnection(client);
        _inUse[client] = conn;
        return client;
      } finally {
        _pendingConnects--;
      }
    } catch (e) {
      _slots.release();
      rethrow;
    }
  }

  Future<void> _release(PgClient client) async {
    final conn = _inUse.remove(client);

    try {
      if (_isClosed ||
          !client.isConnected ||
          client.transactionStatus != .idle) {
        unawaited(client.close());
        return;
      }

      if (afterRelease case final afterRelease?) {
        var ok = false;
        try {
          ok = await afterRelease(client);
        } catch (_) {
          ok = false;
        }
        if (!ok ||
            _isClosed ||
            !client.isConnected ||
            client.transactionStatus != .idle) {
          unawaited(client.close());
          return;
        }
      }

      final pooled = conn ?? _PooledConnection(client);
      pooled.lastUsedAt = DateTime.timestamp();
      _available.add(pooled);
    } finally {
      _slots.release();
    }
  }

  void _startReaper() {
    final interval = healthCheckPeriod ?? const Duration(minutes: 1);
    _reaperTimer = Timer.periodic(interval, (_) => _reap());
  }

  void _reap() {
    if (_isClosed || _available.isEmpty) return;

    final now = DateTime.timestamp();
    final toRemove = <_PooledConnection>[];

    for (var i = _available.length - 1; i >= 0; i--) {
      final conn = _available[i];

      final isExpiredLifetime =
          maxLifetime != null && now.difference(conn.createdAt) > maxLifetime!;

      final isIdleExpired =
          idleTimeout > Duration.zero &&
          now.difference(conn.lastUsedAt) > idleTimeout &&
          (totalConnections - toRemove.length) > minConnections;

      if (!conn.client.isConnected ||
          conn.client.transactionStatus != .idle ||
          isExpiredLifetime ||
          isIdleExpired) {
        toRemove.add(conn);
        _available.removeAt(i);
      }
    }

    for (final conn in toRemove) {
      unawaited(conn.client.close());
    }
  }

  @override
  Future<PgRows> simpleQuery(
    String sql, {
    Context? ctx,
  }) {
    return withClient((c) => c.simpleQuery(sql, ctx: ctx), ctx: ctx);
  }

  @override
  Future<PgRows> query(
    String sql,
    List<Object?> params, {
    PgQueryMode? mode,
    Context? ctx,
  }) {
    return withClient(
      (c) => c.query(sql, params, mode: mode, ctx: ctx),
      ctx: ctx,
    );
  }

  @override
  Future<PgRowStream> queryStream(
    String sql,
    List<Object?> params, {
    PgQueryMode? mode,
    Context? ctx,
  }) {
    return _acquireAndStream(
      (c) => c.queryStream(sql, params, mode: mode, ctx: ctx),
      ctx: ctx,
    );
  }

  @override
  Future<T> transaction<T>(
    Future<T> Function(PgTransaction tx) block, {
    PgIsolationLevel? isolationLevel,
    bool readOnly = false,
    bool deferrable = false,
    Context? ctx,
  }) {
    return withClient(
      (c) => c.transaction(
        block,
        isolationLevel: isolationLevel,
        readOnly: readOnly,
        deferrable: deferrable,
        ctx: ctx,
      ),
      ctx: ctx,
    );
  }

  @override
  Future<List<PgRows>> pipeline(
    void Function(PgPipeline p) buildPipeline, {
    Context? ctx,
  }) {
    return withClient((c) => c.pipeline(buildPipeline, ctx: ctx), ctx: ctx);
  }

  @override
  Future<PgCopyInSink> copyIn(
    String sql, {
    Context? ctx,
  }) async {
    final client = await _acquire(ctx: ctx);
    try {
      final sink = await client.copyIn(sql, ctx: ctx);
      return PgCopyInSink(
        sink.operation,
        onDone: () => unawaited(_release(client)),
      );
    } catch (error, stackTrace) {
      unawaited(_release(client));
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  @override
  Future<PgCopyOutStream> copyOut(
    String sql, {
    Context? ctx,
  }) async {
    final client = await _acquire(ctx: ctx);
    try {
      final inner = await client.copyOut(sql, ctx: ctx);
      final stream = _trackStream(inner, () => unawaited(_release(client)));
      return PgCopyOutStream(
        stream,
        response: inner.response,
        commandTag: inner.commandTag,
      );
    } catch (e) {
      unawaited(_release(client));
      rethrow;
    }
  }

  /// Closes all connections in the pool and rejects pending requests.
  Future<void> close() async {
    _isClosed = true;
    _reaperTimer?.cancel();
    _reaperTimer = null;

    _slots.close();

    final available = _available.toList();
    _available.clear();
    await Future.wait(available.map((c) => c.client.close()));

    final inUse = _inUse.keys.toList();
    _inUse.clear();
    await Future.wait(inUse.map((c) => c.close()));
  }
}
