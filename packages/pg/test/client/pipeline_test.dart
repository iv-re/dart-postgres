@Tags(['integration'])
library;

import 'dart:async';

import 'package:checks/checks.dart';
import 'package:pg/pg.dart';
import 'package:test/scaffolding.dart';

import '../test_utils.dart';

void main() {
  group('PgPipeline Integration', () {
    testWithClient('empty pipeline returns empty list', (client) async {
      final results = await client.pipeline((p) {});
      check(results).isEmpty();
    });

    testWithClient(
      'executes batch of multiple queries in single pipeline',
      (client) async {
        final results = await client.pipeline((p) {
          p.query('SELECT 1 as a;');
          p.query('SELECT 2 as b;');
          p.query('SELECT 3 as c;');
        });

        check(results.length).equals(3);
        check(results[0][0].string('a')).equals('1');
        check(results[1][0].string('b')).equals('2');
        check(results[2][0].string('c')).equals('3');
      },
    );

    testWithClient(
      'executes parameterized queries in pipeline',
      (client) async {
        final results = await client.pipeline((p) {
          p.query(r'SELECT $1::int as num', [42]);
          p.query(r'SELECT $1::text as msg', ['hello pipeline']);
        });

        check(results.length).equals(2);
        check(results[0][0].string('num')).equals('42');
        check(results[1][0].string('msg')).equals('hello pipeline');
      },
    );

    testWithClient(
      'individual item futures complete properly',
      (client) async {
        late Future<PgRows> f1;
        late Future<PgRows> f2;

        await client.pipeline((p) {
          f1 = p.query('SELECT 100 as x');
          f2 = p.query('SELECT 200 as y');
        });

        final r1 = await f1;
        final r2 = await f2;

        check(r1[0].string('x')).equals('100');
        check(r2[0].string('y')).equals('200');
      },
    );

    testWithPool('executes pipeline via PgPool', (pool) async {
      final results = await pool.pipeline((p) {
        p.query('SELECT 10 as v;');
        p.query('SELECT 20 as v;');
      });

      check(results.length).equals(2);
      check(results[0][0].string('v')).equals('10');
      check(results[1][0].string('v')).equals('20');
    });

    testWithClient(
      'executes pipeline inside transaction',
      (client) async {
        await client.simpleQuery(
          'CREATE TEMP TABLE test_pipe_tx (id int, val text);',
        );

        await client.transaction((tx) async {
          await tx.pipeline((p) {
            p.query(r'INSERT INTO test_pipe_tx VALUES ($1, $2)', [1, 'one']);
            p.query(r'INSERT INTO test_pipe_tx VALUES ($1, $2)', [2, 'two']);
          });
        });

        final rows = await client.simpleQuery(
          'SELECT * FROM test_pipe_tx ORDER BY id;',
        );
        check(rows.length).equals(2);
        check(rows[0].string('val')).equals('one');
        check(rows[1].string('val')).equals('two');
      },
    );

    testWithClient('handles error in pipelined query', (client) async {
      await check(
        client.pipeline((p) {
          p.query('SELECT 1');
          p.query('SELECT * FROM non_existing_table_xyz');
          p.query('SELECT 2');
        }),
      ).throws<PgException>();
    });
  });
}
