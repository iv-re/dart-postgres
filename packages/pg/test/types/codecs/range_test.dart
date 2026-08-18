import 'package:checks/checks.dart';
import 'package:pg/pg.dart';
import 'package:test/scaffolding.dart';

void main() {
  group('PgRange Codec Tests', () {
    const intCodec = RangeCodec<int>(Int4Codec());

    test('round-trip bounded int range [10, 20)', () {
      const range = PgRange<int>(10, 20);
      final bin = intCodec.encodeBinary(range);
      final decoded = intCodec.decodeBinary(bin);

      check(decoded.lower).equals(10);
      check(decoded.upper).equals(20);
      check(decoded.lowerInclusive).isTrue();
      check(decoded.upperInclusive).isFalse();
      check(range.toString()).equals('[10,20)');
    });

    test('empty range', () {
      const empty = PgRange<int>.empty();
      final bin = intCodec.encodeBinary(empty);
      final decoded = intCodec.decodeBinary(bin);
      check(decoded.isEmpty).isTrue();
      check(empty.toString()).equals('empty');
    });

    test('unbounded lower (-infinity, 100]', () {
      const range = PgRange<int>(
        null,
        100,
        lowerInclusive: false,
        upperInclusive: true,
      );
      final bin = intCodec.encodeBinary(range);
      final decoded = intCodec.decodeBinary(bin);

      check(decoded.isLowerUnbounded).isTrue();
      check(decoded.upper).equals(100);
      check(decoded.upperInclusive).isTrue();
    });
  });
}
