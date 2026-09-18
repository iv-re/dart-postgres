import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:ctx/ctx.dart';
import 'package:pg/src/client/cancel_token.dart';
import 'package:pg/src/client/config.dart';
import 'package:pg/src/client/copy.dart';
import 'package:pg/src/client/copy_out.dart';
import 'package:pg/src/client/endpoint.dart';
import 'package:pg/src/client/exception.dart';
import 'package:pg/src/client/notification.dart';
import 'package:pg/src/client/operation.dart';
import 'package:pg/src/client/pipeline.dart';
import 'package:pg/src/client/portal.dart';
import 'package:pg/src/client/rows.dart';
import 'package:pg/src/client/session.dart';
import 'package:pg/src/client/statement.dart';
import 'package:pg/src/client/tracer.dart';
import 'package:pg/src/client/transaction.dart';
import 'package:pg/src/protocol/backend.dart';
import 'package:pg/src/protocol/frontend.dart';
import 'package:pg/src/protocol/reader.dart';
import 'package:pg/src/protocol/writer.dart';
import 'package:pg/src/types/types.dart';

/// A physical TCP connection to PostgreSQL managing wire protocol lifecycle.
class PgConnection implements PgSession {
  PgConnection._(this._socket, this.config, this.resolvedEndpoint) {
    _subscription = _socket.listen(
      _onData,
      onError: _onError,
      onDone: _onDone,
    );
  }

  final Socket _socket;
  final PgConfig config;
  final PgEndpoint resolvedEndpoint;
  final PgTypeRegistry _typeRegistry = PgTypeRegistry.defaults;

  final MessageWriter _writer = MessageWriter();
  final ReadBuffer _readBuffer = ReadBuffer();
  final ListQueue<PgOperation> _queue = ListQueue<PgOperation>();
  final StreamController<PgNotification> _notificationsController =
      StreamController<PgNotification>.broadcast();

  late final StreamSubscription<Uint8List> _subscription;

  int _statementId = 0;
  int _portalId = 0;
  bool _isClosed = false;
  int? _processId;
  int? _secretKey;
  PgTransactionStatus _transactionStatus = .idle;

  /// Whether the connection is closed.
  bool get isClosed => _isClosed;

  /// Returns the current backend transaction status.
  PgTransactionStatus get transactionStatus => _transactionStatus;

  /// Gets the cancellation token for cancelling queries running on this
  /// connection.
  PgCancelToken get cancelToken {
    final pid = _processId;
    final key = _secretKey;
    if (pid == null || key == null) {
      throw StateError('Connection handshake not completed yet.');
    }
    return PgCancelToken(
      processId: pid,
      secretKey: key,
      config: config,
      resolvedEndpoint: resolvedEndpoint,
    );
  }

  /// Stream of async server notification responses (LISTEN / NOTIFY).
  Stream<PgNotification> get notifications => _notificationsController.stream;

  /// Opens a connection to PostgreSQL (TCP or Unix domain socket) with failover
  /// across endpoints according to [PgConfig.endpoints] and
  /// [PgConfig.targetSessionAttrs].
  static Future<PgConnection> open(PgConfig config) async {
    Object? lastError;
    StackTrace? lastStackTrace;

    var endpoints = config.endpoints;
    if (config.loadBalanceHosts == .random && endpoints.length > 1) {
      endpoints = List<PgEndpoint>.of(endpoints)..shuffle();
    }

    for (final endpoint in endpoints) {
      try {
        final conn = await _openEndpoint(config, endpoint);
        if (await conn._matchesTargetAttrs(config.targetSessionAttrs)) {
          return conn;
        }
        await conn.close();
      } catch (error, stackTrace) {
        lastError = error;
        lastStackTrace = stackTrace;
      }
    }

    if (lastError != null) {
      Error.throwWithStackTrace(
        lastError,
        lastStackTrace ?? StackTrace.current,
      );
    }
    throw SocketException(
      'Failed to connect to any PostgreSQL endpoint: ${config.endpoints}',
    );
  }

  Future<bool> _matchesTargetAttrs(PgTargetSessionAttrs attrs) async {
    if (attrs == .any) return true;
    final isReadOnly = await _checkIsReadOnly();
    return attrs ==
        (isReadOnly
            ? PgTargetSessionAttrs.readOnly
            : PgTargetSessionAttrs.readWrite);
  }

  Future<bool> _checkIsReadOnly() async {
    try {
      final rows = await simpleQuery('SHOW transaction_read_only;');
      if (rows.isNotEmpty && rows.first.length > 0) {
        final val = rows.first.string(0).toLowerCase();
        return val == 'on' || val == 'true' || val == '1';
      }
    } catch (_) {}
    return false;
  }

  static Future<PgConnection> _openEndpoint(
    PgConfig config,
    PgEndpoint endpoint,
  ) async {
    final sw = config.tracer != null ? (Stopwatch()..start()) : null;

    try {
      final Socket socket;

      if (endpoint.isUnixSocket) {
        socket = await Socket.connect(
          InternetAddress(endpoint.unixSocketPath, type: .unix),
          0,
        );
      } else {
        socket = await Socket.connect(
          endpoint.host,
          endpoint.port,
        );
        socket.setOption(.tcpNoDelay, true);
      }

      var effectiveSocket = socket;

      if (!endpoint.isUnixSocket) {
        if (config.sslConfig case PgSslConfig(
          mode: final mode && != .disable,
          :final securityContext,
          :final onBadCertificate,
        )) {
          final writer = MessageWriter();
          const SslRequestMessage().encode(writer);
          socket.add(writer.takeBytes());

          if (await socket.first case [83, ...]) {
            effectiveSocket = await SecureSocket.secure(
              socket,
              host: mode == .verifyFull ? endpoint.host : null,
              context: securityContext,
              onBadCertificate:
                  onBadCertificate ??
                  (_) => mode != .verifyCa && mode != .verifyFull,
            );
          } else if (mode == .prefer) {
            await socket.close();
            final plainSocket = await Socket.connect(
              endpoint.host,
              endpoint.port,
            );
            plainSocket.setOption(.tcpNoDelay, true);
            effectiveSocket = plainSocket;
          } else {
            throw const SocketException('SSL requested but server rejected it');
          }
        }
      }

      final connection = PgConnection._(effectiveSocket, config, endpoint);

      try {
        await connection._handshake();
        if (config.tracer case final tracer? when sw != null) {
          try {
            tracer.onConnect(endpoint, sw.elapsed);
          } catch (_) {}
        }
        return connection;
      } catch (error, stackTrace) {
        await connection.close();
        Error.throwWithStackTrace(error, stackTrace);
      }
    } catch (error, stackTrace) {
      if (config.tracer case final tracer? when sw != null) {
        try {
          tracer.onConnect(endpoint, sw.elapsed, error: error);
        } catch (_) {}
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  @pragma('vm:prefer-inline')
  void _ensureOpen() {
    if (_isClosed) {
      throw StateError('Cannot execute operation: PgConnection is closed.');
    }
  }

  Completer<T> _cancellableCompleter<T>(Context? ctx) {
    final effectiveCtx = ctx ?? Context.current;
    if (effectiveCtx.error case final error?) {
      throw error;
    }

    final completer = Completer<T>();
    if (!identical(effectiveCtx, const Context.empty())) {
      unawaited(
        effectiveCtx.done.then((_) {
          if (!completer.isCompleted) {
            completer.completeError(
              effectiveCtx.error ?? const ContextCancelException(),
            );
            unawaited(cancelToken.cancel());
          }
        }),
      );
    }
    return completer;
  }

  StreamController<T> _cancellableController<T>(Context? ctx) {
    final effectiveCtx = ctx ?? Context.current;
    if (effectiveCtx.error case final error?) {
      throw error;
    }

    final controller = StreamController<T>(sync: true);
    if (!identical(effectiveCtx, const Context.empty())) {
      unawaited(
        effectiveCtx.done.then((_) {
          if (!controller.isClosed) {
            unawaited(cancelToken.cancel());
            controller.addError(
              effectiveCtx.error ?? const ContextCancelException(),
            );
            controller.close();
          }
        }),
      );
    }
    return controller;
  }

  void _trace<T>(
    Future<T> future,
    String sql,
    List<Object?> params,
    Context? ctx,
  ) {
    if (config.tracer case final tracer?) {
      final sw = Stopwatch()..start();
      unawaited(
        future.then(
          (value) {
            try {
              tracer.onQuery(
                PgQueryTrace(
                  sql: sql,
                  params: params,
                  duration: sw.elapsed,
                  commandTag: switch (value) {
                    PgRows(:final commandTag) => commandTag,
                    final String tag => tag,
                    _ => null,
                  },
                  ctx: ctx,
                ),
              );
            } catch (_) {}
          },
          onError: (Object e) {
            try {
              tracer.onQuery(
                PgQueryTrace(
                  sql: sql,
                  params: params,
                  duration: sw.elapsed,
                  error: e,
                  ctx: ctx,
                ),
              );
            } catch (_) {}
          },
        ),
      );
    }
  }

  @override
  Future<PgRows> simpleQuery(
    String sql, {
    Context? ctx,
  }) {
    _ensureOpen();
    final completer = _cancellableCompleter<PgRows>(ctx);
    _queue.add(RowsOperation(completer: completer));
    _send(QueryMessage(sql));
    _trace(completer.future, sql, const [], ctx);
    return completer.future;
  }

  @override
  Future<PgRows> query(
    String sql,
    List<Object?> params, {
    PgQueryMode? mode,
    Context? ctx,
  }) {
    _ensureOpen();
    if (mode == .simple || (mode == null && params.isEmpty)) {
      return simpleQuery(sql, ctx: ctx);
    }

    final completer = _cancellableCompleter<PgRows>(ctx);
    _queue.add(RowsOperation(completer: completer));
    _sendAll([
      ParseMessage(query: sql),
      // TODO: Introduce PgTyped to support mixed parameterFormatCodes
      // (binary for explicitly typed parameters, text for unspecified).
      BindMessage(
        parameters: _typeRegistry.encodeParameters(params, isBinary: false),
        parameterFormatCodes: const [0],
      ),
      const DescribeMessage.portal(),
      const ExecuteMessage(),
      const SyncMessage(),
    ]);
    _trace(completer.future, sql, params, ctx);
    return completer.future;
  }

  @override
  Future<PgRowStream> queryStream(
    String sql,
    List<Object?> params, {
    PgQueryMode? mode,
    Context? ctx,
  }) async {
    _ensureOpen();
    final controller = _cancellableController<PgRow>(ctx);
    final fieldsCompleter = _cancellableCompleter<List<FieldDescription>>(ctx);
    final commandTagCompleter = Completer<String>();

    final op = StreamRowsOperation(
      controller: controller,
      fieldsCompleter: fieldsCompleter,
      commandTagCompleter: commandTagCompleter,
    );
    _queue.add(op);

    if (mode == .simple || (mode == null && params.isEmpty)) {
      _send(QueryMessage(sql));
    } else {
      _sendAll([
        ParseMessage(query: sql),
        // TODO: Introduce PgTyped to support mixed parameterFormatCodes
        // (binary for explicitly typed parameters, text for unspecified).
        BindMessage(
          parameters: _typeRegistry.encodeParameters(params, isBinary: false),
          parameterFormatCodes: const [0],
        ),
        const DescribeMessage.portal(),
        const ExecuteMessage(),
        const SyncMessage(),
      ]);
    }

    _trace(commandTagCompleter.future, sql, params, ctx);

    final fields = await fieldsCompleter.future;
    return PgRowStream(
      controller.stream,
      fields: fields,
      commandTag: commandTagCompleter.future,
    );
  }

  @override
  Future<PgStatement> prepare(
    String sql, {
    String? name,
    Context? ctx,
  }) {
    _ensureOpen();
    final stmtName = name ?? '_pg_s${++_statementId}';
    final completer = _cancellableCompleter<PgStatement>(ctx);

    _queue.add(
      PrepareOperation(
        name: stmtName,
        sql: sql,
        completer: completer,
      ),
    );

    _sendAll([
      ParseMessage(name: stmtName, query: sql),
      DescribeMessage.statement(stmtName),
      const SyncMessage(),
    ]);

    return completer.future;
  }

  @override
  Future<PgRows> execute(
    PgStatement statement,
    List<Object?> params, {
    Context? ctx,
  }) {
    _ensureOpen();
    final completer = _cancellableCompleter<PgRows>(ctx);
    _queue.add(
      RowsOperation(
        completer: completer,
        fields: statement.fields,
      ),
    );

    _sendAll([
      BindMessage(
        statement: statement.name,
        parameters: _typeRegistry.encodeParameters(
          params,
          paramOids: statement.paramOids,
        ),
        parameterFormatCodes: const [1],
      ),
      const ExecuteMessage(),
      const SyncMessage(),
    ]);

    _trace(completer.future, statement.sql, params, ctx);
    return completer.future;
  }

  @override
  Future<PgRowStream> executeStream(
    PgStatement statement,
    List<Object?> params, {
    Context? ctx,
  }) async {
    _ensureOpen();
    final controller = _cancellableController<PgRow>(ctx);
    final fieldsCompleter = _cancellableCompleter<List<FieldDescription>>(ctx);
    final commandTagCompleter = Completer<String>();

    final op = StreamRowsOperation(
      controller: controller,
      fieldsCompleter: fieldsCompleter,
      commandTagCompleter: commandTagCompleter,
      fields: statement.fields,
    );
    _queue.add(op);

    _sendAll([
      BindMessage(
        statement: statement.name,
        parameters: _typeRegistry.encodeParameters(
          params,
          paramOids: statement.paramOids,
        ),
        parameterFormatCodes: const [1],
      ),
      const ExecuteMessage(),
      const SyncMessage(),
    ]);

    _trace(commandTagCompleter.future, statement.sql, params, ctx);

    final fields = await fieldsCompleter.future;
    return PgRowStream(
      controller.stream,
      fields: fields,
      commandTag: commandTagCompleter.future,
    );
  }

  @override
  Future<PgPortal> bind(
    PgStatement statement,
    List<Object?> params, {
    String? name,
    Context? ctx,
  }) {
    _ensureOpen();
    final portalName = name ?? '_pg_p${++_portalId}';
    final completer = _cancellableCompleter<PgPortal>(ctx);

    _queue.add(
      BindOperation(
        name: portalName,
        statement: statement,
        completer: completer,
      ),
    );

    _sendAll([
      BindMessage(
        portal: portalName,
        statement: statement.name,
        parameters: _typeRegistry.encodeParameters(
          params,
          paramOids: statement.paramOids,
        ),
        parameterFormatCodes: const [1],
      ),
      const SyncMessage(),
    ]);

    return completer.future;
  }

  @override
  Future<PgRows> queryPortal(
    PgPortal portal, {
    int maxRows = 0,
    Context? ctx,
  }) {
    _ensureOpen();
    final completer = _cancellableCompleter<PgRows>(ctx);
    _queue.add(
      RowsOperation(
        completer: completer,
        fields: portal.fields,
      ),
    );

    _sendAll([
      ExecuteMessage(portal: portal.name, maxRows: maxRows),
      const SyncMessage(),
    ]);

    _trace(completer.future, portal.name, const [], ctx);
    return completer.future;
  }

  @override
  Future<PgRowStream> queryPortalStream(
    PgPortal portal, {
    int maxRows = 0,
    Context? ctx,
  }) async {
    _ensureOpen();
    final controller = _cancellableController<PgRow>(ctx);
    final fieldsCompleter = _cancellableCompleter<List<FieldDescription>>(ctx);
    final commandTagCompleter = Completer<String>();
    final hasMoreCompleter = Completer<bool>();

    final op = StreamRowsOperation(
      controller: controller,
      fieldsCompleter: fieldsCompleter,
      commandTagCompleter: commandTagCompleter,
      hasMoreCompleter: hasMoreCompleter,
      fields: portal.fields,
    );
    _queue.add(op);

    _sendAll([
      ExecuteMessage(portal: portal.name, maxRows: maxRows),
      const SyncMessage(),
    ]);

    _trace(commandTagCompleter.future, portal.name, const [], ctx);

    final fields = await fieldsCompleter.future;
    return PgRowStream(
      controller.stream,
      fields: fields,
      commandTag: commandTagCompleter.future,
      hasMore: hasMoreCompleter.future,
    );
  }

  @override
  Future<void> closePortal(
    PgPortal portal, {
    Context? ctx,
  }) {
    _ensureOpen();
    final completer = _cancellableCompleter<void>(ctx);
    _queue.add(CloseStatementOperation(completer));

    _sendAll([
      CloseMessage.portal(portal.name),
      const SyncMessage(),
    ]);

    return completer.future;
  }

  /// Closes and deallocates a prepared statement on the server.
  Future<void> closeStatement(
    PgStatement statement, {
    Context? ctx,
  }) {
    _ensureOpen();
    final completer = _cancellableCompleter<void>(ctx);
    _queue.add(CloseStatementOperation(completer));

    _sendAll([
      CloseMessage.statement(statement.name),
      const SyncMessage(),
    ]);

    return completer.future;
  }

  /// Executes a managed transaction block on this connection.
  @override
  Future<T> transaction<T>(
    Future<T> Function(PgTransaction tx) block, {
    PgIsolationLevel? isolationLevel,
    bool readOnly = false,
    bool deferrable = false,
    Context? ctx,
  }) {
    _ensureOpen();
    return PgTransaction.run(
      this,
      block,
      isolationLevel: isolationLevel,
      readOnly: readOnly,
      deferrable: deferrable,
      ctx: ctx,
    );
  }

  /// Executes a pipelined batch of queries in a single TCP socket payload.
  Future<void> _executePipeline(PgPipeline pipeline, {Context? ctx}) {
    if (pipeline.items.isEmpty) return Future.value();

    final completer = _cancellableCompleter<void>(ctx);
    _queue.add(
      PipelineOperation(
        items: pipeline.items,
        completer: completer,
      ),
    );

    final messages = <FrontendMessage>[];
    for (final item in pipeline.items) {
      messages.add(ParseMessage(query: item.sql));
      messages.add(
        BindMessage(
          parameters: _typeRegistry.encodeParameters(item.params),
          parameterFormatCodes: const [1],
        ),
      );
      messages.add(const DescribeMessage.portal());
      messages.add(const ExecuteMessage());
    }
    messages.add(const SyncMessage());

    _sendAll(messages);
    return completer.future;
  }

  @override
  Future<List<PgRows>> pipeline(
    void Function(PgPipeline p) buildPipeline, {
    Context? ctx,
  }) async {
    _ensureOpen();
    final p = PgPipeline();
    buildPipeline(p);

    if (p.items.isEmpty) return const [];

    final futures = p.items.map((item) => item.completer.future).toList();
    for (final f in futures) {
      f.ignore();
    }

    await _executePipeline(p, ctx: ctx);
    return Future.wait(futures);
  }

  @override
  Future<PgCopyInSink> copyIn(
    String sql, {
    Context? ctx,
  }) {
    _ensureOpen();
    final completer = _cancellableCompleter<PgCopyInSink>(ctx);
    _queue.add(
      CopyInOperation(
        completer: completer,
        send: _send,
      ),
    );
    _send(QueryMessage(sql));
    return completer.future;
  }

  @override
  Future<PgCopyOutStream> copyOut(String sql, {Context? ctx}) async {
    _ensureOpen();
    late final StreamController<Uint8List> controller;
    final responseCompleter = _cancellableCompleter<CopyOutResponseMessage>(
      ctx,
    );
    final commandTagCompleter = Completer<String>();

    controller = StreamController<Uint8List>(
      sync: true,
      onCancel: () {
        _onError(
          const PgException(
            message: 'COPY OUT stream was cancelled locally.',
            code: 'XX000',
          ),
          StackTrace.current,
        );
      },
    );

    final op = CopyOutOperation(
      controller: controller,
      responseCompleter: responseCompleter,
      commandTagCompleter: commandTagCompleter,
    );
    _queue.add(op);

    _send(QueryMessage(sql));

    final response = await responseCompleter.future;
    return PgCopyOutStream(
      controller.stream,
      response: response,
      commandTag: commandTagCompleter.future,
    );
  }

  @pragma('vm:prefer-inline')
  void _send(FrontendMessage message) {
    message.encode(_writer);
    _socket.add(_writer.takeBytes());
  }

  @pragma('vm:prefer-inline')
  void _sendAll(List<FrontendMessage> messages) {
    for (final message in messages) {
      message.encode(_writer);
    }
    _socket.add(_writer.takeBytes());
  }

  Future<void> _handshake() async {
    final completer = Completer<BackendKeyData>();
    final serverCertDer = switch (_socket) {
      final SecureSocket secure => secure.peerCertificate?.der,
      _ => null,
    };

    _queue.add(
      HandshakeOperation(
        config: config,
        send: _send,
        completer: completer,
        serverCertificateDer: serverCertDer,
      ),
    );
    _send(StartupMessage(user: config.user, database: config.database));
    final keyData = await completer.future;
    _processId = keyData.processId;
    _secretKey = keyData.secretKey;
  }

  void _onData(Uint8List chunk) {
    _readBuffer.add(chunk);

    while (true) {
      final reader = _readBuffer.nextMessage();
      if (reader == null) break;

      final message = BackendMessage.decode(reader.tag, reader);

      if (message is NotificationResponseMessage) {
        _notificationsController.add(
          PgNotification(
            processId: message.processId,
            channel: message.channel,
            payload: message.payload,
          ),
        );
        continue;
      }

      if (message is NoticeResponseMessage) {
        if (config.tracer case final tracer?) {
          try {
            tracer.onNotice(
              PgNotice(
                severity: message.severity,
                code: message.code,
                message: message.message,
              ),
            );
          } catch (_) {}
        }
        continue;
      }

      if (message is ReadyForQueryMessage) {
        _transactionStatus = .fromCode(message.transactionStatus);
      }

      if (_queue.isNotEmpty) {
        final current = _queue.first;
        final isDone = current.onMessage(message);
        if (isDone) {
          _queue.removeFirst();
        }
      }
    }
  }

  void _onError(Object error, StackTrace stackTrace) {
    while (_queue.isNotEmpty) {
      _queue.removeFirst().onError(error, stackTrace);
    }
    close();
  }

  void _onDone() {
    while (_queue.isNotEmpty) {
      _queue.removeFirst().onError(
        const SocketException('Connection closed by server'),
        StackTrace.current,
      );
    }
    close();
  }

  /// Closes the connection gracefully by sending TerminateMessage.
  Future<void> close() async {
    if (_isClosed) return;
    _isClosed = true;

    try {
      _send(const TerminateMessage());
      await _socket.flush();
    } catch (_) {}

    await _subscription.cancel();
    await _notificationsController.close();
    await _socket.close();
    _socket.destroy();
  }
}
