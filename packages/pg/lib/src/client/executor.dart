/// @docImport 'package:pg/src/client/client.dart';
/// @docImport 'package:pg/src/client/pool.dart';
/// @docImport 'package:pg/src/client/session.dart';
library;

import 'dart:async';

import 'package:ctx/ctx.dart';
import 'package:pg/src/client/config.dart';
import 'package:pg/src/client/copy.dart';
import 'package:pg/src/client/copy_out.dart';
import 'package:pg/src/client/pipeline.dart';
import 'package:pg/src/client/rows.dart';
import 'package:pg/src/client/transaction.dart';

/// Common interface for executing stateless PostgreSQL queries.
///
/// Implemented by [PgClient], [PgPool], and [PgTransaction] to provide a
/// uniform query surface. Methods on this interface do not require prior
/// state (prepared statements, portals); see [PgSession] for stateful
/// operations.
///
/// All methods accept an optional [Context] for deadline propagation and
/// cancellation.
abstract interface class PgExecutor {
  /// Executes a raw SQL string using the Simple Query protocol.
  ///
  /// Does not support parameterized queries. Multiple semicolon-delimited
  /// statements are allowed; only the last result set is returned.
  Future<PgRows> simpleQuery(
    String sql, {
    Context? ctx,
  });

  /// Executes a parameterized SQL query and returns all result rows.
  ///
  /// Parameters are positional (`$1`, `$2`, …). Pass `null` in [params]
  /// for SQL NULL values.
  ///
  /// - [mode] overrides the default [PgQueryMode] from [PgConfig.queryMode].
  Future<PgRows> query(
    String sql,
    List<Object?> params, {
    PgQueryMode? mode,
    Context? ctx,
  });

  /// Executes a parameterized SQL query and returns rows as a stream.
  ///
  /// Rows are emitted as they arrive from the server, which is useful for
  /// large result sets that should not be buffered entirely in memory.
  Future<PgRowStream> queryStream(
    String sql,
    List<Object?> params, {
    PgQueryMode? mode,
    Context? ctx,
  });

  /// Executes [block] inside a managed transaction.
  ///
  /// Commits on successful return. Rolls back if [block] throws. The
  /// [PgTransaction] passed to [block] must not be used after [block]
  /// returns.
  Future<T> transaction<T>(
    Future<T> Function(PgTransaction tx) block, {
    PgIsolationLevel? isolationLevel,
    bool readOnly = false,
    bool deferrable = false,
    Context? ctx,
  });

  /// Packs multiple queries into a single TCP round-trip.
  ///
  /// Use [buildPipeline] to enqueue queries via [PgPipeline.query]. All
  /// queries are sent together and their results are returned in order.
  /// If any query fails, subsequent queries in the batch are still executed.
  Future<List<PgRows>> pipeline(
    void Function(PgPipeline p) buildPipeline, {
    Context? ctx,
  });

  /// Starts a `COPY FROM STDIN` operation for bulk data ingestion.
  ///
  /// Returns a [PgCopyInSink] for streaming raw data chunks. Call
  /// [PgCopyInSink.finish] to complete the operation or
  /// [PgCopyInSink.abort] to cancel it.
  Future<PgCopyInSink> copyIn(
    String sql, {
    Context? ctx,
  });

  /// Starts a `COPY ... TO STDOUT` operation for bulk data export.
  ///
  /// Returns a [PgCopyOutStream] that emits raw byte chunks. The stream
  /// completes when the server signals end-of-data.
  Future<PgCopyOutStream> copyOut(
    String sql, {
    Context? ctx,
  });
}
