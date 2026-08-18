import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:pg/src/protocol/frontend.dart';
import 'package:pg/src/protocol/writer.dart';
import 'package:pg/src/types/oid.dart';
import 'package:test/scaffolding.dart';

void main() {
  group('FrontendMessage', () {
    late MessageWriter writer;

    setUp(() {
      writer = MessageWriter();
    });

    test('StartupMessage encodes with database', () {
      const message = StartupMessage(
        user: 'postgres',
        database: 'mydb',
      );

      message.encode(writer);

      check(
        writer.takeBytes(),
      ).deepEquals([
        0x00, 0x00, 0x00, 0x3A, // length = 58
        0x00, 0x03, 0x00, 0x00, // protocol 3.0
        ..._cString('user'),
        ..._cString('postgres'),
        ..._cString('database'),
        ..._cString('mydb'),
        ..._cString('client_encoding'),
        ..._cString('UTF8'),
        0x00, // trailing zero
      ]);
    });

    test('StartupMessage encodes without database', () {
      const message = StartupMessage(user: 'postgres');

      message.encode(writer);

      check(
        writer.takeBytes(),
      ).deepEquals([
        0x00, 0x00, 0x00, 0x2C, // length = 44
        0x00, 0x03, 0x00, 0x00, // protocol 3.0
        ..._cString('user'),
        ..._cString('postgres'),
        ..._cString('client_encoding'),
        ..._cString('UTF8'),
        0x00, // trailing zero
      ]);
    });

    test('PasswordMessage encodes tag and password', () {
      const message = PasswordMessage('secret');

      message.encode(writer);

      check(
        writer.takeBytes(),
      ).deepEquals([
        0x70, // tag 'p'
        0x00, 0x00, 0x00, 0x0B, // length = 11
        ..._cString('secret'),
      ]);
    });

    test('QueryMessage encodes tag and query string', () {
      const message = QueryMessage('SELECT 1;');

      message.encode(writer);

      check(
        writer.takeBytes(),
      ).deepEquals([
        0x51, // tag 'Q'
        0x00, 0x00, 0x00, 0x0E, // length 14
        ..._cString('SELECT 1;'),
      ]);
    });

    test('TerminateMessage encodes fixed termination frame', () {
      const message = TerminateMessage();

      message.encode(writer);

      check(
        writer.takeBytes(),
      ).deepEquals([0x58, 0x00, 0x00, 0x00, 0x04]);
    });

    test('ParseMessage encodes statement, query, and parameter types', () {
      const message = ParseMessage(
        name: 'stmt_1',
        query: r'SELECT * FROM users WHERE id = $1',
        paramOids: [PgOid.int4], // int4 OID = 23
      );

      message.encode(writer);

      final bytes = writer.takeBytes();
      check(bytes[0]).equals(0x50); // 'P'
      check(
        bytes.sublist(5),
      ).deepEquals([
        ..._cString('stmt_1'),
        ..._cString(r'SELECT * FROM users WHERE id = $1'),
        0x00, 0x01, // 1 parameter
        0x00, 0x00, 0x00, 0x17, // OID 23
      ]);
    });

    test('DescribeMessage encodes statement and portal describe frames', () {
      const stmtDesc = DescribeMessage.statement('stmt_1');
      stmtDesc.encode(writer);
      check(
        writer.takeBytes(),
      ).deepEquals([
        0x44, // 'D'
        0x00, 0x00, 0x00, 0x0C, // length 12
        0x53, // 'S' (statement)
        ..._cString('stmt_1'),
      ]);

      const portalDesc = DescribeMessage.portal('portal_1');
      portalDesc.encode(writer);
      check(
        writer.takeBytes(),
      ).deepEquals([
        0x44, // 'D'
        0x00, 0x00, 0x00, 0x0E, // length 14
        0x50, // 'P' (portal)
        ..._cString('portal_1'),
      ]);
    });

    test('BindMessage encodes portal, statement, and parameters', () {
      final message = BindMessage(
        portal: 'p1',
        statement: 's1',
        parameterFormatCodes: const [0],
        parameters: [
          Uint8List.fromList([49, 50]),
          null,
        ],
        resultFormatCodes: const [0],
      );

      message.encode(writer);

      final bytes = writer.takeBytes();
      check(bytes[0]).equals(0x42); // 'B'
      check(
        bytes.sublist(5),
      ).deepEquals([
        ..._cString('p1'),
        ..._cString('s1'),
        0x00, 0x01, 0x00, 0x00, // 1 param format code (0 = text)
        0x00, 0x02, // 2 parameters
        0x00, 0x00, 0x00, 0x02, 49, 50, // param 1: length 2, [49, 50]
        0xFF, 0xFF, 0xFF, 0xFF, // param 2: length -1 (NULL)
        0x00, 0x01, 0x00, 0x00, // 1 result format code (0 = text)
      ]);
    });

    test('ExecuteMessage encodes portal name and max rows limit', () {
      const message = ExecuteMessage(portal: 'p1', maxRows: 100);

      message.encode(writer);

      check(
        writer.takeBytes(),
      ).deepEquals([
        0x45, // 'E'
        0x00, 0x00, 0x00, 0x0B, // length 11
        ..._cString('p1'),
        0x00, 0x00, 0x00, 0x64, // maxRows 100
      ]);
    });

    test('SyncMessage encodes fixed sync frame', () {
      const message = SyncMessage();

      message.encode(writer);

      check(
        writer.takeBytes(),
      ).deepEquals([0x53, 0x00, 0x00, 0x00, 0x04]);
    });

    test('CloseMessage encodes statement and portal close frames', () {
      const stmtClose = CloseMessage.statement('stmt_1');
      stmtClose.encode(writer);
      check(
        writer.takeBytes(),
      ).deepEquals([
        0x43, // 'C'
        0x00, 0x00, 0x00, 0x0C, // length 12
        0x53, // 'S'
        ..._cString('stmt_1'),
      ]);

      const portalClose = CloseMessage.portal('portal_1');
      portalClose.encode(writer);
      check(
        writer.takeBytes(),
      ).deepEquals([
        0x43, // 'C'
        0x00, 0x00, 0x00, 0x0E, // length 14
        0x50, // 'P'
        ..._cString('portal_1'),
      ]);
    });

    test('FlushMessage encodes fixed flush frame', () {
      const message = FlushMessage();

      message.encode(writer);

      check(
        writer.takeBytes(),
      ).deepEquals([0x48, 0x00, 0x00, 0x00, 0x04]);
    });

    test('CancelRequestMessage encodes length, cancel code, processId, and '
        'secretKey', () {
      const message = CancelRequestMessage(
        processId: 12345,
        secretKey: 67890,
      );

      message.encode(writer);

      check(
        writer.takeBytes(),
      ).deepEquals([
        0x00, 0x00, 0x00, 0x10, // length = 16
        0x04, 0xD2, 0x16, 0x2E, // cancel code = 80877102
        0x00, 0x00, 0x30, 0x39, // processId = 12345
        0x00, 0x01, 0x09, 0x32, // secretKey = 67890
      ]);
    });

    test('SslRequestMessage encodes valid 8-byte payload', () {
      const message = SslRequestMessage();
      message.encode(writer);

      check(
        writer.takeBytes(),
      ).deepEquals([0x00, 0x00, 0x00, 0x08, 0x04, 0xd2, 0x16, 0x2f]);
    });
  });
}

List<int> _cString(String value) => [...value.codeUnits, 0];
