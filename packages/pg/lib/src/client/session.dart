/// @docImport 'package:pg/src/client/client.dart';
/// @docImport 'package:pg/src/client/transaction.dart';
library;

import 'dart:async';

import 'package:ctx/ctx.dart';
import 'package:pg/src/client/executor.dart';
import 'package:pg/src/client/portal.dart';
import 'package:pg/src/client/rows.dart';
import 'package:pg/src/client/statement.dart';

/// Interface for stateful operations on a single PostgreSQL connection or
/// transaction.
///
/// Extends [PgExecutor] with operations that require server-side state:
/// prepared statements, bound portals, and portal-based pagination.
///
/// Implemented by [PgClient] (single connection) and [PgTransaction].
abstract interface class PgSession implements PgExecutor {
  /// Prepares [sql] on the server and returns a reusable [PgStatement].
  ///
  /// - [name] — server-side statement identifier. If omitted, a name is
  ///   derived from the SQL hash. Named statements persist until the
  ///   connection closes or the statement is explicitly closed.
  FutureOr<PgStatement> prepare(
    String sql, {
    String? name,
    Context? ctx,
  });

  /// Executes a prepared [statement] with [params] and returns all rows.
  Future<PgRows> execute(
    PgStatement statement,
    List<Object?> params, {
    Context? ctx,
  });

  /// Executes a prepared [statement] and returns rows as a stream.
  Future<PgRowStream> executeStream(
    PgStatement statement,
    List<Object?> params, {
    Context? ctx,
  });

  /// Binds [params] to a prepared [statement], creating a server-side
  /// [PgPortal].
  ///
  /// - [name] — portal identifier on the server (empty string for the
  ///   unnamed portal). Named portals must be closed via [closePortal]
  ///   when no longer needed.
  Future<PgPortal> bind(
    PgStatement statement,
    List<Object?> params, {
    String? name,
    Context? ctx,
  });

  /// Fetches up to [maxRows] rows from a bound [portal].
  ///
  /// Pass `0` for [maxRows] to fetch all remaining rows. Check
  /// [PgRows.hasMore] to determine whether additional rows are available.
  Future<PgRows> queryPortal(
    PgPortal portal, {
    int maxRows = 0,
    Context? ctx,
  });

  /// Fetches rows from a bound [portal] as a stream, up to [maxRows].
  Future<PgRowStream> queryPortalStream(
    PgPortal portal, {
    int maxRows = 0,
    Context? ctx,
  });

  /// Closes [portal] on the server, releasing its resources.
  Future<void> closePortal(
    PgPortal portal, {
    Context? ctx,
  });
}
