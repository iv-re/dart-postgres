import 'dart:typed_data';

import 'package:pg/src/protocol/writer.dart';
import 'package:pg/src/types/types.dart';

/// Base class for PostgreSQL frontend (client to server) messages.
abstract class const FrontendMessage() {
  /// Serializes the message into the provided [writer].
  void encode(MessageWriter writer);
}

/// The initial message sent by the client to begin connection handshake.
class const StartupMessage({
  /// The database user name to connect as.
  required final String user,

  /// The database to connect to.
  final String? database,
}) extends FrontendMessage {
  @override
  void encode(MessageWriter writer) => writer.startup((w) {
    w.string('user');
    w.string(user);

    if (database case final database?) {
      w.string('database');
      w.string(database);
    }

    w.string('client_encoding');
    w.string('UTF8');
  });
}

/// A message containing a plaintext password or MD5 password hash.
class const PasswordMessage(
  /// The password or password hash.
  final String password,
) extends FrontendMessage {
  @override
  void encode(MessageWriter writer) {
    writer.frame(0x70, (w) => w.string(password));
  }
}

/// SASL initial response message sent by client to begin SASL authentication.
class const SaslInitialResponseMessage({
  /// Selected SASL mechanism name (e.g. 'SCRAM-SHA-256').
  required final String mechanism,

  /// SASL client initial data payload.
  required final List<int> data,
}) extends FrontendMessage {
  @override
  void encode(MessageWriter writer) {
    writer.frame(0x70, (w) {
      w.string(mechanism);
      w.int32(data.length);
      w.bytes(data);
    });
  }
}

/// SASL response message sent by client during SASL handshake.
class const SaslResponseMessage(
  /// SASL response data payload.
  final List<int> data,
) extends FrontendMessage {
  @override
  void encode(MessageWriter writer) {
    writer.frame(0x70, (w) => w.bytes(data));
  }
}

/// A simple query message containing an SQL command string.
class const QueryMessage(
  /// The SQL command string.
  final String query,
) extends FrontendMessage {
  @override
  void encode(MessageWriter writer) {
    writer.frame(0x51, (w) => w.string(query));
  }
}

/// Parses an SQL query string to create a prepared statement.
class const ParseMessage({
  /// The SQL query string containing placeholders ($1, $2, ...).
  required final String query,

  /// The name of the destination prepared statement.
  final String name = '',

  /// Explicitly specified parameter type OIDs.
  final List<PgOid> paramOids = const [],
}) extends FrontendMessage {
  @override
  void encode(MessageWriter writer) {
    writer.frame(0x50, (w) {
      w.string(name);
      w.string(query);
      w.int16(paramOids.length);
      paramOids.forEach(w.int32);
    });
  }
}

/// Requests description of a prepared statement or portal.
class const DescribeMessage(
  /// The name of the prepared statement or portal to describe.
  final String name, {

  /// Whether this describes a portal (`true`) or a statement (`false`).
  required final bool isPortal,
}) extends FrontendMessage {
  const new statement([String name = '']) : this(name, isPortal: false);
  const new portal([String name = '']) : this(name, isPortal: true);

  @override
  void encode(MessageWriter writer) {
    writer.frame(0x44, (w) {
      w.int8(isPortal ? 0x50 : 0x53);
      w.string(name);
    });
  }
}

/// Binds parameters and creates an executable portal from a prepared statement.
class const BindMessage({
  /// The name of the destination portal (empty string for unnamed).
  final String portal = '',

  /// The name of the source prepared statement (empty string for unnamed).
  final String statement = '',

  /// Format codes for parameters (0 for text, 1 for binary).
  final List<int> parameterFormatCodes = const [],

  /// The list of parameter value bytes (null denotes SQL NULL).
  final List<Uint8List?> parameters = const [],

  /// Format codes for result columns (0 for text, 1 for binary).
  final List<int> resultFormatCodes = const [],
}) extends FrontendMessage {
  @override
  void encode(MessageWriter writer) {
    writer.frame(0x42, (w) {
      w.string(portal);
      w.string(statement);

      w.int16(parameterFormatCodes.length);
      parameterFormatCodes.forEach(w.int16);

      w.int16(parameters.length);
      for (final param in parameters) {
        if (param == null) {
          w.int32(-1);
        } else {
          w.int32(param.length);
          w.bytes(param);
        }
      }

      w.int16(resultFormatCodes.length);
      resultFormatCodes.forEach(w.int16);
    });
  }
}

/// Executes a previously bound portal.
class const ExecuteMessage({
  /// The name of the portal to execute.
  final String portal = '',

  /// Maximum rows to return (0 means unlimited).
  final int maxRows = 0,
}) extends FrontendMessage {
  @override
  void encode(MessageWriter writer) {
    writer.frame(0x45, (w) {
      w.string(portal);
      w.int32(maxRows);
    });
  }
}

/// Synchronizes extended query state and requests ReadyForQuery.
class const SyncMessage() extends FrontendMessage {
  @override
  void encode(MessageWriter writer) {
    writer.bytes([0x53, 0x00, 0x00, 0x00, 0x04]);
  }
}

/// Closes a prepared statement or portal.
class const CloseMessage(
  /// The name of the prepared statement or portal to close.
  final String name, {

  /// Whether to close a portal (`true`) or a prepared statement (`false`).
  required final bool isPortal,
}) extends FrontendMessage {
  const new statement([String name = '']) : this(name, isPortal: false);
  const new portal([String name = '']) : this(name, isPortal: true);

  @override
  void encode(MessageWriter writer) {
    writer.frame(0x43, (w) {
      w.int8(isPortal ? 0x50 : 0x53);
      w.string(name);
    });
  }
}

/// Flushes the output buffer without ending the extended query step.
class const FlushMessage() extends FrontendMessage {
  @override
  void encode(MessageWriter writer) {
    writer.bytes([0x48, 0x00, 0x00, 0x00, 0x04]);
  }
}

/// Connection termination message.
class const TerminateMessage() extends FrontendMessage {
  @override
  void encode(MessageWriter writer) {
    writer.bytes([0x58, 0x00, 0x00, 0x00, 0x04]);
  }
}

/// A message carrying a chunk of COPY data from client to server.
class const CopyDataMessage(
  /// The raw byte data payload chunk.
  final List<int> data,
) extends FrontendMessage {
  @override
  void encode(MessageWriter writer) {
    writer.frame(0x64, (w) => w.bytes(data));
  }
}

/// A message indicating that client has finished sending COPY data.
class const CopyDoneMessage() extends FrontendMessage {
  @override
  void encode(MessageWriter writer) {
    writer.bytes(const [0x63, 0x00, 0x00, 0x00, 0x04]);
  }
}

/// A message indicating that client aborts the COPY operation with an error.
class const CopyFailMessage(
  /// The error message explanation for aborting COPY.
  final String message,
) extends FrontendMessage {
  @override
  void encode(MessageWriter writer) {
    writer.frame(0x66, (w) => w.string(message));
  }
}

/// An SSL connection request message (Length 8, code 80877103).
class const SslRequestMessage() extends FrontendMessage {
  @override
  void encode(MessageWriter writer) {
    writer.bytes(const [0x00, 0x00, 0x00, 0x08, 0x04, 0xd2, 0x16, 0x2f]);
  }
}

/// A request message sent to cancel a running query on a backend process.
class const CancelRequestMessage({
  /// The target backend process ID.
  required final int processId,

  /// The secret cancellation key for the backend process.
  required final int secretKey,
}) extends FrontendMessage {
  @override
  void encode(MessageWriter writer) {
    writer.int32(16);
    writer.int32(80877102);
    writer.int32(processId);
    writer.int32(secretKey);
  }
}
