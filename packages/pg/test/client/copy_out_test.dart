import 'dart:async';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:pg/src/client/copy_out.dart';
import 'package:pg/src/client/operation.dart';
import 'package:pg/src/protocol/backend.dart';
import 'package:test/scaffolding.dart';

void main() {
  group('CopyOutOperation', () {
    test('buffers data chunks and completes stream', () async {
      final controller = StreamController<Uint8List>(sync: true);
      final responseCompleter = Completer<CopyOutResponseMessage>();
      final commandTagCompleter = Completer<String>();

      final op = CopyOutOperation(
        controller: controller,
        responseCompleter: responseCompleter,
        commandTagCompleter: commandTagCompleter,
      );

      const responseMsg = CopyOutResponseMessage(
        overallFormat: 0,
        columnFormats: [0, 0],
      );

      final stream = PgCopyOutStream(
        controller.stream,
        response: responseMsg,
        commandTag: commandTagCompleter.future,
      );

      check(op.onMessage(responseMsg)).equals(false);

      final chunksFuture = stream.toList();

      check(
        op.onMessage(
          BackendCopyDataMessage(Uint8List.fromList([1, 2, 3])),
        ),
      ).equals(false);

      check(
        op.onMessage(
          BackendCopyDataMessage(Uint8List.fromList([4, 5, 6])),
        ),
      ).equals(false);

      check(op.onMessage(const BackendCopyDoneMessage())).equals(false);
      check(
        op.onMessage(const CommandCompleteMessage('COPY 2')),
      ).equals(false);

      check(op.onMessage(const ReadyForQueryMessage(73))).equals(true);

      final chunks = await chunksFuture;
      check(chunks.length).equals(2);
      check(chunks[0]).deepEquals([1, 2, 3]);
      check(chunks[1]).deepEquals([4, 5, 6]);

      check(stream.format).equals(0);
      check(stream.columnFormats).deepEquals([0, 0]);
      check(await stream.commandTag).equals('COPY 2');
    });
  });
}
