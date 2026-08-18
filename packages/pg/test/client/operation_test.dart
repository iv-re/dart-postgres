import 'dart:async';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:pg/src/client/config.dart';
import 'package:pg/src/client/exception.dart';
import 'package:pg/src/client/operation.dart';
import 'package:pg/src/client/rows.dart';
import 'package:pg/src/client/statement.dart';
import 'package:pg/src/protocol/backend.dart';
import 'package:pg/src/protocol/frontend.dart';
import 'package:pg/src/types/types.dart';
import 'package:test/scaffolding.dart';

void main() {
  group('HandshakeOperation', () {
    final config = PgConfig(
      host: 'localhost',
      user: 'postgres',
      password: 'secret_password',
      database: 'postgres',
    );

    test(
      'handles AuthenticationOk, BackendKeyData, and completes on '
      'ReadyForQuery',
      () async {
        final sent = <FrontendMessage>[];
        final completer = Completer<BackendKeyData>();

        final op = HandshakeOperation(
          config: config,
          send: sent.add,
          completer: completer,
        );

        final done1 = op.onMessage(const AuthenticationOk());
        check(done1).equals(false);
        check(completer.isCompleted).equals(false);

        final doneKey = op.onMessage(
          const BackendKeyDataMessage(processId: 1234, secretKey: 5678),
        );
        check(doneKey).equals(false);
        check(completer.isCompleted).equals(false);

        final done2 = op.onMessage(const ReadyForQueryMessage(0x49));
        check(done2).equals(true);
        check(completer.isCompleted).equals(true);
        final keyData = await completer.future;
        check(keyData.processId).equals(1234);
        check(keyData.secretKey).equals(5678);
      },
    );

    test('handles AuthenticationCleartextPassword by sending password', () {
      final sent = <FrontendMessage>[];
      final completer = Completer<BackendKeyData>();

      final op = HandshakeOperation(
        config: config,
        send: sent.add,
        completer: completer,
      );

      final done = op.onMessage(const AuthenticationCleartextPassword());
      check(done).equals(false);
      check(sent.length).equals(1);
      check(sent.first)
          .isA<PasswordMessage>()
          .has(
            (p) => p.password,
            'password',
          )
          .equals('secret_password');
    });

    test('handles AuthenticationMd5Password by sending md5 hash', () {
      final sent = <FrontendMessage>[];
      final completer = Completer<BackendKeyData>();

      final op = HandshakeOperation(
        config: config,
        send: sent.add,
        completer: completer,
      );

      final done = op.onMessage(
        AuthenticationMd5Password(Uint8List.fromList([1, 2, 3, 4])),
      );
      check(done).equals(false);
      check(sent.length).equals(1);
      check(sent.first)
          .isA<PasswordMessage>()
          .has(
            (p) => p.password,
            'password',
          )
          .startsWith('md5');
    });

    test('completes with PgException on ErrorResponseMessage', () async {
      final sent = <FrontendMessage>[];
      final completer = Completer<BackendKeyData>();

      final op = HandshakeOperation(
        config: config,
        send: sent.add,
        completer: completer,
      );

      final done = op.onMessage(
        const ErrorResponseMessage(
          severity: 'FATAL',
          code: '28P01',
          message: 'password auth failed',
        ),
      );

      check(done).equals(true);
      check(completer.isCompleted).equals(true);
      await check(completer.future).throws<PgException>(
        (it) => it
          ..has((e) => e.code, 'code').equals('28P01')
          ..has((e) => e.message, 'message').equals('password auth failed'),
      );
    });

    test('completes with error on onError callback', () async {
      final sent = <FrontendMessage>[];
      final completer = Completer<BackendKeyData>();

      final op = HandshakeOperation(
        config: config,
        send: sent.add,
        completer: completer,
      );

      op.onError(const FormatException('socket closed'), StackTrace.empty);
      check(completer.isCompleted).equals(true);
      await check(completer.future).throws<FormatException>();
    });
  });

  group('PrepareOperation', () {
    test('collects params and fields and completes on ReadyForQuery', () async {
      final completer = Completer<PgStatement>();
      final op = PrepareOperation(
        name: 'stmt_1',
        sql: r'SELECT id FROM users WHERE id = $1',
        completer: completer,
      );

      check(op.onMessage(const ParseCompleteMessage())).equals(false);
      check(
        op.onMessage(const ParameterDescriptionMessage([PgOid.int4])),
      ).equals(false);
      check(
        op.onMessage(
          const RowDescriptionMessage([
            FieldDescription(
              name: 'id',
              tableOid: 100,
              columnAttributeNumber: 1,
              typeOid: .int4,
              dataTypeSize: 4,
              typeModifier: -1,
              formatCode: 0,
            ),
          ]),
        ),
      ).equals(false);
      check(op.onMessage(const ReadyForQueryMessage(0x49))).equals(true);

      final stmt = await completer.future;
      check(stmt.name).equals('stmt_1');
      check(stmt.sql).equals(r'SELECT id FROM users WHERE id = $1');
      check(stmt.paramOids).deepEquals([PgOid.int4]);
      check(stmt.fields.length).equals(1);
      check(stmt.fields.first.name).equals('id');
    });

    test(
      'handles NoDataMessage for statements without result columns',
      () async {
        final completer = Completer<PgStatement>();
        final op = PrepareOperation(
          name: 'stmt_insert',
          sql: r'INSERT INTO users (id) VALUES ($1)',
          completer: completer,
        );

        check(op.onMessage(const ParseCompleteMessage())).equals(false);
        check(
          op.onMessage(const ParameterDescriptionMessage([PgOid.int4])),
        ).equals(false);
        check(op.onMessage(const NoDataMessage())).equals(false);
        check(op.onMessage(const ReadyForQueryMessage(0x49))).equals(true);

        final stmt = await completer.future;
        check(stmt.fields).isEmpty();
        check(stmt.paramOids).deepEquals([PgOid.int4]);
      },
    );

    test('fails on ErrorResponseMessage', () async {
      final completer = Completer<PgStatement>();
      final op = PrepareOperation(
        name: 'stmt_bad',
        sql: 'SYNTAX ERROR',
        completer: completer,
      );

      check(
        op.onMessage(
          const ErrorResponseMessage(
            severity: 'ERROR',
            code: '42601',
            message: 'syntax error',
          ),
        ),
      ).equals(false);
      check(op.onMessage(const ReadyForQueryMessage(0x49))).equals(true);

      await check(completer.future).throws<PgException>(
        (it) => it
          ..has((e) => e.code, 'code').equals('42601')
          ..has((e) => e.message, 'message').equals('syntax error'),
      );
    });
  });

  group('RowsOperation (execute)', () {
    test('buffers rows and completes on CommandComplete', () async {
      final completer = Completer<PgRows>();
      final op = RowsOperation(completer: completer);

      check(op.onMessage(const BindCompleteMessage())).equals(false);
      check(
        op.onMessage(
          const RowDescriptionMessage([
            FieldDescription(
              name: 'count',
              tableOid: 0,
              columnAttributeNumber: 1,
              typeOid: .int4,
              dataTypeSize: 4,
              typeModifier: -1,
              formatCode: 0,
            ),
          ]),
        ),
      ).equals(false);
      check(
        op.onMessage(
          DataRowMessage([
            Uint8List.fromList([0x35]), // '5'
          ]),
        ),
      ).equals(false);
      check(
        op.onMessage(const CommandCompleteMessage('SELECT 1')),
      ).equals(false);
      check(op.onMessage(const ReadyForQueryMessage(0x49))).equals(true);

      final rows = await completer.future;
      check(rows.length).equals(1);
      check(rows[0].string('count')).equals('5');
      check(rows.commandTag).equals('SELECT 1');
    });
  });

  group('CloseStatementOperation', () {
    test('completes on ReadyForQuery after CloseComplete', () async {
      final completer = Completer<void>();
      final op = CloseStatementOperation(completer);

      check(op.onMessage(const CloseCompleteMessage())).equals(false);
      check(op.onMessage(const ReadyForQueryMessage(0x49))).equals(true);
      await check(completer.future).completes();
    });
  });
}
