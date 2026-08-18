import 'dart:async';

import 'package:benchmark/benchmark.dart';
import 'package:pg/pg.dart';
import 'package:postgres/postgres.dart' as v3;

void main(List<String> args) async {
  print(
    'Connecting to PostgreSQL at '
    '${DbConfig.host}:${DbConfig.port}/${DbConfig.database}...',
  );

  final pgClient = await PgClient.connect(DbConfig.pgConfig);
  final pgConn = await v3.Connection.open(
    DbConfig.postgresEndpoint,
    settings: DbConfig.postgresSettings,
  );

  final pgPool = PgPool(DbConfig.pgConfig);
  final postgresPool = v3.Pool<void>.withEndpoints(
    [DbConfig.postgresEndpoint],
    settings: const v3.PoolSettings(
      maxConnectionCount: 10,
      sslMode: v3.SslMode.disable,
    ),
  );

  final cluster = await WebAppCluster.create();

  final runner = BenchmarkRunner()..printHeader();

  try {
    // Simple Query (SELECT 1)
    await runner.measure(
      'Simple Query (SELECT 1)',
      iterations: 2000,
      unit: 'qps',
      pg: () => pgClient.simpleQuery('SELECT 1;'),
      postgres: () => pgConn.execute('SELECT 1;'),
    );

    // Parameterized Query (Statement cache / binding)
    await runner.measure(
      'Parameterized Query',
      iterations: 2000,
      unit: 'qps',
      pg: () => pgClient.query(
        r'SELECT $1::int as id, $2::text as name;',
        [42, 'dart_pg'],
      ),
      postgres: () => pgConn.execute(
        r'SELECT $1::int as id, $2::text as name;',
        parameters: [42, 'dart_pg'],
      ),
    );

    // Multi-Row Query (100 rows fetch)
    const multiRowSql =
        'SELECT id, md5(id::text) as name, now() as created_at '
        'FROM generate_series(1, 100) id;';
    await runner.measure(
      'Multi-Row Fetch (100 rows)',
      iterations: 500,
      itemsPerIteration: 100,
      unit: 'rows/s',
      pg: () => pgClient.query(multiRowSql, []),
      postgres: () => pgConn.execute(multiRowSql),
    );

    // Short Transactions
    await runner.measure(
      'Short Transactions',
      iterations: 1000,
      unit: 'tx/s',
      pg: () => pgClient.transaction((tx) => tx.query('SELECT 1;', [])),
      postgres: () => pgConn.runTx((tx) => tx.execute('SELECT 1;')),
    );

    // Concurrent Pool (50 workers, 10 connections)
    await runner.measure(
      'Concurrent Pool (50 workers)',
      iterations: 100,
      itemsPerIteration: 50,
      unit: 'qps',
      pg: () => Future.wait(
        List.generate(50, (_) => pgPool.query('SELECT 1;', [])),
      ),
      postgres: () => Future.wait(
        List.generate(50, (_) => postgresPool.execute('SELECT 1;')),
      ),
    );

    // Web App (4 isolates x 4 pool connections)
    await runner.measure(
      'Web App (4 isolates x 4 conn)',
      iterations: 50,
      itemsPerIteration: 4 * 100,
      unit: 'qps',
      pg: () => cluster.runPg(100),
      postgres: () => cluster.runPostgres(100),
    );
  } finally {
    runner.printFooter();
    await cluster.close();
    await pgClient.close();
    await pgConn.close();
    await pgPool.close();
    await postgresPool.close();
  }
}
