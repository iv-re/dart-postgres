import 'package:meta/meta.dart';

/// Represents a network host endpoint or Unix domain socket path for
/// PostgreSQL.
@immutable
class const PgEndpoint(
  /// Hostname, IP address, or directory/file path to Unix domain socket.
  final String host, [

  /// TCP port number (ignored for Unix domain sockets).
  final int port = 5432,
]) {
  /// Whether this endpoint points to a local Unix domain socket path.
  bool get isUnixSocket => host.startsWith('/') || host.startsWith('.');

  /// Resolves the effective Unix domain socket file path.
  String get unixSocketPath {
    if (host.endsWith('.s.PGSQL.$port')) {
      return host;
    }
    if (host.endsWith('/')) {
      return '$host.s.PGSQL.$port';
    }
    return '$host/.s.PGSQL.$port';
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PgEndpoint &&
          runtimeType == other.runtimeType &&
          host == other.host &&
          port == other.port;

  @override
  int get hashCode => host.hashCode ^ port.hashCode;

  @override
  String toString() => isUnixSocket ? host : '$host:$port';
}

/// Target server session attributes for multi-host connection filtering.
enum PgTargetSessionAttrs {
  /// Connect to any host regardless of read/write state.
  any,

  /// Connect only to a primary / read-write host (`SHOW transaction_read_only`
  /// is 'off').
  readWrite,

  /// Connect only to a standby / read-only host (`SHOW transaction_read_only`
  /// is 'on').
  readOnly,
}
