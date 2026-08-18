@Tags(['integration'])
library;

import 'dart:async';

import 'package:checks/checks.dart';
import 'package:pg/pg.dart';
import 'package:test/scaffolding.dart';

import '../test_utils.dart';

void main() {
  group('PgPool Integration', () {
    testWithPool('executes queries directly via pool', (pool) async {
      final rows = await pool.simpleQuery('SELECT 1 as num;');
      check(rows.length).equals(1);
      check(rows[0].string('num')).equals('1');

      final paramRows = await pool.query(
        r'SELECT $1::int + $2::int as sum',
        [5, 7],
      );
      check(paramRows[0].string('sum')).equals('12');
    });

    testWithPool('streams results via pool.queryStream', (pool) async {
      final stream = await pool.queryStream(
        r'SELECT s FROM generate_series(1, $1) as s',
        [4],
      );

      check(stream.fields.length).equals(1);
      check(stream.fields[0].name).equals('s');

      final rows = await stream.toList();
      check(rows.length).equals(4);
      check(
        rows.map((r) => r.string('s')).toList(),
      ).deepEquals(['1', '2', '3', '4']);
    });

    testWithPool(
      'prepares and executes prepared statements via withClient',
      (pool) async {
        final res = await pool.withClient((client) async {
          final stmt = await client.prepare(r'SELECT $1::text as echo');
          final rows = await client.execute(stmt, ['hello pool']);
          return rows[0].string('echo');
        });
        check(res).equals('hello pool');
      },
    );

    testWithPool('executes transaction on pool connection', (pool) async {
      await pool.simpleQuery('CREATE TEMP TABLE test_pool_tx (id int);');

      await pool.transaction((tx) async {
        await tx.query(r'INSERT INTO test_pool_tx VALUES ($1)', [99]);
      });

      final rows = await pool.simpleQuery('SELECT * FROM test_pool_tx;');
      check(rows.length).equals(1);
      check(rows[0].string('id')).equals('99');
    });

    testWithPool('borrows client with withClient', (pool) async {
      final res = await pool.withClient((client) async {
        final rows = await client.simpleQuery('SELECT 42 as val');
        return rows[0].string('val');
      });

      check(res).equals('42');
    });

    testWithPool(
      'handles high concurrency exceeding maxConnections',
      (pool) async {
        // 20 concurrent queries with pool maxConnections = 3
        final futures = List.generate(20, (i) async {
          final rows = await pool.query(r'SELECT $1::int as idx', [i]);
          return rows[0].int('idx');
        });

        final results = await Future.wait(futures);
        check(results.length).equals(20);
        check(results).deepEquals(List.generate(20, (i) => i));
        check(pool.totalConnections).isLessOrEqual(3);
      },
    );

    testWithPool(
      'supports pool.copyIn and pool.copyOut and returns connection to pool',
      (pool) async {
        await pool.simpleQuery('DROP TABLE IF EXISTS pool_copy_test_tbl;');
        await pool.simpleQuery('''
          CREATE TABLE pool_copy_test_tbl (id INT, name TEXT);
        ''');

        try {
          final sink = await pool.copyIn(
            'COPY pool_copy_test_tbl (id, name) FROM STDIN WITH (FORMAT text)',
          );
          sink.add(const [0x31, 0x09, 0x61, 0x0a]); // '1\ta\n'
          sink.add(const [0x32, 0x09, 0x62, 0x0a]); // '2\tb\n'
          final count = await sink.finish();
          check(count).equals(2);

          final copyOut = await pool.copyOut(
            'COPY pool_copy_test_tbl TO STDOUT WITH (FORMAT csv)',
          );
          final chunks = await copyOut.toList();
          check(chunks.isNotEmpty).equals(true);

          // Verify pool can immediately run regular queries
          final rows = await pool.simpleQuery(
            'SELECT count(*)::int as c FROM pool_copy_test_tbl;',
          );
          check(rows.first.int('c')).equals(2);
        } finally {
          await pool.simpleQuery('DROP TABLE IF EXISTS pool_copy_test_tbl;');
        }
      },
    );

    testWithPool(
      'releases connection back to pool on transaction error',
      (pool) async {
        await check(
          pool.transaction((tx) async {
            await tx.simpleQuery('SELECT 1;');
            throw StateError('tx error');
          }),
        ).throws<StateError>();

        // After error, connection must be returned to pool and ready for new
        // queries.
        final rows = await pool.simpleQuery('SELECT 10 as num;');
        check(rows.first.int('num')).equals(10);
      },
    );

    testWithPool('throws StateError when pool is closed', (pool) async {
      await pool.close();
      check(pool.isClosed).equals(true);

      await check(pool.simpleQuery('SELECT 1')).throws<StateError>();
    });

    test('afterRelease hook resets session state', () async {
      var afterReleaseCalls = 0;
      final pool = PgPool(
        defaultTestConfig,
        minConnections: 1,
        maxConnections: 1,
        afterRelease: (client) async {
          afterReleaseCalls++;
          await client.simpleQuery('DISCARD ALL;');
          return true;
        },
      );

      try {
        // Query 1: set custom search_path or config
        await pool.withClient((client) async {
          await client.simpleQuery("SET timezone = 'America/New_York';");
          final rows = await client.simpleQuery('SHOW timezone;');
          check(rows.first.string('TimeZone')).equals('America/New_York');
        });

        check(afterReleaseCalls).equals(1);

        // Query 2: should receive connection with reset state
        await pool.withClient((client) async {
          final rows = await client.simpleQuery('SHOW timezone;');
          // Default timezone is not America/New_York after DISCARD ALL
          check(
            rows.first.string('TimeZone'),
          ).not((it) => it.equals('America/New_York'));
        });

        check(afterReleaseCalls).equals(2);
      } finally {
        await pool.close();
      }
    });

    test('afterRelease closing connection when returning false', () async {
      final pool = PgPool(
        defaultTestConfig,
        minConnections: 1,
        maxConnections: 1,
        afterRelease: (client) => false, // rejects connection on return
      );

      try {
        await pool.simpleQuery('SELECT 1;');
        check(pool.idleConnections).equals(0);

        // Second query creates fresh connection
        final rows = await pool.simpleQuery('SELECT 2 as num;');
        check(rows.first.int('num')).equals(2);
      } finally {
        await pool.close();
      }
    });

    test('afterRelease closes connection on exception', () async {
      final pool = PgPool(
        defaultTestConfig,
        minConnections: 1,
        maxConnections: 1,
        afterRelease: (client) => throw StateError('release failed'),
      );

      try {
        await pool.simpleQuery('SELECT 1;');
        check(pool.idleConnections).equals(0);

        final rows = await pool.simpleQuery('SELECT 99 as val;');
        check(rows.first.int('val')).equals(99);
      } finally {
        await pool.close();
      }
    });

    test('afterRelease hands connection to waiting waiter', () async {
      var afterReleaseCalls = 0;
      final pool = PgPool(
        defaultTestConfig,
        minConnections: 1,
        maxConnections: 1,
        afterRelease: (client) async {
          afterReleaseCalls++;
          await client.simpleQuery('RESET ALL;');
          return true;
        },
      );

      try {
        final acquired = Completer<void>();
        final lock = Completer<void>();
        // First query holds the only connection
        final f1 = pool.withClient((c) async {
          acquired.complete();
          await lock.future;
          return 1;
        });

        await acquired.future;

        // Second query queues in _waiters
        final f2 = pool.withClient((c) async => 2);
        await Future<void>.delayed(Duration.zero);

        check(pool.inUseConnections).equals(1);
        check(pool.waiterCount).equals(1);

        lock.complete();
        final r1 = await f1;
        final r2 = await f2;

        check(r1).equals(1);
        check(r2).equals(2);
        check(afterReleaseCalls).equals(2);
      } finally {
        await pool.close();
      }
    });

    test('beforeAcquire hook validates and filters connections', () async {
      var beforeAcquireCalls = 0;
      var rejectNext = false;

      final pool = PgPool(
        defaultTestConfig,
        minConnections: 1,
        maxConnections: 1,
        beforeAcquire: (client) async {
          beforeAcquireCalls++;
          if (rejectNext) {
            return false;
          }
          return true;
        },
      );

      try {
        await pool.simpleQuery('SELECT 1;');
        check(beforeAcquireCalls).equals(0);

        // Reusing idle connection calls beforeAcquire
        await pool.simpleQuery('SELECT 2;');
        check(beforeAcquireCalls).equals(1);

        // Now instruct hook to reject next idle connection
        rejectNext = true;
        final rows = await pool.simpleQuery('SELECT 3 as val;');
        check(rows.first.int('val')).equals(3);
        check(beforeAcquireCalls).equals(2);
      } finally {
        await pool.close();
      }
    });

    test('beforeAcquire closes connection when it throws exception', () async {
      var shouldThrow = false;
      final pool = PgPool(
        defaultTestConfig,
        minConnections: 1,
        maxConnections: 1,
        beforeAcquire: (client) {
          if (shouldThrow) throw Exception('validation error');
          return true;
        },
      );

      try {
        await pool.simpleQuery('SELECT 1;');
        shouldThrow = true;
        // Throws during beforeAcquire -> discarded -> creates fresh connection
        final rows = await pool.simpleQuery('SELECT 77 as num;');
        check(rows.first.int('num')).equals(77);
      } finally {
        await pool.close();
      }
    });

    test(
      'healthCheckPeriod only triggers beforeAcquire after threshold',
      () async {
        var beforeAcquireCalls = 0;
        final pool = PgPool(
          defaultTestConfig,
          minConnections: 1,
          maxConnections: 1,
          healthCheckPeriod: const Duration(milliseconds: 100),
          beforeAcquire: (client) {
            beforeAcquireCalls++;
            return true;
          },
        );

        try {
          await pool.simpleQuery('SELECT 1;');
          // Immediate acquire should not trigger beforeAcquire because
          // idle time < 100ms
          await pool.simpleQuery('SELECT 2;');
          check(beforeAcquireCalls).equals(0);

          // Wait past healthCheckPeriod
          await Future<void>.delayed(const Duration(milliseconds: 120));
          await pool.simpleQuery('SELECT 3;');
          check(beforeAcquireCalls).equals(1);
        } finally {
          await pool.close();
        }
      },
    );

    test(
      'healthCheckPeriod performs default ping when beforeAcquire is null',
      () async {
        final pool = PgPool(
          defaultTestConfig,
          minConnections: 1,
          maxConnections: 1,
          healthCheckPeriod: const Duration(milliseconds: 50),
        );

        try {
          await pool.simpleQuery('SELECT 1;');
          await Future<void>.delayed(const Duration(milliseconds: 70));
          // Idle connection pinged via simpleQuery('') and successfully reused
          final rows = await pool.simpleQuery('SELECT 5 as num;');
          check(rows.first.int('num')).equals(5);
        } finally {
          await pool.close();
        }
      },
    );

    test('maxLifetime retires old connections', () async {
      final pool = PgPool(
        defaultTestConfig,
        minConnections: 1,
        maxConnections: 1,
        maxLifetime: const Duration(milliseconds: 50),
      );

      try {
        await pool.simpleQuery('SELECT 1;');
        check(pool.idleConnections).equals(1);

        // Wait past maxLifetime
        await Future<void>.delayed(const Duration(milliseconds: 70));

        // On acquire, expired connection is retired and a new one opened
        final rows = await pool.simpleQuery('SELECT 42 as num;');
        check(rows.first.int('num')).equals(42);
      } finally {
        await pool.close();
      }
    });

    test('validates pool constructor arguments', () {
      check(
        () => PgPool(defaultTestConfig, minConnections: -1),
      ).throws<ArgumentError>();

      check(
        () => PgPool(defaultTestConfig, minConnections: 5, maxConnections: 3),
      ).throws<ArgumentError>();
    });

    test('pool metrics report accurate counts', () async {
      final pool = PgPool(
        defaultTestConfig,
        minConnections: 1,
        maxConnections: 2,
      );

      try {
        check(pool.idleConnections).equals(0);
        check(pool.inUseConnections).equals(0);
        check(pool.totalConnections).equals(0);
        check(pool.waiterCount).equals(0);

        await pool.withClient((client) async {
          check(pool.inUseConnections).equals(1);
          check(pool.idleConnections).equals(0);
          check(pool.totalConnections).equals(1);
        });

        check(pool.idleConnections).equals(1);
        check(pool.inUseConnections).equals(0);
        check(pool.totalConnections).equals(1);
      } finally {
        await pool.close();
      }
    });

    testWithPool(
      'discards dirty connection left in aborted transaction state',
      (pool) async {
        late PgClient dirtyClient;
        await pool.withClient((client) async {
          dirtyClient = client;
          await client.simpleQuery('BEGIN;');
          try {
            await client.simpleQuery('SELECT 1/0;');
          } catch (_) {}
          check(client.transactionStatus).equals(.failed);
        });

        // The old dirty client socket must be closed
        check(dirtyClient.isConnected).isFalse();

        // Next query from the pool succeeds on a fresh connection
        final rows = await pool.simpleQuery('SELECT 42 as num;');
        check(rows.first.int('num')).equals(42);
      },
      minConnections: 0,
      maxConnections: 1,
    );

    testWithPool(
      'discards dirty connection left in active uncommitted transaction',
      (pool) async {
        late PgClient dirtyClient;
        await pool.withClient((client) async {
          dirtyClient = client;
          await client.simpleQuery('BEGIN;');
          check(client.transactionStatus).equals(.inTransaction);
        });

        // The uncommitted transaction connection must be closed
        check(dirtyClient.isConnected).isFalse();

        // Next query from the pool runs cleanly outside any transaction
        final rows = await pool.simpleQuery('SELECT 100 as val;');
        check(rows.first.int('val')).equals(100);
      },
      minConnections: 0,
      maxConnections: 1,
    );

    testWithPool(
      'unblocks waiting requests when a dirty connection is discarded',
      (pool) async {
        final ready = Completer<void>();
        final finishDirty = Completer<void>();

        // First task borrows the only available connection and makes
        // it dirty
        final dirtyTask = pool.withClient((client) async {
          await client.simpleQuery('BEGIN;');
          try {
            await client.simpleQuery('SELECT 1/0;');
          } catch (_) {}
          ready.complete();
          await finishDirty.future;
        });

        await ready.future;

        // Second task queues in _waiters because maxConnections = 1
        final waitingQuery = pool.simpleQuery('SELECT 777 as num;');

        // Complete first task, which discards the dirty connection
        finishDirty.complete();
        await dirtyTask;

        // Waiting query should unblock and succeed on a newly established
        // connection
        final rows = await waitingQuery.timeout(const Duration(seconds: 3));
        check(rows.first.int('num')).equals(777);
      },
      minConnections: 0,
      maxConnections: 1,
    );
  });
}
