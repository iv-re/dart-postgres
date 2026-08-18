import 'dart:async';
import 'dart:typed_data';

import 'package:pg/src/client/auth.dart';
import 'package:pg/src/client/config.dart';
import 'package:pg/src/client/copy.dart';
import 'package:pg/src/client/exception.dart';
import 'package:pg/src/client/pipeline.dart';
import 'package:pg/src/client/portal.dart';
import 'package:pg/src/client/rows.dart';
import 'package:pg/src/client/statement.dart';
import 'package:pg/src/protocol/backend.dart';
import 'package:pg/src/protocol/frontend.dart';
import 'package:pg/src/types/types.dart';

/// Base class representing an in-flight operation in the connection queue.
sealed class PgOperation {
  /// Handles an incoming [BackendMessage].
  ///
  /// Returns `true` if this operation is finished and should be popped
  /// from the queue.
  bool onMessage(BackendMessage message);

  /// Called on socket or protocol errors.
  void onError(Object error, StackTrace stackTrace);
}

/// Abstract base class for operations completed via a single [Completer].
abstract class _PgFutureOperation<T> extends PgOperation {
  /// Completer for this operation's result.
  Completer<T> get completer;

  @override
  void onError(Object error, StackTrace stackTrace) {
    if (!completer.isCompleted) {
      completer.completeError(error, stackTrace);
    }
  }
}

/// Backend process ID and secret key data for cancellation.
typedef BackendKeyData = ({int processId, int secretKey});

/// Operation for performing startup authentication handshake.
class HandshakeOperation extends _PgFutureOperation<BackendKeyData> {
  HandshakeOperation({
    required this.config,
    required this.send,
    required this.completer,
    this.serverCertificateDer,
  });

  final PgConfig config;
  final void Function(FrontendMessage) send;
  @override
  final Completer<BackendKeyData> completer;
  final Uint8List? serverCertificateDer;

  ScramAuthenticator? _scram;
  int? _processId;
  int? _secretKey;

  @override
  bool onMessage(BackendMessage message) {
    switch (message) {
      case AuthenticationOk():
        return false;

      case AuthenticationCleartextPassword():
        if (config.password.isEmpty) {
          onError(
            ArgumentError(
              'Password cannot be empty when authentication is required',
            ),
            StackTrace.current,
          );
          return true;
        }
        send(PasswordMessage(config.password));
        return false;

      case AuthenticationMd5Password(:final salt):
        if (config.password.isEmpty) {
          onError(
            ArgumentError(
              'Password cannot be empty when authentication is required',
            ),
            StackTrace.current,
          );
          return true;
        }
        final hash = md5Password(
          username: config.user,
          password: config.password,
          salt: salt,
        );
        send(PasswordMessage(hash));
        return false;

      case AuthenticationSasl(:final mechanisms):
        if (config.password.isEmpty) {
          onError(
            ArgumentError(
              'Password cannot be empty when authentication is required',
            ),
            StackTrace.current,
          );
          return true;
        }

        final channelBinding = config.sslConfig.channelBinding;
        final hasTlsCert = serverCertificateDer != null;
        final supportsPlus = mechanisms.contains('SCRAM-SHA-256-PLUS');
        final supportsPlain = mechanisms.contains('SCRAM-SHA-256');

        final String mechanism;
        final Uint8List? certDerForScram;

        if (channelBinding == .require) {
          if (!hasTlsCert) {
            onError(
              StateError(
                'Channel binding required (SCRAM-SHA-256-PLUS), '
                'but connection is not encrypted with TLS',
              ),
              StackTrace.current,
            );
            return true;
          }
          if (!supportsPlus) {
            onError(
              UnsupportedError(
                'Channel binding required, but server does not support '
                'SCRAM-SHA-256-PLUS (available: $mechanisms)',
              ),
              StackTrace.current,
            );
            return true;
          }
          mechanism = 'SCRAM-SHA-256-PLUS';
          certDerForScram = serverCertificateDer;
        } else if (channelBinding == .prefer && hasTlsCert && supportsPlus) {
          mechanism = 'SCRAM-SHA-256-PLUS';
          certDerForScram = serverCertificateDer;
        } else if (supportsPlain) {
          mechanism = 'SCRAM-SHA-256';
          certDerForScram = null;
        } else {
          onError(
            UnsupportedError(
              'Unsupported SASL mechanisms ($mechanisms). '
              'Supported: SCRAM-SHA-256, SCRAM-SHA-256-PLUS.',
            ),
            StackTrace.current,
          );
          return true;
        }

        _scram = ScramAuthenticator(
          username: config.user,
          password: config.password,
          serverCertificateDer: certDerForScram,
        );
        send(
          SaslInitialResponseMessage(
            mechanism: mechanism,
            data: _scram!.createInitialMessage(),
          ),
        );
        return false;

      case AuthenticationSaslContinue(:final data):
        if (_scram == null) {
          onError(
            StateError(
              'Unexpected AuthenticationSaslContinue without SASL start',
            ),
            StackTrace.current,
          );
          return true;
        }
        try {
          final response = _scram!.processServerFirstMessage(data);
          send(SaslResponseMessage(response));
        } catch (error, stackTrace) {
          onError(error, stackTrace);
          return true;
        }
        return false;

      case AuthenticationSaslFinal(:final data):
        if (_scram == null) {
          onError(
            StateError('Unexpected AuthenticationSaslFinal without SASL start'),
            StackTrace.current,
          );
          return true;
        }
        try {
          _scram!.verifyServerFinalMessage(data);
        } catch (error, stackTrace) {
          onError(error, stackTrace);
          return true;
        }
        return false;

      case ParameterStatusMessage():
        return false;

      case BackendKeyDataMessage(:final processId, :final secretKey):
        _processId = processId;
        _secretKey = secretKey;
        return false;

      case ReadyForQueryMessage():
        final pid = _processId;
        final key = _secretKey;
        if (pid == null || key == null) {
          onError(
            StateError('Server completed handshake without BackendKeyData'),
            StackTrace.current,
          );
        } else {
          completer.complete((processId: pid, secretKey: key));
        }
        return true;

      case final ErrorResponseMessage err:
        onError(
          PgException.fromErrorResponse(err),
          StackTrace.current,
        );
        return true;

      default:
        return false;
    }
  }
}

/// Operation for executing a query and buffering all returned rows into
/// [PgRows].
class RowsOperation extends _PgFutureOperation<PgRows> {
  RowsOperation({
    required this.completer,
    List<FieldDescription>? fields,
  }) : _fields = fields ?? const [];

  /// Completer for the buffered query results.
  @override
  final Completer<PgRows> completer;

  List<FieldDescription> _fields;
  final List<PgRow> _rows = [];

  @override
  bool onMessage(BackendMessage message) {
    switch (message) {
      case ParseCompleteMessage() || BindCompleteMessage() || NoDataMessage():
        return false;

      case RowDescriptionMessage(:final fields):
        _fields = fields;
        return false;

      case DataRowMessage(:final columns):
        _rows.add(PgRow(_fields, columns));
        return false;

      case PortalSuspendedMessage():
        if (!completer.isCompleted) {
          completer.complete(
            PgRows(
              fields: _fields,
              rows: _rows,
              commandTag: '',
              hasMore: true,
            ),
          );
        }
        return false;

      case CommandCompleteMessage(:final tag):
        if (!completer.isCompleted) {
          completer.complete(
            PgRows(
              fields: _fields,
              rows: _rows,
              commandTag: tag,
            ),
          );
        }
        return false;

      case EmptyQueryResponseMessage():
        if (!completer.isCompleted) {
          completer.complete(
            const PgRows(
              fields: [],
              rows: <PgRow>[],
              commandTag: '',
            ),
          );
        }
        return false;

      case ReadyForQueryMessage():
        return true;

      case final ErrorResponseMessage err:
        onError(
          PgException.fromErrorResponse(err),
          StackTrace.current,
        );
        return false;

      default:
        return false;
    }
  }
}

/// Operation for streaming query results as a real-time stream of [PgRow]s.
class StreamRowsOperation extends PgOperation {
  StreamRowsOperation({
    required this.controller,
    Completer<List<FieldDescription>>? fieldsCompleter,
    Completer<String>? commandTagCompleter,
    Completer<bool>? hasMoreCompleter,
    List<FieldDescription>? fields,
  }) : fieldsCompleter = fieldsCompleter ?? Completer<List<FieldDescription>>(),
       commandTagCompleter = commandTagCompleter ?? Completer<String>(),
       hasMoreCompleter = hasMoreCompleter ?? Completer<bool>(),
       _fields = fields ?? const [] {
    this.hasMoreCompleter.future.ignore();
    this.commandTagCompleter.future.ignore();
    if (fields != null && fields.isNotEmpty) {
      this.fieldsCompleter.complete(fields);
    }
  }

  /// The stream controller emitting rows to the caller.
  final StreamController<PgRow> controller;

  /// Completer for the column metadata.
  final Completer<List<FieldDescription>> fieldsCompleter;

  /// Completer for the command completion tag.
  final Completer<String> commandTagCompleter;

  /// Completer indicating whether more rows remain in the portal.
  final Completer<bool> hasMoreCompleter;

  List<FieldDescription> _fields;

  @override
  bool onMessage(BackendMessage message) {
    switch (message) {
      case ParseCompleteMessage() || BindCompleteMessage() || NoDataMessage():
        return false;

      case RowDescriptionMessage(:final fields):
        _fields = fields;
        if (!fieldsCompleter.isCompleted) {
          fieldsCompleter.complete(fields);
        }
        return false;

      case DataRowMessage(:final columns):
        controller.add(PgRow(_fields, columns));
        return false;

      case PortalSuspendedMessage():
        if (!hasMoreCompleter.isCompleted) {
          hasMoreCompleter.complete(true);
        }
        if (!commandTagCompleter.isCompleted) {
          commandTagCompleter.complete('');
        }
        return false;

      case CommandCompleteMessage(:final tag):
        if (!commandTagCompleter.isCompleted) {
          commandTagCompleter.complete(tag);
        }
        if (!hasMoreCompleter.isCompleted) {
          hasMoreCompleter.complete(false);
        }
        return false;

      case EmptyQueryResponseMessage():
        if (!commandTagCompleter.isCompleted) {
          commandTagCompleter.complete('');
        }
        if (!fieldsCompleter.isCompleted) {
          fieldsCompleter.complete(const []);
        }
        if (!hasMoreCompleter.isCompleted) {
          hasMoreCompleter.complete(false);
        }
        return false;

      case ReadyForQueryMessage():
        controller.close();
        return true;

      case final ErrorResponseMessage err:
        onError(
          PgException.fromErrorResponse(err),
          StackTrace.current,
        );
        return false;

      default:
        return false;
    }
  }

  @override
  void onError(Object error, StackTrace stackTrace) {
    if (!fieldsCompleter.isCompleted) {
      fieldsCompleter.completeError(error, stackTrace);
    }
    if (!commandTagCompleter.isCompleted) {
      commandTagCompleter.completeError(error, stackTrace);
    }
    if (!hasMoreCompleter.isCompleted) {
      hasMoreCompleter.completeError(error, stackTrace);
    }
    if (!controller.isClosed) {
      controller.addError(error, stackTrace);
      controller.close();
    }
  }
}

/// Operation for binding parameters to a prepared statement creating a
/// [PgPortal].
class BindOperation extends _PgFutureOperation<PgPortal> {
  BindOperation({
    required this.name,
    required this.statement,
    required this.completer,
  });

  /// The destination portal name on the server.
  final String name;

  /// The source prepared statement descriptor.
  final PgStatement statement;

  /// Completer for the created [PgPortal].
  @override
  final Completer<PgPortal> completer;

  @override
  bool onMessage(BackendMessage message) {
    switch (message) {
      case BindCompleteMessage():
        return false;

      case ReadyForQueryMessage():
        if (!completer.isCompleted) {
          completer.complete(
            PgPortal(
              name: name,
              statement: statement,
            ),
          );
        }
        return true;

      case final ErrorResponseMessage err:
        onError(
          PgException.fromErrorResponse(err),
          StackTrace.current,
        );
        return false;

      default:
        return false;
    }
  }
}

/// Operation for preparing an SQL statement on the server.
class PrepareOperation extends _PgFutureOperation<PgStatement> {
  PrepareOperation({
    required this.name,
    required this.sql,
    required this.completer,
  });

  /// The statement name on the server.
  final String name;

  /// The original SQL query.
  final String sql;

  /// Completer for the created [PgStatement].
  @override
  final Completer<PgStatement> completer;

  List<PgOid> _paramOids = const [];
  List<FieldDescription> _fields = const [];

  @override
  bool onMessage(BackendMessage message) {
    switch (message) {
      case ParseCompleteMessage():
        return false;

      case ParameterDescriptionMessage(:final paramOids):
        _paramOids = paramOids;
        return false;

      case RowDescriptionMessage(:final fields):
        _fields = fields;
        return false;

      case NoDataMessage():
        _fields = const [];
        return false;

      case ReadyForQueryMessage():
        if (!completer.isCompleted) {
          completer.complete(
            PgStatement(
              name: name,
              sql: sql,
              paramOids: _paramOids,
              fields: _fields,
            ),
          );
        }
        return true;

      case final ErrorResponseMessage err:
        onError(
          PgException.fromErrorResponse(err),
          StackTrace.current,
        );
        return false;

      default:
        return false;
    }
  }
}

/// Operation for executing a pipelined batch of queries in a single round-trip.
class PipelineOperation extends PgOperation {
  PipelineOperation({
    required this.items,
    required this.completer,
  });

  /// The list of items in the pipeline.
  final List<PgPipelineQueryItem> items;

  /// Completer for the entire pipeline batch.
  final Completer<void> completer;

  int _currentIndex = 0;
  List<FieldDescription> _currentFields = const [];
  final List<PgRow> _currentRows = [];

  @override
  bool onMessage(BackendMessage message) {
    switch (message) {
      case ParseCompleteMessage() || BindCompleteMessage() || NoDataMessage():
        return false;

      case RowDescriptionMessage(:final fields):
        _currentFields = fields;
        return false;

      case DataRowMessage(:final columns):
        _currentRows.add(PgRow(_currentFields, columns));
        return false;

      case EmptyQueryResponseMessage():
        if (_currentIndex < items.length) {
          final item = items[_currentIndex];
          if (!item.completer.isCompleted) {
            item.completer.complete(
              const PgRows(
                fields: [],
                rows: <PgRow>[],
                commandTag: '',
              ),
            );
          }
          _currentIndex++;
          _currentFields = const [];
          _currentRows.clear();
        }
        return false;

      case CommandCompleteMessage(:final tag):
        if (_currentIndex < items.length) {
          final item = items[_currentIndex];
          if (!item.completer.isCompleted) {
            item.completer.complete(
              PgRows(
                fields: _currentFields,
                rows: List<PgRow>.from(_currentRows),
                commandTag: tag,
              ),
            );
          }
          _currentIndex++;
          _currentFields = const [];
          _currentRows.clear();
        }
        return false;

      case ReadyForQueryMessage():
        if (!completer.isCompleted) {
          completer.complete();
        }
        return true;

      case final ErrorResponseMessage err:
        final exception = PgException.fromErrorResponse(err);
        if (_currentIndex < items.length) {
          final item = items[_currentIndex];
          if (!item.completer.isCompleted) {
            item.completer.completeError(exception, StackTrace.current);
          }
          _currentIndex++;
        }
        for (var i = _currentIndex; i < items.length; i++) {
          final item = items[i];
          if (!item.completer.isCompleted) {
            item.completer.completeError(exception, StackTrace.current);
          }
        }
        return false;

      default:
        return false;
    }
  }

  @override
  void onError(Object error, StackTrace stackTrace) {
    for (final item in items) {
      if (!item.completer.isCompleted) {
        item.completer.completeError(error, stackTrace);
      }
    }
    if (!completer.isCompleted) {
      completer.completeError(error, stackTrace);
    }
  }
}

/// Operation for closing a prepared statement or portal on the server.
class CloseStatementOperation extends _PgFutureOperation<void> {
  CloseStatementOperation(this.completer);

  /// Completer indicating the close command finished.
  @override
  final Completer<void> completer;

  @override
  bool onMessage(BackendMessage message) {
    switch (message) {
      case CloseCompleteMessage():
        return false;

      case ReadyForQueryMessage():
        if (!completer.isCompleted) {
          completer.complete();
        }
        return true;

      case final ErrorResponseMessage err:
        onError(
          PgException.fromErrorResponse(err),
          StackTrace.current,
        );
        return false;

      default:
        return false;
    }
  }
}

/// Operation for managing a COPY FROM STDIN (`COPY IN`) data stream.
class CopyInOperation extends PgOperation {
  CopyInOperation({
    required this.completer,
    required this.send,
  });

  /// Completer for the initial [PgCopyInSink] when server responds with
  /// CopyInResponse.
  final Completer<PgCopyInSink> completer;

  /// Low-level send callback for transmission over connection.
  final void Function(FrontendMessage) send;

  /// Completer for final inserted row count.
  final Completer<int> finishCompleter = Completer<int>();

  /// CopyIn metadata received from backend.
  CopyInResponseMessage? copyInResponse;

  /// Command completion tag (e.g. 'COPY 100').
  String? commandTag;

  bool _finishedSending = false;

  @override
  bool onMessage(BackendMessage message) {
    switch (message) {
      case CopyInResponseMessage():
        copyInResponse = message;
        if (!completer.isCompleted) {
          completer.complete(PgCopyInSink(this));
        }
        return false;

      case CommandCompleteMessage(:final tag):
        commandTag = tag;
        return false;

      case ReadyForQueryMessage():
        if (!finishCompleter.isCompleted) {
          finishCompleter.complete(_parseCopyCount(commandTag));
        }
        return true;

      case final ErrorResponseMessage err:
        final exception = PgException.fromErrorResponse(err);
        if (!completer.isCompleted) {
          completer.completeError(exception, StackTrace.current);
        }
        if (!finishCompleter.isCompleted) {
          finishCompleter.completeError(exception, StackTrace.current);
        }
        return false;

      default:
        return false;
    }
  }

  static int _parseCopyCount(String? tag) {
    if (tag == null || !tag.startsWith('COPY ')) return 0;
    final parts = tag.split(' ');
    if (parts.length >= 2) {
      return int.tryParse(parts.last) ?? 0;
    }
    return 0;
  }

  @override
  void onError(Object error, StackTrace stackTrace) {
    if (!completer.isCompleted) {
      completer.completeError(error, stackTrace);
    }
    if (!finishCompleter.isCompleted) {
      finishCompleter.completeError(error, stackTrace);
    }
  }

  void addChunk(List<int> bytes) {
    if (_finishedSending) {
      throw StateError('Cannot send COPY data after finish() or abort()');
    }
    send(CopyDataMessage(bytes));
  }

  Future<int> finish() {
    if (_finishedSending) {
      return finishCompleter.future;
    }
    _finishedSending = true;
    send(const CopyDoneMessage());
    return finishCompleter.future;
  }

  Future<int> abort([String reason = 'COPY aborted by client']) {
    if (_finishedSending) {
      return finishCompleter.future;
    }
    _finishedSending = true;
    send(CopyFailMessage(reason));
    return finishCompleter.future;
  }
}

/// Operation for managing a COPY TO STDOUT (`COPY OUT`) data stream.
class CopyOutOperation extends PgOperation {
  CopyOutOperation({
    required this.controller,
    Completer<CopyOutResponseMessage>? responseCompleter,
    Completer<String>? commandTagCompleter,
  }) : responseCompleter =
           responseCompleter ?? Completer<CopyOutResponseMessage>(),
       commandTagCompleter = commandTagCompleter ?? Completer<String>() {
    this.responseCompleter.future.ignore();
    this.commandTagCompleter.future.ignore();
  }

  /// Controller emitting data bytes.
  final StreamController<Uint8List> controller;

  /// Completer for CopyOutResponse message.
  final Completer<CopyOutResponseMessage> responseCompleter;

  /// Completer for command tag.
  final Completer<String> commandTagCompleter;

  @override
  bool onMessage(BackendMessage message) {
    switch (message) {
      case CopyOutResponseMessage():
        if (!responseCompleter.isCompleted) {
          responseCompleter.complete(message);
        }
        return false;

      case BackendCopyDataMessage(:final data):
        controller.add(data);
        return false;

      case BackendCopyDoneMessage():
        return false;

      case CommandCompleteMessage(:final tag):
        if (!commandTagCompleter.isCompleted) {
          commandTagCompleter.complete(tag);
        }
        return false;

      case ReadyForQueryMessage():
        controller.close();
        return true;

      case final ErrorResponseMessage err:
        onError(
          PgException.fromErrorResponse(err),
          StackTrace.current,
        );
        return false;

      default:
        return false;
    }
  }

  @override
  void onError(Object error, StackTrace stackTrace) {
    if (!responseCompleter.isCompleted) {
      responseCompleter.completeError(error, stackTrace);
    }
    if (!commandTagCompleter.isCompleted) {
      commandTagCompleter.completeError(error, stackTrace);
    }
    if (!controller.isClosed) {
      controller.addError(error, stackTrace);
      controller.close();
    }
  }
}
