import 'dart:async';

import 'package:pg/src/client/client.dart';
import 'package:pg/src/client/config.dart';
import 'package:pg/src/client/notification.dart';
import 'package:pg/src/client/utils.dart';

/// A client for receiving asynchronous PostgreSQL notifications (`LISTEN` / `NOTIFY`).
///
/// Reconnects automatically if the underlying connection drops and restores
/// active channel subscriptions.
class PgListener {
  PgListener._(
    this.config, {
    this.reconnectDelay = const Duration(seconds: 1),
  });

  /// The connection configuration.
  final PgConfig config;

  /// Delay between reconnection attempts when the connection is severed.
  final Duration reconnectDelay;

  final Set<String> _channels = <String>{};
  final StreamController<PgNotification> _controller =
      StreamController<PgNotification>.broadcast();

  PgClient? _client;
  StreamSubscription<PgNotification>? _sub;
  bool _isClosed = false;
  bool _isReconnecting = false;

  /// Stream of incoming notifications across all subscribed channels.
  Stream<PgNotification> get stream => _controller.stream;

  /// Set of currently active channel subscriptions.
  Set<String> get channels => Set<String>.unmodifiable(_channels);

  /// Whether the listener has been closed.
  bool get isClosed => _isClosed;

  /// Whether the listener is currently connected and actively listening.
  bool get isConnected => _client != null && _client!.isConnected;

  /// Checks whether [channel] is in the active subscriptions set.
  bool isListening(String channel) => _channels.contains(channel);

  /// Connects a new [PgListener] and optionally subscribes to [channels].
  static Future<PgListener> connect(
    PgConfig config, {
    Iterable<String>? channels,
    Duration reconnectDelay = const Duration(seconds: 1),
  }) async {
    final listener = PgListener._(
      config,
      reconnectDelay: reconnectDelay,
    );

    await listener._connectClient();

    if (channels != null && channels.isNotEmpty) {
      await listener.listenAll(channels);
    }

    return listener;
  }

  /// Subscribes to [channel] and sends `LISTEN` to the server.
  Future<void> listen(String channel) async {
    _ensureOpen();
    if (_channels.add(channel)) {
      if (_client case final client? when client.isConnected) {
        await client.simpleQuery('LISTEN ${escapeIdentifier(channel)};');
      }
    }
  }

  /// Subscribes to multiple [channels] and sends `LISTEN` to the server.
  Future<void> listenAll(Iterable<String> channels) async {
    _ensureOpen();
    final toListen = <String>[];
    for (final channel in channels) {
      if (_channels.add(channel)) {
        toListen.add(channel);
      }
    }

    if (toListen.isNotEmpty) {
      if (_client case final client? when client.isConnected) {
        final sql = toListen
            .map((c) => 'LISTEN ${escapeIdentifier(c)};')
            .join(' ');
        await client.simpleQuery(sql);
      }
    }
  }

  /// Unsubscribes from [channel] and sends `UNLISTEN` to the server.
  Future<void> unlisten(String channel) async {
    _ensureOpen();
    if (_channels.remove(channel)) {
      if (_client case final client? when client.isConnected) {
        await client.simpleQuery('UNLISTEN ${escapeIdentifier(channel)};');
      }
    }
  }

  /// Unsubscribes from all active channels and sends `UNLISTEN *` to the
  /// server.
  Future<void> unlistenAll() async {
    _ensureOpen();
    _channels.clear();
    if (_client case final client? when client.isConnected) {
      await client.simpleQuery('UNLISTEN *;');
    }
  }

  /// Closes the listener connection and terminates the [stream].
  Future<void> close() async {
    if (_isClosed) return;
    _isClosed = true;
    _channels.clear();

    await _sub?.cancel();
    _sub = null;

    final client = _client;
    _client = null;
    if (client != null) {
      await client.close();
    }

    if (!_controller.isClosed) {
      await _controller.close();
    }
  }

  Future<void> _connectClient() async {
    final client = await PgClient.connect(config);
    _attachClient(client);
  }

  void _attachClient(PgClient client) {
    _client = client;
    _sub?.cancel();
    _sub = client.notifications.listen(
      (n) {
        if (!_controller.isClosed) {
          _controller.add(n);
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        _handleConnectionLoss();
      },
      onDone: _handleConnectionLoss,
      cancelOnError: true,
    );
  }

  void _handleConnectionLoss() {
    if (_isClosed || _isReconnecting) return;
    _isReconnecting = true;
    _sub?.cancel();
    _sub = null;

    unawaited(_reconnectLoop());
  }

  Future<void> _reconnectLoop() async {
    while (!_isClosed) {
      await Future<void>.delayed(reconnectDelay);
      if (_isClosed) break;

      try {
        final client = await PgClient.connect(config);
        if (_isClosed) {
          await client.close();
          break;
        }

        // Restore all channel subscriptions on the new connection
        if (_channels.isNotEmpty) {
          final sql = _channels
              .map((c) => 'LISTEN ${escapeIdentifier(c)};')
              .join(' ');
          await client.simpleQuery(sql);
        }

        _attachClient(client);
        _isReconnecting = false;
        return;
      } catch (_) {
        // Reconnect attempt failed, retry after delay
      }
    }
    _isReconnecting = false;
  }

  void _ensureOpen() {
    if (_isClosed) {
      throw StateError('Cannot operate on a closed PgListener.');
    }
  }
}
