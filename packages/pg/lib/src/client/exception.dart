import 'package:pg/src/protocol/backend.dart';

/// Exception thrown on PostgreSQL server error responses.
class const PgException({
  /// Primary human-readable error message.
  required final String message,

  /// 5-character SQLSTATE error code.
  required final String code,

  /// Severity level (e.g. 'ERROR', 'FATAL', 'PANIC').
  final String? severity,

  /// Optional detailed error description.
  final String? detail,

  /// Optional hint on how to resolve the error.
  final String? hint,

  /// 1-based cursor index position of error in original query string.
  final int? position,

  /// 1-based cursor index position in internally generated query.
  final int? internalPosition,

  /// Text of failed internally generated query.
  final String? internalQuery,

  /// PL/pgSQL callstack context or indication of context.
  final String? where,

  /// Schema name associated with the error.
  final String? schemaName,

  /// Table name associated with the error.
  final String? tableName,

  /// Column name associated with the error.
  final String? columnName,

  /// Data type name associated with the error.
  final String? dataTypeName,

  /// Constraint name associated with the error.
  final String? constraintName,

  /// Source file name where error was reported.
  final String? file,

  /// Source line number where error was reported.
  final int? line,

  /// Source routine name where error was reported.
  final String? routine,

  /// All raw protocol error fields mapped by their byte identifier.
  final Map<int, String> fields = const {},
}) implements Exception {
  /// Creates a [PgException] from a decoded backend [ErrorResponseMessage].
  new fromErrorResponse(ErrorResponseMessage msg)
    : this(
        message: msg.message,
        code: msg.code,
        severity: msg.severity,
        detail: msg.detail,
        hint: msg.hint,
        position: msg.position,
        internalPosition: msg.internalPosition,
        internalQuery: msg.internalQuery,
        where: msg.where,
        schemaName: msg.schemaName,
        tableName: msg.tableName,
        columnName: msg.columnName,
        dataTypeName: msg.dataTypeName,
        constraintName: msg.constraintName,
        file: msg.file,
        line: msg.line,
        routine: msg.routine,
        fields: msg.fields,
      );

  @override
  String toString() {
    final sb = StringBuffer('PgException($code: $message');
    if (detail != null) {
      sb.write(', detail: $detail');
    }
    if (hint != null) {
      sb.write(', hint: $hint');
    }
    if (constraintName != null) {
      sb.write(', constraint: $constraintName');
    }
    if (tableName != null) {
      sb.write(', table: $tableName');
    }
    if (columnName != null) {
      sb.write(', column: $columnName');
    }
    if (position != null) {
      sb.write(', position: $position');
    }
    if (where != null) {
      sb.write(', where: $where');
    }
    sb.write(')');
    return sb.toString();
  }
}
