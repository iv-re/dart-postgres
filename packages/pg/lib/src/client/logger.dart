import 'package:pg/src/client/endpoint.dart';
import 'package:pg/src/client/tracer.dart';
import 'package:sl/sl.dart';

/// A [PgTracer] adapter that emits structured logs to a [Logger] from
/// `package:sl`.
final class PgLogger implements PgTracer {
  const PgLogger(
    this.logger, {
    this.group = 'db',
    this.logParams = true,
    this.slowThreshold = const Duration(milliseconds: 200),
  });

  /// The underlying structured logger.
  final Logger logger;

  /// The root attribute group key (e.g. `'db'`), or `null` for flat attributes.
  final String? group;

  /// Whether to include query parameters in the log attributes.
  final bool logParams;

  /// Duration threshold after which queries are logged at [LogLevel.warn].
  final Duration? slowThreshold;

  List<LogAttr> _wrap(List<LogAttr> attrs) {
    if (group case final g?) {
      return [.group(g, attrs)];
    }
    return attrs;
  }

  @override
  void onQuery(PgQueryTrace trace) {
    if (trace.error case final err?) {
      logger.error(
        'query failed',
        attrs: _wrap([
          .string('sql', trace.sql),
          .int('duration_us', trace.duration.inMicroseconds),
          .error(err),
        ]),
        ctx: trace.ctx,
      );
      return;
    }

    final isSlow = slowThreshold != null && trace.duration >= slowThreshold!;

    final attrs = <LogAttr>[
      .string('sql', trace.sql),
      if (logParams && trace.params.isNotEmpty)
        .string('params', trace.params.toString()),
      .int('duration_us', trace.duration.inMicroseconds),
      if (trace.commandTag case final tag?) .string('command_tag', tag),
    ];

    logger.log(
      isSlow ? .warn : .debug,
      isSlow ? 'slow query' : 'query',
      attrs: _wrap(attrs),
      ctx: trace.ctx,
    );
  }

  @override
  void onNotice(PgNotice notice) {
    final isWarn = notice.severity.toUpperCase() == 'WARNING';

    logger.log(
      isWarn ? .warn : .info,
      'server notice',
      attrs: _wrap([
        .string('severity', notice.severity),
        .string('code', notice.code),
        .string('message', notice.message),
      ]),
    );
  }

  @override
  void onConnect(PgEndpoint endpoint, Duration duration, {Object? error}) {
    if (error case final err?) {
      logger.error(
        'connection failed',
        attrs: _wrap([
          .string('host', endpoint.host),
          .int('port', endpoint.port),
          .int('duration_us', duration.inMicroseconds),
          .error(err),
        ]),
      );
    } else {
      logger.debug(
        'connection established',
        attrs: _wrap([
          .string('host', endpoint.host),
          .int('port', endpoint.port),
          .int('duration_us', duration.inMicroseconds),
        ]),
      );
    }
  }
}
