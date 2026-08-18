import 'dart:io';

import 'package:pg/src/client/config.dart';
import 'package:pg/src/client/endpoint.dart';
import 'package:pg/src/protocol/frontend.dart';
import 'package:pg/src/protocol/writer.dart';

/// A token that can be used to request cancellation of a query running on a
/// PostgreSQL backend connection.
class const PgCancelToken({
  /// Server backend process ID.
  required final int processId,

  /// Secret cancellation key for this backend process.
  required final int secretKey,

  /// Connection configuration used to establish the cancellation socket.
  required final PgConfig config,

  /// The specific endpoint this token's connection is connected to.
  required final PgEndpoint resolvedEndpoint,
}) {
  /// Opens a separate connection (TCP or Unix socket) to PostgreSQL and sends a
  /// [CancelRequestMessage] to interrupt the query running on this backend.
  Future<void> cancel() async {
    final Socket socket;
    if (resolvedEndpoint.isUnixSocket) {
      socket = await Socket.connect(
        InternetAddress(
          resolvedEndpoint.unixSocketPath,
          type: InternetAddressType.unix,
        ),
        0,
      );
    } else {
      socket = await Socket.connect(
        resolvedEndpoint.host,
        resolvedEndpoint.port,
      );
    }
    var effectiveSocket = socket;

    try {
      if (!resolvedEndpoint.isUnixSocket) {
        if (config.sslConfig case PgSslConfig(
          mode: final mode && != PgSslMode.disable,
          :final securityContext,
          :final onBadCertificate,
        )) {
          final sslWriter = MessageWriter();
          const SslRequestMessage().encode(sslWriter);
          socket.add(sslWriter.takeBytes());

          if (await socket.first case [83, ...]) {
            effectiveSocket = await SecureSocket.secure(
              socket,
              host: mode == .verifyFull ? resolvedEndpoint.host : null,
              context: securityContext,
              onBadCertificate:
                  onBadCertificate ??
                  (_) => mode != .verifyCa && mode != .verifyFull,
            );
          } else {
            throw const SocketException(
              'SSL requested but server rejected it',
            );
          }
        }
      }

      final writer = MessageWriter();
      CancelRequestMessage(
        processId: processId,
        secretKey: secretKey,
      ).encode(writer);
      effectiveSocket.add(writer.takeBytes());
      await effectiveSocket.flush();
    } finally {
      await effectiveSocket.close();
      effectiveSocket.destroy();
    }
  }
}
