@Tags(['integration'])
library;

import 'dart:async';

import 'package:checks/checks.dart';
import 'package:pg/pg.dart';
import 'package:test/scaffolding.dart';

import '../test_utils.dart';

void main() {
  group('PgCancelToken Integration Tests', () {
    testWithClient('cancelToken has valid processId and secretKey', (
      client,
    ) async {
      final token = client.cancelToken;
      check(token.processId).isGreaterThan(0);
      check(token.secretKey).not((it) => it.equals(0));
    });

    testWithClient('cancels long running query on the server', (client) async {
      final token = client.cancelToken;

      // Start long query
      final queryFuture = client.simpleQuery('SELECT pg_sleep(3);');

      // Wait a moment for the server to begin executing pg_sleep
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Cancel query out-of-band
      await token.cancel();

      // Query should abort with PostgreSQL error 57014 (query_canceled)
      await check(queryFuture).throws<PgException>(
        (it) => it.has((e) => e.code, 'code').equals('57014'),
      );

      // Connection should still be in ReadyForQuery state and execute
      // subsequent queries.
      final nextRows = await client.simpleQuery('SELECT 42 as num;');
      check(nextRows.length).equals(1);
      check(nextRows.first.int('num')).equals(42);
    });
  });
}
