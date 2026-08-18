import 'dart:convert';
import 'dart:core' as core;
import 'dart:core';
import 'dart:typed_data';

import 'package:pg/src/client/rows.dart';
import 'package:pg/src/types/codec.dart';

final _binaryBoolTrue = Uint8List(1)..[0] = 1;
final _binaryBoolFalse = Uint8List(1)..[0] = 0;
final _textBoolTrue = Uint8List.fromList(const [0x74]); // 't'
final _textBoolFalse = Uint8List.fromList(const [0x66]); // 'f'

/// Codec for PostgreSQL `bool` type.
class const BoolCodec() implements PgCodec<core.bool> {
  @override
  Uint8List encodeBinary(core.bool value) {
    return value ? _binaryBoolTrue : _binaryBoolFalse;
  }

  @override
  Uint8List encodeText(core.bool value) {
    return value ? _textBoolTrue : _textBoolFalse;
  }

  @override
  core.bool decodeBinary(Uint8List bytes) {
    return bytes.isNotEmpty && bytes[0] == 1;
  }

  @override
  core.bool decodeText(Uint8List bytes) {
    if (bytes.isEmpty) return false;
    final b = bytes[0];
    return b == 0x74 || b == 0x54 || b == 0x31; // 't', 'T', '1'
  }
}

/// Codec for PostgreSQL `int2` (smallint) type.
class const Int2Codec() implements PgCodec<core.int> {
  @override
  Uint8List encodeBinary(core.int value) {
    final bytes = Uint8List(2);
    ByteData.sublistView(bytes).setInt16(0, value);
    return bytes;
  }

  @override
  Uint8List encodeText(core.int value) {
    return Uint8List.fromList(utf8.encode(value.toString()));
  }

  @override
  core.int decodeBinary(Uint8List bytes) {
    return ByteData.sublistView(bytes).getInt16(0);
  }

  @override
  core.int decodeText(Uint8List bytes) => core.int.parse(utf8.decode(bytes));
}

/// Codec for PostgreSQL `int4` (integer) type.
class const Int4Codec() implements PgCodec<core.int> {
  @override
  Uint8List encodeBinary(core.int value) {
    final bytes = Uint8List(4);
    ByteData.sublistView(bytes).setInt32(0, value);
    return bytes;
  }

  @override
  Uint8List encodeText(core.int value) {
    return Uint8List.fromList(utf8.encode(value.toString()));
  }

  @override
  core.int decodeBinary(Uint8List bytes) {
    if (bytes.length == 4) {
      return ByteData.sublistView(bytes).getInt32(0);
    }
    if (bytes.length == 8) {
      return ByteData.sublistView(bytes).getInt64(0);
    }
    if (bytes.length == 2) {
      return ByteData.sublistView(bytes).getInt16(0);
    }
    throw ArgumentError('Invalid binary int length: ${bytes.length}');
  }

  @override
  core.int decodeText(Uint8List bytes) => core.int.parse(utf8.decode(bytes));
}

/// Codec for PostgreSQL `int8` (bigint) type when mapped to [int].
class const Int8Codec() implements PgCodec<core.int> {
  @override
  Uint8List encodeBinary(core.int value) {
    final bytes = Uint8List(8);
    ByteData.sublistView(bytes).setInt64(0, value);
    return bytes;
  }

  @override
  Uint8List encodeText(core.int value) {
    return Uint8List.fromList(utf8.encode(value.toString()));
  }

  @override
  core.int decodeBinary(Uint8List bytes) {
    if (bytes.length == 8) {
      return ByteData.sublistView(bytes).getInt64(0);
    }
    if (bytes.length == 4) {
      return ByteData.sublistView(bytes).getInt32(0);
    }
    throw ArgumentError('Invalid binary int length: ${bytes.length}');
  }

  @override
  core.int decodeText(Uint8List bytes) => core.int.parse(utf8.decode(bytes));
}

/// Codec for PostgreSQL `int8` (bigint) type when mapped to [BigInt].
class const BigIntCodec() implements PgCodec<core.BigInt> {
  @override
  Uint8List encodeBinary(core.BigInt value) {
    if (value.isValidInt) {
      final bytes = Uint8List(8);
      ByteData.sublistView(bytes).setInt64(0, value.toInt());
      return bytes;
    }
    return Uint8List.fromList(utf8.encode(value.toString()));
  }

  @override
  Uint8List encodeText(core.BigInt value) {
    return Uint8List.fromList(utf8.encode(value.toString()));
  }

  @override
  core.BigInt decodeBinary(Uint8List bytes) {
    if (bytes.length == 8) {
      return core.BigInt.from(ByteData.sublistView(bytes).getInt64(0));
    }
    if (bytes.length == 4) {
      return core.BigInt.from(ByteData.sublistView(bytes).getInt32(0));
    }
    throw ArgumentError('Invalid binary bigint length: ${bytes.length}');
  }

  @override
  core.BigInt decodeText(Uint8List bytes) {
    return core.BigInt.parse(utf8.decode(bytes));
  }
}

/// Codec for PostgreSQL `float4` (real) type.
class const Float4Codec() implements PgCodec<core.double> {
  @override
  Uint8List encodeBinary(core.double value) {
    final bytes = Uint8List(4);
    ByteData.sublistView(bytes).setFloat32(0, value);
    return bytes;
  }

  @override
  Uint8List encodeText(core.double value) {
    return Uint8List.fromList(utf8.encode(value.toString()));
  }

  @override
  core.double decodeBinary(Uint8List bytes) {
    return ByteData.sublistView(bytes).getFloat32(0);
  }

  @override
  core.double decodeText(Uint8List bytes) {
    return core.double.parse(utf8.decode(bytes));
  }
}

/// Codec for PostgreSQL `float8` (double precision) type.
class const Float8Codec() implements PgCodec<core.double> {
  @override
  Uint8List encodeBinary(core.double value) {
    final bytes = Uint8List(8);
    ByteData.sublistView(bytes).setFloat64(0, value);
    return bytes;
  }

  @override
  Uint8List encodeText(core.double value) {
    return Uint8List.fromList(utf8.encode(value.toString()));
  }

  @override
  core.double decodeBinary(Uint8List bytes) {
    if (bytes.length == 8) {
      return ByteData.sublistView(bytes).getFloat64(0);
    }
    if (bytes.length == 4) {
      return ByteData.sublistView(bytes).getFloat32(0);
    }
    throw ArgumentError('Invalid binary float length: ${bytes.length}');
  }

  @override
  core.double decodeText(Uint8List bytes) {
    return core.double.parse(utf8.decode(bytes));
  }
}

/// Codec for PostgreSQL text-like types (`text`, `varchar`, `char`, `name`,
/// `bpchar`).
class const TextCodec() implements PgCodec<core.String> {
  @override
  Uint8List encodeBinary(core.String value) {
    return Uint8List.fromList(utf8.encode(value));
  }

  @override
  Uint8List encodeText(core.String value) {
    return Uint8List.fromList(utf8.encode(value));
  }

  @override
  core.String decodeBinary(Uint8List bytes) => utf8.decode(bytes);

  @override
  core.String decodeText(Uint8List bytes) => utf8.decode(bytes);
}

/// Codec for PostgreSQL `bytea` type.
class const ByteaCodec() implements PgCodec<Uint8List> {
  @override
  Uint8List encodeBinary(Uint8List value) => value;

  @override
  Uint8List encodeText(Uint8List value) {
    final buffer = StringBuffer(r'\x');
    for (final b in value) {
      buffer.write(_hexChars[(b >> 4) & 0x0F]);
      buffer.write(_hexChars[b & 0x0F]);
    }
    return Uint8List.fromList(utf8.encode(buffer.toString()));
  }

  @override
  Uint8List decodeBinary(Uint8List bytes) => bytes;

  @override
  Uint8List decodeText(Uint8List bytes) {
    if (bytes.length >= 2 && bytes[0] == 0x5C && bytes[1] == 0x78) {
      final len = (bytes.length - 2) ~/ 2;
      final result = Uint8List(len);
      var outIdx = 0;
      for (var i = 2; i < bytes.length; i += 2) {
        final high = _hexVal(bytes[i]);
        final low = (i + 1 < bytes.length) ? _hexVal(bytes[i + 1]) : 0;
        result[outIdx++] = (high << 4) | low;
      }
      return result;
    }
    return bytes;
  }
}

/// Codec for PostgreSQL `uuid` type.
class const UuidCodec() implements PgCodec<core.String> {
  @override
  Uint8List encodeBinary(core.String value) {
    final bytes = Uint8List(16);
    var byteIndex = 0;
    var high = -1;
    for (var i = 0; i < value.length; i++) {
      final code = value.codeUnitAt(i);
      if (code == 0x2D) continue; // '-'
      final val = (code >= 0x30 && code <= 0x39)
          ? code - 0x30
          : (code >= 0x61 && code <= 0x66)
          ? code - 0x57
          : (code >= 0x41 && code <= 0x46)
          ? code - 0x37
          : 0;
      if (high == -1) {
        high = val;
      } else {
        bytes[byteIndex++] = (high << 4) | val;
        high = -1;
      }
    }
    return bytes;
  }

  @override
  Uint8List encodeText(core.String value) {
    return Uint8List.fromList(utf8.encode(value));
  }

  @override
  core.String decodeBinary(Uint8List bytes) {
    if (bytes.length == 16) {
      final buffer = StringBuffer();
      for (var i = 0; i < 16; i++) {
        if (i == 4 || i == 6 || i == 8 || i == 10) {
          buffer.write('-');
        }
        final b = bytes[i];
        buffer.write(_hexChars[(b >> 4) & 0x0F]);
        buffer.write(_hexChars[b & 0x0F]);
      }
      return buffer.toString();
    }
    return utf8.decode(bytes);
  }

  @override
  core.String decodeText(Uint8List bytes) => utf8.decode(bytes);
}

const _hexChars = '0123456789abcdef';

int _hexVal(int code) {
  if (code >= 0x30 && code <= 0x39) return code - 0x30;
  if (code >= 0x61 && code <= 0x66) return code - 0x57;
  if (code >= 0x41 && code <= 0x46) return code - 0x37;
  return 0;
}

const _boolCodec = BoolCodec();
const _int4Codec = Int4Codec();
const _bigIntCodec = BigIntCodec();
const _float8Codec = Float8Codec();
const _textCodec = TextCodec();
const _byteaCodec = ByteaCodec();
const _uuidCodec = UuidCodec();

/// Convenience primitive getters for [PgRow].
extension PgRowPrimitiveGetters on PgRow {
  /// Decodes column as [bool], or `null` if SQL NULL.
  @pragma('vm:prefer-inline')
  core.bool? boolOrNull(core.Object column) => decodeOrNull(column, _boolCodec);

  /// Decodes column as [bool]. Throws [StateError] if null.
  @pragma('vm:prefer-inline')
  core.bool bool(core.Object column) => decode(column, _boolCodec);

  /// Decodes column as [int], or `null` if SQL NULL.
  @pragma('vm:prefer-inline')
  core.int? intOrNull(core.Object column) => decodeOrNull(column, _int4Codec);

  /// Decodes column as [int]. Throws [StateError] if null.
  @pragma('vm:prefer-inline')
  core.int int(core.Object column) => decode(column, _int4Codec);

  /// Decodes column as [BigInt], or `null` if SQL NULL.
  @pragma('vm:prefer-inline')
  core.BigInt? bigintOrNull(core.Object column) =>
      decodeOrNull(column, _bigIntCodec);

  /// Decodes column as [BigInt]. Throws [StateError] if null.
  @pragma('vm:prefer-inline')
  core.BigInt bigint(core.Object column) => decode(column, _bigIntCodec);

  /// Decodes column as [double], or `null` if SQL NULL.
  @pragma('vm:prefer-inline')
  core.double? doubleOrNull(core.Object column) =>
      decodeOrNull(column, _float8Codec);

  /// Decodes column as [double]. Throws [StateError] if null.
  @pragma('vm:prefer-inline')
  core.double double(core.Object column) => decode(column, _float8Codec);

  /// Decodes column as UTF-8 [String], or `null` if SQL NULL.
  @pragma('vm:prefer-inline')
  core.String? stringOrNull(core.Object column) =>
      decodeOrNull(column, _textCodec);

  /// Decodes column as UTF-8 [String]. Throws [StateError] if null.
  @pragma('vm:prefer-inline')
  core.String string(core.Object column) => decode(column, _textCodec);

  /// Decodes column as [Uint8List] (bytea), or `null` if SQL NULL.
  @pragma('vm:prefer-inline')
  Uint8List? bytesOrNull(core.Object column) =>
      decodeOrNull(column, _byteaCodec);

  /// Decodes column as [Uint8List] (bytea). Throws [StateError] if null.
  @pragma('vm:prefer-inline')
  Uint8List bytes(core.Object column) => decode(column, _byteaCodec);

  /// Decodes column as UUID [String], or `null` if SQL NULL.
  @pragma('vm:prefer-inline')
  core.String? uuidOrNull(core.Object column) =>
      decodeOrNull(column, _uuidCodec);

  /// Decodes column as UUID [String]. Throws [StateError] if null.
  @pragma('vm:prefer-inline')
  core.String uuid(core.Object column) => decode(column, _uuidCodec);
}
