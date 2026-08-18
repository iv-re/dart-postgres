import 'dart:collection';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:pg/src/client/statement.dart';

/// LRU (Least Recently Used) prepared statement cache for `PgClient`.
class PgStatementCache {
  PgStatementCache({this.capacity = 100});

  /// Maximum number of statements to keep in cache.
  final int capacity;

  final LinkedHashMap<String, PgStatement> _cache = LinkedHashMap();

  /// Returns total statements in cache.
  int get length => _cache.length;

  /// Computes deterministic statement name for [sql] using SHA-256 hash.
  static String computeStatementName(String sql) {
    final digest = sha256.convert(utf8.encode(sql)).bytes;
    final hexStr = digest
        .take(12)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    return 'stmtcache_$hexStr';
  }

  /// Fetches statement by SQL, updating LRU order.
  PgStatement? get(String sql) {
    final stmt = _cache.remove(sql);
    if (stmt != null) {
      _cache[sql] = stmt;
    }
    return stmt;
  }

  /// Adds a statement to cache, returning evicted statement if capacity
  /// exceeded.
  PgStatement? put(String sql, PgStatement statement) {
    _cache.remove(sql);
    _cache[sql] = statement;

    if (_cache.length > capacity) {
      final oldestKey = _cache.keys.first;
      return _cache.remove(oldestKey);
    }
    return null;
  }

  /// Removes a statement from cache.
  PgStatement? remove(String sql) {
    return _cache.remove(sql);
  }

  /// Clears cache.
  void clear() {
    _cache.clear();
  }
}
