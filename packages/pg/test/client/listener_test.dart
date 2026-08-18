@Tags(['integration'])
library;

import 'dart:async';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:pg/pg.dart';
import 'package:test/scaffolding.dart';

void main() {
  group('PgListener', () {
    late PgConfig config;

    setUp(() {
      final env = Platform.environment;
      final host = env['PGHOST'] ?? 'localhost';
      final port = int.tryParse(env['PGPORT'] ?? '5432') ?? 5432;
      final user = env['PGUSER'] ?? 'postgres';
      final password = env['PGPASSWORD'] ?? 'postgres';
      final database = env['PGDATABASE'] ?? 'postgres';

      config = PgConfig(
        host: host,
        port: port,
        user: user,
        password: password,
        database: database,
      );
    });

    test('subscribes and receives notifications via stream', () async {
      final listener = await PgListener.connect(
        config,
        channels: ['channel_a'],
      );

      final notifier = await PgClient.connect(config);

      try {
        check(listener.isConnected).isTrue();
        check(listener.isListening('channel_a')).isTrue();
        check(listener.channels).deepEquals({'channel_a'});

        final received = <PgNotification>[];
        final sub = listener.stream.listen(received.add);

        // Send a notification from another connection
        await notifier.simpleQuery("NOTIFY channel_a, 'hello world';");

        // Wait briefly for socket delivery
        await Future<void>.delayed(const Duration(milliseconds: 100));

        check(received.length).equals(1);
        check(received.first.channel).equals('channel_a');
        check(received.first.payload).equals('hello world');

        await sub.cancel();
      } finally {
        await notifier.close();
        await listener.close();
      }
    });

    test(
      'broadcast stream supports multiple concurrent subscribers',
      () async {
        final listener = await PgListener.connect(
          config,
          channels: ['broadcast_ch'],
        );
        final notifier = await PgClient.connect(config);

        try {
          final received1 = <String>[];
          final received2 = <String>[];

          final sub1 = listener.stream.listen((n) => received1.add(n.payload));
          final sub2 = listener.stream.listen((n) => received2.add(n.payload));

          await notifier.simpleQuery("NOTIFY broadcast_ch, 'payload_123';");
          await Future<void>.delayed(const Duration(milliseconds: 100));

          check(received1).deepEquals(['payload_123']);
          check(received2).deepEquals(['payload_123']);

          await sub1.cancel();
          await sub2.cancel();
        } finally {
          await notifier.close();
          await listener.close();
        }
      },
    );

    test(
      'dynamically manages subscriptions (listen, unlisten, unlistenAll)',
      () async {
        final listener = await PgListener.connect(config);
        final notifier = await PgClient.connect(config);

        try {
          check(listener.channels).isEmpty();

          await listener.listen('dyn_1');
          // Idempotent duplicate listen
          await listener.listen('dyn_1');
          await listener.listenAll(['dyn_2', 'dyn_3']);

          check(listener.isListening('dyn_1')).isTrue();
          check(listener.isListening('dyn_2')).isTrue();
          check(listener.isListening('dyn_3')).isTrue();
          check(listener.channels).deepEquals({'dyn_1', 'dyn_2', 'dyn_3'});

          final received = <String>[];
          final sub = listener.stream.listen((n) => received.add(n.channel));

          await notifier.simpleQuery("NOTIFY dyn_1, '1';");
          await notifier.simpleQuery("NOTIFY dyn_2, '2';");
          await Future<void>.delayed(const Duration(milliseconds: 100));

          check(received).deepEquals(['dyn_1', 'dyn_2']);

          // Unlisten single channel
          await listener.unlisten('dyn_1');
          // Idempotent unlisten
          await listener.unlisten('dyn_1');
          check(listener.isListening('dyn_1')).isFalse();
          check(listener.channels).deepEquals({'dyn_2', 'dyn_3'});

          await notifier.simpleQuery("NOTIFY dyn_1, 'ignored';");
          await notifier.simpleQuery("NOTIFY dyn_3, '3';");
          await Future<void>.delayed(const Duration(milliseconds: 100));

          check(received).deepEquals(['dyn_1', 'dyn_2', 'dyn_3']);

          // Unlisten all
          await listener.unlistenAll();
          check(listener.channels).isEmpty();

          await notifier.simpleQuery("NOTIFY dyn_3, 'ignored';");
          await Future<void>.delayed(const Duration(milliseconds: 100));

          check(received.length).equals(3);

          await sub.cancel();
        } finally {
          await notifier.close();
          await listener.close();
        }
      },
    );

    test('handles channel names with identifiers escaping', () async {
      final listener = await PgListener.connect(
        config,
        channels: ['user.event_log', 'order-items'],
      );
      final notifier = await PgClient.connect(config);

      try {
        check(listener.isListening('user.event_log')).isTrue();
        check(listener.isListening('order-items')).isTrue();

        final received = <String>[];
        final sub = listener.stream.listen((n) => received.add(n.channel));

        await notifier.simpleQuery('NOTIFY "user.event_log", \'data\';');
        await notifier.simpleQuery('NOTIFY "order-items", \'data\';');
        await Future<void>.delayed(const Duration(milliseconds: 100));

        check(received).deepEquals(['user.event_log', 'order-items']);

        await sub.cancel();
      } finally {
        await notifier.close();
        await listener.close();
      }
    });

    test(
      'reconnects and restores active subscriptions after disconnect',
      () async {
        final listener = await PgListener.connect(
          config,
          channels: ['reconnect_ch'],
          reconnectDelay: const Duration(milliseconds: 50),
        );
        final notifier = await PgClient.connect(config);

        try {
          final received = <String>[];
          final sub = listener.stream.listen((n) => received.add(n.payload));

          await notifier.simpleQuery("NOTIFY reconnect_ch, 'before_drop';");
          await Future<void>.delayed(const Duration(milliseconds: 100));
          check(received).deepEquals(['before_drop']);

          // Terminate backend connection using pg_terminate_backend or
          // closing underlying socket
          final clientPid = await notifier.simpleQuery(
            "SELECT pid FROM pg_stat_activity WHERE application_name = '' "
            'AND pid <> pg_backend_pid() ORDER BY backend_start DESC LIMIT 1;',
          );

          if (clientPid.isNotEmpty) {
            final pid = clientPid.first.int('pid');
            await notifier.simpleQuery('SELECT pg_terminate_backend($pid);');
          }

          // Wait for reconnect loop to re-establish connection and re-subscribe
          await Future<void>.delayed(const Duration(milliseconds: 400));

          check(listener.isClosed).isFalse();

          // Send notification after reconnect
          await notifier.simpleQuery("NOTIFY reconnect_ch, 'after_reconnect';");
          await Future<void>.delayed(const Duration(milliseconds: 100));

          check(received).contains('after_reconnect');

          await sub.cancel();
        } finally {
          await notifier.close();
          await listener.close();
        }
      },
    );

    test(
      'close terminates listener stream and throws on further operations',
      () async {
        final listener = await PgListener.connect(
          config,
          channels: ['close_ch'],
        );

        final doneCompleter = Completer<void>();
        listener.stream.listen(
          (_) {},
          onDone: doneCompleter.complete,
        );

        check(listener.isConnected).isTrue();
        await listener.close();
        // Idempotent duplicate close
        await listener.close();

        check(listener.isClosed).isTrue();
        check(listener.isConnected).isFalse();
        check(listener.channels).isEmpty();
        await check(doneCompleter.future).completes();

        await check(listener.listen('other')).throws<StateError>();
        await check(listener.unlisten('close_ch')).throws<StateError>();
        await check(listener.unlistenAll()).throws<StateError>();
      },
    );
  });
}
