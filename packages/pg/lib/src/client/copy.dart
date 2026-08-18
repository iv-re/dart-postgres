/// @docImport 'package:pg/src/client/executor.dart';
library;

import 'dart:async';

import 'package:pg/src/client/operation.dart';

/// Sink for streaming data into PostgreSQL via `COPY FROM STDIN`.
///
/// Obtained from [PgExecutor.copyIn]. After writing data with [add] or
/// [addStream], call [finish] to commit or [abort] to cancel.
class PgCopyInSink {
  PgCopyInSink(
    this._operation, {
    this._onDone,
  });

  final CopyInOperation _operation;
  final void Function()? _onDone;

  /// The underlying copy-in operation handle.
  CopyInOperation get operation => _operation;

  /// Overall format: 0 for text/CSV, 1 for binary.
  int get overallFormat => _operation.copyInResponse?.overallFormat ?? 0;

  /// Format codes for individual columns (0 for text, 1 for binary).
  List<int> get columnFormats {
    return _operation.copyInResponse?.columnFormats ?? const [];
  }

  /// Sends a chunk of raw byte data to the server.
  void add(List<int> bytes) {
    _operation.addChunk(bytes);
  }

  /// Sends a stream of data chunks to the server.
  ///
  /// If [stream] emits an error, the COPY operation is aborted with the error
  /// message, and the error is rethrown.
  Future<void> addStream(Stream<List<int>> stream) async {
    try {
      await stream.forEach(add);
    } catch (error, stackTrace) {
      await abort(error.toString());
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  /// Completes the COPY operation by sending a CopyDone message to the server
  /// and returning the total count of inserted rows.
  Future<int> finish() async {
    try {
      return await _operation.finish();
    } finally {
      _onDone?.call();
    }
  }

  /// Aborts the COPY operation by sending a CopyFail message to the server.
  Future<int> abort([String reason = 'COPY aborted by client']) async {
    try {
      return await _operation.abort(reason);
    } finally {
      _onDone?.call();
    }
  }
}
