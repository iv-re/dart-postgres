import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:pg/src/client/rows.dart';
import 'package:pg/src/types/codec.dart';

/// Represents a 2D geometric point `(x, y)` in PostgreSQL.
@immutable
class const PgPoint(
  final double x,
  final double y,
) {
  factory parse(String text) {
    var s = text.trim();
    if (s.startsWith('(') && s.endsWith(')')) {
      s = s.substring(1, s.length - 1);
    }
    final parts = s.split(',');
    return PgPoint(
      double.parse(parts[0].trim()),
      double.parse(parts[1].trim()),
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is PgPoint && x == other.x && y == other.y;
  }

  @override
  int get hashCode => Object.hash(x, y);

  @override
  String toString() => '($x,$y)';
}

/// Represents a rectangular box `(high, low)` in PostgreSQL.
@immutable
class const PgBox(
  final PgPoint high,
  final PgPoint low,
) {
  factory parse(String text) {
    var s = text.trim();
    if (s.startsWith('(') && s.endsWith(')')) {
      s = s.substring(1, s.length - 1);
    }
    final parts = s.split('),(');
    final p1Str = parts[0].replaceAll('(', '').replaceAll(')', '');
    final p2Str = parts[1].replaceAll('(', '').replaceAll(')', '');
    return PgBox(PgPoint.parse(p1Str), PgPoint.parse(p2Str));
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is PgBox && high == other.high && low == other.low;
  }

  @override
  int get hashCode => Object.hash(high, low);

  @override
  String toString() => '($high,$low)';
}

/// Represents an infinite line `{A, B, C}` (Ax + By + C = 0) in PostgreSQL.
@immutable
class const PgLine(
  final double a,
  final double b,
  final double c,
) {
  factory parse(String text) {
    var s = text.trim();
    if (s.startsWith('{') && s.endsWith('}')) {
      s = s.substring(1, s.length - 1);
    }
    final parts = s.split(',');
    return PgLine(
      double.parse(parts[0].trim()),
      double.parse(parts[1].trim()),
      double.parse(parts[2].trim()),
    );
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is PgLine && a == other.a && b == other.b && c == other.c;
  }

  @override
  int get hashCode => Object.hash(a, b, c);

  @override
  String toString() => '{$a,$b,$c}';
}

/// Represents a line segment `[(x1, y1), (x2, y2)]` in PostgreSQL.
@immutable
class const PgLineSegment(
  final PgPoint p1,
  final PgPoint p2,
) {
  factory parse(String text) {
    var s = text.trim();
    if ((s.startsWith('[') && s.endsWith(']')) ||
        (s.startsWith('(') && s.endsWith(')'))) {
      s = s.substring(1, s.length - 1);
    }
    final parts = s.split('),(');
    final p1Str = parts[0].replaceAll('(', '').replaceAll(')', '');
    final p2Str = parts[1].replaceAll('(', '').replaceAll(')', '');
    return PgLineSegment(PgPoint.parse(p1Str), PgPoint.parse(p2Str));
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is PgLineSegment && p1 == other.p1 && p2 == other.p2;
  }

  @override
  int get hashCode => Object.hash(p1, p2);

  @override
  String toString() => '[$p1,$p2]';
}

/// Represents a circle `<(x, y), r>` in PostgreSQL.
@immutable
class const PgCircle(
  final PgPoint center,
  final double radius,
) {
  factory parse(String text) {
    var s = text.trim();
    if (s.startsWith('<') && s.endsWith('>')) {
      s = s.substring(1, s.length - 1);
    }
    final lastComma = s.lastIndexOf(',');
    final centerPart = s.substring(0, lastComma).trim();
    final radPart = s.substring(lastComma + 1).trim();
    return PgCircle(PgPoint.parse(centerPart), double.parse(radPart));
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is PgCircle && center == other.center && radius == other.radius;
  }

  @override
  int get hashCode => Object.hash(center, radius);

  @override
  String toString() => '<$center,$radius>';
}

/// Represents a closed polygon `((x1, y1), (x2, y2), ...)` in PostgreSQL.
@immutable
class const PgPolygon(
  final List<PgPoint> points,
) {
  factory parse(String text) {
    var s = text.trim();
    if (s.startsWith('(') && s.endsWith(')')) {
      s = s.substring(1, s.length - 1);
    }
    final pointsList = <PgPoint>[];
    final regExp = RegExp(r'\(([^)]+)\)');
    for (final match in regExp.allMatches(s)) {
      final pointText = match.group(1)!;
      final coords = pointText.split(',');
      pointsList.add(
        PgPoint(double.parse(coords[0].trim()), double.parse(coords[1].trim())),
      );
    }
    return PgPolygon(pointsList);
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is PgPolygon &&
            points.length == other.points.length &&
            List.generate(
              points.length,
              (i) => points[i] == other.points[i],
            ).every((eq) => eq);
  }

  @override
  int get hashCode => Object.hashAll(points);

  @override
  String toString() => '(${points.map((p) => p.toString()).join(',')})';
}

/// Codec for PostgreSQL `point` type.
class const PointCodec() implements PgCodec<PgPoint> {
  @override
  Uint8List encodeBinary(PgPoint value) {
    final bytes = Uint8List(16);
    final bd = ByteData.sublistView(bytes);
    bd.setFloat64(0, value.x);
    bd.setFloat64(8, value.y);
    return bytes;
  }

  @override
  Uint8List encodeText(PgPoint value) {
    return Uint8List.fromList(utf8.encode(value.toString()));
  }

  @override
  PgPoint decodeBinary(Uint8List bytes) {
    final bd = ByteData.sublistView(bytes);
    return PgPoint(bd.getFloat64(0), bd.getFloat64(8));
  }

  @override
  PgPoint decodeText(Uint8List bytes) => PgPoint.parse(utf8.decode(bytes));
}

/// Codec for PostgreSQL `box` type.
class const BoxCodec() implements PgCodec<PgBox> {
  @override
  Uint8List encodeBinary(PgBox value) {
    final bytes = Uint8List(32);
    final bd = ByteData.sublistView(bytes);
    bd.setFloat64(0, value.high.x);
    bd.setFloat64(8, value.high.y);
    bd.setFloat64(16, value.low.x);
    bd.setFloat64(24, value.low.y);
    return bytes;
  }

  @override
  Uint8List encodeText(PgBox value) {
    return Uint8List.fromList(utf8.encode(value.toString()));
  }

  @override
  PgBox decodeBinary(Uint8List bytes) {
    final bd = ByteData.sublistView(bytes);
    final high = PgPoint(bd.getFloat64(0), bd.getFloat64(8));
    final low = PgPoint(bd.getFloat64(16), bd.getFloat64(24));
    return PgBox(high, low);
  }

  @override
  PgBox decodeText(Uint8List bytes) => PgBox.parse(utf8.decode(bytes));
}

/// Codec for PostgreSQL `circle` type.
class const CircleCodec() implements PgCodec<PgCircle> {
  @override
  Uint8List encodeBinary(PgCircle value) {
    final bytes = Uint8List(24);
    final bd = ByteData.sublistView(bytes);
    bd.setFloat64(0, value.center.x);
    bd.setFloat64(8, value.center.y);
    bd.setFloat64(16, value.radius);
    return bytes;
  }

  @override
  Uint8List encodeText(PgCircle value) {
    return Uint8List.fromList(utf8.encode(value.toString()));
  }

  @override
  PgCircle decodeBinary(Uint8List bytes) {
    final bd = ByteData.sublistView(bytes);
    final center = PgPoint(bd.getFloat64(0), bd.getFloat64(8));
    final radius = bd.getFloat64(16);
    return PgCircle(center, radius);
  }

  @override
  PgCircle decodeText(Uint8List bytes) => PgCircle.parse(utf8.decode(bytes));
}

/// Codec for PostgreSQL `polygon` type.
class const PolygonCodec() implements PgCodec<PgPolygon> {
  @override
  Uint8List encodeBinary(PgPolygon value) {
    final count = value.points.length;
    final bytes = Uint8List(4 + (count * 16));
    final bd = ByteData.sublistView(bytes);
    bd.setInt32(0, count);
    var offset = 4;
    for (final p in value.points) {
      bd.setFloat64(offset, p.x);
      bd.setFloat64(offset + 8, p.y);
      offset += 16;
    }
    return bytes;
  }

  @override
  Uint8List encodeText(PgPolygon value) {
    return Uint8List.fromList(utf8.encode(value.toString()));
  }

  @override
  PgPolygon decodeBinary(Uint8List bytes) {
    final bd = ByteData.sublistView(bytes);
    final count = bd.getInt32(0);
    final points = <PgPoint>[];
    var offset = 4;
    for (var i = 0; i < count; i++) {
      points.add(PgPoint(bd.getFloat64(offset), bd.getFloat64(offset + 8)));
      offset += 16;
    }
    return PgPolygon(points);
  }

  @override
  PgPolygon decodeText(Uint8List bytes) => PgPolygon.parse(utf8.decode(bytes));
}

const _pointCodec = PointCodec();
const _boxCodec = BoxCodec();
const _circleCodec = CircleCodec();
const _polygonCodec = PolygonCodec();

/// Geometric getters for [PgRow].
extension PgRowGeoGetters on PgRow {
  /// Decodes column as [PgPoint], or `null` if SQL NULL.
  @pragma('vm:prefer-inline')
  PgPoint? pointOrNull(Object column) => decodeOrNull(column, _pointCodec);

  /// Decodes column as [PgPoint]. Throws [StateError] if null.
  @pragma('vm:prefer-inline')
  PgPoint point(Object column) => decode(column, _pointCodec);

  /// Decodes column as [PgBox], or `null` if SQL NULL.
  @pragma('vm:prefer-inline')
  PgBox? boxOrNull(Object column) => decodeOrNull(column, _boxCodec);

  /// Decodes column as [PgBox]. Throws [StateError] if null.
  @pragma('vm:prefer-inline')
  PgBox box(Object column) => decode(column, _boxCodec);

  /// Decodes column as [PgCircle], or `null` if SQL NULL.
  @pragma('vm:prefer-inline')
  PgCircle? circleOrNull(Object column) => decodeOrNull(column, _circleCodec);

  /// Decodes column as [PgCircle]. Throws [StateError] if null.
  @pragma('vm:prefer-inline')
  PgCircle circle(Object column) => decode(column, _circleCodec);

  /// Decodes column as [PgPolygon], or `null` if SQL NULL.
  @pragma('vm:prefer-inline')
  PgPolygon? polygonOrNull(Object column) =>
      decodeOrNull(column, _polygonCodec);

  /// Decodes column as [PgPolygon]. Throws [StateError] if null.
  @pragma('vm:prefer-inline')
  PgPolygon polygon(Object column) => decode(column, _polygonCodec);
}
