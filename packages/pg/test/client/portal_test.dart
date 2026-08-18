import 'dart:async';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:pg/pg.dart';
import 'package:pg/src/client/operation.dart';
import 'package:pg/src/protocol/backend.dart';
import 'package:test/scaffolding.dart';

void main() {
  group('BindOperation', () {
    test('completes with PgPortal on ReadyForQuery', () async {
      final completer = Completer<PgPortal>();
      const statement = PgStatement(
        name: '_pg_s1',
        sql: r'SELECT $1::int',
        paramOids: [PgOid.int4],
        fields: [
          FieldDescription(
            name: 'col',
            tableOid: 0,
            columnAttributeNumber: 0,
            typeOid: .int4,
            dataTypeSize: 4,
            typeModifier: -1,
            formatCode: 1,
          ),
        ],
      );

      final op = BindOperation(
        name: '_pg_p1',
        statement: statement,
        completer: completer,
      );

      final done1 = op.onMessage(const BindCompleteMessage());
      check(done1).equals(false);
      check(completer.isCompleted).equals(false);

      final done2 = op.onMessage(const ReadyForQueryMessage(0x49));
      check(done2).equals(true);
      check(completer.isCompleted).equals(true);

      final portal = await completer.future;
      check(portal.name).equals('_pg_p1');
      check(portal.statement).equals(statement);
      check(portal.fields.length).equals(1);
    });

    test('completes with error on ErrorResponseMessage', () async {
      final completer = Completer<PgPortal>();
      const statement = PgStatement(
        name: '_pg_s1',
        sql: r'SELECT $1::int',
        paramOids: [PgOid.int4],
        fields: [],
      );

      final op = BindOperation(
        name: '_pg_p1',
        statement: statement,
        completer: completer,
      );

      final done = op.onMessage(
        const ErrorResponseMessage(
          severity: 'ERROR',
          code: '42P01',
          message: 'undefined_table',
        ),
      );

      check(done).equals(false);
      check(op.onMessage(const ReadyForQueryMessage(0x49))).equals(true);
      check(completer.isCompleted).equals(true);
      await check(completer.future).throws<PgException>(
        (it) => it.has((e) => e.code, 'code').equals('42P01'),
      );
    });
  });

  group('RowsOperation with PortalSuspended', () {
    test(
      'completes PgRows with hasMore = true on PortalSuspendedMessage',
      () async {
        final completer = Completer<PgRows>();
        const fields = [
          FieldDescription(
            name: 'id',
            tableOid: 0,
            columnAttributeNumber: 0,
            typeOid: .int4,
            dataTypeSize: 4,
            typeModifier: -1,
            formatCode: 1,
          ),
        ];

        final op = RowsOperation(
          completer: completer,
          fields: fields,
        );

        // Add one DataRow
        op.onMessage(
          DataRowMessage([
            Uint8List.fromList([0, 0, 0, 1]),
          ]),
        );

        // Receive PortalSuspendedMessage
        final done1 = op.onMessage(const PortalSuspendedMessage());
        check(done1).equals(false);
        check(completer.isCompleted).equals(true);

        final rows = await completer.future;
        check(rows.length).equals(1);
        check(rows.hasMore).equals(true);

        // ReadyForQuery arrives
        final done2 = op.onMessage(const ReadyForQueryMessage(0x49));
        check(done2).equals(true);
      },
    );

    test(
      'completes PgRows with hasMore = false on CommandComplete',
      () async {
        final completer = Completer<PgRows>();
        final op = RowsOperation(completer: completer);

        op.onMessage(const CommandCompleteMessage('SELECT 1'));
        final rows = await completer.future;
        check(rows.hasMore).equals(false);
      },
    );
  });

  group('StreamRowsOperation with PortalSuspended', () {
    test('signals hasMore = true on PortalSuspendedMessage', () async {
      final controller = StreamController<PgRow>(sync: true);
      final fieldsCompleter = Completer<List<FieldDescription>>();
      final commandTagCompleter = Completer<String>();
      final hasMoreCompleter = Completer<bool>();

      final op = StreamRowsOperation(
        controller: controller,
        fieldsCompleter: fieldsCompleter,
        commandTagCompleter: commandTagCompleter,
        hasMoreCompleter: hasMoreCompleter,
      );

      op.onMessage(const PortalSuspendedMessage());
      check(await hasMoreCompleter.future).equals(true);

      final done = op.onMessage(const ReadyForQueryMessage(0x49));
      check(done).equals(true);
    });
  });
}
