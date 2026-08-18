/// Escapes a PostgreSQL identifier (table name, column name, savepoint, etc.)
/// by enclosing it in double quotes and escaping any double quotes within.
String escapeIdentifier(String identifier) {
  return '"${identifier.replaceAll('"', '""')}"';
}
