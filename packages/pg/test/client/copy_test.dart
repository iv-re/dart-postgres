import 'dart:async';
import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:pg/src/client/copy.dart';
import 'package:pg/src/client/exception.dart';
import 'package:pg/src/client/operation.dart';
import 'package:pg/src/protocol/backend.dart';
import 'package:pg/src/protocol/frontend.dart';
import 'package:test/scaffolding.dart';

void main() {
  group('CopyInOperation & PgCopyInSink', () {
    test('successful COPY IN flow with add() and finish()', () async {
      final sent = <FrontendMessage>[];
      final completer = Completer<PgCopyInSink>();

      final op = CopyInOperation(
        completer: completer,
        send: sent.add,
      );

      final done1 = op.onMessage(
        const CopyInResponseMessage(
          overallFormat: 0,
          columnFormats: [0, 0],
        ),
      );
      check(done1).equals(false);
      check(completer.isCompleted).equals(true);

      final sink = await completer.future;
      check(sink.overallFormat).equals(0);
      check(sink.columnFormats).deepEquals([0, 0]);

      sink.add(utf8.encode('1\tAlice\n'));
      check(sent.length).equals(1);
      check(sent.first)
          .isA<CopyDataMessage>()
          .has(
            (m) => utf8.decode(m.data),
            'data',
          )
          .equals('1\tAlice\n');

      final finishFuture = sink.finish();
      check(sent.length).equals(2);
      check(sent.last).isA<CopyDoneMessage>();

      final done2 = op.onMessage(const CommandCompleteMessage('COPY 100'));
      check(done2).equals(false);

      final done3 = op.onMessage(const ReadyForQueryMessage(0x49));
      check(done3).equals(true);

      final rowsCopied = await finishFuture;
      check(rowsCopied).equals(100);
    });

    test('streams byte chunks via addStream()', () async {
      final sent = <FrontendMessage>[];
      final completer = Completer<PgCopyInSink>();

      final op = CopyInOperation(
        completer: completer,
        send: sent.add,
      );

      op.onMessage(
        const CopyInResponseMessage(
          overallFormat: 0,
          columnFormats: [0],
        ),
      );

      final sink = await completer.future;
      final controller = StreamController<List<int>>();

      final addStreamFuture = sink.addStream(controller.stream);

      controller.add(utf8.encode('chunk1\n'));
      controller.add(utf8.encode('chunk2\n'));
      await controller.close();

      await addStreamFuture;

      check(sent.length).equals(2);
      check(sent[0]).isA<CopyDataMessage>();
      check(sent[1]).isA<CopyDataMessage>();

      final finishFuture = sink.finish();
      op.onMessage(const CommandCompleteMessage('COPY 2'));
      op.onMessage(const ReadyForQueryMessage(0x49));

      final rows = await finishFuture;
      check(rows).equals(2);
    });

    test('aborts COPY IN when addStream encounters an error', () async {
      final sent = <FrontendMessage>[];
      final completer = Completer<PgCopyInSink>();

      final op = CopyInOperation(
        completer: completer,
        send: sent.add,
      );

      op.onMessage(
        const CopyInResponseMessage(
          overallFormat: 0,
          columnFormats: [0],
        ),
      );

      final sink = await completer.future;
      final controller = StreamController<List<int>>();

      final addStreamFuture = sink.addStream(controller.stream);

      controller.addError(Exception('stream failure'));
      await controller.close();

      // Simulate server response to CopyFail
      op.onMessage(
        const ErrorResponseMessage(
          severity: 'ERROR',
          code: '57014',
          message: 'COPY fail',
        ),
      );
      op.onMessage(const ReadyForQueryMessage(0x49));

      await check(addStreamFuture).throws<Exception>();

      check(sent.any((m) => m is CopyFailMessage)).equals(true);
      final failMsg =
          sent.firstWhere((m) => m is CopyFailMessage) as CopyFailMessage;
      check(failMsg.message).contains('stream failure');
    });

    test('aborts COPY IN explicitly via abort()', () async {
      final sent = <FrontendMessage>[];
      final completer = Completer<PgCopyInSink>();

      final op = CopyInOperation(
        completer: completer,
        send: sent.add,
      );

      op.onMessage(
        const CopyInResponseMessage(
          overallFormat: 0,
          columnFormats: [0],
        ),
      );

      final sink = await completer.future;
      final abortFuture = sink.abort('user cancelled');

      check(sent.length).equals(1);
      check(sent.first)
          .isA<CopyFailMessage>()
          .has(
            (m) => m.message,
            'message',
          )
          .equals('user cancelled');

      op.onMessage(
        const ErrorResponseMessage(
          severity: 'ERROR',
          code: '57014',
          message: 'canceling statement due to user request',
        ),
      );
      op.onMessage(const ReadyForQueryMessage(0x45));

      await check(abortFuture).throws<PgException>();
    });
  });
}
