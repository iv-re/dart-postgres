import 'package:checks/checks.dart';
import 'package:pg/pg.dart';
import 'package:test/scaffolding.dart';

void main() {
  group('PgNumeric Codec Tests', () {
    const codec = NumericCodec();

    test('round-trip positive integer numeric', () {
      const num1 = PgNumeric('12345');
      final bin = codec.encodeBinary(num1);
      check(codec.decodeBinary(bin).toString()).equals('12345');
      check(num1.toInt()).equals(12345);
    });

    test('round-trip negative and fractional numeric', () {
      const num2 = PgNumeric('-987654.3210');
      final bin = codec.encodeBinary(num2);
      check(codec.decodeBinary(bin).toString()).equals('-987654.3210');
      check(num2.isNegative).isTrue();
      check(num2.toDouble()).equals(-987654.321);
    });

    test('zero and leading/trailing zeros', () {
      const numZero = PgNumeric('0');
      final bin = codec.encodeBinary(numZero);
      check(codec.decodeBinary(bin).toString()).equals('0');

      const numZeroFraction = PgNumeric('0.0050');
      final bin2 = codec.encodeBinary(numZeroFraction);
      check(codec.decodeBinary(bin2).toString()).equals('0.0050');
    });

    test('NaN numeric', () {
      const numNan = PgNumeric('NaN');
      final bin = codec.encodeBinary(numNan);
      check(codec.decodeBinary(bin).isNaN).isTrue();
      check(numNan.isNaN).isTrue();
    });

    test('large arbitrary precision numbers', () {
      const largeNum = PgNumeric('123456789012345678901234567890.123456789');
      final bin = codec.encodeBinary(largeNum);
      check(codec.decodeBinary(bin).toString()).equals(
        '123456789012345678901234567890.123456789',
      );
    });
  });
}
