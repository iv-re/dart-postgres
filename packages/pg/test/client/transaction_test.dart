@Tags(['integration'])
library;

import 'dart:async';

import 'package:checks/checks.dart';
import 'package:pg/pg.dart';
import 'package:test/scaffolding.dart';

import '../test_utils.dart';

void main() {
  group('PgTransaction', () {
    testWithClient('commits transaction block successfully', (client) async {
      await client.simpleQuery('CREATE TEMP TABLE test_tx (id int, val text);');

      final res = await client.transaction((tx) async {
        await tx.query(r'INSERT INTO test_tx VALUES ($1, $2)', [1, 'first']);
        return 'success';
      });

      check(res).equals('success');

      final rows = await client.simpleQuery('SELECT * FROM test_tx;');
      check(rows.length).equals(1);
      check(rows[0].string('val')).equals('first');
    });

    testWithClient('rolls back transaction on error and rethrows', (
      client,
    ) async {
      await client.simpleQuery('CREATE TEMP TABLE test_tx (id int, val text);');

      await check(
        client.transaction((tx) async {
          await tx.query(
            r'INSERT INTO test_tx VALUES ($1, $2)',
            [2, 'error'],
          );
          throw StateError('something went wrong');
        }),
      ).throws<StateError>();

      final rows = await client.simpleQuery('SELECT * FROM test_tx;');
      check(rows.length).equals(0);
    });

    testWithClient('nested transaction commits inner and outer', (
      client,
    ) async {
      await client.simpleQuery('CREATE TEMP TABLE test_tx (id int, val text);');

      await client.transaction((tx) async {
        await tx.query(r'INSERT INTO test_tx VALUES ($1, $2)', [1, 'outer']);

        await tx.transaction((nested) async {
          await nested.query(
            r'INSERT INTO test_tx VALUES ($1, $2)',
            [2, 'inner'],
          );
        });
      });

      final rows = await client.simpleQuery(
        'SELECT * FROM test_tx ORDER BY id;',
      );
      check(rows.length).equals(2);
      check(rows[0].string('val')).equals('outer');
      check(rows[1].string('val')).equals('inner');
    });

    testWithClient(
      'nested transaction rollback only discards inner savepoint',
      (client) async {
        await client.simpleQuery(
          'CREATE TEMP TABLE test_tx (id int, val text);',
        );

        await client.transaction((tx) async {
          await tx.query(r'INSERT INTO test_tx VALUES ($1, $2)', [1, 'outer']);

          try {
            await tx.transaction((nested) async {
              await nested.query(
                r'INSERT INTO test_tx VALUES ($1, $2)',
                [2, 'inner_fail'],
              );
              throw const FormatException('inner abort');
            });
          } catch (_) {}
        });

        final rows = await client.simpleQuery('SELECT * FROM test_tx;');
        check(rows.length).equals(1);
        check(rows[0].string('val')).equals('outer');
      },
    );

    testWithClient('supports isolationLevel in transaction block', (
      client,
    ) async {
      await client.transaction((tx) async {
        final rows = await tx.simpleQuery('SHOW transaction_isolation;');
        check(rows.first.string('transaction_isolation'))
            .equals('serializable');
      }, isolationLevel: .serializable);

      await client.transaction((tx) async {
        final rows = await tx.simpleQuery('SHOW transaction_isolation;');
        check(
          rows.first.string('transaction_isolation'),
        ).equals('repeatable read');
      }, isolationLevel: .repeatableRead);
    });

    testWithClient('enforces readOnly transaction mode', (client) async {
      await client.simpleQuery('DROP TABLE IF EXISTS test_tx_readonly_perm;');
      await client.simpleQuery(
        'CREATE TABLE test_tx_readonly_perm (id int);',
      );

      try {
        await client.transaction((tx) async {
          final rows = await tx.simpleQuery('SHOW transaction_read_only;');
          check(rows.first.string('transaction_read_only')).equals('on');
        }, readOnly: true);

        PgException? caught;
        try {
          await client.transaction((tx) async {
            await tx.query(
              r'INSERT INTO test_tx_readonly_perm VALUES ($1)',
              [1],
            );
          }, readOnly: true);
        } on PgException catch (e) {
          caught = e;
        }

        check(caught).isNotNull();
        check(caught!.code).equals('25006'); // read_only_sql_transaction
      } finally {
        await client.simpleQuery('DROP TABLE IF EXISTS test_tx_readonly_perm;');
      }
    });

    testWithClient(
      'supports deferrable read-only serializable transaction',
      (client) async {
        final res = await client.transaction(
          (tx) async {
            final rows = await tx.simpleQuery('SELECT 100 as num;');
            return rows.first.int('num');
          },
          isolationLevel: .serializable,
          readOnly: true,
          deferrable: true,
        );

        check(res).equals(100);
      },
    );

    testWithClient('tracks transactionStatus states', (client) async {
      check(client.transactionStatus).equals(.idle);

      await client.transaction((tx) async {
        check(client.transactionStatus).equals(.inTransaction);
        check(tx.status).equals(.inTransaction);

        // Trigger a query error inside transaction
        try {
          await tx.simpleQuery('SELECT * FROM non_existing_table_xyz;');
        } catch (_) {}

        // Server marked transaction as failed ('E')
        check(client.transactionStatus).equals(.failed);
        check(tx.status).equals(.failed);
      });

      // After rollback, connection is cleanly back to idle ('I')
      check(client.transactionStatus).equals(.idle);
    });

    testWithPool('supports isolation options via PgPool.transaction', (
      pool,
    ) async {
      final res = await pool.transaction(
        (tx) async {
          final rows = await tx.simpleQuery('SHOW transaction_isolation;');
          return rows.first.string('transaction_isolation');
        },
        isolationLevel: .serializable,
      );

      check(res).equals('serializable');
    });

    testWithClient('manual savepoint, rollback, and release', (client) async {
      await client.simpleQuery('CREATE TEMP TABLE test_tx (id int, val text);');

      final tx = PgTransaction(client);
      await tx.begin();

      await tx.query(r'INSERT INTO test_tx VALUES ($1, $2)', [10, 'base']);
      await tx.savepoint('sp1');

      await tx.query(r'INSERT INTO test_tx VALUES ($1, $2)', [20, 'extra']);
      await tx.rollbackToSavepoint('sp1');

      await tx.commit();

      final rows = await client.simpleQuery('SELECT * FROM test_tx;');
      check(rows.length).equals(1);
      check(rows[0].string('val')).equals('base');
    });

    testWithClient(
      'throws StateError when calling queries on completed transaction',
      (client) async {
        final tx = PgTransaction(client);
        await tx.begin();
        await tx.commit();

        check(() => tx.simpleQuery('SELECT 1;')).throws<StateError>();
      },
    );

    test('PgTransactionStatus correctly decodes codes', () {
      check(PgTransactionStatus.fromCode(0x49)).equals(.idle);
      check(PgTransactionStatus.fromCode(0x54)).equals(.inTransaction);
      check(PgTransactionStatus.fromCode(0x45)).equals(.failed);
      check(PgTransactionStatus.fromCode(0x00)).equals(.idle);
    });

    testWithClient('manual tx.begin supports isolationLevel and options', (
      client,
    ) async {
      final tx = PgTransaction(client);
      await tx.begin(
        isolationLevel: .repeatableRead,
        readOnly: true,
        deferrable: true,
      );

      final isoRows = await tx.simpleQuery('SHOW transaction_isolation;');
      check(
        isoRows.first.string('transaction_isolation'),
      ).equals('repeatable read');

      final roRows = await tx.simpleQuery('SHOW transaction_read_only;');
      check(roRows.first.string('transaction_read_only')).equals('on');

      check(tx.status).equals(.inTransaction);
      await tx.commit();

      check(tx.status).equals(.idle);
      check(client.transactionStatus).equals(.idle);
    });

    testWithClient(
      'supports polymorphic transaction execution on PgExecutor',
      (client) async {
        await client.simpleQuery(
          'CREATE TEMP TABLE test_tx (id int, val text);',
        );

        Future<void> runInTx(PgExecutor executor, int id, String val) async {
          await executor.transaction((tx) async {
            await tx.query(r'INSERT INTO test_tx VALUES ($1, $2)', [id, val]);
          });
        }

        final PgExecutor executor = client;
        await runInTx(executor, 999, 'poly');

        final rows = await client.simpleQuery(
          'SELECT * FROM test_tx WHERE id = 999;',
        );
        check(rows.length).equals(1);
        check(rows.first.string('val')).equals('poly');
      },
    );
  });
}
