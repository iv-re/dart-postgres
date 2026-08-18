/// Asynchronous server notification response from PostgreSQL LISTEN / NOTIFY.
class const PgNotification({
  /// The process ID of the notifying backend process.
  required final int processId,

  /// The name of the channel that the notification was raised on.
  required final String channel,

  /// The payload string passed to NOTIFY.
  required final String payload,
}) {
  @override
  String toString() {
    return 'PgNotification(pid: $processId, channel: $channel, '
        'payload: $payload)';
  }
}
