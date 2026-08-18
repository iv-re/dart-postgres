import 'package:checks/checks.dart';
import 'package:pg/pg.dart';
import 'package:test/scaffolding.dart';

void main() {
  group('PgDate Codec Tests', () {
    const codec = DateCodec();

    test('round-trip binary and text', () {
      const date = PgDate(2026, 8, 14);
      final bin = codec.encodeBinary(date);
      check(codec.decodeBinary(bin)).equals(date);

      final txt = codec.encodeText(date);
      check(codec.decodeText(txt)).equals(date);
      check(date.toString()).equals('2026-08-14');
    });

    test('epoch boundary dates', () {
      const epochDate = PgDate(2000, 1, 1);
      check(epochDate.daysSinceEpoch).equals(0);

      final bin = codec.encodeBinary(epochDate);
      check(codec.decodeBinary(bin)).equals(epochDate);

      const pastDate = PgDate(1970, 1, 1);
      check(pastDate.daysSinceEpoch).equals(-10957);
      final pastBin = codec.encodeBinary(pastDate);
      check(codec.decodeBinary(pastBin)).equals(pastDate);
    });

    test('conversion to/from DateTime', () {
      final dt = DateTime.utc(2026, 8, 14);
      final pgDate = PgDate.fromDateTime(dt);
      check(pgDate.toDateTime()).equals(dt);
    });
  });

  group('PgTime Codec Tests', () {
    const codec = TimeCodec();

    test('round-trip binary and text', () {
      const time = PgTime(14, 30, 45, 123456);
      final bin = codec.encodeBinary(time);
      check(codec.decodeBinary(bin)).equals(time);

      final txt = codec.encodeText(time);
      check(codec.decodeText(txt)).equals(time);
      check(time.toString()).equals('14:30:45.123456');
    });

    test('time without microseconds', () {
      const time = PgTime(9, 15);
      check(time.toString()).equals('09:15:00');
      final bin = codec.encodeBinary(time);
      check(codec.decodeBinary(bin)).equals(time);
    });
  });

  group('PgTimeTz Codec Tests', () {
    const codec = TimeTzCodec();

    test('round-trip binary and text', () {
      const timeTz = PgTimeTz(PgTime(14, 30), 10800); // UTC+3
      final bin = codec.encodeBinary(timeTz);
      check(codec.decodeBinary(bin)).equals(timeTz);

      final txt = codec.encodeText(timeTz);
      check(codec.decodeText(txt)).equals(timeTz);
      check(timeTz.toString()).equals('14:30:00+03:00');
    });

    test('negative UTC offset', () {
      const timeTz = PgTimeTz(PgTime(8, 0), -18000); // UTC-5
      final bin = codec.encodeBinary(timeTz);
      check(codec.decodeBinary(bin)).equals(timeTz);
      check(timeTz.toString()).equals('08:00:00-05:00');
    });
  });

  group('PgInterval Codec Tests', () {
    const codec = IntervalCodec();

    test('round-trip binary and text', () {
      const interval = PgInterval(
        months: 14,
        days: 5,
        microseconds: 3600000000,
      );
      final bin = codec.encodeBinary(interval);
      check(codec.decodeBinary(bin)).equals(interval);

      const duration = Duration(hours: 2, minutes: 30, seconds: 15);
      final fromDuration = PgInterval.fromDuration(duration);
      final binDur = codec.encodeBinary(fromDuration);
      check(codec.decodeBinary(binDur)).equals(fromDuration);
    });
  });

  group('TimestampCodec Tests', () {
    test('timestamptz (isUtc: true) encodes absolute UTC instant', () {
      const codec = TimestampCodec();
      final utcTime = DateTime.utc(2026, 8, 17, 14, 30, 45);
      final bin = codec.encodeBinary(utcTime);
      check(codec.decodeBinary(bin)).equals(utcTime);

      final txt = codec.encodeText(utcTime);
      check(codec.decodeText(txt)).equals(utcTime);
    });

    test(
      'timestamp (isUtc: false) preserves wall clock time from local DateTime',
      () {
        const codec = TimestampCodec(isUtc: false);
        final localTime = DateTime(2026, 8, 17, 14, 30, 45);
        final bin = codec.encodeBinary(localTime);
        // Encoded naive timestamp matches DateTime.utc with same components
        final expectedUtc = DateTime.utc(2026, 8, 17, 14, 30, 45);
        check(codec.decodeBinary(bin)).equals(expectedUtc);

        final txt = codec.encodeText(localTime);
        check(codec.decodeText(txt)).equals(expectedUtc);
      },
    );
  });
}
