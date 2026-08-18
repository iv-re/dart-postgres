import 'dart:convert';
import 'dart:typed_data';

import 'package:pg/src/client/rows.dart';
import 'package:pg/src/types/codec.dart';
import 'package:pg/src/types/oid.dart';

final _nullLengthBytes = Uint8List(4)
  ..[0] = 0xFF
  ..[1] = 0xFF
  ..[2] = 0xFF
  ..[3] = 0xFF; // -1 (int32)

/// Generic codec for PostgreSQL 1D and N-dimensional arrays.
class const ArrayCodec<T>(
  final PgOid elementOid,
  final PgCodec<T> elementCodec,
) implements PgCodec<List<T?>> {
  @override
  Uint8List encodeBinary(List<T?> elements) {
    if (elements.isEmpty) {
      final bytes = Uint8List(12);
      final bd = ByteData.sublistView(bytes);
      bd.setInt32(0, 0); // ndim = 0
      bd.setInt32(4, 0); // flags = 0
      bd.setInt32(8, elementOid); // elemtype
      return bytes;
    }

    final hasNulls = elements.contains(null);
    final builder = BytesBuilder();

    final header = Uint8List(20);
    final headerBd = ByteData.sublistView(header);
    headerBd.setInt32(0, 1); // ndim = 1
    headerBd.setInt32(4, hasNulls ? 1 : 0); // flags
    headerBd.setInt32(8, elementOid); // elemtype
    headerBd.setInt32(12, elements.length); // dim_len
    headerBd.setInt32(16, 1); // lower_bound = 1

    builder.add(header);

    for (final elem in elements) {
      if (elem == null) {
        builder.add(_nullLengthBytes);
      } else {
        final elemBytes = elementCodec.encodeBinary(elem);
        final lenBytes = Uint8List(4);
        ByteData.sublistView(lenBytes).setInt32(0, elemBytes.length);
        builder.add(lenBytes);
        builder.add(elemBytes);
      }
    }

    return builder.takeBytes();
  }

  @override
  Uint8List encodeText(List<T?> elements) {
    final buffer = StringBuffer('{');
    for (var i = 0; i < elements.length; i++) {
      if (i > 0) buffer.write(',');
      final elem = elements[i];
      if (elem == null) {
        buffer.write('NULL');
      } else {
        final encoded = utf8.decode(elementCodec.encodeText(elem));
        if (encoded.contains(',') ||
            encoded.contains('{') ||
            encoded.contains('}') ||
            encoded.contains('"') ||
            encoded.contains(r'\') ||
            encoded.contains(' ')) {
          buffer.write(
            '"${encoded.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"',
          );
        } else {
          buffer.write(encoded);
        }
      }
    }
    buffer.write('}');
    return Uint8List.fromList(utf8.encode(buffer.toString()));
  }

  @override
  List<T?> decodeBinary(Uint8List bytes) {
    if (bytes.length < 12) return <T>[];

    // Check if it's text representation starting with '{'
    if (bytes.first == 0x7B && bytes.last == 0x7D) {
      return decodeText(bytes);
    }

    final bd = ByteData.sublistView(bytes);
    final ndim = bd.getInt32(0);
    if (ndim == 0) return <T>[];

    final dimLen = bd.getInt32(12);
    var offset = 12 + (ndim * 8); // Skip dimensions and lower bounds

    final result = <T?>[];
    for (var i = 0; i < dimLen; i++) {
      if (offset + 4 > bytes.length) break;
      final elemLen = bd.getInt32(offset);
      offset += 4;

      if (elemLen == -1) {
        result.add(null);
      } else {
        if (offset + elemLen > bytes.length) break;
        final elemBytes = Uint8List.sublistView(
          bytes,
          offset,
          offset + elemLen,
        );
        offset += elemLen;
        result.add(elementCodec.decodeBinary(elemBytes));
      }
    }

    return result;
  }

  @override
  List<T?> decodeText(Uint8List bytes) {
    final str = utf8.decode(bytes, allowMalformed: true);
    return parseTextList<T?>(
      str,
      (token) {
        return elementCodec.decodeText(Uint8List.fromList(utf8.encode(token)));
      },
    );
  }
}

/// Parses a PostgreSQL text format array into typed elements.
List<T> parseTextList<T>(String src, T Function(String token) tokenParser) {
  final trimmed = src.trim();
  if (trimmed == '{}' || trimmed.isEmpty) return <T>[];
  if (!trimmed.startsWith('{') || !trimmed.endsWith('}')) return <T>[];

  final inner = trimmed.substring(1, trimmed.length - 1);
  final items = <T>[];
  final buffer = StringBuffer();
  var inQuotes = false;
  var escape = false;

  for (var i = 0; i < inner.length; i++) {
    final c = inner[i];
    if (escape) {
      buffer.write(c);
      escape = false;
    } else if (c == r'\') {
      escape = true;
    } else if (c == '"') {
      inQuotes = !inQuotes;
    } else if (c == ',' && !inQuotes) {
      final token = buffer.toString();
      items.add(_parseToken(token, tokenParser));
      buffer.clear();
    } else {
      buffer.write(c);
    }
  }

  if (buffer.isNotEmpty || inQuotes) {
    final token = buffer.toString();
    items.add(_parseToken(token, tokenParser));
  }

  return items;
}

T _parseToken<T>(String token, T Function(String token) tokenParser) {
  if (token == 'NULL') return null as T;
  return tokenParser(token);
}

// Fallback dynamic element decoder for [decodeList]
T _decodeElement<T>(Uint8List bytes) {
  if (T == int) {
    try {
      final str = utf8.decode(bytes);
      final val = int.tryParse(str);
      if (val != null) return val as T;
    } catch (_) {}
    if (bytes.length == 4) return ByteData.sublistView(bytes).getInt32(0) as T;
    if (bytes.length == 8) return ByteData.sublistView(bytes).getInt64(0) as T;
    if (bytes.length == 2) return ByteData.sublistView(bytes).getInt16(0) as T;
    return int.parse(utf8.decode(bytes)) as T;
  }
  if (T == double) {
    try {
      final str = utf8.decode(bytes);
      final val = double.tryParse(str);
      if (val != null) return val as T;
    } catch (_) {}
    if (bytes.length == 8) {
      return ByteData.sublistView(bytes).getFloat64(0) as T;
    }
    if (bytes.length == 4) {
      return ByteData.sublistView(bytes).getFloat32(0) as T;
    }
    return double.parse(utf8.decode(bytes)) as T;
  }
  if (T == bool) {
    if (bytes.isNotEmpty) {
      final b = bytes[0];
      return (b == 1 || b == 0x74 || b == 0x54) as T;
    }
    return false as T;
  }
  if (T == String) {
    return utf8.decode(bytes) as T;
  }
  if (T == Uint8List) {
    return bytes as T;
  }
  if (T == BigInt) {
    try {
      final str = utf8.decode(bytes);
      final val = BigInt.tryParse(str);
      if (val != null) return val as T;
    } catch (_) {}
    if (bytes.length == 8) {
      return BigInt.from(ByteData.sublistView(bytes).getInt64(0)) as T;
    }
    return BigInt.parse(utf8.decode(bytes)) as T;
  }
  return utf8.decode(bytes) as T;
}

/// Helper function to decode any binary or text array into [List<T>].
List<T>? decodeList<T>(Uint8List? bytes) {
  if (bytes == null) return null;
  if (bytes.isEmpty) return <T>[];

  if (bytes.first == 0x7B && bytes.last == 0x7D) {
    final str = utf8.decode(bytes, allowMalformed: true);
    return parseTextList<T>(
      str,
      (token) => _decodeElement<T>(Uint8List.fromList(utf8.encode(token))),
    );
  }

  if (bytes.length < 12) return <T>[];

  final bd = ByteData.sublistView(bytes);
  final ndim = bd.getInt32(0);
  if (ndim == 0) return <T>[];

  final dimLen = bd.getInt32(12);
  var offset = 12 + (ndim * 8);

  final result = <T>[];
  for (var i = 0; i < dimLen; i++) {
    if (offset + 4 > bytes.length) break;
    final elemLen = bd.getInt32(offset);
    offset += 4;

    if (elemLen == -1) {
      result.add(null as T);
    } else {
      if (offset + elemLen > bytes.length) break;
      final elemBytes = Uint8List.sublistView(bytes, offset, offset + elemLen);
      offset += elemLen;
      result.add(_decodeElement<T>(elemBytes));
    }
  }

  return result;
}

/// Array getters for [PgRow].
extension PgRowArrayGetters on PgRow {
  /// Decodes column array as [List<T>], or `null` if SQL NULL.
  @pragma('vm:prefer-inline')
  List<T>? listOrNull<T>(Object column) => decodeList<T>(this[column]);

  /// Decodes column array as [List<T>]. Throws [StateError] if null.
  @pragma('vm:prefer-inline')
  List<T> list<T>(Object column) =>
      listOrNull<T>(column) ?? (throw StateError('Column "$column" is null'));
}
