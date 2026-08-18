import 'package:pg/src/client/statement.dart';
import 'package:pg/src/protocol/backend.dart';

/// A bound, executable portal handle on PostgreSQL server.
class const PgPortal({
  /// Portal identifier on the server (empty string for unnamed portal).
  required final String name,

  /// The parent prepared statement descriptor from which this portal was bound.
  required final PgStatement statement,
}) {
  /// Metadata for all columns returned by this portal.
  List<FieldDescription> get fields => statement.fields;

  @override
  String toString() {
    return 'PgPortal(name: $name, statement: ${statement.name})';
  }
}
