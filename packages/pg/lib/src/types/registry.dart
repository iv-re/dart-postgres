import 'dart:convert';
import 'dart:typed_data';

import 'package:pg/src/types/codec.dart';
import 'package:pg/src/types/codecs/array.dart';
import 'package:pg/src/types/codecs/geo.dart';
import 'package:pg/src/types/codecs/json.dart';
import 'package:pg/src/types/codecs/numeric.dart';
import 'package:pg/src/types/codecs/primitives.dart';
import 'package:pg/src/types/codecs/temporal.dart';
import 'package:pg/src/types/codecs/text_search.dart';
import 'package:pg/src/types/oid.dart';

/// Registry mapping PostgreSQL Type OIDs and Dart Types to their respective
/// [PgCodec]s.
class PgTypeRegistry {
  PgTypeRegistry() : _codecsByOid = {}, _codecsByType = {} {
    _registerDefaults();
  }

  final Map<int, PgCodec<Object?>> _codecsByOid;
  final Map<Type, (PgOid, PgCodec<Object?>)> _codecsByType;

  /// Default static instance of [PgTypeRegistry] with all built-in types
  /// registered.
  static final PgTypeRegistry defaults = PgTypeRegistry();

  /// Registers a custom codec for a PostgreSQL type [oid] and Dart type [T].
  void register<T>({
    required PgOid oid,
    required PgCodec<T> codec,
    PgOid? arrayOid,
  }) {
    _codecsByOid[oid] = codec;
    _codecsByType[T] = (oid, codec);

    if (arrayOid != null) {
      final arrayCodec = ArrayCodec<T>(oid, codec);
      _codecsByOid[arrayOid] = arrayCodec;
      _codecsByType[List<T>] = (arrayOid, arrayCodec);
    }
  }

  /// Encodes a list of query parameters into PostgreSQL wire buffers.
  List<Uint8List?> encodeParameters(
    List<Object?> params, {
    List<PgOid>? paramOids,
    bool isBinary = true,
  }) {
    if (params.isEmpty) return const [];
    return List<Uint8List?>.generate(
      params.length,
      (i) => encodeValue(
        params[i],
        targetOid: (paramOids != null && i < paramOids.length)
            ? PgOid(paramOids[i])
            : null,
        isBinary: isBinary,
      ),
      growable: false,
    );
  }

  Uint8List? encodeValue(
    Object? value, {
    PgOid? targetOid,
    bool isBinary = true,
  }) {
    if (value == null) return null;

    switch (value) {
      case final bool v:
        return const BoolCodec().encode(v, isBinary: isBinary);

      case final int v when targetOid == .int2:
        return const Int2Codec().encode(v, isBinary: isBinary);

      case final int v
          when targetOid == .int4 ||
              (v >= -2147483648 && v <= 2147483647 && targetOid != .int8):
        return const Int4Codec().encode(v, isBinary: isBinary);

      case final int v:
        return const Int8Codec().encode(v, isBinary: isBinary);

      case final double v when targetOid == .float4:
        return const Float4Codec().encode(v, isBinary: isBinary);

      case final double v:
        return const Float8Codec().encode(v, isBinary: isBinary);

      case final BigInt v:
        return const BigIntCodec().encode(v, isBinary: isBinary);

      case final String v
          when targetOid == .uuid || (targetOid == null && _isUuid(v)):
        return const UuidCodec().encode(v, isBinary: isBinary);

      case final String v:
        return const TextCodec().encode(v, isBinary: isBinary);

      case final Uint8List v:
        return const ByteaCodec().encode(v, isBinary: isBinary);

      case final DateTime v when targetOid == .timestamp:
        return const TimestampCodec(isUtc: false).encode(v, isBinary: isBinary);

      case final DateTime v:
        return const TimestampCodec().encode(v, isBinary: isBinary);

      case final Duration v:
        return const IntervalCodec().encode(
          PgInterval.fromDuration(v),
          isBinary: isBinary,
        );

      case final Map<Object?, Object?> v:
        return const JsonbCodec().encode(jsonEncode(v), isBinary: isBinary);

      case final List<Object?> v:
        return _encodeArray(v, targetOid: targetOid, isBinary: isBinary);

      default:
        if (_codecsByType[value.runtimeType] case (_, final codec)) {
          return codec.encode(value, isBinary: isBinary);
        }
        if (targetOid != null) {
          if (_codecsByOid[targetOid] case final codec?) {
            return codec.encode(value, isBinary: isBinary);
          }
        }
        throw ArgumentError.value(
          value,
          'value',
          'Unsupported parameter type "${value.runtimeType}" '
              'for PostgreSQL encoding.',
        );
    }
  }

  /// Decodes [bytes] using the codec registered for [typeOid].
  T decodeValue<T>(
    Uint8List bytes, {
    required int typeOid,
    bool isBinary = true,
  }) {
    if (_codecsByOid[typeOid] case final codec?) {
      return codec.decode(bytes, isBinary: isBinary) as T;
    }
    if (T == Uint8List) return bytes as T;
    if (T == String) return utf8.decode(bytes) as T;
    throw ArgumentError.value(
      typeOid,
      'typeOid',
      'No codec registered for PostgreSQL type OID $typeOid to decode into $T.',
    );
  }

  void _registerDefaults() {
    // Primary Typed Codecs
    register<bool>(
      oid: .bool,
      codec: const BoolCodec(),
      arrayOid: .boolArray,
    );
    register<BigInt>(
      oid: .int8,
      codec: const BigIntCodec(),
      arrayOid: .int8Array,
    );
    register<double>(
      oid: .float8,
      codec: const Float8Codec(),
      arrayOid: .float8Array,
    );
    register<String>(
      oid: .text,
      codec: const TextCodec(),
      arrayOid: .textArray,
    );
    register<Uint8List>(
      oid: .bytea,
      codec: const ByteaCodec(),
      arrayOid: .byteaArray,
    );
    register<DateTime>(
      oid: .timestamptz,
      codec: const TimestampCodec(),
      arrayOid: .timestampTzArray,
    );
    register<PgDate>(
      oid: .date,
      codec: const DateCodec(),
      arrayOid: .dateArray,
    );
    register<PgTime>(
      oid: .time,
      codec: const TimeCodec(),
      arrayOid: .timeArray,
    );
    register<PgTimeTz>(
      oid: .timetz,
      codec: const TimeTzCodec(),
    );
    register<PgInterval>(
      oid: .interval,
      codec: const IntervalCodec(),
      arrayOid: .intervalArray,
    );
    register<PgNumeric>(
      oid: .numeric,
      codec: const NumericCodec(),
      arrayOid: .numericArray,
    );
    register<PgPoint>(
      oid: .point,
      codec: const PointCodec(),
      arrayOid: .pointArray,
    );
    register<PgBox>(oid: .box, codec: const BoxCodec());
    register<PgCircle>(oid: .circle, codec: const CircleCodec());
    register<PgPolygon>(oid: .polygon, codec: const PolygonCodec());
    register<PgTsVector>(oid: .tsvector, codec: const TsVectorCodec());
    register<PgTsQuery>(oid: .tsquery, codec: const TsQueryCodec());

    // Integer OID Variations & Arrays
    _codecsByOid[PgOid.int4] = const Int4Codec();
    _codecsByOid[PgOid.int2] = const Int2Codec();
    _codecsByOid[PgOid.int8] = const Int8Codec();
    _codecsByOid[PgOid.int4Array] = const ArrayCodec<int>(.int4, Int4Codec());
    _codecsByOid[PgOid.int2Array] = const ArrayCodec<int>(.int2, Int2Codec());
    _codecsByOid[PgOid.int8Array] = const ArrayCodec<int>(.int8, Int8Codec());

    // Float OID Variations
    _codecsByOid[PgOid.float4] = const Float4Codec();
    _codecsByOid[PgOid.float4Array] = const ArrayCodec<double>(
      .float4,
      Float4Codec(),
    );

    // Text-like OID Aliases
    _codecsByOid[PgOid.varchar] = const TextCodec();
    _codecsByOid[PgOid.varcharArray] = const ArrayCodec<String>(
      .varchar,
      TextCodec(),
    );
    _codecsByOid[PgOid.char] = const TextCodec();
    _codecsByOid[PgOid.charArray] = const ArrayCodec<String>(
      .char,
      TextCodec(),
    );
    _codecsByOid[PgOid.bpchar] = const TextCodec();
    _codecsByOid[PgOid.bpcharArray] = const ArrayCodec<String>(
      .bpchar,
      TextCodec(),
    );
    _codecsByOid[PgOid.name] = const TextCodec();
    _codecsByOid[PgOid.nameArray] = const ArrayCodec<String>(
      .name,
      TextCodec(),
    );

    // Special / UUID / JSON / Timestamp OIDs
    _codecsByOid[PgOid.uuid] = const UuidCodec();
    _codecsByOid[PgOid.uuidArray] = const ArrayCodec<String>(
      .uuid,
      UuidCodec(),
    );
    _codecsByOid[PgOid.json] = const JsonCodec();
    _codecsByOid[PgOid.jsonArray] = const ArrayCodec<String>(
      .json,
      JsonCodec(),
    );
    _codecsByOid[PgOid.jsonb] = const JsonbCodec();
    _codecsByOid[PgOid.jsonbArray] = const ArrayCodec<String>(
      .jsonb,
      JsonbCodec(),
    );
    _codecsByOid[PgOid.timestamp] = const TimestampCodec(isUtc: false);
    _codecsByOid[PgOid.timestampArray] = const ArrayCodec<DateTime>(
      .timestamp,
      TimestampCodec(isUtc: false),
    );
  }

  Uint8List _encodeArray(
    List<Object?> list, {
    required bool isBinary,
    PgOid? targetOid,
  }) {
    final arrayOid = targetOid ?? _inferArrayOid(list);
    final codec = _codecsByOid[arrayOid];
    if (codec is! ArrayCodec<dynamic>) {
      throw ArgumentError.value(
        list,
        'list',
        'No ArrayCodec registered for PostgreSQL array OID $arrayOid.',
      );
    }

    final List<Object?> typedList;
    switch (codec.elementOid) {
      case .int2 || .int4 || .int8:
        typedList = list.map((e) => (e as num?)?.toInt()).toList();
      case .float4 || .float8:
        typedList = list.map((e) => (e as num?)?.toDouble()).toList();
      case .bool:
        typedList = list.cast<bool?>();
      case .bytea:
        typedList = list.cast<Uint8List?>();
      case .text || .varchar || .bpchar || .name || .char:
        typedList = list.map((e) => e?.toString()).toList();
      case .json || .jsonb:
        typedList = list
            .map((e) => e == null ? null : (e is String ? e : jsonEncode(e)))
            .toList();
      case .timestamp || .timestamptz:
        typedList = list.cast<DateTime?>();
      default:
        typedList = list.toList();
    }

    return codec.encode(typedList, isBinary: isBinary);
  }

  PgOid _inferArrayOid(List<Object?> list) {
    if (list is List<bool>) return .boolArray;
    if (list is List<int>) return .int4Array;
    if (list is List<double>) return .float8Array;
    if (list is List<String>) return .textArray;
    if (list is List<DateTime>) return .timestampTzArray;
    if (list is List<Uint8List>) return .byteaArray;
    for (final item in list) {
      if (item != null) {
        if (item is bool) return .boolArray;
        if (item is int) return .int4Array;
        if (item is double) return .float8Array;
        if (item is DateTime) return .timestampTzArray;
        if (item is Uint8List) return .byteaArray;
        if (item is Map) return .jsonbArray;
        return .textArray;
      }
    }
    return .textArray;
  }
}

bool _isUuid(String s) {
  if (s.length != 36) return false;
  if (s.codeUnitAt(8) != 0x2D ||
      s.codeUnitAt(13) != 0x2D ||
      s.codeUnitAt(18) != 0x2D ||
      s.codeUnitAt(23) != 0x2D) {
    return false;
  }
  for (var i = 0; i < 36; i++) {
    if (i == 8 || i == 13 || i == 18 || i == 23) continue;
    final c = s.codeUnitAt(i);
    if (!((c >= 0x30 && c <= 0x39) ||
        (c >= 0x61 && c <= 0x66) ||
        (c >= 0x41 && c <= 0x46))) {
      return false;
    }
  }
  return true;
}
