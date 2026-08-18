import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:pg/src/client/rows.dart';
import 'package:pg/src/types/codec.dart';

const int _rangeEmpty = 0x01;
const int _rangeLbInc = 0x02;
const int _rangeUbInc = 0x04;
const int _rangeLbInf = 0x08;
const int _rangeUbInf = 0x10;

/// Represents a PostgreSQL `range` type (e.g. `int4range`, `daterange`,
/// `tsrange`).
@immutable
class const PgRange<T>(
  final T? lower,
  final T? upper, {
  final bool lowerInclusive = true,
  final bool upperInclusive = false,
  final bool isEmpty = false,
}) {
  /// Creates an empty range (`empty`).
  const new empty()
    : this(
        null,
        null,
        lowerInclusive: false,
        upperInclusive: false,
        isEmpty: true,
      );

  /// Whether the lower bound is unbounded (-infinity).
  bool get isLowerUnbounded => lower == null && !isEmpty;

  /// Whether the upper bound is unbounded (+infinity).
  bool get isUpperUnbounded => upper == null && !isEmpty;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is PgRange<T> &&
            lower == other.lower &&
            upper == other.upper &&
            lowerInclusive == other.lowerInclusive &&
            upperInclusive == other.upperInclusive &&
            isEmpty == other.isEmpty;
  }

  @override
  int get hashCode =>
      Object.hash(lower, upper, lowerInclusive, upperInclusive, isEmpty);

  @override
  String toString() {
    if (isEmpty) return 'empty';
    final lBracket = lowerInclusive ? '[' : '(';
    final rBracket = upperInclusive ? ']' : ')';
    final lStr = lower?.toString() ?? '';
    final uStr = upper?.toString() ?? '';
    return '$lBracket$lStr,$uStr$rBracket';
  }
}

/// Codec for PostgreSQL Range types.
class const RangeCodec<T>(
  final PgCodec<T> elementCodec,
) implements PgCodec<PgRange<T>> {
  @override
  Uint8List encodeBinary(PgRange<T> value) {
    if (value.isEmpty) {
      return Uint8List(1)..[0] = _rangeEmpty;
    }

    var flags = 0;
    if (value.lowerInclusive) flags |= _rangeLbInc;
    if (value.upperInclusive) flags |= _rangeUbInc;
    if (value.isLowerUnbounded) flags |= _rangeLbInf;
    if (value.isUpperUnbounded) flags |= _rangeUbInf;

    final builder = BytesBuilder();
    builder.addByte(flags);

    if (!value.isLowerUnbounded && value.lower != null) {
      final bytes = elementCodec.encodeBinary(value.lower as T);
      final len = Uint8List(4);
      ByteData.sublistView(len).setInt32(0, bytes.length);
      builder.add(len);
      builder.add(bytes);
    }

    if (!value.isUpperUnbounded && value.upper != null) {
      final bytes = elementCodec.encodeBinary(value.upper as T);
      final len = Uint8List(4);
      ByteData.sublistView(len).setInt32(0, bytes.length);
      builder.add(len);
      builder.add(bytes);
    }

    return builder.takeBytes();
  }

  @override
  Uint8List encodeText(PgRange<T> value) {
    return Uint8List.fromList(utf8.encode(value.toString()));
  }

  @override
  PgRange<T> decodeBinary(Uint8List bytes) {
    if (bytes.isEmpty) return PgRange<T>.empty();

    final flags = bytes[0];
    if ((flags & _rangeEmpty) != 0) {
      return PgRange<T>.empty();
    }

    final isLbInc = (flags & _rangeLbInc) != 0;
    final isUbInc = (flags & _rangeUbInc) != 0;
    final isLbInf = (flags & _rangeLbInf) != 0;
    final isUbInf = (flags & _rangeUbInf) != 0;

    var offset = 1;
    T? lower;
    T? upper;

    if (!isLbInf && offset + 4 <= bytes.length) {
      final len = ByteData.sublistView(bytes, offset, offset + 4).getInt32(0);
      offset += 4;
      if (offset + len <= bytes.length) {
        lower = elementCodec.decodeBinary(
          Uint8List.sublistView(bytes, offset, offset + len),
        );
        offset += len;
      }
    }

    if (!isUbInf && offset + 4 <= bytes.length) {
      final len = ByteData.sublistView(bytes, offset, offset + 4).getInt32(0);
      offset += 4;
      if (offset + len <= bytes.length) {
        upper = elementCodec.decodeBinary(
          Uint8List.sublistView(bytes, offset, offset + len),
        );
      }
    }

    return PgRange<T>(
      lower,
      upper,
      lowerInclusive: isLbInc,
      upperInclusive: isUbInc,
    );
  }

  @override
  PgRange<T> decodeText(Uint8List bytes) {
    final str = utf8.decode(bytes).trim();
    if (str == 'empty' || str.isEmpty) return PgRange<T>.empty();

    final lInc = str.startsWith('[');
    final uInc = str.endsWith(']');
    final inner = str.substring(1, str.length - 1);
    final parts = inner.split(',');

    T? lower;
    T? upper;

    if (parts.isNotEmpty && parts[0].isNotEmpty) {
      lower = elementCodec.decodeText(
        Uint8List.fromList(utf8.encode(parts[0])),
      );
    }
    if (parts.length > 1 && parts[1].isNotEmpty) {
      upper = elementCodec.decodeText(
        Uint8List.fromList(utf8.encode(parts[1])),
      );
    }

    return PgRange<T>(
      lower,
      upper,
      lowerInclusive: lInc,
      upperInclusive: uInc,
    );
  }
}

/// Range getters for [PgRow].
extension PgRowRangeGetters on PgRow {
  /// Decodes column as [PgRange<T>], or `null` if SQL NULL.
  @pragma('vm:prefer-inline')
  PgRange<T>? rangeOrNull<T>(Object column, PgCodec<T> elementCodec) =>
      decodeOrNull(column, RangeCodec<T>(elementCodec));

  /// Decodes column as [PgRange<T>]. Throws [StateError] if null.
  @pragma('vm:prefer-inline')
  PgRange<T> range<T>(Object column, PgCodec<T> elementCodec) =>
      decode(column, RangeCodec<T>(elementCodec));
}
