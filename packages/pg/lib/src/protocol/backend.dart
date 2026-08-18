import 'dart:typed_data';

import 'package:pg/src/protocol/reader.dart';
import 'package:pg/src/types/types.dart';

/// Base class for PostgreSQL backend (server to client) messages.
abstract class const BackendMessage() {
  /// Decodes a backend message by its 1-byte [tag] and payload [reader].
  static BackendMessage decode(int tag, MessageReader reader) {
    return switch (tag) {
      0x52 => AuthenticationMessage.decode(reader), // 'R'
      0x53 => ParameterStatusMessage.decode(reader), // 'S'
      0x4B => BackendKeyDataMessage.decode(reader), // 'K'
      0x5A => ReadyForQueryMessage.decode(reader), // 'Z'
      0x54 => RowDescriptionMessage.decode(reader), // 'T'
      0x44 => DataRowMessage.decode(reader), // 'D'
      0x43 => CommandCompleteMessage.decode(reader), // 'C'
      0x49 => const EmptyQueryResponseMessage(), // 'I'
      0x45 => ErrorResponseMessage.decode(reader), // 'E'
      0x4E => NoticeResponseMessage.decode(reader), // 'N'
      0x31 => const ParseCompleteMessage(), // '1'
      0x32 => const BindCompleteMessage(), // '2'
      0x33 => const CloseCompleteMessage(), // '3'
      0x73 => const PortalSuspendedMessage(), // 's'
      0x6E => const NoDataMessage(), // 'n'
      0x74 => ParameterDescriptionMessage.decode(reader), // 't'
      0x47 => CopyInResponseMessage.decode(reader), // 'G'
      0x48 => CopyOutResponseMessage.decode(reader), // 'H'
      0x64 => BackendCopyDataMessage.decode(reader), // 'd'
      0x63 => const BackendCopyDoneMessage(), // 'c'
      0x41 => NotificationResponseMessage.decode(reader), // 'A'
      _ => UnknownBackendMessage(tag, reader.rest()),
    };
  }
}

/// Authentication request message from the server.
sealed class const AuthenticationMessage() extends BackendMessage {
  factory decode(MessageReader reader) {
    final authType = reader.int32();

    return switch (authType) {
      0 => const AuthenticationOk(),
      3 => const AuthenticationCleartextPassword(),
      5 => AuthenticationMd5Password.decode(reader),
      10 => AuthenticationSasl.decode(reader),
      11 => AuthenticationSaslContinue.decode(reader),
      12 => AuthenticationSaslFinal.decode(reader),
      _ => throw UnsupportedError('Unsupported auth type: $authType'),
    };
  }
}

/// Indicates successful authentication.
class const AuthenticationOk() extends AuthenticationMessage {
  @override
  String toString() {
    return 'AuthenticationOk()';
  }
}

/// Indicates server requests a plaintext password.
class const AuthenticationCleartextPassword() extends AuthenticationMessage {
  @override
  String toString() {
    return 'AuthenticationCleartextPassword()';
  }
}

/// Indicates server requests an MD5-hashed password with [salt].
class const AuthenticationMd5Password(
  /// 4-byte salt from the server.
  final Uint8List salt,
) extends AuthenticationMessage {
  new decode(MessageReader reader) : this(reader.bytes(4));

  @override
  String toString() {
    return 'AuthenticationMd5Password(salt: $salt)';
  }
}

/// Indicates server requests SASL authentication (e.g. SCRAM-SHA-256).
class const AuthenticationSasl(
  /// Supported SASL authentication mechanisms.
  final List<String> mechanisms,
) extends AuthenticationMessage {
  factory decode(MessageReader reader) {
    final list = <String>[];
    while (reader.isNotEmpty) {
      final mech = reader.string();
      if (mech.isEmpty) break;
      list.add(mech);
    }
    return AuthenticationSasl(list);
  }

  @override
  String toString() {
    return 'AuthenticationSasl(mechanisms: $mechanisms)';
  }
}

/// Indicates server sends SASL authentication continuation data.
class const AuthenticationSaslContinue(
  /// Server SASL response payload.
  final Uint8List data,
) extends AuthenticationMessage {
  new decode(MessageReader reader) : this(reader.rest());

  @override
  String toString() {
    return 'AuthenticationSaslContinue(bytes: ${data.length})';
  }
}

/// Indicates server sends SASL authentication final data.
class const AuthenticationSaslFinal(
  /// Server final authentication data.
  final Uint8List data,
) extends AuthenticationMessage {
  new decode(MessageReader reader) : this(reader.rest());

  @override
  String toString() {
    return 'AuthenticationSaslFinal(bytes: ${data.length})';
  }
}

/// Run-time parameter status report from the server.
class const ParameterStatusMessage({
  /// Parameter name (e.g. 'server_version', 'client_encoding').
  required final String name,

  /// Parameter value.
  required final String value,
}) extends BackendMessage {
  new decode(MessageReader reader)
    : this(
        name: reader.string(),
        value: reader.string(),
      );

  @override
  String toString() {
    return 'ParameterStatus($name: $value)';
  }
}

/// Backend process ID and secret key for query cancellation.
class const BackendKeyDataMessage({
  /// Server process ID.
  required final int processId,

  /// Secret cancellation key.
  required final int secretKey,
}) extends BackendMessage {
  new decode(MessageReader reader)
    : this(
        processId: reader.int32(),
        secretKey: reader.int32(),
      );

  @override
  String toString() {
    return 'BackendKeyData(pid: $processId, key: $secretKey)';
  }
}

/// Indicates the backend is ready to accept a new query cycle.
class const ReadyForQueryMessage(
  /// Current backend transaction status indicator:
  /// - 'I' (0x49): Idle (not in a transaction block).
  /// - 'T' (0x54): In a transaction block.
  /// - 'E' (0x45): In a failed transaction block.
  final int transactionStatus,
) extends BackendMessage {
  new decode(MessageReader reader) : this(reader.int8());

  @override
  String toString() {
    return 'ReadyForQuery(${String.fromCharCode(transactionStatus)})';
  }
}

/// Field description in a [RowDescriptionMessage].
class const FieldDescription({
  /// The field name.
  required final String name,

  /// Object ID of the table (if the field can be identified as a column).
  required final int tableOid,

  /// Attribute number of the column.
  required final int columnAttributeNumber,

  /// Object ID of the field's data type.
  required final PgOid typeOid,

  /// Data type size in bytes (negative for variable size).
  required final int dataTypeSize,

  /// Type modifier.
  required final int typeModifier,

  /// Format code: 0 for text, 1 for binary.
  required final int formatCode,
}) {
  new decode(MessageReader reader)
    : this(
        name: reader.string(),
        tableOid: reader.int32(),
        columnAttributeNumber: reader.int16(),
        typeOid: PgOid(reader.int32()),
        dataTypeSize: reader.int16(),
        typeModifier: reader.int32(),
        formatCode: reader.int16(),
      );

  @override
  String toString() {
    return 'FieldDescription($name, typeOid: $typeOid)';
  }
}

/// Describes the fields (columns) of rows returned by a query.
class const RowDescriptionMessage(
  /// The list of column field descriptions.
  final List<FieldDescription> fields,
) extends BackendMessage {
  factory decode(MessageReader reader) {
    final count = reader.int16();
    final fields = List<FieldDescription>.generate(
      count,
      (_) => FieldDescription.decode(reader),
      growable: false,
    );
    return RowDescriptionMessage(fields);
  }

  @override
  String toString() {
    return 'RowDescription(fields: ${fields.length})';
  }
}

/// A row of data returned by a query.
class const DataRowMessage(
  /// The raw column byte values (null represents SQL NULL).
  final List<Uint8List?> columns,
) extends BackendMessage {
  new decode(MessageReader reader)
    : this(
        List.generate(
          reader.int16(),
          (_) {
            final length = reader.int32();
            return length == -1 ? null : reader.bytes(length);
          },
          growable: false,
        ),
      );

  @override
  String toString() {
    return 'DataRow(columns: ${columns.length})';
  }
}

/// Command completion status response (e.g. 'SELECT 1', 'INSERT 0 1').
class const CommandCompleteMessage(
  /// The command tag string from the server.
  final String tag,
) extends BackendMessage {
  new decode(MessageReader reader) : this(reader.string());

  @override
  String toString() {
    return 'CommandComplete($tag)';
  }
}

/// Empty query response when a query string is empty.
class const EmptyQueryResponseMessage() extends BackendMessage {
  @override
  String toString() {
    return 'EmptyQueryResponse()';
  }
}

/// Error response from the server.
class const ErrorResponseMessage({
  /// Severity level (e.g. 'ERROR', 'FATAL', 'PANIC').
  required final String severity,

  /// 5-character SQLSTATE error code.
  required final String code,

  /// Primary human-readable error message.
  required final String message,

  /// Optional detailed error description ('D').
  final String? detail,

  /// Optional hint on how to resolve the error ('H').
  final String? hint,

  /// 1-based cursor index position of error in original query string ('P').
  final int? position,

  /// 1-based cursor index position in internally generated query ('p').
  final int? internalPosition,

  /// Text of failed internally generated query ('q').
  final String? internalQuery,

  /// PL/pgSQL callstack context or indication of context ('W').
  final String? where,

  /// Schema name associated with the error ('s').
  final String? schemaName,

  /// Table name associated with the error ('t').
  final String? tableName,

  /// Column name associated with the error ('c').
  final String? columnName,

  /// Data type name associated with the error ('d').
  final String? dataTypeName,

  /// Constraint name associated with the error ('n').
  final String? constraintName,

  /// Source file name where error was reported ('F').
  final String? file,

  /// Source line number where error was reported ('L').
  final int? line,

  /// Source routine name where error was reported ('R').
  final String? routine,

  /// All raw protocol error fields mapped by their byte identifier.
  final Map<int, String> fields = const {},
}) extends BackendMessage {
  factory decode(MessageReader reader) {
    final fields = _decodeErrorFields(reader);
    return ErrorResponseMessage(
      severity: fields[0x53] ?? fields[0x56] ?? 'ERROR', // 'S' or 'V'
      code: fields[0x43] ?? 'UNKNOWN', // 'C'
      message: fields[0x4D] ?? 'Unknown error', // 'M'
      detail: fields[0x44], // 'D'
      hint: fields[0x48], // 'H'
      position: int.tryParse(fields[0x50] ?? ''), // 'P'
      internalPosition: int.tryParse(fields[0x70] ?? ''), // 'p'
      internalQuery: fields[0x71], // 'q'
      where: fields[0x57], // 'W'
      schemaName: fields[0x73], // 's'
      tableName: fields[0x74], // 't'
      columnName: fields[0x63], // 'c'
      dataTypeName: fields[0x64], // 'd'
      constraintName: fields[0x6E], // 'n'
      file: fields[0x46], // 'F'
      line: int.tryParse(fields[0x4C] ?? ''), // 'L'
      routine: fields[0x52], // 'R'
      fields: fields,
    );
  }

  @override
  String toString() {
    return 'ErrorResponse($severity, code: $code, $message)';
  }
}

/// Notice / warning response from the server.
class const NoticeResponseMessage({
  /// Severity level (e.g. 'NOTICE', 'WARNING').
  required final String severity,

  /// 5-character SQLSTATE code.
  required final String code,

  /// Primary notice message.
  required final String message,
}) extends BackendMessage {
  factory decode(MessageReader reader) {
    final fields = _decodeErrorFields(reader);
    return NoticeResponseMessage(
      severity: fields[0x53] ?? fields[0x56] ?? 'NOTICE',
      code: fields[0x43] ?? 'UNKNOWN',
      message: fields[0x4D] ?? '',
    );
  }

  @override
  String toString() {
    return 'NoticeResponse($severity, code: $code, $message)';
  }
}

/// Indicates that a Parse message was successfully processed.
class const ParseCompleteMessage() extends BackendMessage {
  @override
  String toString() {
    return 'ParseCompleteMessage()';
  }
}

/// Indicates that a Bind message was successfully processed.
class const BindCompleteMessage() extends BackendMessage {
  @override
  String toString() {
    return 'BindCompleteMessage()';
  }
}

/// Indicates that a Close message was successfully processed.
class const CloseCompleteMessage() extends BackendMessage {
  @override
  String toString() {
    return 'CloseCompleteMessage()';
  }
}

/// Indicates that portal execution was suspended because maxRows limit was
/// reached.
class const PortalSuspendedMessage() extends BackendMessage {
  @override
  String toString() {
    return 'PortalSuspendedMessage()';
  }
}

/// Indicates that a query returned no data / no columns.
class const NoDataMessage() extends BackendMessage {
  @override
  String toString() {
    return 'NoDataMessage()';
  }
}

/// Describes parameter types required by a prepared statement.
class const ParameterDescriptionMessage(
  /// List of parameter type OIDs.
  final List<PgOid> paramOids,
) extends BackendMessage {
  new decode(MessageReader reader)
    : this(
        List<PgOid>.generate(
          reader.int16(),
          (_) => PgOid(reader.int32()),
          growable: false,
        ),
      );

  @override
  String toString() {
    return 'ParameterDescriptionMessage(params: $paramOids)';
  }
}

/// Server response indicating readiness to receive COPY data (COPY FROM STDIN).
class const CopyInResponseMessage({
  /// Overall format: 0 for text/CSV, 1 for binary.
  required final int overallFormat,

  /// Format codes for individual columns (0 for text, 1 for binary).
  required final List<int> columnFormats,
}) extends BackendMessage {
  factory decode(MessageReader reader) {
    final overallFormat = reader.int8();
    final numColumns = reader.int16();
    final columnFormats = List<int>.generate(
      numColumns,
      (_) => reader.int16(),
      growable: false,
    );
    return CopyInResponseMessage(
      overallFormat: overallFormat,
      columnFormats: columnFormats,
    );
  }

  @override
  String toString() {
    return 'CopyInResponseMessage(overallFormat: $overallFormat, '
        'columnFormats: $columnFormats)';
  }
}

/// Server response indicating readiness to transmit COPY data (COPY TO STDOUT).
class const CopyOutResponseMessage({
  /// Overall format: 0 for text/CSV, 1 for binary.
  required final int overallFormat,

  /// Format codes for individual columns (0 for text, 1 for binary).
  required final List<int> columnFormats,
}) extends BackendMessage {
  factory decode(MessageReader reader) {
    final overallFormat = reader.int8();
    final numColumns = reader.int16();
    final columnFormats = List<int>.generate(
      numColumns,
      (_) => reader.int16(),
      growable: false,
    );
    return CopyOutResponseMessage(
      overallFormat: overallFormat,
      columnFormats: columnFormats,
    );
  }

  @override
  String toString() {
    return 'CopyOutResponseMessage(overallFormat: $overallFormat, '
        'columnFormats: $columnFormats)';
  }
}

/// A chunk of data received from the server during a COPY OUT operation.
class const BackendCopyDataMessage(
  /// Raw byte payload chunk.
  final Uint8List data,
) extends BackendMessage {
  new decode(MessageReader reader) : this(reader.rest());

  @override
  String toString() {
    return 'BackendCopyDataMessage(bytes: ${data.length})';
  }
}

/// Indicates server has completed transmitting COPY data during COPY OUT.
class const BackendCopyDoneMessage() extends BackendMessage {
  @override
  String toString() {
    return 'BackendCopyDoneMessage()';
  }
}

/// Notification response message from server (LISTEN / NOTIFY).
class const NotificationResponseMessage({
  /// PID of backend process that sent the notification.
  required final int processId,

  /// Name of the notification channel.
  required final String channel,

  /// Notification payload string.
  required final String payload,
}) extends BackendMessage {
  new decode(MessageReader reader)
    : this(
        processId: reader.int32(),
        channel: reader.string(),
        payload: reader.string(),
      );

  @override
  String toString() {
    return 'NotificationResponse(pid: $processId, channel: $channel, '
        'payload: $payload)';
  }
}

/// Fallback for unhandled backend messages.
class const UnknownBackendMessage(
  /// 1-byte message tag.
  final int tag,

  /// Raw unparsed payload bytes.
  final Uint8List payload,
) extends BackendMessage {
  @override
  String toString() {
    return 'UnknownBackendMessage(${String.fromCharCode(tag)}, '
        'bytes: ${payload.length})';
  }
}

Map<int, String> _decodeErrorFields(MessageReader reader) {
  final fields = <int, String>{};
  while (reader.isNotEmpty) {
    final fieldType = reader.int8();
    if (fieldType == 0) break;
    fields[fieldType] = reader.string();
  }
  return fields;
}
