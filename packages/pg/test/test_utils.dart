import 'dart:async';
import 'dart:io';

import 'package:meta/meta.dart';
import 'package:pg/pg.dart';
import 'package:test/scaffolding.dart';

/// Default configuration for testing against a local PostgreSQL instance,
/// with fallback to standard PG environment variables for CI/Docker environments.
final defaultTestConfig = PgConfig(
  host: Platform.environment['PGHOST'] ?? 'localhost',
  port: int.tryParse(Platform.environment['PGPORT'] ?? '') ?? 5432,
  user: Platform.environment['PGUSER'] ?? 'postgres',
  password: Platform.environment['PGPASSWORD'] ?? '',
  database: Platform.environment['PGDATABASE'] ?? 'postgres',
);

/// Executes [action] with a freshly connected [PgClient] and guarantees
/// resource cleanup on completion or failure.
Future<T> withClient<T>(
  Future<T> Function(PgClient client) action, {
  PgConfig? config,
}) async {
  final client = await PgClient.connect(config ?? defaultTestConfig);
  try {
    return await action(client);
  } finally {
    await client.close();
  }
}

/// Executes [action] with a freshly opened [PgPool] and guarantees
/// resource cleanup on completion or failure.
Future<T> withPool<T>(
  Future<T> Function(PgPool pool) action, {
  PgConfig? config,
  int minConnections = 1,
  int maxConnections = 3,
}) async {
  final pool = PgPool(
    config ?? defaultTestConfig,
    minConnections: minConnections,
    maxConnections: maxConnections,
  );
  try {
    return await action(pool);
  } finally {
    await pool.close();
  }
}

/// Declares a test that runs with an isolated [PgClient] instance.
@isTest
void testWithClient(
  String description,
  Future<void> Function(PgClient client) body, {
  PgConfig? config,
  Timeout? timeout,
  dynamic tags = 'integration',
  Map<String, dynamic>? onPlatform,
  int? retry,
}) {
  test(
    description,
    () => withClient(body, config: config),
    timeout: timeout,
    tags: tags,
    onPlatform: onPlatform,
    retry: retry,
  );
}

/// Declares a test that runs with an isolated [PgPool] instance.
@isTest
void testWithPool(
  String description,
  Future<void> Function(PgPool pool) body, {
  PgConfig? config,
  int minConnections = 1,
  int maxConnections = 3,
  Timeout? timeout,
  dynamic tags = 'integration',
  Map<String, dynamic>? onPlatform,
  int? retry,
}) {
  test(
    description,
    () => withPool(
      body,
      config: config,
      minConnections: minConnections,
      maxConnections: maxConnections,
    ),
    timeout: timeout,
    tags: tags,
    onPlatform: onPlatform,
    retry: retry,
  );
}
