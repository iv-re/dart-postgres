/// @docImport 'package:pg/src/types/codec.dart';
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:pg/src/protocol/backend.dart';
import 'package:pg/src/types/codec.dart';

/// A single row of query results containing raw column byte buffers.
///
/// Access columns by zero-based index or by name via the `[]` operator.
/// Values are raw `Uint8List` bytes as received from PostgreSQL; decode
/// them using the appropriate [PgCodec].
class const PgRow(
  final List<FieldDescription> fields,
  final List<Uint8List?> _values,
) {
  /// Number of columns in this row.
  int get length => _values.length;

  /// Returns column raw bytes by [column] (either zero-based int index or
  /// String name).
  @pragma('vm:prefer-inline')
  Uint8List? operator [](Object column) {
    return _values[_resolveColumnIndex(column)];
  }

  /// Decodes column raw bytes using [codec], returning `null` if SQL NULL.
  @pragma('vm:prefer-inline')
  T? decodeOrNull<T>(Object column, PgCodec<T> codec) {
    final idx = _resolveColumnIndex(column);
    final bytes = _values[idx];
    if (bytes == null) return null;
    return fields[idx].formatCode == 0
        ? codec.decodeText(bytes)
        : codec.decodeBinary(bytes);
  }

  /// Decodes column raw bytes using [codec]. Throws [StateError] if null.
  @pragma('vm:prefer-inline')
  T decode<T>(Object column, PgCodec<T> codec) {
    return decodeOrNull(column, codec) ??
        (throw StateError('Column "$column" is null'));
  }

  @pragma('vm:prefer-inline')
  int _resolveColumnIndex(Object column) {
    assert(
      column is int || column is String,
      'Column identifier must be int or String, got ${column.runtimeType}',
    );
    if (column is int) {
      if (column < 0 || column >= _values.length) {
        throw RangeError.index(column, _values, 'column');
      }
      return column;
    } else if (column is String) {
      final len = fields.length;
      for (var i = 0; i < len; i++) {
        if (fields[i].name == column) return i;
      }
      throw ArgumentError.value(column, 'column', 'Column not found in row');
    }
    throw ArgumentError.value(
      column,
      'column',
      'Expected int index or String column name, got ${column.runtimeType}',
    );
  }

  @override
  String toString() {
    return 'PgRow($_values)';
  }
}

/// In-memory query result set containing all rows and execution metadata.
///
/// Iterable over [PgRow] instances. Access individual rows by index via
/// the `[]` operator. Use [affectedRows] for DML row counts and
/// [commandTag] for the raw server completion tag.
class const PgRows({
  /// Metadata for all columns.
  required final List<FieldDescription> fields,
  required final List<PgRow> _rows,

  /// Command completion tag (e.g. 'SELECT 1', 'INSERT 0 5').
  required final String commandTag,

  /// Whether more rows are available in the portal after reaching `maxRows`.
  final bool hasMore = false,
}) extends Iterable<PgRow> {
  /// Number of rows affected by the query (parsed lazily from [commandTag]).
  int get affectedRows => _parseAffectedRows(commandTag);

  @override
  Iterator<PgRow> get iterator => _rows.iterator;

  /// Returns the row at zero-based [index].
  PgRow operator [](int index) => _rows[index];

  @override
  int get length => _rows.length;

  @override
  String toString() {
    return 'PgRows(length: $length, '
        'affectedRows: $affectedRows, '
        'tag: $commandTag, '
        'hasMore: $hasMore)';
  }
}

/// A streaming query result emitting [PgRow] instances as they arrive.
///
/// Unlike [PgRows], rows are not buffered in memory. The stream completes
/// when the server sends the final row. Use [commandTag] and [affectedRows]
/// after the stream finishes.
class PgRowStream(
  super.stream, {

  /// Schema metadata for columns in this stream.
  required final List<FieldDescription> fields,

  /// Command tag (available when stream finishes).
  required final Future<String> commandTag,
  Future<bool>? hasMore,
}) extends StreamView<PgRow> {
  /// Whether more rows are available in the portal after reaching `maxRows`.
  final Future<bool> hasMore = hasMore ?? Future.value(false);

  /// Number of affected rows.
  Future<int> get affectedRows => commandTag.then(_parseAffectedRows);
}

int _parseAffectedRows(String tag) {
  final lastSpace = tag.lastIndexOf(' ');
  if (lastSpace == -1) return 0;
  return int.tryParse(tag.substring(lastSpace + 1)) ?? 0;
}
