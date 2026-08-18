@Tags(['integration'])
library;

import 'dart:async';

import 'package:checks/checks.dart';
import 'package:ctx/ctx.dart';
import 'package:pg/pg.dart';
import 'package:test/scaffolding.dart';

import '../test_utils.dart';

void main() {
  group('Context Integration Tests', () {
    testWithClient('cancels simpleQuery when context is canceled', (
      client,
    ) async {
      final (ctx, cancel) = const Context.empty().withCancel();

      final queryFuture = client.simpleQuery('SELECT pg_sleep(3);', ctx: ctx);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      cancel();

      await check(queryFuture).throws<ContextCancelException>();

      // Connection remains healthy for next queries
      final nextRows = await client.simpleQuery('SELECT 42 as num;');
      check(nextRows.length).equals(1);
      check(nextRows.first.int('num')).equals(42);
    });

    testWithClient('cancels parameterized query when context times out', (
      client,
    ) async {
      final (ctx, cancel) = const Context.empty().withTimeout(
        const Duration(milliseconds: 50),
      );

      final queryFuture = client.query(
        r'SELECT pg_sleep($1::int)',
        [3],
        ctx: ctx,
      );

      await check(queryFuture).throws<ContextTimeoutException>();
      cancel();

      final nextRows = await client.query(r'SELECT $1::int as num', [100]);
      check(nextRows.length).equals(1);
      check(nextRows.first.int('num')).equals(100);
    });

    testWithClient('fails fast when context is already canceled', (
      client,
    ) async {
      final (ctx, cancel) = const Context.empty().withCancel();
      cancel();

      check(
        () => client.simpleQuery('SELECT 1', ctx: ctx),
      ).throws<ContextCancelException>();

      check(
        () => client.query('SELECT 1', const [], ctx: ctx),
      ).throws<ContextCancelException>();

      final rows = await client.simpleQuery('SELECT 1 as val');
      check(rows.first.int('val')).equals(1);
    });

    testWithClient(
      'implicitly uses Context.current from Zone',
      (client) async {
        final (ctx, cancel) = const Context.empty().withTimeout(
          const Duration(milliseconds: 50),
        );

        await ctx.run(() async {
          final queryFuture = client.simpleQuery('SELECT pg_sleep(3);');
          await check(queryFuture).throws<ContextTimeoutException>();
        });
        cancel();

        final nextRows = await client.simpleQuery('SELECT 7 as lucky;');
        check(nextRows.first.int('lucky')).equals(7);
      },
    );

    testWithClient('cancels queryStream when context is canceled', (
      client,
    ) async {
      final (ctx, cancel) = const Context.empty().withCancel();

      final streamFuture = client.queryStream(
        'SELECT pg_sleep(3);',
        const [],
        ctx: ctx,
      );

      // Cancel while queryStream is in-flight
      await Future<void>.delayed(const Duration(milliseconds: 50));
      cancel();

      await check(streamFuture).throws<ContextCancelException>();

      final nextRows = await client.simpleQuery('SELECT 99 as val;');
      check(nextRows.first.int('val')).equals(99);
    });
  });

  group('PgPool Context Integration Tests', () {
    testWithPool('fails fast when context is already canceled', (pool) async {
      final (ctx, cancel) = const Context.empty().withCancel();
      cancel();

      await check(
        pool.simpleQuery('SELECT 1', ctx: ctx),
      ).throws<ContextCancelException>();

      await check(
        pool.query('SELECT 1', const [], ctx: ctx),
      ).throws<ContextCancelException>();

      await check(
        pool.withClient((c) => c.simpleQuery('SELECT 1'), ctx: ctx),
      ).throws<ContextCancelException>();

      final rows = await pool.simpleQuery('SELECT 1 as val');
      check(rows.first.int('val')).equals(1);
    });

    testWithPool(
      'cancels waiter in queue when context times out while pool is saturated',
      (pool) async {
        final (busyCtx, cancelBusy) = const Context.empty().withCancel();

        // Occupy all available connections (maxConnections: 1)
        final busyQuery = pool.simpleQuery('SELECT pg_sleep(3);', ctx: busyCtx);
        await Future<void>.delayed(const Duration(milliseconds: 50));

        // Queue second query with short timeout
        final (timeoutCtx, cancelTimeout) = const Context.empty().withTimeout(
          const Duration(milliseconds: 100),
        );
        final queuedQuery = pool.simpleQuery('SELECT 2;', ctx: timeoutCtx);

        await check(queuedQuery).throws<ContextTimeoutException>();
        cancelTimeout();

        // Cancel the busy query to release connection
        cancelBusy();
        await check(busyQuery).throws<ContextCancelException>();

        // Verify pool still operates smoothly
        final healthyRows = await pool.simpleQuery('SELECT 42 as num;');
        check(healthyRows.first.int('num')).equals(42);
      },
      maxConnections: 1,
    );

    testWithPool(
      'releases connection to next active waiter when earlier waiter was '
      'canceled',
      (pool) async {
        final (busyCtx, cancelBusy) = const Context.empty().withCancel();

        // Occupy connection
        final busyQuery = pool.simpleQuery(
          'SELECT pg_sleep(3);',
          ctx: busyCtx,
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));

        // Waiter 1 (will cancel)
        final (w1Ctx, cancelW1) = const Context.empty().withTimeout(
          const Duration(milliseconds: 50),
        );
        final waiter1 = pool.simpleQuery('SELECT 101;', ctx: w1Ctx);

        // Waiter 2 (stays active)
        final waiter2 = pool.simpleQuery('SELECT 202 as res;');

        // Wait for Waiter 1 to timeout
        await check(waiter1).throws<ContextTimeoutException>();
        cancelW1();

        // Cancel busy query -> connection should go to Waiter 2
        cancelBusy();
        await check(busyQuery).throws<ContextCancelException>();

        final w2Rows = await waiter2;
        check(w2Rows.first.int('res')).equals(202);
      },
      maxConnections: 1,
    );
  });
}
