import 'package:checks/checks.dart';
import 'package:pg/pg.dart';
import 'package:test/scaffolding.dart';

void main() {
  group('Geometric Codec Tests', () {
    test('PgPoint round-trip', () {
      const codec = PointCodec();
      const point = PgPoint(12.5, -34.75);
      final bin = codec.encodeBinary(point);
      check(codec.decodeBinary(bin)).equals(point);

      final txt = codec.encodeText(point);
      check(codec.decodeText(txt)).equals(point);
      check(point.toString()).equals('(12.5,-34.75)');
    });

    test('PgBox round-trip', () {
      const codec = BoxCodec();
      const box = PgBox(PgPoint(10, 20), PgPoint(0, 0));
      final bin = codec.encodeBinary(box);
      check(codec.decodeBinary(bin)).equals(box);
    });

    test('PgCircle round-trip', () {
      const codec = CircleCodec();
      const circle = PgCircle(PgPoint(5, 5), 2.5);
      final bin = codec.encodeBinary(circle);
      check(codec.decodeBinary(bin)).equals(circle);
    });

    test('PgPolygon round-trip', () {
      const codec = PolygonCodec();
      const polygon = PgPolygon([
        PgPoint(0, 0),
        PgPoint(0, 10),
        PgPoint(10, 10),
        PgPoint(10, 0),
      ]);
      final bin = codec.encodeBinary(polygon);
      check(codec.decodeBinary(bin)).equals(polygon);
    });
  });
}
