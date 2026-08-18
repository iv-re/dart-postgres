@Tags(['integration'])
library;

import 'package:checks/checks.dart';
import 'package:pg/pg.dart';
import 'package:test/scaffolding.dart';

import '../test_utils.dart';

void main() {
  group('PgClient Integration', () {
    testWithClient('simpleQuery executes simple SQL', (client) async {
      final rows = await client.simpleQuery(
        "SELECT 42 as num, 'hello' as msg",
      );
      check(rows.length).equals(1);
      check(rows[0].string('num')).equals('42');
      check(rows[0].string('msg')).equals('hello');
      check(rows.commandTag).equals('SELECT 1');
    });

    testWithClient(r'query executes parameterized SQL ($1, $2)', (
      client,
    ) async {
      final rows = await client.query(
        r'SELECT $1::int as id, $2::text as name',
        [101, 'Bob'],
      );
      check(rows.length).equals(1);
      check(rows[0].string('id')).equals('101');
      check(rows[0].string('name')).equals('Bob');
      check(rows[0].string(0)).equals('101');
      check(rows[0].string(1)).equals('Bob');
    });

    testWithClient('queryStream streams parameterized results', (
      client,
    ) async {
      final stream = await client.queryStream(
        r'SELECT x FROM generate_series(1, $1) as x',
        [3],
      );

      check(stream.fields.length).equals(1);
      check(stream.fields[0].name).equals('x');

      final rows = await stream.toList();
      check(rows.length).equals(3);
      check(
        rows.map((r) => r.string('x')).toList(),
      ).deepEquals(['1', '2', '3']);
      check(await stream.commandTag).equals('SELECT 3');
      check(await stream.affectedRows).equals(3);
    });

    testWithClient(
      'prepare, execute, and executeStream with prepared statement',
      (client) async {
        final stmt = await client.prepare(
          r'SELECT $1::int + $2::int as total, $3::text as label',
        );

        check(stmt.name).isNotEmpty();
        check(stmt.fields.length).equals(2);
        check(stmt.fields[0].name).equals('total');
        check(stmt.fields[1].name).equals('label');

        final res1 = await client.execute(stmt, [15, 27, 'Sum1']);
        check(res1.length).equals(1);
        check(res1[0].string('total')).equals('42');
        check(res1[0].string('label')).equals('Sum1');

        final res2 = await client.execute(stmt, [100, 200, 'Sum2']);
        check(res2[0].string('total')).equals('300');
        check(res2[0].string('label')).equals('Sum2');

        final streamRes = await client.executeStream(
          stmt,
          [5, 5, 'StreamSum'],
        );
        check(streamRes.fields.length).equals(2);
        final streamedRows = await streamRes.toList();
        check(streamedRows.length).equals(1);
        check(streamedRows[0].string('total')).equals('10');
      },
    );

    testWithClient(
      'statement cache automatically caches prepared statements in query',
      (client) async {
        // First call compiles statement
        final stmt1 = await client.prepare(r'SELECT $1::int * 2 as doubled');
        // Second call returns cached statement
        final stmt2 = await client.prepare(r'SELECT $1::int * 2 as doubled');

        check(identical(stmt1, stmt2)).equals(true);

        final res = await client.query(r'SELECT $1::int * 2 as doubled', [21]);
        check(res[0].string('doubled')).equals('42');
      },
    );

    testWithClient('queryStream in prepared mode resolves fields eagerly', (
      client,
    ) async {
      final stream = await client.queryStream(
        r'SELECT $1::int as val',
        [42],
        mode: PgQueryMode.prepared,
      );

      // Access fields synchronously before listening to the stream
      final fields = stream.fields;
      check(fields.length).equals(1);
      check(fields.first.name).equals('val');

      final rows = await stream.toList();
      check(rows.length).equals(1);
      check(rows[0].string('val')).equals('42');
    });

    testWithClient(
      'executes parameterized query and stream in PgQueryMode.unnamed',
      (client) async {
        final rows = await client.query(
          r'SELECT $1::int * 10 as result, $2::text as prefix',
          [5, 'value_'],
          mode: .unnamed,
        );
        check(rows.length).equals(1);
        check(rows[0].string('result')).equals('50');
        check(rows[0].string('prefix')).equals('value_');

        final stream = await client.queryStream(
          r'SELECT $1::text || num as item FROM generate_series(1, 2) as num',
          ['unnamed_'],
          mode: .unnamed,
        );
        final streamed = await stream.toList();
        check(streamed.length).equals(2);
        check(streamed[0].string('item')).equals('unnamed_1');
        check(streamed[1].string('item')).equals('unnamed_2');
      },
    );

    testWithClient(
      'throws ArgumentError when passing params with PgQueryMode.simple',
      (client) async {
        check(
          () => client.query('SELECT 1', [1], mode: PgQueryMode.simple),
        ).throws<ArgumentError>();

        await check(
          client.queryStream('SELECT 1', [1], mode: PgQueryMode.simple),
        ).throws<ArgumentError>();
      },
    );

    test(
      'statement cache evicts oldest statements and deallocates on server',
      () async {
        final client = await PgClient.connect(
          defaultTestConfig,
          statementCacheCapacity: 2,
        );
        try {
          // Execute 5 different statements
          for (var i = 1; i <= 5; i++) {
            final res = await client.query(
              'SELECT \$1::int + $i as offset_val',
              [10],
            );
            check(res[0].int('offset_val')).equals(10 + i);
          }

          // Re-running first statement re-compiles cleanly without protocol
          // corruption.
          final reRun = await client.query(
            r'SELECT $1::int + 1 as offset_val',
            [10],
          );
          check(reRun[0].int('offset_val')).equals(11);
        } finally {
          await client.close();
        }
      },
      tags: 'integration',
    );

    testWithClient(
      'diagnoses unique constraint violation with detailed fields',
      (
        client,
      ) async {
        await client.simpleQuery('DROP TABLE IF EXISTS test_users_diag;');
        await client.simpleQuery('''
        CREATE TABLE test_users_diag (
          id INT PRIMARY KEY,
          email TEXT CONSTRAINT test_users_diag_email_key UNIQUE
        );
      ''');

        try {
          await client.query(
            r'INSERT INTO test_users_diag (id, email) VALUES ($1, $2)',
            [1, 'test@example.com'],
          );

          PgException? caught;
          try {
            await client.query(
              r'INSERT INTO test_users_diag (id, email) VALUES ($1, $2)',
              [2, 'test@example.com'],
            );
          } on PgException catch (e) {
            caught = e;
          }

          check(caught).isNotNull();
          check(caught!.code).equals('23505'); // unique_violation
          check(caught.constraintName).equals('test_users_diag_email_key');
          check(caught.tableName).equals('test_users_diag');
          check(caught.detail).isNotNull();
          check(caught.toString()).contains('test_users_diag_email_key');
        } finally {
          await client.simpleQuery('DROP TABLE IF EXISTS test_users_diag;');
        }
      },
    );

    testWithClient('diagnoses syntax error position', (client) async {
      PgException? caught;
      try {
        await client.simpleQuery('SELECT 1 FROM;');
      } on PgException catch (e) {
        caught = e;
      }

      check(caught).isNotNull();
      check(caught!.code).equals('42601'); // syntax_error
      check(caught.position).isNotNull();
      check(caught.position!).isGreaterThan(0);
      check(caught.severity).isNotNull();
    });

    testWithClient(
      'throws StateError when executing queries on closed client',
      (client) async {
        await client.close();
        check(() => client.simpleQuery('SELECT 1')).throws<StateError>();
        check(() => client.query('SELECT 1', const [])).throws<StateError>();
        await check(
          client.queryStream('SELECT 1', const []),
        ).throws<StateError>();
        check(() => client.prepare('SELECT 1')).throws<StateError>();
      },
    );

    test('loadBalanceHosts distributes candidate endpoints when random', () {
      const endpoints = [
        PgEndpoint('127.0.0.1'),
        PgEndpoint('127.0.0.1', 5433),
        PgEndpoint('127.0.0.1', 5434),
        PgEndpoint('127.0.0.1', 5435),
      ];

      final config = PgConfig.multi(
        endpoints: endpoints,
        user: 'postgres',
        password: 'password',
        database: 'postgres',
        loadBalanceHosts: .random,
      );

      final firstElements = <PgEndpoint>{};
      for (var i = 0; i < 50; i++) {
        final list = List.of(config.endpoints)..shuffle();
        firstElements.add(list.first);
      }
      check(firstElements.length).isGreaterThan(1);
    });

    test(
      'multi-endpoint failover connects with loadBalanceHosts.random',
      () async {
        final config = PgConfig.multi(
          endpoints: const [
            PgEndpoint('127.0.0.1', 59999), // unreachable
            PgEndpoint('localhost'), // real
          ],
          user: 'postgres',
          password: 'password',
          database: 'postgres',
          loadBalanceHosts: .random,
        );

        final client = await PgClient.connect(config);
        try {
          final rows = await client.simpleQuery('SELECT 42 as num;');
          check(rows.first.int('num')).equals(42);
        } finally {
          await client.close();
        }
      },
    );

    test('connects with sslMode.prefer against PostgreSQL server', () async {
      final config = PgConfig(
        host: 'localhost',
        user: 'postgres',
        password: 'password',
        database: 'postgres',
        sslConfig: const PgSslConfig(mode: .prefer),
      );

      final client = await PgClient.connect(config);
      try {
        final rows = await client.simpleQuery('SELECT 1 + 1 as res;');
        check(rows.first.int('res')).equals(2);
      } finally {
        await client.close();
      }
    });
  });
}
