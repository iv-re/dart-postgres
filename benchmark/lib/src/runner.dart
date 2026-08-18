import 'dart:async';
import 'dart:math' as math;

/// Result metrics for a single measured run.
final class BenchResult {
  const BenchResult({
    required this.name,
    required this.iterations,
    required this.itemsPerIteration,
    required this.unit,
    required this.pgDuration,
    required this.postgresDuration,
  });

  final String name;
  final int iterations;
  final int itemsPerIteration;
  final String unit;
  final Duration pgDuration;
  final Duration postgresDuration;

  int get totalItems => iterations * itemsPerIteration;

  double get pgOpsSec {
    return totalItems / (pgDuration.inMicroseconds / 1000000.0);
  }

  double get postgresOpsSec {
    return totalItems / (postgresDuration.inMicroseconds / 1000000.0);
  }

  double get pgAvgUs {
    return pgDuration.inMicroseconds / totalItems;
  }

  double get postgresAvgUs {
    return postgresDuration.inMicroseconds / totalItems;
  }

  double get speedup {
    return pgOpsSec / postgresOpsSec;
  }
}

/// Lightweight benchmark harness for comparing async database operations.
final class BenchmarkRunner {
  final List<BenchResult> _results = [];

  /// Measures [pg] and [postgres] side-by-side.
  Future<BenchResult> measure(
    String name, {
    required int iterations,
    required Future<void> Function() pg,
    required Future<void> Function() postgres,
    int itemsPerIteration = 1,
    String unit = 'op/s',
    int? warmup,
  }) async {
    final warmupCount =
        warmup ?? math.min(10, math.max(2, (iterations * 0.05).round()));

    // Warmup
    for (var i = 0; i < warmupCount; i++) {
      await pg();
      await postgres();
    }

    // Measure pg
    final swPg = Stopwatch()..start();
    for (var i = 0; i < iterations; i++) {
      await pg();
    }
    swPg.stop();

    // Measure postgres
    final swPostgres = Stopwatch()..start();
    for (var i = 0; i < iterations; i++) {
      await postgres();
    }
    swPostgres.stop();

    final result = BenchResult(
      name: name,
      iterations: iterations,
      itemsPerIteration: itemsPerIteration,
      unit: unit,
      pgDuration: swPg.elapsed,
      postgresDuration: swPostgres.elapsed,
    );

    _results.add(result);
    _printRow(result);
    return result;
  }

  void printHeader() {
    print('');
    print('-' * 90);
    print(
      '${'Benchmark'.padRight(32)} | '
      '${'pg'.padRight(26)} | '
      '${'postgres v3'.padRight(26)}',
    );
    print('-' * 90);
  }

  void printFooter() {
    print('-' * 90);
    print('');
  }

  void _printRow(BenchResult r) {
    final pgOps = _formatThroughput(r.pgOpsSec, r.unit);
    final pgLat = _formatDuration(r.pgAvgUs);
    final pgCell = '$pgOps ($pgLat)';

    final v3Ops = _formatThroughput(r.postgresOpsSec, r.unit);
    final v3Lat = _formatDuration(r.postgresAvgUs);
    final postgresCell = '$v3Ops ($v3Lat)';

    print(
      '${r.name.padRight(32)} | '
      '${pgCell.padRight(26)} | '
      '${postgresCell.padRight(26)}',
    );
  }

  static String _formatThroughput(double ops, String unit) {
    if (ops >= 1000000) {
      return '${(ops / 1000000).toStringAsFixed(2)}M $unit';
    }
    if (ops >= 1000) {
      return '${(ops / 1000).toStringAsFixed(1)}k $unit';
    }
    return '${ops.toStringAsFixed(0)} $unit';
  }

  static String _formatDuration(double us) {
    if (us >= 1000) return '${(us / 1000).toStringAsFixed(2)}ms';
    return '${us.toStringAsFixed(1)}µs';
  }
}
