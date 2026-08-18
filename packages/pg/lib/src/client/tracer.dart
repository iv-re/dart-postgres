import 'package:ctx/ctx.dart';
import 'package:pg/src/client/endpoint.dart';

/// Structured telemetry and performance metadata for an executed PostgreSQL
/// query.
final class const PgQueryTrace({
  /// The raw SQL query string that was executed.
  required final String sql,

  /// The query positional parameters.
  required final List<Object?> params,

  /// Total execution duration.
  required final Duration duration,

  /// The server completion tag (e.g. `'SELECT 42'`, `'INSERT 0 1'`), if
  /// successful.
  final String? commandTag,

  /// The exception or error that occurred during execution, if failed.
  final Object? error,

  /// The [Context] associated with the query, if any.
  final Context? ctx,
}) {
  /// Whether the query execution failed with an error.
  bool get isError => error != null;

  @override
  String toString() {
    return 'PgQueryTrace(sql: $sql, duration: $duration, '
        'commandTag: $commandTag, error: $error)';
  }
}

/// Server warning or notice received from the PostgreSQL backend during query
/// execution (e.g. `RAISE NOTICE`, `WARNING`).
final class const PgNotice({
  /// The severity of the notice (e.g. `'WARNING'`, `'NOTICE'`, `'INFO'`).
  required final String severity,

  /// The 5-character SQLSTATE code (e.g. `'01000'`).
  required final String code,

  /// The human-readable notice message.
  required final String message,
}) {
  @override
  String toString() {
    return 'PgNotice(severity: $severity, code: $code, message: $message)';
  }
}

/// Hook interface for observing PostgreSQL queries, connections, and server
/// notices.
abstract interface class PgTracer {
  /// Called upon completion of an SQL query or stream (both on success and
  /// failure).
  void onQuery(PgQueryTrace trace);

  /// Called when a server notice/warning is received from PostgreSQL.
  void onNotice(PgNotice notice) {}

  /// Called when a connection attempt completes.
  void onConnect(PgEndpoint endpoint, Duration duration, {Object? error}) {}
}
