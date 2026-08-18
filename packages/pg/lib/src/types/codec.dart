import 'dart:typed_data';

/// Interface for PostgreSQL type encoders and decoders.
abstract interface class PgCodec<T> {
  /// Encodes [value] into binary wire format.
  Uint8List encodeBinary(T value);

  /// Encodes [value] into text wire format.
  Uint8List encodeText(T value);

  /// Decodes [bytes] from binary wire format.
  T decodeBinary(Uint8List bytes);

  /// Decodes [bytes] from text wire format.
  T decodeText(Uint8List bytes);
}

/// Extension for convenient decoding based on binary flag.
extension PgCodecExt<T> on PgCodec<T> {
  /// Decodes [bytes] using either binary or text format depending on
  /// [isBinary].
  T decode(Uint8List bytes, {bool isBinary = true}) {
    return isBinary ? decodeBinary(bytes) : decodeText(bytes);
  }

  /// Encodes [value] using either binary or text format depending on
  /// [isBinary].
  Uint8List encode(T value, {bool isBinary = true}) {
    return isBinary ? encodeBinary(value) : encodeText(value);
  }
}
