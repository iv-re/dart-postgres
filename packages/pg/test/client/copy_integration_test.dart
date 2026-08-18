@Tags(['integration'])
library;

import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:pg/pg.dart';
import 'package:test/scaffolding.dart';

import '../test_utils.dart';

void main() {
  group('COPY Integration Tests', () {
    testWithClient(
      'copyIn streams TSV data into table and returns affected rows',
      (client) async {
        await client.simpleQuery('''
          CREATE TEMP TABLE copy_test_table (
            id INT,
            name TEXT,
            score FLOAT8
          );
        ''');

        final sink = await client.copyIn(
          'COPY copy_test_table (id, name, score) '
          'FROM STDIN WITH (FORMAT text)',
        );

        sink.add(utf8.encode('1\tAlice\t95.5\n'));
        sink.add(utf8.encode('2\tBob\t88.0\n'));
        sink.add(utf8.encode('3\tCharlie\t72.3\n'));

        final affectedRows = await sink.finish();
        check(affectedRows).equals(3);

        final rows = await client.simpleQuery(
          'SELECT * FROM copy_test_table ORDER BY id;',
        );
        check(rows.length).equals(3);
        check(rows[0].string('name')).equals('Alice');
        check(rows[1].string('name')).equals('Bob');
        check(rows[2].string('name')).equals('Charlie');
      },
    );

    testWithClient(
      'copyOut streams table data as bytes from STDOUT',
      (client) async {
        await client.simpleQuery('''
          CREATE TEMP TABLE copy_test_table (
            id INT,
            name TEXT,
            score FLOAT8
          );
        ''');

        // Seed data
        await client.query(
          'INSERT INTO copy_test_table '
          r'VALUES (10, $1, 100.0), (20, $2, 50.0);',
          ['Row1', 'Row2'],
        );

        final copyOutStream = await client.copyOut(
          'COPY copy_test_table (id, name) '
          'TO STDOUT WITH (FORMAT csv, HEADER false)',
        );

        final chunks = await copyOutStream.toList();

        final combined = utf8.decode(chunks.expand((c) => c).toList());
        check(combined).contains('10,Row1');
        check(combined).contains('20,Row2');
        check(await copyOutStream.commandTag).equals('COPY 2');
      },
    );

    testWithClient(
      'copyIn streams chunks via sink.addStream and completes',
      (client) async {
        await client.simpleQuery('''
          CREATE TEMP TABLE copy_stream_table (id INT, val TEXT);
        ''');

        final sink = await client.copyIn(
          'COPY copy_stream_table (id, val) FROM STDIN WITH (FORMAT text)',
        );

        final byteChunks = Stream.fromIterable([
          utf8.encode('10\tfirst\n'),
          utf8.encode('20\tsecond\n'),
          utf8.encode('30\tthird\n'),
        ]);

        await sink.addStream(byteChunks);
        final affectedRows = await sink.finish();
        check(affectedRows).equals(3);

        final rows = await client.simpleQuery(
          'SELECT count(*)::int as cnt FROM copy_stream_table;',
        );
        check(rows.first.int('cnt')).equals(3);
      },
    );

    testWithClient(
      'copyIn abort resets server state and client remains usable',
      (client) async {
        await client.simpleQuery('''
          CREATE TEMP TABLE copy_abort_table (id INT, val TEXT);
        ''');

        final sink = await client.copyIn(
          'COPY copy_abort_table (id, val) FROM STDIN WITH (FORMAT text)',
        );

        sink.add(utf8.encode('1\tpartial\n'));

        // Abort copy operation
        await check(
          sink.abort('client canceled copy operation'),
        ).throws<PgException>();

        // Verify table is empty (copy aborted)
        final rows = await client.simpleQuery(
          'SELECT count(*)::int as cnt FROM copy_abort_table;',
        );
        check(rows.first.int('cnt')).equals(0);

        // Verify client executes regular queries cleanly after copy abort
        final probe = await client.simpleQuery('SELECT 100 as ok;');
        check(probe.first.int('ok')).equals(100);
      },
    );
  });
}
