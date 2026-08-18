@Tags(['integration'])
library;

import 'dart:async';

import 'package:checks/checks.dart';
import 'package:pg/pg.dart';
import 'package:test/scaffolding.dart';

import '../test_utils.dart';

void main() {
  group('LISTEN / NOTIFY Integration Tests', () {
    testWithClient(
      'delivers notification with payload from separate client',
      (listener) async {
        await withClient((notifier) async {
          await listener.simpleQuery('LISTEN test_events;');

          final notificationFuture = listener.notifications.first;

          await notifier.simpleQuery(
            "NOTIFY test_events, 'user_signed_up';",
          );

          final notification = await notificationFuture;
          check(notification.channel).equals('test_events');
          check(notification.payload).equals('user_signed_up');
          check(notification.processId).isGreaterThan(0);
        });
      },
    );

    testWithClient(
      'stops receiving notifications after UNLISTEN',
      (listener) async {
        await withClient((notifier) async {
          await listener.simpleQuery('LISTEN test_channel_unlisten;');

          final received = <PgNotification>[];
          final sub = listener.notifications.listen(received.add);

          await notifier.simpleQuery("NOTIFY test_channel_unlisten, 'msg1';");
          await Future<void>.delayed(const Duration(milliseconds: 100));

          check(received.length).equals(1);
          check(received.first.payload).equals('msg1');

          await listener.simpleQuery('UNLISTEN test_channel_unlisten;');

          await notifier.simpleQuery("NOTIFY test_channel_unlisten, 'msg2';");
          await Future<void>.delayed(const Duration(milliseconds: 100));

          check(received.length).equals(1);

          await sub.cancel();
        });
      },
    );

    testWithClient(
      'delivers notifications arriving during active query execution',
      (listener) async {
        await withClient((notifier) async {
          await listener.simpleQuery('LISTEN test_channel_concurrent;');

          final received = <PgNotification>[];
          final sub = listener.notifications.listen(received.add);

          // Start a query on listener that takes a short time
          final queryFuture = listener.simpleQuery(
            'SELECT count(*)::int as c FROM generate_series(1, 5000);',
          );

          // Concurrently send notification from another client
          await notifier.simpleQuery(
            "NOTIFY test_channel_concurrent, 'concurrent_payload';",
          );

          final rows = await queryFuture;
          check(rows.first.int('c')).equals(5000);

          // Wait a brief moment for notification to arrive if not yet delivered
          await Future<void>.delayed(const Duration(milliseconds: 50));

          check(received.length).equals(1);
          check(received.first.channel).equals('test_channel_concurrent');
          check(received.first.payload).equals('concurrent_payload');

          await sub.cancel();
        });
      },
    );
  });
}
