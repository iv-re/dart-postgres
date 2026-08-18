import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

/// A buffer for accumulating incoming network bytes and reading message frames.
class ReadBuffer {
  ReadBuffer({int initialCapacity = 65536})
    : _buffer = Uint8List(initialCapacity) {
    _bd = ByteData.sublistView(_buffer);
    _reader = MessageReader._(_buffer, _bd);
  }

  Uint8List _buffer;
  late ByteData _bd;
  late final MessageReader _reader;
  int _readOffset = 0;
  int _writeOffset = 0;

  /// The number of unread bytes in the buffer.
  int get length => _writeOffset - _readOffset;

  /// Whether the buffer has no unread bytes.
  bool get isEmpty => length == 0;

  /// Whether the buffer contains unread bytes.
  bool get isNotEmpty => length > 0;

  /// Appends incoming network bytes to the buffer.
  void add(List<int> chunk) {
    _ensure(chunk.length);
    _buffer.setRange(_writeOffset, _writeOffset + chunk.length, chunk);
    _writeOffset += chunk.length;
  }

  /// Consumes and returns the next complete message frame if available.
  ///
  /// The returned [MessageReader] is reused across calls to avoid allocations.
  /// Returns `null` if the buffer does not contain a complete frame yet.
  MessageReader? nextMessage() {
    if (length < 5) return null;

    final lengthPrefix = _bd.getInt32(_readOffset + 1);
    final totalFrameLength = 1 + lengthPrefix;

    if (length < totalFrameLength) return null;

    final tag = _buffer[_readOffset];
    _reader._reset(tag, _readOffset + 5, _readOffset + totalFrameLength);

    _readOffset += totalFrameLength;

    if (_readOffset == _writeOffset) {
      _readOffset = 0;
      _writeOffset = 0;
    }

    return _reader;
  }

  void _ensure(int size) {
    if (_writeOffset + size > _buffer.length) {
      final unread = length;
      if (unread > 0) {
        _buffer.setRange(0, unread, _buffer, _readOffset);
      }
      _readOffset = 0;
      _writeOffset = unread;

      if (_writeOffset + size > _buffer.length) {
        final newCap = math.max(_buffer.length * 2, _writeOffset + size);
        final newBuf = Uint8List(newCap);
        if (unread > 0) {
          newBuf.setRange(0, unread, _buffer);
        }
        _buffer = newBuf;
        _bd = ByteData.sublistView(newBuf);
        _reader._updateBuffer(newBuf, _bd);
      }
    }
  }
}

/// A reader for deserializing PostgreSQL backend message fields.
class MessageReader {
  /// Creates a standalone reader for [bytes].
  MessageReader(Uint8List bytes, {this.tag = 0})
    : _bytes = bytes,
      _bd = ByteData.sublistView(bytes),
      _offset = 0,
      _endOffset = bytes.length;

  MessageReader._(this._bytes, this._bd) : tag = 0, _offset = 0, _endOffset = 0;

  Uint8List _bytes;
  ByteData _bd;
  int _offset;
  int _endOffset;

  /// The 1-byte message tag (e.g. 'T', 'D', 'C', 'Z', 'R').
  int tag;

  void _reset(int newTag, int start, int end) {
    tag = newTag;
    _offset = start;
    _endOffset = end;
  }

  void _updateBuffer(Uint8List newBuffer, ByteData newBd) {
    _bytes = newBuffer;
    _bd = newBd;
  }

  /// The number of remaining unread bytes in this message frame.
  int get length => _endOffset - _offset;

  /// Whether all bytes in this message frame have been read.
  bool get isEmpty => length == 0;

  /// Whether there are unread bytes remaining in this message frame.
  bool get isNotEmpty => length > 0;

  /// Reads an 8-bit integer.
  int int8() => _bytes[_offset++];

  /// Reads a big-endian 16-bit integer.
  int int16() {
    final value = _bd.getInt16(_offset);
    _offset += 2;
    return value;
  }

  /// Reads a big-endian 32-bit integer.
  int int32() {
    final value = _bd.getInt32(_offset);
    _offset += 4;
    return value;
  }

  /// Reads a big-endian 64-bit integer.
  int int64() {
    final value = _bd.getInt64(_offset);
    _offset += 8;
    return value;
  }

  /// Reads a null-terminated UTF-8 string.
  String string() {
    final nullIndex = _bytes.indexOf(0, _offset);
    if (nullIndex == -1 || nullIndex >= _endOffset) {
      throw const FormatException('Missing null terminator in C-string');
    }
    final str = utf8.decode(Uint8List.sublistView(_bytes, _offset, nullIndex));
    _offset = nullIndex + 1;
    return str;
  }

  /// Reads [count] raw bytes as an independent Uint8List copy.
  Uint8List bytes(int count) {
    final slice = _bytes.sublist(_offset, _offset + count);
    _offset += count;
    return slice;
  }

  /// Reads all remaining bytes in this message frame as an independent copy.
  Uint8List rest() {
    final slice = _bytes.sublist(_offset, _endOffset);
    _offset = _endOffset;
    return slice;
  }
}
