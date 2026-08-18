import 'dart:convert';
import 'dart:typed_data';

/// A buffer for serializing PostgreSQL frontend messages.
class MessageWriter {
  MessageWriter({int initialCapacity = 1024})
    : _buffer = Uint8List(initialCapacity) {
    _bd = ByteData.sublistView(_buffer);
  }

  Uint8List _buffer;
  late ByteData _bd;
  int _offset = 0;

  /// The number of bytes currently written.
  int get length => _offset;

  /// Writes an 8-bit integer.
  void int8(int value) {
    _ensure(1);
    _buffer[_offset++] = value & 0xFF;
  }

  /// Writes a big-endian 16-bit integer.
  void int16(int value) {
    _ensure(2);
    _bd.setInt16(_offset, value);
    _offset += 2;
  }

  /// Writes a big-endian 32-bit integer.
  void int32(int value) {
    _ensure(4);
    _bd.setInt32(_offset, value);
    _offset += 4;
  }

  /// Writes a big-endian 64-bit integer.
  void int64(int value) {
    _ensure(8);
    _bd.setInt64(_offset, value);
    _offset += 8;
  }

  /// Writes a null-terminated UTF-8 string.
  void string(String value) {
    final len = value.length;
    _ensure(len + 1);

    var isAscii = true;
    for (var i = 0; i < len; i++) {
      final unit = value.codeUnitAt(i);
      if (unit > 0x7F) {
        isAscii = false;
        break;
      }
      _buffer[_offset + i] = unit;
    }

    if (isAscii) {
      _offset += len;
      _buffer[_offset++] = 0;
      return;
    }

    final encoded = utf8.encode(value);
    _ensure(encoded.length + 1);
    _buffer.setRange(_offset, _offset + encoded.length, encoded);
    _offset += encoded.length;
    _buffer[_offset++] = 0;
  }

  /// Writes raw bytes.
  void bytes(List<int> bytes) {
    _ensure(bytes.length);
    _buffer.setRange(_offset, _offset + bytes.length, bytes);
    _offset += bytes.length;
  }

  /// Writes a standard message frame with a 1-byte [tag] and length prefix.
  void frame(int tag, void Function(MessageWriter w) build) {
    int8(tag);
    final lengthOffset = _offset;
    int32(0);
    build(this);
    final totalLength = _offset - lengthOffset;
    _bd.setInt32(lengthOffset, totalLength);
  }

  /// Writes a startup message frame with protocol version 3.0.
  void startup(void Function(MessageWriter w) build) {
    final lengthOffset = _offset;
    int32(0);
    int32(196608);
    build(this);
    int8(0);
    final totalLength = _offset - lengthOffset;
    _bd.setInt32(lengthOffset, totalLength);
  }

  /// Returns accumulated bytes and resets the buffer offset.
  Uint8List takeBytes() {
    final result = Uint8List.fromList(
      Uint8List.sublistView(_buffer, 0, _offset),
    );
    _offset = 0;
    return result;
  }

  void _ensure(int size) {
    if (_offset + size > _buffer.length) {
      var newCap = _buffer.length * 2;
      while (newCap < _offset + size) {
        newCap *= 2;
      }
      final newBuf = Uint8List(newCap);
      newBuf.setRange(0, _offset, _buffer);
      _buffer = newBuf;
      _bd = ByteData.sublistView(newBuf);
    }
  }
}
