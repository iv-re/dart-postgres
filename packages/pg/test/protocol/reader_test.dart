import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:pg/src/protocol/reader.dart';
import 'package:test/scaffolding.dart';

void main() {
  group('ReadBuffer', () {
    late ReadBuffer buffer;

    setUp(() {
      buffer = ReadBuffer(initialCapacity: 16);
    });

    test('initial state is empty', () {
      check(buffer.length).equals(0);
      check(buffer.isEmpty).isTrue();
      check(buffer.isNotEmpty).isFalse();
      check(buffer.nextMessage()).isNull();
    });

    test('add appends bytes and updates length', () {
      buffer.add([1, 2, 3]);

      check(buffer.length).equals(3);
      check(buffer.isEmpty).isFalse();
      check(buffer.isNotEmpty).isTrue();
    });

    test('nextMessage returns null when fewer than 5 bytes', () {
      buffer.add([0x52, 0x00, 0x00, 0x00]); // 4 bytes

      check(buffer.nextMessage()).isNull();
    });

    test('nextMessage returns null when full payload not yet received', () {
      // tag 'R', length 8, but only 2 bytes payload received (need 4)
      buffer.add([0x52, 0x00, 0x00, 0x00, 0x08, 0x00, 0x00]);

      check(buffer.nextMessage()).isNull();
      check(buffer.length).equals(7);
    });

    test('nextMessage consumes complete frame and returns payload reader', () {
      // tag 'R' (0x52), length 8, payload [1, 2, 3, 4]
      buffer.add([0x52, 0x00, 0x00, 0x00, 0x08, 1, 2, 3, 4]);

      final result = buffer.nextMessage();
      check(result).isNotNull();
      check(result!.tag).equals(0x52);
      check(result.bytes(4)).deepEquals([1, 2, 3, 4]);
      check(buffer.length).equals(0);
      check(buffer.isEmpty).isTrue();
    });

    test('compacts and expands buffer when needed', () {
      final smallBuffer = ReadBuffer(initialCapacity: 8);

      // Frame 1: tag 'R' (0x52), length 8, payload [1, 2, 3, 4]
      smallBuffer.add([0x52, 0x00, 0x00, 0x00, 0x08, 1, 2, 3, 4]);
      final msg1 = smallBuffer.nextMessage();
      check(msg1).isNotNull();
      check(msg1!.bytes(4)).deepEquals([1, 2, 3, 4]);
      check(smallBuffer.length).equals(0);

      // Add 20 bytes -> triggers compaction and expansion
      smallBuffer.add([
        0x53, 0x00, 0x00, 0x00, 0x07, 10, 20, 30, // Frame 2: 8 bytes
        0x5A, 0x00, 0x00, 0x00, 0x05, 0x49, // Frame 3: 6 bytes
      ]);
      check(smallBuffer.length).equals(14);

      final msg2 = smallBuffer.nextMessage();
      check(msg2!.tag).equals(0x53);
      check(msg2.bytes(3)).deepEquals([10, 20, 30]);

      final msg3 = smallBuffer.nextMessage();
      check(msg3!.tag).equals(0x5A);
      check(msg3.int8()).equals(0x49);
      check(smallBuffer.isEmpty).isTrue();
    });
  });

  group('MessageReader', () {
    test('reads primitive numbers in big-endian', () {
      final bytes = Uint8List.fromList([
        0x7F, // int8: 127
        0x12, 0x34, // int16: 0x1234
        0x12, 0x34, 0x56, 0x78, // int32: 0x12345678
        0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, // int64
      ]);

      final reader = MessageReader(bytes);

      check(reader.int8()).equals(127);
      check(reader.int16()).equals(0x1234);
      check(reader.int32()).equals(0x12345678);
      check(reader.int64()).equals(0x0011223344556677);
      check(reader.isEmpty).isTrue();
    });

    test('reads null-terminated string and advances offset', () {
      final bytes = Uint8List.fromList([
        ...utf8.encode('server_version'),
        0,
        ...utf8.encode('16.1'),
        0,
      ]);

      final reader = MessageReader(bytes);

      check(reader.string()).equals('server_version');
      check(reader.string()).equals('16.1');
      check(reader.isEmpty).isTrue();
    });

    test('string throws FormatException when null-terminator is missing', () {
      final bytes = Uint8List.fromList(utf8.encode('unterminated'));
      final reader = MessageReader(bytes);

      check(reader.string).throws<FormatException>();
    });

    test('bytes reads exact sublist slice without advancing beyond count', () {
      final bytes = Uint8List.fromList([1, 2, 3, 4, 5, 6]);
      final reader = MessageReader(bytes);

      check(reader.bytes(3)).deepEquals([1, 2, 3]);
      check(reader.length).equals(3);
      check(reader.bytes(2)).deepEquals([4, 5]);
      check(reader.length).equals(1);
    });

    test('rest reads all remaining bytes', () {
      final bytes = Uint8List.fromList([1, 2, 3, 4, 5]);
      final reader = MessageReader(bytes);

      check(reader.int8()).equals(1);
      check(reader.rest()).deepEquals([2, 3, 4, 5]);
      check(reader.isEmpty).isTrue();
    });
  });
}
