import 'package:checks/checks.dart';
import 'package:pg/pg.dart';
import 'package:pg/src/client/statement_cache.dart';
import 'package:test/scaffolding.dart';

void main() {
  group('PgStatementCache', () {
    test('computeStatementName produces deterministic sha256 hex string', () {
      final name1 = PgStatementCache.computeStatementName('SELECT 1');
      final name2 = PgStatementCache.computeStatementName('SELECT 1');
      final name3 = PgStatementCache.computeStatementName('SELECT 2');

      check(name1).equals(name2);
      check(name1).startsWith('stmtcache_');
      check(name1).not((it) => it.equals(name3));
    });

    test('get and put manages statements with LRU order', () {
      final cache = PgStatementCache(capacity: 2);

      const stmt1 = PgStatement(
        name: 's1',
        sql: 'SQL 1',
        paramOids: [],
        fields: [],
      );
      const stmt2 = PgStatement(
        name: 's2',
        sql: 'SQL 2',
        paramOids: [],
        fields: [],
      );
      const stmt3 = PgStatement(
        name: 's3',
        sql: 'SQL 3',
        paramOids: [],
        fields: [],
      );

      check(cache.put('SQL 1', stmt1)).isNull();
      check(cache.put('SQL 2', stmt2)).isNull();
      check(cache.length).equals(2);

      // Access SQL 1 to make it most recently used (SQL 2 becomes oldest)
      check(cache.get('SQL 1')).equals(stmt1);

      // Adding SQL 3 should evict SQL 2
      final evicted = cache.put('SQL 3', stmt3);
      check(evicted).equals(stmt2);
      check(cache.get('SQL 2')).isNull();
      check(cache.get('SQL 1')).equals(stmt1);
      check(cache.get('SQL 3')).equals(stmt3);
    });

    test('remove and clear methods work correctly', () {
      final cache = PgStatementCache(capacity: 5);

      const stmt = PgStatement(
        name: 's1',
        sql: 'SQL 1',
        paramOids: [],
        fields: [],
      );

      cache.put('SQL 1', stmt);
      check(cache.length).equals(1);

      final removed = cache.remove('SQL 1');
      check(removed).equals(stmt);
      check(cache.length).equals(0);

      cache.put('SQL 1', stmt);
      cache.clear();
      check(cache.length).equals(0);
      check(cache.get('SQL 1')).isNull();
    });
  });
}
