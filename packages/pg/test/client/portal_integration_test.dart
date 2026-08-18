@Tags(['integration'])
library;

import 'package:checks/checks.dart';
import 'package:pg/pg.dart';
import 'package:test/scaffolding.dart';

import '../test_utils.dart';

void main() {
  group('PgPortal Integration Tests', () {
    testWithClient(
      'bind and queryPortal batches results with maxRows pagination',
      (client) async {
        await client.transaction((tx) async {
          final stmt = await tx.prepare(
            r'SELECT x FROM generate_series(1, $1) as x',
          );
          final portal = await tx.bind(stmt, [12]);

          final batch1 = await tx.queryPortal(portal, maxRows: 5);
          check(batch1.length).equals(5);
          check(batch1.hasMore).equals(true);
          check(
            batch1.map((r) => r.string('x')).toList(),
          ).deepEquals(['1', '2', '3', '4', '5']);

          final batch2 = await tx.queryPortal(portal, maxRows: 5);
          check(batch2.length).equals(5);
          check(batch2.hasMore).equals(true);
          check(
            batch2.map((r) => r.string('x')).toList(),
          ).deepEquals(['6', '7', '8', '9', '10']);

          final batch3 = await tx.queryPortal(portal, maxRows: 5);
          check(batch3.length).equals(2);
          check(batch3.hasMore).equals(false);
          check(
            batch3.map((r) => r.string('x')).toList(),
          ).deepEquals(['11', '12']);

          await tx.closePortal(portal);
        });
      },
    );

    testWithClient(
      'queryPortalStream streams batches and reports hasMore metadata',
      (client) async {
        await client.transaction((tx) async {
          final stmt = await tx.prepare(
            r'SELECT n FROM generate_series(1, $1) as n',
          );
          final portal = await tx.bind(
            stmt,
            [7],
            name: 'custom_stream_portal',
          );

          final stream1 = await tx.queryPortalStream(portal, maxRows: 4);
          check(stream1.fields.length).equals(1);
          check(stream1.fields.first.name).equals('n');

          final batch1 = await stream1.toList();
          check(batch1.length).equals(4);
          check(await stream1.hasMore).equals(true);
          check(
            batch1.map((r) => r.string('n')).toList(),
          ).deepEquals(['1', '2', '3', '4']);

          final stream2 = await tx.queryPortalStream(portal, maxRows: 4);
          final batch2 = await stream2.toList();
          check(batch2.length).equals(3);
          check(await stream2.hasMore).equals(false);
          check(
            batch2.map((r) => r.string('n')).toList(),
          ).deepEquals(['5', '6', '7']);

          await tx.closePortal(portal);
        });
      },
    );
  });
}
