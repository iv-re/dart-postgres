import 'package:pg/src/protocol/backend.dart';
import 'package:pg/src/types/types.dart';

/// A compiled prepared statement descriptor on PostgreSQL server.
class const PgStatement({
  /// Statement identifier on the server (empty string for anonymous).
  required final String name,

  /// The original SQL query string.
  required final String sql,

  /// PostgreSQL type OIDs for parameters ($1, $2, ...).
  required final List<PgOid> paramOids,

  /// Metadata for all columns returned by this statement.
  required final List<FieldDescription> fields,
}) {
  @override
  String toString() {
    return 'PgStatement('
        'name: $name, '
        'sql: $sql, '
        'params: $paramOids, '
        'fields: $fields)';
  }
}
