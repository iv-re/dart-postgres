import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:pg/src/protocol/backend.dart';
import 'package:pg/src/protocol/reader.dart';
import 'package:test/scaffolding.dart';

void main() {
  group('BackendMessage.decode', () {
    test('decodes AuthenticationOk (authType: 0)', () {
      final reader = _reader([0x00, 0x00, 0x00, 0x00]);
      final msg = BackendMessage.decode(0x52, reader);

      check(msg).isA<AuthenticationOk>();
    });

    test('decodes AuthenticationCleartextPassword (authType: 3)', () {
      final reader = _reader([0x00, 0x00, 0x00, 0x03]);
      final msg = BackendMessage.decode(0x52, reader);

      check(msg).isA<AuthenticationCleartextPassword>();
    });

    test('decodes AuthenticationMd5Password (authType: 5)', () {
      final reader = _reader([
        0x00, 0x00, 0x00, 0x05, // authType 5
        1, 2, 3, 4, // salt
      ]);
      final msg = BackendMessage.decode(0x52, reader);

      check(msg)
          .isA<AuthenticationMd5Password>()
          .has(
            (m) => m.salt,
            'salt',
          )
          .deepEquals([1, 2, 3, 4]);
    });

    test('decodes AuthenticationSasl (authType: 10)', () {
      final reader = _reader([
        0x00, 0x00, 0x00, 0x0A, // authType 10
        ...utf8.encode('SCRAM-SHA-256'),
        0,
        ...utf8.encode('SCRAM-SHA-256-PLUS'),
        0,
        0, // end of list
      ]);
      final msg = BackendMessage.decode(0x52, reader);

      check(msg)
          .isA<AuthenticationSasl>()
          .has(
            (m) => m.mechanisms,
            'mechanisms',
          )
          .deepEquals(['SCRAM-SHA-256', 'SCRAM-SHA-256-PLUS']);
    });

    test('throws UnsupportedError on unknown authType', () {
      final reader = _reader([0x00, 0x00, 0x00, 0x99]);

      check(
        () => BackendMessage.decode(0x52, reader),
      ).throws<UnsupportedError>();
    });

    test('decodes ParameterStatusMessage (tag: S)', () {
      final reader = _reader([
        ...utf8.encode('server_version'),
        0,
        ...utf8.encode('16.2'),
        0,
      ]);
      final msg = BackendMessage.decode(0x53, reader);

      check(msg).isA<ParameterStatusMessage>()
        ..has((p) => p.name, 'name').equals('server_version')
        ..has((p) => p.value, 'value').equals('16.2');
    });

    test('decodes BackendKeyDataMessage (tag: K)', () {
      final reader = _reader([
        0x00, 0x00, 0x04, 0xD2, // pid: 1234
        0x00, 0x00, 0x16, 0x2E, // secretKey: 5678
      ]);
      final msg = BackendMessage.decode(0x4B, reader);

      check(msg).isA<BackendKeyDataMessage>()
        ..has((k) => k.processId, 'processId').equals(1234)
        ..has((k) => k.secretKey, 'secretKey').equals(5678);
    });

    test('decodes ReadyForQueryMessage (tag: Z)', () {
      final reader = _reader([0x49]); // 'I' (idle)
      final msg = BackendMessage.decode(0x5A, reader);

      check(msg)
          .isA<ReadyForQueryMessage>()
          .has(
            (m) => m.transactionStatus,
            'transactionStatus',
          )
          .equals(0x49);
    });

    test('decodes ErrorResponseMessage with all fields (tag: E)', () {
      final reader = _reader([
        0x53, ...utf8.encode('FATAL'), 0, // 'S': Severity
        0x43, ...utf8.encode('28P01'), 0, // 'C': Code
        0x4D, ...utf8.encode('auth failed'), 0, // 'M': Message
        0x44, ...utf8.encode('detailed info'), 0, // 'D': Detail
        0x48, ...utf8.encode('check password'), 0, // 'H': Hint
        0x50, ...utf8.encode('15'), 0, // 'P': Position
        0x70, ...utf8.encode('8'), 0, // 'p': internalPosition
        0x71, ...utf8.encode('SELECT 1'), 0, // 'q': internalQuery
        0x57, ...utf8.encode('PL/pgSQL stack'), 0, // 'W': Where
        0x73, ...utf8.encode('public'), 0, // 's': schemaName
        0x74, ...utf8.encode('users'), 0, // 't': tableName
        0x63, ...utf8.encode('email'), 0, // 'c': columnName
        0x64, ...utf8.encode('text'), 0, // 'd': dataTypeName
        0x6E, ...utf8.encode('users_email_key'), 0, // 'n': constraintName
        0x46, ...utf8.encode('auth.c'), 0, // 'F': file
        0x4C, ...utf8.encode('123'), 0, // 'L': line
        0x52, ...utf8.encode('check_auth'), 0, // 'R': routine
        0x00, // terminator
      ]);
      final msg = BackendMessage.decode(0x45, reader);

      check(msg).isA<ErrorResponseMessage>()
        ..has((e) => e.severity, 'severity').equals('FATAL')
        ..has((e) => e.code, 'code').equals('28P01')
        ..has((e) => e.message, 'message').equals('auth failed')
        ..has((e) => e.detail, 'detail').equals('detailed info')
        ..has((e) => e.hint, 'hint').equals('check password')
        ..has((e) => e.position, 'position').equals(15)
        ..has((e) => e.internalPosition, 'internalPosition').equals(8)
        ..has((e) => e.internalQuery, 'internalQuery').equals('SELECT 1')
        ..has((e) => e.where, 'where').equals('PL/pgSQL stack')
        ..has((e) => e.schemaName, 'schemaName').equals('public')
        ..has((e) => e.tableName, 'tableName').equals('users')
        ..has((e) => e.columnName, 'columnName').equals('email')
        ..has((e) => e.dataTypeName, 'dataTypeName').equals('text')
        ..has(
          (e) => e.constraintName,
          'constraintName',
        ).equals('users_email_key')
        ..has((e) => e.file, 'file').equals('auth.c')
        ..has((e) => e.line, 'line').equals(123)
        ..has((e) => e.routine, 'routine').equals('check_auth')
        ..has((e) => e.fields[0x6E], 'fields[n]').equals('users_email_key');
    });

    test('decodes NoticeResponseMessage (tag: N)', () {
      final reader = _reader([
        0x53,
        ...utf8.encode('NOTICE'),
        0,
        0x43,
        ...utf8.encode('00000'),
        0,
        0x4D,
        ...utf8.encode('table created'),
        0,
        0x00,
      ]);
      final msg = BackendMessage.decode(0x4E, reader);

      check(msg).isA<NoticeResponseMessage>()
        ..has((n) => n.severity, 'severity').equals('NOTICE')
        ..has((n) => n.code, 'code').equals('00000')
        ..has((n) => n.message, 'message').equals('table created');
    });

    test('decodes RowDescriptionMessage (tag: T)', () {
      final reader = _reader([
        0x00, 0x01, // 1 field
        ...utf8.encode('id'), 0, // name
        0x00, 0x00, 0x04, 0xD2, // tableOid: 1234
        0x00, 0x01, // columnAttributeNumber: 1
        0x00, 0x00, 0x00, 0x17, // typeOid: 23 (int4)
        0x00, 0x04, // dataTypeSize: 4
        0xFF, 0xFF, 0xFF, 0xFF, // typeModifier: -1
        0x00, 0x00, // formatCode: 0 (text)
      ]);
      final msg = BackendMessage.decode(0x54, reader);

      check(msg)
          .isA<RowDescriptionMessage>()
          .has(
            (r) => r.fields,
            'fields',
          )
          .single
        ..has((f) => f.name, 'name').equals('id')
        ..has((f) => f.typeOid, 'typeOid').equals(.int4);
    });

    test('decodes DataRowMessage with null and non-null columns (tag: D)', () {
      final reader = _reader([
        0x00, 0x02, // 2 columns
        0x00, 0x00, 0x00, 0x01, 0x31, // col 1: len 1, value '1' (0x31)
        0xFF, 0xFF, 0xFF, 0xFF, // col 2: len -1 (NULL)
      ]);
      final msg = BackendMessage.decode(0x44, reader);

      check(msg)
          .isA<DataRowMessage>()
          .has(
            (r) => r.columns,
            'columns',
          )
          .deepEquals([
            [0x31],
            null,
          ]);
    });

    test('decodes CommandCompleteMessage (tag: C)', () {
      final reader = _reader([
        ...utf8.encode('SELECT 1'),
        0,
      ]);
      final msg = BackendMessage.decode(0x43, reader);

      check(msg)
          .isA<CommandCompleteMessage>()
          .has(
            (c) => c.tag,
            'tag',
          )
          .equals('SELECT 1');
    });

    test('decodes EmptyQueryResponseMessage (tag: I)', () {
      final reader = _reader([]);
      final msg = BackendMessage.decode(0x49, reader);

      check(msg).isA<EmptyQueryResponseMessage>();
    });

    test('decodes ParseCompleteMessage (tag: 1)', () {
      final reader = _reader([]);
      final msg = BackendMessage.decode(0x31, reader);

      check(msg).isA<ParseCompleteMessage>();
    });

    test('decodes BindCompleteMessage (tag: 2)', () {
      final reader = _reader([]);
      final msg = BackendMessage.decode(0x32, reader);

      check(msg).isA<BindCompleteMessage>();
    });

    test('decodes CloseCompleteMessage (tag: 3)', () {
      final reader = _reader([]);
      final msg = BackendMessage.decode(0x33, reader);

      check(msg).isA<CloseCompleteMessage>();
    });

    test('decodes NoDataMessage (tag: n)', () {
      final reader = _reader([]);
      final msg = BackendMessage.decode(0x6E, reader);

      check(msg).isA<NoDataMessage>();
    });

    test('decodes ParameterDescriptionMessage (tag: t)', () {
      final reader = _reader([
        0x00, 0x02, // 2 parameters
        0x00, 0x00, 0x00, 0x17, // OID 23 (int4)
        0x00, 0x00, 0x00, 0x19, // OID 25 (text)
      ]);
      final msg = BackendMessage.decode(0x74, reader);

      check(msg)
          .isA<ParameterDescriptionMessage>()
          .has(
            (p) => p.paramOids,
            'paramOids',
          )
          .deepEquals([23, 25]);
    });

    test('decodes NotificationResponseMessage (tag: A)', () {
      final reader = _reader([
        0x00, 0x00, 0x00, 0x2A, // pid 42
        ...utf8.encode('events'), 0x00, // channel 'events'
        ...utf8.encode('item_created'), 0x00, // payload 'item_created'
      ]);
      final msg = BackendMessage.decode(0x41, reader);

      check(msg).isA<NotificationResponseMessage>()
        ..has((n) => n.processId, 'processId').equals(42)
        ..has((n) => n.channel, 'channel').equals('events')
        ..has((n) => n.payload, 'payload').equals('item_created');
    });

    test('decodes UnknownBackendMessage for unhandled tag', () {
      final reader = _reader([1, 2, 3, 4]);
      final msg = BackendMessage.decode(0x99, reader);

      check(msg).isA<UnknownBackendMessage>()
        ..has((u) => u.tag, 'tag').equals(0x99)
        ..has((u) => u.payload, 'payload').deepEquals([1, 2, 3, 4]);
    });
  });
}

MessageReader _reader(List<int> bytes) {
  return MessageReader(Uint8List.fromList(bytes));
}
