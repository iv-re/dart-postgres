import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:meta/meta.dart';
import 'package:pg/pg.dart';
import 'package:test/scaffolding.dart';

@immutable
class CustomPoint {
  const CustomPoint(this.x, this.y);
  final int x;
  final int y;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is CustomPoint && x == other.x && y == other.y;
  }

  @override
  int get hashCode => Object.hash(x, y);
}

class CustomPointCodec implements PgCodec<CustomPoint> {
  const CustomPointCodec();

  @override
  Uint8List encodeBinary(CustomPoint value) {
    final bytes = Uint8List(8);
    ByteData.sublistView(bytes).setInt32(0, value.x);
    ByteData.sublistView(bytes).setInt32(4, value.y);
    return bytes;
  }

  @override
  Uint8List encodeText(CustomPoint value) =>
      Uint8List.fromList('(${value.x},${value.y})'.codeUnits);

  @override
  CustomPoint decodeBinary(Uint8List bytes) {
    final bd = ByteData.sublistView(bytes);
    return CustomPoint(bd.getInt32(0), bd.getInt32(4));
  }

  @override
  CustomPoint decodeText(Uint8List bytes) {
    final str = String.fromCharCodes(
      bytes,
    ).replaceAll('(', '').replaceAll(')', '');
    final parts = str.split(',');
    return CustomPoint(int.parse(parts[0]), int.parse(parts[1]));
  }
}

void main() {
  group('PgTypeRegistry Tests', () {
    test('default registry resolves standard types', () {
      final reg = PgTypeRegistry.defaults;
      final encoded = reg.encodeValue(42);

      check(encoded).isNotNull();
      check(ByteData.sublistView(encoded!).getInt32(0)).equals(42);
    });

    test('custom type registration', () {
      final reg = PgTypeRegistry();
      const customOid = PgOid(19999);
      const customArrayOid = PgOid(19998);

      reg.register<CustomPoint>(
        oid: customOid,
        codec: const CustomPointCodec(),
        arrayOid: customArrayOid,
      );

      const point = CustomPoint(100, 200);
      final encoded = reg.encodeValue(point);
      check(encoded).isNotNull();

      final decoded = reg.decodeValue<CustomPoint>(
        encoded!,
        typeOid: customOid,
      );
      check(decoded).equals(point);
    });

    test('encodeParameters encodes full parameter list', () {
      final reg = PgTypeRegistry.defaults;
      final params = [42, 'test', true, null];
      final encoded = reg.encodeParameters(params);
      check(encoded.length).equals(4);
      check(encoded[0]!.length).equals(4);
      check(encoded[1]!).deepEquals('test'.codeUnits);
      check(encoded[2]!).deepEquals([1]);
      check(encoded[3]).isNull();
    });

    test('throws ArgumentError on unsupported type', () {
      final reg = PgTypeRegistry.defaults;
      check(
        () => reg.encodeValue(Object()),
      ).throws<ArgumentError>();
    });
  });
}
