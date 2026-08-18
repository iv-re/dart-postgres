import 'dart:convert';
import 'dart:typed_data';

import 'package:pg/src/client/rows.dart';
import 'package:pg/src/types/codec.dart';

/// Codec for PostgreSQL `json` type.
class const JsonCodec() implements PgCodec<String> {
  @override
  Uint8List encodeBinary(String value) {
    return Uint8List.fromList(utf8.encode(value));
  }

  @override
  Uint8List encodeText(String value) => Uint8List.fromList(utf8.encode(value));

  @override
  String decodeBinary(Uint8List bytes) => utf8.decode(bytes);

  @override
  String decodeText(Uint8List bytes) => utf8.decode(bytes);
}

/// Codec for PostgreSQL `jsonb` type.
class const JsonbCodec() implements PgCodec<String> {
  @override
  Uint8List encodeBinary(String value) {
    final jsonBytes = utf8.encode(value);
    final bytes = Uint8List(1 + jsonBytes.length);
    bytes[0] = 1; // JSONB binary version 1
    bytes.setRange(1, bytes.length, jsonBytes);
    return bytes;
  }

  @override
  Uint8List encodeText(String value) => Uint8List.fromList(utf8.encode(value));

  @override
  String decodeBinary(Uint8List bytes) {
    if (bytes.isNotEmpty && bytes[0] == 1) {
      return utf8.decode(Uint8List.sublistView(bytes, 1));
    }
    return utf8.decode(bytes);
  }

  @override
  String decodeText(Uint8List bytes) => utf8.decode(bytes);
}

const _jsonbCodec = JsonbCodec();
final Converter<List<int>, Object?> _jsonUtf8 = utf8.decoder.fuse(json.decoder);

/// JSON and JSONB getters for [PgRow].
extension PgRowJsonGetters on PgRow {
  /// Decodes column as raw unparsed JSON [String], or `null` if SQL NULL.
  @pragma('vm:prefer-inline')
  String? rawJsonOrNull(Object column) => decodeOrNull(column, _jsonbCodec);

  /// Decodes column as raw unparsed JSON [String]. Throws [StateError] if null.
  @pragma('vm:prefer-inline')
  String rawJson(Object column) => decode(column, _jsonbCodec);

  /// Decodes column as parsed JSON object of type [T], or `null` if SQL NULL.
  @pragma('vm:prefer-inline')
  T? jsonOrNull<T>(Object column) {
    final bytes = this[column];
    if (bytes == null) return null;
    final payload = (bytes.isNotEmpty && bytes[0] == 1)
        ? Uint8List.sublistView(bytes, 1)
        : bytes;
    return _jsonUtf8.convert(payload) as T;
  }

  /// Decodes column as parsed JSON object of type [T]. Throws [StateError] if
  /// null.
  @pragma('vm:prefer-inline')
  T json<T>(Object column) =>
      jsonOrNull<T>(column) ?? (throw StateError('Column "$column" is null'));
}
