import 'dart:async';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:pg/pg.dart';
import 'package:pg/src/client/operation.dart';
import 'package:pg/src/protocol/backend.dart';
import 'package:test/scaffolding.dart';

void main() {
  group('PgRow & PgRows', () {
    const fields = [
      FieldDescription(
        name: 'id',
        tableOid: 0,
        columnAttributeNumber: 1,
        typeOid: .int4,
        dataTypeSize: 4,
        typeModifier: -1,
        formatCode: 0,
      ),
      FieldDescription(
        name: 'name',
        tableOid: 0,
        columnAttributeNumber: 2,
        typeOid: .text,
        dataTypeSize: -1,
        typeModifier: -1,
        formatCode: 0,
      ),
    ];

    test('PgRow reads columns and strings', () {
      final row = PgRow(
        fields,
        [
          Uint8List.fromList([0x34, 0x32]), // '42'
          null, // NULL
        ],
      );

      check(row.length).equals(2);

      // By index
      check(row[0] as List?).isNotNull().deepEquals([0x34, 0x32]);
      check(row.bytes(0)).deepEquals([0x34, 0x32]);
      check(row.string(0)).equals('42');
      check(row[1]).isNull();
      check(row.stringOrNull(1)).isNull();
      check(() => row.string(1)).throws<StateError>();

      // By column name
      check(row['id'] as List?).isNotNull().deepEquals([0x34, 0x32]);
      check(row.bytes('id')).deepEquals([0x34, 0x32]);
      check(row.string('id')).equals('42');
      check(row['name']).isNull();
      check(row.stringOrNull('name')).isNull();
      check(() => row.string('name')).throws<StateError>();

      // Errors
      check(() => row[5]).throws<RangeError>();
      check(() => row[-1]).throws<RangeError>();
      check(() => row['unknown']).throws<ArgumentError>();
      check(() => row[true]).throws<Object>();
    });

    test('PgRows provides row indexing and metadata', () {
      final row1 = PgRow(fields, [
        Uint8List.fromList([0x31]),
        null,
      ]);
      final row2 = PgRow(fields, [
        Uint8List.fromList([0x32]),
        null,
      ]);

      final rows = PgRows(
        fields: fields,
        rows: [row1, row2],
        commandTag: 'SELECT 2',
      );

      check(rows.length).equals(2);
      check(rows[0]).equals(row1);
      check(rows[1]).equals(row2);
      check(rows.affectedRows).equals(2);
      check(rows.commandTag).equals('SELECT 2');
    });
  });

  group('RowsOperation (buffered)', () {
    const fields = [
      FieldDescription(
        name: 'count',
        tableOid: 0,
        columnAttributeNumber: 1,
        typeOid: .int4,
        dataTypeSize: 4,
        typeModifier: -1,
        formatCode: 0,
      ),
    ];

    test('collects rows and completes on CommandComplete', () async {
      final completer = Completer<PgRows>();
      final op = RowsOperation(completer: completer);

      check(op.onMessage(const RowDescriptionMessage(fields))).equals(false);
      check(
        op.onMessage(
          DataRowMessage([
            Uint8List.fromList([0x35]),
          ]),
        ),
      ).equals(false);
      check(
        op.onMessage(const CommandCompleteMessage('SELECT 1')),
      ).equals(false);
      check(op.onMessage(const ReadyForQueryMessage(0x49))).equals(true);

      final rows = await completer.future;
      check(rows.length).equals(1);
      check(rows[0].string(0)).equals('5');
      check(rows.affectedRows).equals(1);
      check(rows.commandTag).equals('SELECT 1');
    });

    test('handles EmptyQueryResponse', () async {
      final completer = Completer<PgRows>();
      final op = RowsOperation(completer: completer);

      check(op.onMessage(const EmptyQueryResponseMessage())).equals(false);
      check(op.onMessage(const ReadyForQueryMessage(0x49))).equals(true);

      final rows = await completer.future;
      check(rows.length).equals(0);
      check(rows.affectedRows).equals(0);
    });

    test('handles ErrorResponseMessage', () async {
      final completer = Completer<PgRows>();
      final op = RowsOperation(completer: completer);

      check(
        op.onMessage(
          const ErrorResponseMessage(
            severity: 'ERROR',
            code: '42P01',
            message: 'relation does not exist',
          ),
        ),
      ).equals(false);
      check(op.onMessage(const ReadyForQueryMessage(0x49))).equals(true);

      await check(completer.future).throws<PgException>();
    });
  });

  group('StreamRowsOperation (streaming)', () {
    const fields = [
      FieldDescription(
        name: 'num',
        tableOid: 0,
        columnAttributeNumber: 1,
        typeOid: .int4,
        dataTypeSize: 4,
        typeModifier: -1,
        formatCode: 0,
      ),
    ];

    test('streams rows and completes metadata', () async {
      final controller = StreamController<PgRow>();
      final op = StreamRowsOperation(controller: controller);

      check(op.onMessage(const RowDescriptionMessage(fields))).equals(false);
      check(await op.fieldsCompleter.future).deepEquals(fields);

      check(
        op.onMessage(
          DataRowMessage([
            Uint8List.fromList([0x37]),
          ]),
        ),
      ).equals(false);

      check(
        op.onMessage(const CommandCompleteMessage('SELECT 1')),
      ).equals(false);
      check(await op.commandTagCompleter.future).equals('SELECT 1');

      check(op.onMessage(const ReadyForQueryMessage(0x49))).equals(true);

      final streamed = await controller.stream.toList();
      check(streamed.length).equals(1);
      check(streamed.first.string(0)).equals('7');
    });

    test('handles onError callback', () async {
      final controller = StreamController<PgRow>();
      final op = StreamRowsOperation(controller: controller);

      final f1 = check(op.fieldsCompleter.future).throws<FormatException>();
      final f2 = check(op.commandTagCompleter.future).throws<FormatException>();
      final f3 = check(controller.stream.toList()).throws<FormatException>();

      op.onError(const FormatException('corrupt'), StackTrace.empty);

      await Future.wait([f1, f2, f3]);
    });
  });

  group('PgException Diagnostics', () {
    test('exposes all diagnostic getters and formats toString', () {
      const errorMsg = ErrorResponseMessage(
        severity: 'ERROR',
        code: '23505',
        message: 'duplicate key value violates unique constraint',
        detail: 'Key (email)=(test@example.com) already exists.',
        hint: 'Use a different email address.',
        position: 42,
        internalPosition: 10,
        internalQuery: 'SELECT 1',
        where: 'PL/pgSQL function inline_code_block line 3',
        schemaName: 'public',
        tableName: 'users',
        columnName: 'email',
        dataTypeName: 'text',
        constraintName: 'users_email_key',
        file: 'nbtinsert.c',
        line: 673,
        routine: '_bt_check_unique',
        fields: {0x53: 'ERROR', 0x43: '23505'},
      );

      final ex = PgException.fromErrorResponse(errorMsg);

      check(ex.severity).equals('ERROR');
      check(ex.code).equals('23505');
      check(ex.message)
          .equals('duplicate key value violates unique constraint');
      check(ex.detail).equals('Key (email)=(test@example.com) already exists.');
      check(ex.hint).equals('Use a different email address.');
      check(ex.position).equals(42);
      check(ex.internalPosition).equals(10);
      check(ex.internalQuery).equals('SELECT 1');
      check(ex.where).equals('PL/pgSQL function inline_code_block line 3');
      check(ex.schemaName).equals('public');
      check(ex.tableName).equals('users');
      check(ex.columnName).equals('email');
      check(ex.dataTypeName).equals('text');
      check(ex.constraintName).equals('users_email_key');
      check(ex.file).equals('nbtinsert.c');
      check(ex.line).equals(673);
      check(ex.routine).equals('_bt_check_unique');
      check(ex.fields[0x43]).equals('23505');

      final str = ex.toString();
      check(str).contains('23505');
      check(str).contains('users_email_key');
      check(str).contains('users');
      check(str).contains('email');
      check(str).contains('42');
      check(str).contains('Key (email)=(test@example.com) already exists.');
      check(str).contains('Use a different email address.');
    });
  });
}
