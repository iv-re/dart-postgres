import 'dart:async';
import 'dart:typed_data';

import 'package:pg/src/protocol/backend.dart';

/// A stream emitting raw byte chunks during a `COPY ... TO STDOUT` (`copyOut`)
/// operation.
class PgCopyOutStream(
  super.stream, {

  /// Server response describing overall and per-column formats.
  required final CopyOutResponseMessage response,

  /// Command completion tag (e.g. 'COPY 100').
  required final Future<String> commandTag,
}) extends StreamView<Uint8List> {
  /// Overall format code: 0 for text/CSV, 1 for binary.
  int get format => response.overallFormat;

  /// Individual column format codes (0 for text, 1 for binary).
  List<int> get columnFormats => response.columnFormats;
}
