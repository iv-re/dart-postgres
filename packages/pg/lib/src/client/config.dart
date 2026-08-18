import 'dart:io';

import 'package:pg/src/client/endpoint.dart';
import 'package:pg/src/client/tracer.dart';

/// SSL connection modes for PostgreSQL.
enum PgSslMode {
  /// Disable SSL/TLS encryption.
  disable,

  /// Try SSL/TLS first. If the server does not support SSL (responds with 'N'),
  /// gracefully fall back to an unencrypted plain TCP connection.
  prefer,

  /// Request SSL/TLS encryption. Allow self-signed or unverified certificates.
  require,

  /// Require SSL/TLS, verify server certificate against trusted Root CAs.
  verifyCa,

  /// Require SSL/TLS, verify server certificate against trusted Root CAs,
  /// and verify host name matching (CN/SAN).
  verifyFull,
}

/// Mode for load balancing across multiple host endpoints.
enum PgLoadBalanceHosts {
  /// Connect to host endpoints sequentially in the order specified.
  disable,

  /// Shuffle host endpoints before connecting to distribute connections
  /// across cluster nodes.
  random,
}

/// Channel binding modes for SCRAM-SHA-256-PLUS authentication (RFC 5802 /
/// RFC 5929).
enum PgChannelBinding {
  /// Do not use channel binding (always use SCRAM-SHA-256).
  disable,

  /// Use channel binding (SCRAM-SHA-256-PLUS) if server supports it and TLS is
  /// active, otherwise fall back to SCRAM-SHA-256.
  prefer,

  /// Require channel binding (SCRAM-SHA-256-PLUS). Fails if TLS is not active
  /// or server does not support SCRAM-SHA-256-PLUS.
  require,
}

/// SSL/TLS configuration for PostgreSQL connections.
///
/// Pass to [PgConfig] to control encryption, certificate verification, and
/// channel binding.
class PgSslConfig {
  const PgSslConfig({
    this.mode = .require,
    this.securityContext,
    this.onBadCertificate,
    this.channelBinding = .prefer,
  });

  /// The SSL mode to use.
  final PgSslMode mode;

  /// Custom [SecurityContext] for trusted Root CA certificates and client
  /// certificates for mTLS authentication.
  final SecurityContext? securityContext;

  /// Custom callback to validate bad or untrusted certificates.
  final bool Function(X509Certificate cert)? onBadCertificate;

  /// Channel binding mode for SASL authentication.
  final PgChannelBinding channelBinding;
}

/// Mode for executing PostgreSQL queries.
enum PgQueryMode {
  /// Default mode: Uses cached named prepared statements for optimal
  /// performance.
  prepared,

  /// PgBouncer-compatible mode: Uses unnamed prepared statements per query.
  /// Recommended for PgBouncer in Transaction Pooling mode.
  unnamed,

  /// Simple Query Protocol for executing raw SQL statements.
  simple,
}

/// Configuration for establishing PostgreSQL connections.
///
/// Use [PgConfig.new] for single-host setups, [PgConfig.multi] for
/// multi-host failover, or [PgConfig.fromUri] to parse a connection URI.
class PgConfig {
  /// Creates a single-host configuration.
  PgConfig({
    required String host,
    required this.user,
    required this.password,
    required this.database,
    int port = 5432,
    this.sslConfig = const PgSslConfig(mode: .disable),
    this.queryMode = .prepared,
    this.loadBalanceHosts = .disable,
    this.tracer,
  }) : endpoints = List.unmodifiable([PgEndpoint(host, port)]),
       targetSessionAttrs = .any;

  /// Creates a multi-host failover configuration.
  PgConfig.multi({
    required List<PgEndpoint> endpoints,
    required this.user,
    required this.password,
    required this.database,
    this.targetSessionAttrs = .any,
    this.sslConfig = const PgSslConfig(mode: .disable),
    this.queryMode = .prepared,
    this.loadBalanceHosts = .disable,
    this.tracer,
  }) : endpoints = List.unmodifiable(endpoints);

  /// Creates a configuration from a [Uri].
  ///
  /// ```dart
  /// PgConfig.fromUri(Uri.parse('postgres://user:pass@localhost:5432/mydb'));
  /// PgConfig.fromUri(Uri.parse('postgres://user:pass@host1:5432,host2:5432/mydb?target_session_attrs=read-write&load_balance_hosts=random'));
  /// PgConfig.fromUri(Uri.parse('postgres://user:pass@/mydb?host=/tmp'));
  /// ```
  factory PgConfig.fromUri(
    Uri uri, {
    PgTracer? tracer,
  }) {
    if (uri case Uri(scheme: != 'postgres' && != 'postgresql')) {
      throw ArgumentError.value(
        uri,
        'uri',
        'Invalid scheme: "${uri.scheme}". Expected "postgres" or "postgresql"',
      );
    }

    final (user, password) = uri.credentials;

    return PgConfig.multi(
      endpoints: uri.endpoints,
      user: user,
      password: password,
      database: uri.database ?? user,
      targetSessionAttrs: uri.targetSessionAttrs,
      sslConfig: PgSslConfig(
        mode: uri.sslMode,
        channelBinding: uri.channelBinding,
      ),
      queryMode: uri.queryMode,
      loadBalanceHosts: uri.loadBalanceHosts,
      tracer: tracer,
    );
  }

  /// Ordered list of host endpoints to connect to.
  final List<PgEndpoint> endpoints;

  /// PostgreSQL role name for authentication.
  final String user;

  /// Password for the [user] role.
  final String password;

  /// Name of the database to connect to.
  final String database;

  /// SSL/TLS configuration options.
  final PgSslConfig sslConfig;

  /// Default query execution mode for connections.
  final PgQueryMode queryMode;

  /// Target server session attributes for filtering connections.
  final PgTargetSessionAttrs targetSessionAttrs;

  /// Mode for load balancing across candidate host endpoints.
  final PgLoadBalanceHosts loadBalanceHosts;

  /// Optional telemetry and logging tracer.
  final PgTracer? tracer;
}

extension on Uri {
  (String user, String password) get credentials {
    if (userInfo.isEmpty) {
      return ('postgres', '');
    }

    final separator = userInfo.indexOf(':');
    final rawUser = separator != -1
        ? userInfo.substring(0, separator)
        : userInfo;
    final rawPassword = separator != -1
        ? userInfo.substring(separator + 1)
        : '';

    final decodedUser = Uri.decodeComponent(rawUser);
    final decodedPassword = Uri.decodeComponent(rawPassword);

    return (
      decodedUser.isEmpty ? 'postgres' : decodedUser,
      decodedPassword,
    );
  }

  String? get database {
    final segment = pathSegments.where((s) => s.isNotEmpty).firstOrNull;
    return segment != null ? Uri.decodeComponent(segment) : null;
  }

  List<PgEndpoint> get endpoints {
    final queryHost = queryParameters['host'];
    final list = <PgEndpoint>[];
    final defaultPort = hasPort ? port : 5432;

    if (queryHost != null && queryHost.isNotEmpty) {
      for (final part in queryHost.split(',')) {
        if (part.trim().isNotEmpty) {
          list.add(_parseEndpoint(part, defaultPort));
        }
      }
    } else if (authority.contains(',')) {
      final hostsStr = authority.split('@').last;
      for (final part in hostsStr.split(',')) {
        if (part.trim().isNotEmpty) {
          list.add(_parseEndpoint(part, defaultPort));
        }
      }
    }

    if (list.isEmpty) {
      final h = host.isEmpty ? 'localhost' : host;
      list.add(PgEndpoint(h, defaultPort));
    }

    return list;
  }

  PgSslMode get sslMode {
    final val = queryParameters['sslmode'];

    return switch (val?.toLowerCase().trim()) {
      null || 'disable' => .disable,
      'prefer' => .prefer,
      'require' => .require,
      'verify-ca' => .verifyCa,
      'verify-full' => .verifyFull,
      final invalid => throw ArgumentError.value(
        invalid,
        'sslmode',
        'Invalid sslmode: "$invalid". '
            'Expected "disable", "prefer", "require", '
            '"verify-ca", or "verify-full"',
      ),
    };
  }

  PgLoadBalanceHosts get loadBalanceHosts {
    final val = queryParameters['load_balance_hosts'];

    return switch (val?.toLowerCase().trim()) {
      null || 'disable' => .disable,
      'random' => .random,
      final invalid => throw ArgumentError.value(
        invalid,
        'load_balance_hosts',
        'Invalid load_balance_hosts: "$invalid". '
            'Expected "disable" or "random"',
      ),
    };
  }

  PgChannelBinding get channelBinding {
    final val = queryParameters['channel_binding'];

    return switch (val?.toLowerCase().trim()) {
      null || 'prefer' => .prefer,
      'disable' => .disable,
      'require' => .require,
      final invalid => throw ArgumentError.value(
        invalid,
        'channel_binding',
        'Invalid channel_binding: "$invalid". '
            'Expected "disable", "prefer", or "require"',
      ),
    };
  }

  PgQueryMode get queryMode {
    final val = queryParameters['query_mode'];

    return switch (val?.toLowerCase().trim()) {
      null || 'prepared' => .prepared,
      'unnamed' => .unnamed,
      'simple' => .simple,
      final invalid => throw ArgumentError.value(
        invalid,
        'query_mode',
        'Invalid query_mode: "$invalid". '
            'Expected "prepared", "unnamed", or "simple"',
      ),
    };
  }

  PgTargetSessionAttrs get targetSessionAttrs {
    final val = queryParameters['target_session_attrs'];

    return switch (val?.toLowerCase().trim()) {
      null || 'any' => .any,
      'read-write' || 'primary' => .readWrite,
      'read-only' || 'standby' => .readOnly,
      final invalid => throw ArgumentError.value(
        invalid,
        'target_session_attrs',
        'Invalid target_session_attrs: "$invalid". '
            'Expected "any", "read-write", "primary", '
            '"read-only", or "standby"',
      ),
    };
  }

  static PgEndpoint _parseEndpoint(String raw, int defaultPort) {
    final trimmed = raw.trim();
    if (trimmed.startsWith('/') || trimmed.startsWith('.')) {
      return PgEndpoint(trimmed, defaultPort);
    }

    if (trimmed.startsWith('[')) {
      final closeBracket = trimmed.indexOf(']');
      if (closeBracket != -1) {
        final host = trimmed.substring(1, closeBracket);
        final rest = trimmed.substring(closeBracket + 1);
        if (rest.startsWith(':')) {
          final port = int.tryParse(rest.substring(1)) ?? defaultPort;
          return PgEndpoint(host, port);
        }
        return PgEndpoint(host, defaultPort);
      }
    }

    final colonIdx = trimmed.lastIndexOf(':');
    if (colonIdx != -1) {
      final h = trimmed.substring(0, colonIdx);
      final p = int.tryParse(trimmed.substring(colonIdx + 1)) ?? defaultPort;
      return PgEndpoint(h, p);
    }
    return PgEndpoint(trimmed, defaultPort);
  }
}
