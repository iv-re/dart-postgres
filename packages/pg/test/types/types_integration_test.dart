@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:pg/pg.dart';
import 'package:test/scaffolding.dart';

import '../test_utils.dart';

void main() {
  group('PgRow Typed Getters Integration Tests', () {
    testWithClient(
      'accesses all columns with clean typed getters',
      (client) async {
        await client.simpleQuery('''
          CREATE TEMP TABLE getter_test (
            id SERIAL PRIMARY KEY,
            c_bool BOOL,
            c_int INT,
            c_bigint BIGINT,
            c_float FLOAT8,
            c_text TEXT,
            c_bytea BYTEA,
            c_json JSONB,
            c_timestamptz TIMESTAMPTZ,
            c_interval INTERVAL,
            c_uuid UUID,
            c_int_arr INT[],
            c_text_arr TEXT[]
          );
        ''');

        final now = DateTime.utc(2026, 8, 12, 15, 30);
        final rawBytes = Uint8List.fromList([1, 2, 3, 4, 5]);

        await client.query(
          r'''
          INSERT INTO getter_test (
            c_bool, c_int, c_bigint, c_float, c_text,
            c_bytea, c_json, c_timestamptz, c_interval, c_uuid,
            c_int_arr, c_text_arr
          ) VALUES (
            $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12
          );
          ''',
          [
            true,
            42,
            BigInt.parse('9223372036854775800'),
            3.14159,
            'PgRow Typed Getters',
            rawBytes,
            {'key': 'value', 'count': 10},
            now,
            const Duration(seconds: 45, milliseconds: 500),
            'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11',
            [10, 20, 30],
            ['one', 'two', 'three'],
          ],
        );

        final rows = await client.simpleQuery(
          'SELECT * FROM getter_test LIMIT 1;',
        );
        check(rows.length).equals(1);
        final row = rows.first;

        check(row.bool('c_bool')).equals(true);
        check(row.boolOrNull('c_bool')).equals(true);
        check(row.int('c_int')).equals(42);
        check(row.intOrNull('c_int')).equals(42);
        check(row.bigint('c_bigint')).equals(
          BigInt.parse('9223372036854775800'),
        );
        check(row.bigintOrNull('c_bigint')).equals(
          BigInt.parse('9223372036854775800'),
        );
        check(row.double('c_float')).equals(3.14159);
        check(row.doubleOrNull('c_float')).equals(3.14159);
        check(row.string('c_text')).equals('PgRow Typed Getters');
        check(row.stringOrNull('c_text')).equals('PgRow Typed Getters');
        check(row.bytes('c_bytea')).deepEquals(rawBytes);
        check(row.bytesOrNull('c_bytea')).isNotNull().deepEquals(rawBytes);
        check(row.dateTime('c_timestamptz')).equals(now);
        check(row.dateTimeOrNull('c_timestamptz')).equals(now);
        check(
          row.uuid('c_uuid'),
        ).equals('a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11');
        check(
          row.uuidOrNull('c_uuid'),
        ).equals('a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11');
        check(row.rawJson('c_json')).equals('{"key": "value", "count": 10}');
        check(
          row.rawJsonOrNull('c_json'),
        ).equals('{"key": "value", "count": 10}');
        check(
          row.duration('c_interval'),
        ).equals(const Duration(seconds: 45, milliseconds: 500));
        check(
          row.durationOrNull('c_interval'),
        ).equals(const Duration(seconds: 45, milliseconds: 500));
        check(row.list<int>('c_int_arr')).deepEquals([10, 20, 30]);
        check(
          row.listOrNull<int>('c_int_arr'),
        ).isNotNull().deepEquals([10, 20, 30]);
        check(
          row.list<String>('c_text_arr'),
        ).deepEquals(['one', 'two', 'three']);
        check(
          row.listOrNull<String>('c_text_arr'),
        ).isNotNull().deepEquals(['one', 'two', 'three']);
      },
    );

    testWithClient(
      'handles NULL values with *OrNull and throws on non-null getters',
      (client) async {
        final rows = await client.simpleQuery('SELECT NULL as val;');
        final row = rows.first;

        check(row.intOrNull('val')).isNull();
        check(row.stringOrNull('val')).isNull();
        check(row.boolOrNull('val')).isNull();
        check(row.doubleOrNull('val')).isNull();
        check(row.bytesOrNull('val')).isNull();
        check(row.uuidOrNull('val')).isNull();
        check(row.dateTimeOrNull('val')).isNull();
        check(row.intervalOrNull('val')).isNull();
        check(row.rawJsonOrNull('val')).isNull();
        check(row.listOrNull<int>('val')).isNull();

        check(() => row.int('val')).throws<StateError>();
        check(() => row.string('val')).throws<StateError>();
        check(() => row.bool('val')).throws<StateError>();
      },
    );
  });

  group('Binary Parameter Encoder Integration Tests', () {
    group('primitives & numerics', () {
      testWithClient(
        'round-trips bool, integers, floats, and numeric types',
        (client) async {
          await client.simpleQuery('''
            CREATE TEMP TABLE num_test (
              id SERIAL PRIMARY KEY,
              c_bool BOOL,
              c_smallint SMALLINT,
              c_int INT,
              c_bigint_int BIGINT,
              c_bigint_obj BIGINT,
              c_real REAL,
              c_double FLOAT8,
              c_numeric NUMERIC
            );
          ''');

          await client.query(
            r'''
            INSERT INTO num_test (
              c_bool, c_smallint, c_int, c_bigint_int, c_bigint_obj,
              c_real, c_double, c_numeric
            ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8);
            ''',
            [
              true,
              32767, // smallint max
              2147483647, // int4 max
              9000000000, // bigint as Dart int
              BigInt.parse('9223372036854775807'), // bigint as BigInt
              3.14, // real (float4)
              2.718281828459045, // double (float8)
              PgNumeric.fromNum(12345.67), // numeric
            ],
          );

          final rows = await client.simpleQuery(
            'SELECT * FROM num_test LIMIT 1;',
          );
          check(rows.length).equals(1);
          final row = rows.first;

          check(row.bool('c_bool')).equals(true);
          check(row.int('c_smallint')).equals(32767);
          check(row.int('c_int')).equals(2147483647);
          check(row.int('c_bigint_int')).equals(9000000000);
          check(row.bigint('c_bigint_obj')).equals(
            BigInt.parse('9223372036854775807'),
          );
          check((row.double('c_real') - 3.14).abs()).isLessThan(0.001);
          check(row.double('c_double')).equals(2.718281828459045);
          check(row.numeric('c_numeric').toDouble()).equals(12345.67);
        },
      );
    });

    group('strings, bytes, json & uuid', () {
      testWithClient(
        'round-trips text, bytea, jsonb, and uuid types',
        (client) async {
          await client.simpleQuery('''
            CREATE TEMP TABLE str_test (
              id SERIAL PRIMARY KEY,
              c_text TEXT,
              c_bytea BYTEA,
              c_json JSONB,
              c_uuid UUID
            );
          ''');

          final rawBytes = Uint8List.fromList([1, 2, 3, 4, 5]);

          await client.query(
            r'''
            INSERT INTO str_test (
              c_text, c_bytea, c_json, c_uuid
            ) VALUES ($1, $2, $3, $4);
            ''',
            [
              'Dart Postgres Binary',
              rawBytes,
              {'key': 'value', 'count': 10},
              'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11',
            ],
          );

          final rows = await client.simpleQuery(
            'SELECT * FROM str_test LIMIT 1;',
          );
          check(rows.length).equals(1);
          final row = rows.first;

          check(row.string('c_text')).equals('Dart Postgres Binary');
          check(row.bytes('c_bytea')).deepEquals(rawBytes);
          check(
            jsonDecode(row.string('c_json')) as Map,
          ).deepEquals({'key': 'value', 'count': 10});
          check(
            row.uuid('c_uuid'),
          ).equals('a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11');
        },
      );

      testWithClient(
        'round-trips jsonb using raw string and list parameters',
        (client) async {
          await client.simpleQuery('''
            CREATE TEMP TABLE jsonb_param_test (
              id SERIAL PRIMARY KEY,
              data JSONB
            );
          ''');

          // Insert raw JSON string
          await client.query(
            r'INSERT INTO jsonb_param_test (data) VALUES ($1);',
            ['{"raw_string": true, "items": [1, 2]}'],
          );

          // Insert JSON array (List)
          await client.query(
            r'INSERT INTO jsonb_param_test (data) VALUES ($1);',
            [
              [
                {'role': 'system', 'content': 'prompt'},
                {'role': 'user', 'content': 'hello'},
              ],
            ],
          );

          final rows = await client.simpleQuery(
            'SELECT data FROM jsonb_param_test ORDER BY id;',
          );
          check(rows.length).equals(2);

          check(rows[0].json<Map<String, Object?>>('data')).deepEquals({
            'raw_string': true,
            'items': [1, 2],
          });

          check(rows[1].json<List<Object?>>('data')).deepEquals([
            {'role': 'system', 'content': 'prompt'},
            {'role': 'user', 'content': 'hello'},
          ]);
        },
      );
    });

    group('temporal types', () {
      testWithClient(
        'round-trips date, time, timetz, timestamp, timestamptz, and interval',
        (client) async {
          await client.simpleQuery('''
            CREATE TEMP TABLE temp_test (
              id SERIAL PRIMARY KEY,
              c_date DATE,
              c_time TIME,
              c_timetz TIMETZ,
              c_timestamp TIMESTAMP,
              c_timestamptz TIMESTAMPTZ,
              c_interval INTERVAL
            );
          ''');

          const testDate = PgDate(2026, 8, 17);
          const testTime = PgTime(14, 30, 45);
          const testTimeTz = PgTimeTz(PgTime(14, 30, 45), 10800);
          final testTimestamp = DateTime.utc(2026, 8, 17, 14, 30, 45);
          const testInterval = PgInterval(
            months: 2,
            days: 5,
            microseconds: 1500000,
          );

          await client.query(
            r'''
            INSERT INTO temp_test (
              c_date, c_time, c_timetz, c_timestamp, c_timestamptz, c_interval
            ) VALUES ($1, $2, $3, $4, $5, $6);
            ''',
            [
              testDate,
              testTime,
              testTimeTz,
              testTimestamp,
              testTimestamp,
              testInterval,
            ],
          );

          final rows = await client.simpleQuery(
            'SELECT * FROM temp_test LIMIT 1;',
          );
          check(rows.length).equals(1);
          final row = rows.first;

          check(row.date('c_date')).equals(testDate);
          check(row.time('c_time')).equals(testTime);
          check(row.timeTz('c_timetz')).equals(testTimeTz);
          check(row.dateTime('c_timestamp')).equals(testTimestamp);
          check(row.dateTime('c_timestamptz')).equals(testTimestamp);
          check(row.interval('c_interval')).equals(testInterval);
        },
      );
    });

    group('geometric & full-text search', () {
      testWithClient(
        'round-trips point, box, circle, polygon, tsvector, and tsquery',
        (client) async {
          await client.simpleQuery('''
            CREATE TEMP TABLE geo_search_test (
              id SERIAL PRIMARY KEY,
              c_point POINT,
              c_box BOX,
              c_circle CIRCLE,
              c_polygon POLYGON,
              c_tsvector TSVECTOR,
              c_tsquery TSQUERY
            );
          ''');

          const testPoint = PgPoint(1.5, 2.5);
          const testBox = PgBox(PgPoint(10, 10), PgPoint(0, 0));
          const testCircle = PgCircle(PgPoint(5, 5), 3);
          const testPolygon = PgPolygon([
            PgPoint(0, 0),
            PgPoint(4, 0),
            PgPoint(4, 3),
          ]);
          const testTsVector = PgTsVector([
            PgTsWord('cat'),
            PgTsWord('fat'),
          ]);
          final testTsQuery = PgTsQuery.parse('cat & fat');

          await client.query(
            r'''
            INSERT INTO geo_search_test (
              c_point, c_box, c_circle, c_polygon, c_tsvector, c_tsquery
            ) VALUES ($1, $2, $3, $4, $5, $6);
            ''',
            [
              testPoint,
              testBox,
              testCircle,
              testPolygon,
              testTsVector,
              testTsQuery,
            ],
          );

          final rows = await client.simpleQuery(
            'SELECT * FROM geo_search_test LIMIT 1;',
          );
          check(rows.length).equals(1);
          final row = rows.first;

          check(row.point('c_point')).equals(testPoint);
          check(row.box('c_box')).equals(testBox);
          check(row.circle('c_circle')).equals(testCircle);
          check(row.polygon('c_polygon')).equals(testPolygon);
          check(row.tsVector('c_tsvector')).equals(testTsVector);
          check(row.tsQuery('c_tsquery')).equals(
            const PgTsQueryWord('fat') & const PgTsQueryWord('cat'),
          );
        },
      );
    });

    group('array collections & edge cases', () {
      testWithClient(
        'round-trips multi-type arrays (integers, floats, text, bytea, json)',
        (client) async {
          await client.simpleQuery('''
            CREATE TEMP TABLE arr_test (
              id SERIAL PRIMARY KEY,
              c_smallint_arr SMALLINT[],
              c_int_arr INT[],
              c_bigint_arr BIGINT[],
              c_real_arr REAL[],
              c_double_arr FLOAT8[],
              c_text_arr TEXT[],
              c_bytea_arr BYTEA[],
              c_jsonb_arr JSONB[]
            );
          ''');

          await client.query(
            r'''
            INSERT INTO arr_test (
              c_smallint_arr, c_int_arr, c_bigint_arr, c_real_arr, c_double_arr,
              c_text_arr, c_bytea_arr, c_jsonb_arr
            ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8);
            ''',
            [
              [1, 2, 3], // smallint[]
              [100, 200, 300], // int[]
              [1000, 2000, 3000], // bigint[]
              [1.5, 2.5], // real[]
              [3.14, 6.28], // float8[]
              ['one', 'two', 'three'],
              [
                Uint8List.fromList([0xAA, 0xBB]),
                Uint8List.fromList([0xCC, 0xDD]),
              ],
              [
                {'tag': 'dev'},
                {'tag': 'prod'},
              ],
            ],
          );

          final rows = await client.simpleQuery(
            'SELECT * FROM arr_test LIMIT 1;',
          );
          check(rows.length).equals(1);
          final row = rows.first;

          check(row.list<int>('c_smallint_arr')).deepEquals([1, 2, 3]);
          check(row.list<int>('c_int_arr')).deepEquals([100, 200, 300]);
          check(row.list<int>('c_bigint_arr')).deepEquals([1000, 2000, 3000]);
          check(row.list<double>('c_double_arr')).deepEquals([3.14, 6.28]);
          check(
            row.list<String>('c_text_arr'),
          ).deepEquals(['one', 'two', 'three']);
          check(row.string('c_bytea_arr')).equals(
            r'{"\\xaa","\\xccdd"}'.replaceAll('aa', 'aabb'),
          );
          check(
            row.string('c_jsonb_arr'),
          ).equals(r'{"{\"tag\": \"dev\"}","{\"tag\": \"prod\"}"}');
        },
      );

      testWithClient(
        'arrays with NULLs, empty arrays, unicode/emojis, and boundary BigInts',
        (client) async {
          await client.simpleQuery('''
            CREATE TEMP TABLE edge_type_test (
              id SERIAL PRIMARY KEY,
              c_int_arr INT[],
              c_empty_arr INT[],
              c_text TEXT,
              c_max_bigint BIGINT,
              c_min_bigint BIGINT
            );
          ''');

          final maxBigInt = BigInt.parse('9223372036854775807');
          final minBigInt = BigInt.parse('-9223372036854775808');
          const emojiText = 'Dart 🚀 🐘 🔥 Привет мир! 日本語';

          await client.query(
            r'''
            INSERT INTO edge_type_test (
              c_int_arr, c_empty_arr, c_text, c_max_bigint, c_min_bigint
            ) VALUES ($1, $2, $3, $4, $5);
            ''',
            [
              [100, null, 300],
              <int>[],
              emojiText,
              maxBigInt,
              minBigInt,
            ],
          );

          final rows = await client.simpleQuery(
            'SELECT * FROM edge_type_test LIMIT 1;',
          );
          check(rows.length).equals(1);
          final row = rows.first;

          check(row.string('c_int_arr')).equals('{100,NULL,300}');
          check(row.string('c_empty_arr')).equals('{}');
          check(row.string('c_text')).equals(emojiText);
          check(row.bigint('c_max_bigint')).equals(maxBigInt);
          check(row.bigint('c_min_bigint')).equals(minBigInt);
        },
      );
    });
  });
}
