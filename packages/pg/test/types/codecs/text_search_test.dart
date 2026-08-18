import 'package:checks/checks.dart';
import 'package:pg/pg.dart';
import 'package:test/scaffolding.dart';

void main() {
  group('PgTsVector Codec Tests', () {
    const codec = TsVectorCodec();

    test('round-trip TsVector with positions and weights', () {
      const vector = PgTsVector([
        PgTsWord(
          'fat',
          positions: [
            PgTsWordPos(2, weight: PgTsWeight.a),
            PgTsWordPos(4, weight: PgTsWeight.c),
          ],
        ),
        PgTsWord(
          'cat',
          positions: [
            PgTsWordPos(1, weight: PgTsWeight.a),
          ],
        ),
      ]);

      final bin = codec.encodeBinary(vector);
      final decoded = codec.decodeBinary(bin);

      check(decoded.words.length).equals(2);
      check(decoded.words[0].text).equals('fat');
      check(decoded.words[0].positions.length).equals(2);
      check(decoded.words[0].positions[0].position).equals(2);
      check(decoded.words[0].positions[0].weight).equals(PgTsWeight.a);
    });

    test('parse and toString text search vector', () {
      final parsed = PgTsVector.parse("'cat':1A 'fat':2A,4C");
      check(parsed.words.length).equals(2);
      check(parsed.words[0].text).equals('cat');
      check(parsed.words[0].positions.first.position).equals(1);
    });
  });

  group('PgTsQuery Tests', () {
    test('construct and format tsqueries', () {
      const q1 = PgTsQuery.word('fat', weight: PgTsWeight.a);
      const q2 = PgTsQuery.word('cat', prefix: true);
      final combined = q1 & q2;
      check(combined.toString()).equals('(fat:A & cat:*)');

      const notQuery = PgTsQuery.not(q1);
      check(notQuery.toString()).equals('!(fat:A)');
    });
  });
}
