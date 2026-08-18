import 'dart:io';

import 'package:pg/pg.dart';
import 'package:postgres/postgres.dart' as v3;

/// Shared database connection settings loaded from environment variables.
final class DbConfig {
  const DbConfig._();

  static final Map<String, String> _env = Platform.environment;

  static final String host = _env['PGHOST'] ?? 'localhost';
  static final int port = int.tryParse(_env['PGPORT'] ?? '') ?? 5432;
  static final String user = _env['PGUSER'] ?? 'postgres';
  static final String password = _env['PGPASSWORD'] ?? 'postgres';
  static final String database = _env['PGDATABASE'] ?? 'postgres';

  static PgConfig get pgConfig => PgConfig(
    host: host,
    port: port,
    user: user,
    password: password,
    database: database,
  );

  static v3.Endpoint get postgresEndpoint => v3.Endpoint(
    host: host,
    port: port,
    username: user,
    password: password,
    database: database,
  );

  static v3.ConnectionSettings get postgresSettings {
    return const v3.ConnectionSettings(sslMode: .disable);
  }
}
