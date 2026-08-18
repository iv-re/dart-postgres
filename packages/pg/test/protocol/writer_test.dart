import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:pg/src/protocol/writer.dart';
import 'package:test/scaffolding.dart';

void main() {
  group('MessageWriter', () {
    late MessageWriter writer;

    setUp(() {
      writer = MessageWriter();
    });

    test('int8 writes a single byte', () {
      writer
        ..int8(0)
        ..int8(127)
        ..int8(255);

      check(writer.takeBytes()).deepEquals([0, 127, 255]);
    });

    test('int16 writes 16-bit big-endian integer', () {
      writer
        ..int16(0)
        ..int16(0x1234)
        ..int16(-1);

      check(
        writer.takeBytes(),
      ).deepEquals([0x00, 0x00, 0x12, 0x34, 0xFF, 0xFF]);
    });

    test('int32 writes 32-bit big-endian integer', () {
      writer
        ..int32(0)
        ..int32(0x12345678)
        ..int32(-1);

      check(
        writer.takeBytes(),
      ).deepEquals([
        0x00,
        0x00,
        0x00,
        0x00,
        0x12,
        0x34,
        0x56,
        0x78,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
      ]);
    });

    test('int64 writes 64-bit big-endian integer', () {
      writer.int64(0x0011223344556677);

      check(
        writer.takeBytes(),
      ).deepEquals([0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77]);
    });

    test('string writes null-terminated UTF-8 string', () {
      writer.string('test');

      check(writer.takeBytes()).deepEquals([116, 101, 115, 116, 0]);
    });

    test('string writes null-terminator for empty string', () {
      writer.string('');

      check(writer.takeBytes()).deepEquals([0]);
    });

    test('string writes multi-byte UTF-8 characters', () {
      const text = 'Привет';
      final utf8Bytes = utf8.encode(text);

      writer.string(text);

      check(writer.takeBytes()).deepEquals([...utf8Bytes, 0]);
    });

    test('bytes writes raw byte array', () {
      writer.bytes([1, 2, 3, 4, 5]);

      check(writer.takeBytes()).deepEquals([1, 2, 3, 4, 5]);
    });

    test('frame writes message with tag, length prefix and payload', () {
      writer.frame(0x51, (w) {
        w.string('SELECT 1');
      });

      // 'Q' = 0x51, length = 4 (length itself) + 9 ('SELECT 1\0') = 13
      check(
        writer.takeBytes(),
      ).deepEquals([
        0x51, // tag 'Q'
        0x00, 0x00, 0x00, 0x0D, // length = 13
        83, 69, 76, 69, 67, 84, 32, 49, 0, // 'SELECT 1\0'
      ]);
    });

    test('frame writes empty message correctly', () {
      writer.frame(0x53, (_) {}); // Sync 'S'

      check(
        writer.takeBytes(),
      ).deepEquals([
        0x53, // tag 'S'
        0x00, 0x00, 0x00, 0x04, // length = 4
      ]);
    });

    test('startup writes protocol 3.0 header, payload and trailing zero', () {
      writer.startup((w) {
        w
          ..string('user')
          ..string('postgres');
      });

      // Length = 4 (len) + 4 (ver) + 5 ('user\0') + 9 ('postgres\0') + 1 (\0)
      check(
        writer.takeBytes(),
      ).deepEquals([
        0x00, 0x00, 0x00, 0x17, // length = 23
        0x00, 0x03, 0x00, 0x00, // protocol 3.0 (196608)
        117, 115, 101, 114, 0, // 'user\0'
        112, 111, 115, 116, 103, 114, 101, 115, 0, // 'postgres\0'
        0x00, // trailing zero
      ]);
    });

    test('dynamically expands buffer when exceeding capacity', () {
      final smallWriter = MessageWriter(initialCapacity: 4);

      final largePayload = List<int>.generate(200, (i) => i % 256);
      smallWriter.bytes(largePayload);

      check(smallWriter.length).equals(200);
      check(smallWriter.takeBytes()).deepEquals(largePayload);
    });

    test('takeBytes resets length for subsequent reuse', () {
      writer.int32(100);
      check(writer.length).equals(4);

      final bytes1 = writer.takeBytes();
      check(bytes1.length).equals(4);
      check(writer.length).equals(0);

      writer.int8(42);
      check(writer.length).equals(1);

      final bytes2 = writer.takeBytes();
      check(bytes2).deepEquals([42]);
    });
  });
}
