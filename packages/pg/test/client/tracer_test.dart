@Tags(['integration'])
library;

import 'dart:async';

import 'package:checks/checks.dart';
import 'package:ctx/ctx.dart';
import 'package:pg/pg.dart';
import 'package:sl/sl.dart';
import 'package:test/scaffolding.dart';

import '../test_utils.dart';

class _TestTracer implements PgTracer {
  final List<PgQueryTrace> queryTraces = [];
  final List<PgNotice> notices = [];
  final List<(PgEndpoint, Duration, Object?)> connectTraces = [];

  @override
  void onQuery(PgQueryTrace trace) {
    queryTraces.add(trace);
  }

  @override
  void onNotice(PgNotice notice) {
    notices.add(notice);
  }

  @override
  void onConnect(PgEndpoint endpoint, Duration duration, {Object? error}) {
    connectTraces.add((endpoint, duration, error));
  }
}

class _MemoryLogHandler implements LogHandler {
  final List<LogRecord> records = [];

  @override
  bool enabled(Context ctx, LogLevel level) => true;

  @override
  void handle(Context ctx, LogRecord record) {
    records.add(record);
  }

  @override
  LogHandler withAttrs(List<LogAttr> attrs) => this;

  @override
  LogHandler withGroup(String name) => this;
}

void main() {
  group('PgTracer Integration', () {
    test('traces simpleQuery and query execution with metrics', () async {
      final tracer = _TestTracer();
      final config = defaultTestConfig.copyWithTracer(tracer);

      await withClient(
        (client) async {
          // simpleQuery
          final rows = await client.simpleQuery('SELECT 1 as num;');
          check(rows.first.int('num')).equals(1);

          check(tracer.queryTraces.length).equals(1);
          final trace1 = tracer.queryTraces.first;
          check(trace1.sql).equals('SELECT 1 as num;');
          check(trace1.params).isEmpty();
          check(trace1.commandTag).equals('SELECT 1');
          check(trace1.duration.inMicroseconds).isGreaterThan(0);
          check(trace1.error).isNull();

          // parameterized query
          final paramRows = await client.query(
            r'SELECT $1::int + $2::int as total',
            [10, 20],
          );
          check(paramRows.first.int('total')).equals(30);

          check(tracer.queryTraces.length).equals(2);
          final trace2 = tracer.queryTraces[1];
          check(trace2.sql).equals(r'SELECT $1::int + $2::int as total');
          check(trace2.params.length).equals(2);
          check(trace2.params[0]).equals(10);
          check(trace2.params[1]).equals(20);
          check(trace2.commandTag).equals('SELECT 1');
          check(trace2.duration.inMicroseconds).isGreaterThan(0);
          check(trace2.error).isNull();
        },
        config: config,
      );

      // Verify onConnect was traced
      check(tracer.connectTraces.isNotEmpty).equals(true);
      check(tracer.connectTraces.first.$2.inMicroseconds).isGreaterThan(0);
    });

    test('traces query errors with exception details', () async {
      final tracer = _TestTracer();
      final config = defaultTestConfig.copyWithTracer(tracer);

      await withClient(
        (client) async {
          await check(
            client.simpleQuery('SELECT * FROM non_existent_table_xyz_404;'),
          ).throws<PgException>();

          check(tracer.queryTraces.length).equals(1);
          final trace = tracer.queryTraces.first;
          check(trace.sql).equals(
            'SELECT * FROM non_existent_table_xyz_404;',
          );
          check(trace.isError).equals(true);
          check(trace.error).isNotNull();
        },
        config: config,
      );
    });

    test('traces queryStream and captures full stream duration', () async {
      final tracer = _TestTracer();
      final config = defaultTestConfig.copyWithTracer(tracer);

      await withClient(
        (client) async {
          final stream = await client.queryStream(
            'SELECT generate_series(1, 5) as s;',
            const [],
          );
          final list = await stream.toList();
          check(list.length).equals(5);

          // Allow stream completion to trace
          await Future<void>.delayed(const Duration(milliseconds: 20));

          check(tracer.queryTraces.length).equals(1);
          final trace = tracer.queryTraces.first;
          check(trace.sql).equals('SELECT generate_series(1, 5) as s;');
          check(trace.commandTag).equals('SELECT 5');
          check(trace.duration.inMicroseconds).isGreaterThan(0);
          check(trace.error).isNull();
        },
        config: config,
      );
    });

    test('traces server notices (RAISE NOTICE)', () async {
      final tracer = _TestTracer();
      final config = defaultTestConfig.copyWithTracer(tracer);

      await withClient(
        (client) async {
          await client.simpleQuery(r'''
            DO $$
            BEGIN
              RAISE NOTICE 'test server warning from db';
            END
            $$;
          ''');

          check(tracer.notices.length).equals(1);
          final notice = tracer.notices.first;
          check(notice.severity).equals('NOTICE');
          check(notice.message).contains('test server warning from db');
        },
        config: config,
      );
    });

    test('traces queries executed via PgPool', () async {
      final tracer = _TestTracer();
      final config = defaultTestConfig.copyWithTracer(tracer);

      await withPool(
        (pool) async {
          final rows = await pool.simpleQuery('SELECT 99 as val;');
          check(rows.first.int('val')).equals(99);

          check(tracer.queryTraces.isNotEmpty).equals(true);
          final trace = tracer.queryTraces.last;
          check(trace.sql).equals('SELECT 99 as val;');
          check(trace.commandTag).equals('SELECT 1');
        },
        config: config,
      );
    });
  });

  group('PgLogger Integration with package:sl', () {
    test('logs queries, slow queries, notices, and errors to Logger', () async {
      final handler = _MemoryLogHandler();
      final logger = Logger(handler: handler);
      final tracer = PgLogger(
        logger,
        slowThreshold: const Duration(milliseconds: 50),
      );
      final config = defaultTestConfig.copyWithTracer(tracer);

      await withClient(
        (client) async {
          // 1. Normal fast query -> DEBUG
          await client.simpleQuery('SELECT 1 as num;');
          final normalRecord = handler.records.firstWhere(
            (r) => r.level == .debug && r.message.contains('query'),
          );
          check(normalRecord.attrs.length).equals(1);
          check(normalRecord.attrs.first.key).equals('db');
          check(normalRecord.attrs.first).isA<LogGroupAttr>();

          // 2. Slow query (>50ms) -> WARN
          await client.simpleQuery('SELECT pg_sleep(0.08);');
          check(
            handler.records.any(
              (r) => r.level == .warn && r.message.contains('slow query'),
            ),
          ).equals(true);

          // 3. Notice -> INFO / WARN
          await client.simpleQuery(r'''
            DO $$
            BEGIN
              RAISE NOTICE 'sl notice check';
            END
            $$;
          ''');
          check(
            handler.records.any((r) => r.message.contains('server notice')),
          ).equals(true);

          // 4. Error -> ERROR
          await check(
            client.simpleQuery('SELECT * FROM non_existent_table_abc_123;'),
          ).throws<PgException>();
          check(
            handler.records.any(
              (r) => r.level == .error && r.message.contains('failed'),
            ),
          ).equals(true);
        },
        config: config,
      );
    });

    test('supports flat logging (group: null) and logParams: false', () async {
      final handler = _MemoryLogHandler();
      final logger = Logger(handler: handler);
      final tracer = PgLogger(
        logger,
        group: null,
        logParams: false,
      );
      final config = defaultTestConfig.copyWithTracer(tracer);

      await withClient(
        (client) async {
          await client.query(r'SELECT $1::int as num', [123]);

          final record = handler.records.firstWhere(
            (r) => r.level == .debug && r.message == 'query',
          );

          // Flat attributes, no group
          check(record.attrs.any((a) => a is LogGroupAttr)).equals(false);
          check(record.attrs.any((a) => a.key == 'sql')).equals(true);
          check(record.attrs.any((a) => a.key == 'command_tag')).equals(true);
          // logParams: false -> no 'params' attribute
          check(record.attrs.any((a) => a.key == 'params')).equals(false);
        },
        config: config,
      );
    });
  });
}

extension on PgConfig {
  PgConfig copyWithTracer(PgTracer tracer) {
    return PgConfig.multi(
      endpoints: endpoints,
      user: user,
      password: password,
      database: database,
      targetSessionAttrs: targetSessionAttrs,
      sslConfig: sslConfig,
      queryMode: queryMode,
      tracer: tracer,
    );
  }
}
