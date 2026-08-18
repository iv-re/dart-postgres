import 'dart:async';

import 'package:pg/src/client/rows.dart';

/// Item in a batch query pipeline.
class PgPipelineQueryItem(
  /// The SQL query string.
  final String sql,

  /// Parameter values for this query.
  final List<Object?> params,
) {
  /// Completer for this individual query result.
  final Completer<PgRows> completer = Completer<PgRows>();
}

/// Batch query pipeline container for packing multiple queries into a single
/// TCP socket payload.
class PgPipeline {
  final List<PgPipelineQueryItem> items = [];

  /// Queues a SQL query into the pipeline batch.
  Future<PgRows> query(String sql, [List<Object?> params = const []]) {
    final item = PgPipelineQueryItem(sql, params);
    items.add(item);
    return item.completer.future;
  }

  /// Whether the pipeline contains queued queries.
  bool get isNotEmpty => items.isNotEmpty;

  /// Total number of queued queries.
  int get length => items.length;
}
