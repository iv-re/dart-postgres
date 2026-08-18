import 'dart:async';
import 'dart:isolate';

import 'package:benchmark/src/config.dart';
import 'package:pg/pg.dart';
import 'package:postgres/postgres.dart' as v3;

/// Simulates a multi-isolate web application backend.
final class WebAppCluster {
  WebAppCluster._(this._pgWorkers, this._postgresWorkers);

  final List<_Worker> _pgWorkers;
  final List<_Worker> _postgresWorkers;

  static Future<WebAppCluster> create({
    int isolateCount = 4,
    int poolSize = 4,
  }) async {
    final pg = await Future.wait(
      List.generate(
        isolateCount,
        (_) => _Worker.spawn(_pgWorkerEntry, poolSize),
      ),
    );
    final postgres = await Future.wait(
      List.generate(
        isolateCount,
        (_) => _Worker.spawn(_postgresWorkerEntry, poolSize),
      ),
    );
    return WebAppCluster._(pg, postgres);
  }

  Future<void> runPg(int queriesPerIsolate) async {
    await Future.wait(_pgWorkers.map((w) => w.run(queriesPerIsolate)));
  }

  Future<void> runPostgres(int queriesPerIsolate) async {
    await Future.wait(_postgresWorkers.map((w) => w.run(queriesPerIsolate)));
  }

  Future<void> close() async {
    await Future.wait([
      for (final w in _pgWorkers) w.close(),
      for (final w in _postgresWorkers) w.close(),
    ]);
  }
}

final class _Worker {
  _Worker(this._commandPort);

  final SendPort _commandPort;

  static Future<_Worker> spawn(
    void Function((SendPort, int)) entry,
    int poolSize,
  ) async {
    final initPort = ReceivePort();
    await Isolate.spawn(entry, (initPort.sendPort, poolSize));
    final commandPort = await initPort.first as SendPort;
    initPort.close();
    return _Worker(commandPort);
  }

  Future<void> run(int count) async {
    final replyPort = ReceivePort();
    _commandPort.send((count, replyPort.sendPort));
    await replyPort.first;
    replyPort.close();
  }

  Future<void> close() async {
    _commandPort.send(null);
  }
}

const _userQuerySql =
    'SELECT 1::int AS id, '
    "'Alex'::text AS first_name, "
    'NULL::text AS last_name, '
    'now() AS created_at;';

Future<void> _pgWorkerEntry((SendPort, int) args) async {
  final (mainPort, poolSize) = args;
  final pool = PgPool(
    DbConfig.pgConfig,
    minConnections: poolSize,
    maxConnections: poolSize,
  );
  await _listenWorker(mainPort, pool.close, (count) async {
    await Future.wait(
      List.generate(count, (_) async {
        final rows = await pool.query(_userQuerySql, []);
        final row = rows.first;
        row.int(0);
        row.string(1);
        row.stringOrNull(2);
        row.dateTime(3);
      }),
    );
  });
}

Future<void> _postgresWorkerEntry((SendPort, int) args) async {
  final (mainPort, poolSize) = args;
  final pool = v3.Pool<void>.withEndpoints(
    [DbConfig.postgresEndpoint],
    settings: v3.PoolSettings(
      maxConnectionCount: poolSize,
      sslMode: v3.SslMode.disable,
    ),
  );
  await _listenWorker(mainPort, pool.close, (count) async {
    await Future.wait(
      List.generate(count, (_) async {
        final result = await pool.execute(_userQuerySql);
        final row = result.first;
        row[0]! as int;
        row[1]! as String;
        row[2] as String?;
        row[3]! as DateTime;
      }),
    );
  });
}

Future<void> _listenWorker(
  SendPort mainPort,
  Future<void> Function() onClose,
  Future<void> Function(int count) onRun,
) async {
  final commandPort = ReceivePort();
  mainPort.send(commandPort.sendPort);

  await for (final msg in commandPort) {
    if (msg case (final int count, final SendPort replyPort)) {
      await onRun(count);
      replyPort.send(null);
    } else {

      await onClose();
      commandPort.close();
      break;
    }
  }
}
