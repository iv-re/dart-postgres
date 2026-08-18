# pg

[![pub package](https://img.shields.io/pub/v/pg.svg)](https://pub.dev/packages/pg)

PostgreSQL client for Dart.

## Quick Start

```dart
import 'package:pg/pg.dart';

void main() async {
  final pool = PgPool(
    PgConfig(
      host: 'localhost',
      user: 'postgres',
      password: 'password',
      database: 'mydb',
    ),
    minConnections: 2,
    maxConnections: 10,
  );

  final rows = await pool.query(
    r'SELECT id, name, email FROM users WHERE active = $1',
    [true],
  );

  for (final row in rows) {
    print('${row.int('id')}: ${row.string('name')} <${row.string('email')}>');
  }

  await pool.close();
}
```

---

## Performance

Benchmarks comparing `package:pg` against `package:postgres` and `pgx` (Go):

| Benchmark | `pg` | `postgres v3` | `pgx` (Go) |
|:---|:---|:---|:---|
| **Simple Query (SELECT 1)** | 16.1k qps (62.2 µs) | 3.9k qps (258.8 µs) | 17.1k qps (58.3 µs) |
| **Parameterized Query** | 20.1k qps (49.8 µs) | 3.5k qps (289.3 µs) | 18.5k qps (54.0 µs) |
| **Multi-Row Fetch (100 rows)** | 457.7k rows/s (2.2 µs) | 149.7k rows/s (6.7 µs) | 561.2k rows/s (1.8 µs) |
| **Short Transactions** | 5.4k tx/s (184.6 µs) | 2.1k tx/s (465.3 µs) | 6.9k tx/s (143.9 µs) |
| **Concurrent Pool (50 workers)** | 46.3k qps (21.6 µs) | 8.8k qps (113.4 µs) | 88.0k qps (11.4 µs) |
| **Web App (4 isolates x 4 conn)** | 123.3k qps (8.1 µs) | 25.1k qps (39.8 µs) | 90.1k qps (11.1 µs) |


---

## Connecting

### PgClient (Single Connection)

Represents a single connection to PostgreSQL:

```dart
final client = await PgClient.connect(PgConfig(
  host: 'localhost',
  user: 'app',
  password: 'password',
  database: 'production',
));

final rows = await client.query('SELECT 1', []);
await client.close();
```

### PgPool (Connection Pool)

Manages a pool of reusable connections with automatic lifecycle management and idle connection reaping.

```dart
final pool = PgPool(
  PgConfig(
    host: 'localhost',
    user: 'postgres',
    password: 'password',
    database: 'mydb',
  ),
  minConnections: 2,
  maxConnections: 10,
  idleTimeout: Duration(minutes: 5),
);

// Execute directly on the pool (borrows and returns a connection automatically):
final rows = await pool.query('SELECT count(*) FROM users', []);

// Borrow a dedicated connection for multi-step operations:
await pool.withClient((client) async {
  final stmt  = await client.prepare(r'SELECT * FROM users WHERE id = $1');
  final alice = await client.execute(stmt, [1]);
  final bob   = await client.execute(stmt, [2]);
});

// Diagnostics:
print(pool.idleConnections);  // idle connections available
print(pool.inUseConnections); // borrowed connections
print(pool.totalConnections); // total (idle + in-use + pending)

await pool.close();
```

Pool options:

| Parameter | Default | Description |
|:----------|:--------|:------------|
| `minConnections` | `2` | Minimum idle connections to keep alive |
| `maxConnections` | `10` | Maximum total connections |
| `idleTimeout` | `5 min` | Close idle connections after this duration |
| `maxLifetime` | `null` | Retire connections older than this duration |
| `healthCheckPeriod` | `null` | Ping idle connections at this interval |
| `beforeAcquire` | `null` | Validate connection before borrowing |
| `afterRelease` | `null` | Reset connection state after returning (e.g. `DISCARD ALL`) |

### Configuration (PgConfig)

```dart
final config = PgConfig(
  host: 'db.example.com',
  port: 5432,
  user: 'app',
  password: 'password',
  database: 'production',
  queryMode: .prepared,
);
```

### Connection URI

Parse standard PostgreSQL connection strings:

```dart
// Single host
final client = await PgClient.connect(
  PgConfig.fromUri(Uri.parse('postgres://app:s3cret@localhost:5432/mydb')),
);

// Multi-host with options
final client = await PgClient.connect(
  PgConfig.fromUri(Uri.parse(
    'postgres://app:s3cret@host1:5432,host2:5432/mydb'
    '?sslmode=require'
    '&target_session_attrs=read-write'
    '&load_balance_hosts=random',
  )),
);

// Unix domain socket
final client = await PgClient.connect(
  PgConfig.fromUri(Uri.parse('postgres://app:s3cret@/mydb?host=/var/run/postgresql')),
);
```

### SSL/TLS

Configure encryption, certificate validation, and SCRAM channel binding:

```dart
final client = await PgClient.connect(PgConfig(
  host: 'db.example.com',
  user: 'app',
  password: 'password',
  database: 'production',
  sslConfig: PgSslConfig(
    mode: .verifyFull,        // certificate + hostname verification
    channelBinding: .require, // SCRAM-SHA-256-PLUS
  ),
));
```

SSL modes:

| Mode | Encryption | Certificate Verification | Hostname Verification |
|:-----|:----------:|:------------------------:|:---------------------:|
| `disable` | ✗ | ✗ | ✗ |
| `prefer` | fallback | ✗ | ✗ |
| `require` | ✓ | ✗ | ✗ |
| `verifyCa` | ✓ | ✓ | ✗ |
| `verifyFull` | ✓ | ✓ | ✓ |

### Multi-Host Failover & Load Balancing

```dart
final client = await PgClient.connect(PgConfig.multi(
  endpoints: [
    PgEndpoint('primary.db.example.com', 5432),
    PgEndpoint('replica.db.example.com', 5432),
  ],
  user: 'app',
  password: 'password',
  database: 'production',
  targetSessionAttrs: .readWrite, // connect to primary only
  loadBalanceHosts: .random,      // shuffle before connecting
));
```

---

## Queries & Transactions

`PgClient`, `PgPool`, and `PgTransaction` implement `PgExecutor`, sharing the same query API.

### Simple Queries

Use `simpleQuery` for unparameterized SQL (DDL, `SET`, session configuration):

```dart
await client.simpleQuery('SET timezone TO "UTC";');
await client.simpleQuery('CREATE TABLE IF NOT EXISTS users (id serial PRIMARY KEY, name text NOT NULL);');
```

### Parameterized Queries

Use `query` with positional parameters (`$1`, `$2`, …):

```dart
// INSERT
final result = await client.query(
  r'INSERT INTO users (name, email) VALUES ($1, $2) RETURNING id',
  ['Alice', 'alice@example.com'],
);
final newId = result.first.int('id');

// SELECT
final rows = await client.query(
  r'SELECT * FROM users WHERE created_at > $1 AND role = $2',
  [DateTime.utc(2026, 1, 1), 'admin'],
);
```

### Streaming Results

For large result sets, use `queryStream` to stream rows without buffering the entire result set in memory:

```dart
final stream = await client.queryStream(
  r'SELECT * FROM events WHERE timestamp > $1',
  [DateTime.utc(2026, 1, 1)],
);

await for (final row in stream) {
  processEvent(row.int('id'), row.dateTime('timestamp'));
}
```

### Reading Results

Query results (`PgRows`) are iterable over `PgRow`. Access columns by name or zero-based index:

```dart
final rows = await client.query(
  r'SELECT id, name, score, bio FROM players WHERE team = $1',
  ['red'],
);

for (final row in rows) {
  final id    = row.int('id');           // int (throws if NULL)
  final name  = row.string('name');      // String
  final score = row.double('score');     // double
  final bio   = row.stringOrNull('bio'); // String? (nullable)
}

// By column index:
final firstId = rows[0].int(0);

// Result metadata:
print(rows.commandTag);   // 'SELECT 3'
print(rows.affectedRows); // 3
print(rows.length);       // 3
```

### Transactions

```dart
final userId = await client.transaction((tx) async {
  final rows = await tx.query(
    r'INSERT INTO users (name) VALUES ($1) RETURNING id',
    ['Bob'],
  );
  final id = rows.first.int('id');

  await tx.query(
    r'INSERT INTO profiles (user_id, bio) VALUES ($1, $2)',
    [id, 'Hello!'],
  );

  return id; // automatically commits on return
}); // automatically rolls back if an exception is thrown
```

Transaction options:

```dart
await client.transaction(
  (tx) async { /* ... */ },
  isolationLevel: .serializable,
  readOnly: true,
  deferrable: true,
);
```

### Nested Transactions (Savepoints)

Nested `transaction()` calls inside an active transaction create savepoints automatically:

```dart
await client.transaction((tx) async {
  await tx.query(r'INSERT INTO log (msg) VALUES ($1)', ['step 1']);

  try {
    await tx.transaction((nested) async {
      await nested.query(r'INSERT INTO log (msg) VALUES ($1)', ['step 2']);
      throw Exception('rollback nested only');
    });
  } catch (_) {
    // nested rolled back to savepoint; outer transaction continues
  }

  await tx.query(r'INSERT INTO log (msg) VALUES ($1)', ['step 3']); // succeeds
});
```

### Timeouts & Context Propagation

All operations accept an optional `Context` from `package:ctx` for cancellation and deadlines:

```dart
import 'package:ctx/ctx.dart';

final ctx = Context.current.withTimeout(Duration(seconds: 2));

try {
  final rows = await pool.query(
    'SELECT pg_sleep(5)',
    [],
    ctx: ctx,
  );
} on ContextTimeoutException {
  print('Query timed out');
}
```

### Query Cancellation

Cancel a long-running query out-of-band using the connection's `PgCancelToken`:

```dart
final token = client.cancelToken;

// In a timer callback or separate isolate:
Timer(Duration(seconds: 5), () => token.cancel());

try {
  await client.query(r'SELECT pg_sleep($1)', [60]);
} on PgException catch (e) {
  print('Query cancelled: ${e.message}');
}
```

---

## Advanced Features

### Prepared Statements

Prepared statements are parsed and planned once on the server, then executed repeatedly:

```dart
final stmt = await client.prepare(
  r'SELECT * FROM users WHERE role = $1 AND active = $2',
);

final admins  = await client.execute(stmt, ['admin', true]);
final editors = await client.execute(stmt, ['editor', true]);
```

`PgClient` caches prepared statements automatically (LRU, default capacity 100). Repeated `query()` calls reuse cached statements transparently.

### Portals (Cursor-Based Pagination)

Fetch rows from a prepared statement in batches:

```dart
final stmt = await client.prepare(
  'SELECT * FROM large_table ORDER BY id',
);
final portal = await client.bind(stmt, []);

while (true) {
  final batch = await client.queryPortal(portal, maxRows: 100);
  processBatch(batch);
  if (!batch.hasMore) break;
}

await client.closePortal(portal);
```

### Pipelining

Send multiple queries in a single TCP socket payload:

```dart
final [users, orders, stats] = await client.pipeline((p) {
  p.query(r'SELECT * FROM users WHERE active = $1', [true]);
  p.query(r'SELECT * FROM orders WHERE status = $1', ['pending']);
  p.query(r'SELECT count(*) as c FROM events', []);
});

print('${users.length} users, ${orders.length} orders');
print('${stats.first.int('c')} events');
```

### Bulk Data Transfer (COPY)

#### COPY IN (Import)

Stream data into PostgreSQL using the `COPY FROM STDIN` protocol:

```dart
final sink = await client.copyIn(
  "COPY users (name, email) FROM STDIN WITH (FORMAT csv)",
);

sink.add(utf8.encode('Alice,alice@example.com\n'));
sink.add(utf8.encode('Bob,bob@example.com\n'));

final rowCount = await sink.finish();
print('Imported $rowCount rows');
```

Stream from a file:

```dart
final sink = await client.copyIn(
  "COPY users (name, email) FROM STDIN WITH (FORMAT csv)",
);
await sink.addStream(File('users.csv').openRead());
final rowCount = await sink.finish();
```

#### COPY OUT (Export)

Stream data out of PostgreSQL using the `COPY ... TO STDOUT` protocol:

```dart
final stream = await client.copyOut(
  "COPY users TO STDOUT WITH (FORMAT csv, HEADER true)",
);

final file = File('export.csv').openWrite();
await stream.pipe(file);
```

### Notifications (LISTEN / NOTIFY)

`PgListener` subscribes to PostgreSQL notification channels with automatic reconnection:

```dart
final listener = await PgListener.connect(
  PgConfig(host: 'localhost', user: 'postgres', password: 'pw', database: 'mydb'),
  channels: ['events', 'alerts'],
  reconnectDelay: Duration(seconds: 5),
);

listener.stream.listen((notification) {
  print('[${notification.channel}] ${notification.payload}');
});

// Dynamic subscriptions:
await listener.listen('new_channel');
await listener.unlisten('alerts');

await listener.close();
```

Receive notifications directly on a regular `PgClient`:

```dart
client.notifications.listen((n) {
  print('${n.channel}: ${n.payload}');
});

await client.simpleQuery('LISTEN my_channel;');
```

### Tracing & Logging

Attach a `PgTracer` to observe queries, connection attempts, and server notices:

```dart
import 'package:sl/sl.dart';

final logger = Logger(handler: LogTextHandler(level: .debug));

final client = await PgClient.connect(
  PgConfig(
    host: 'localhost',
    user: 'postgres',
    password: 'password',
    database: 'mydb',
    tracer: PgLogger(
      logger.withAttrs([.string('component', 'postgres')]),
      slowThreshold: Duration(milliseconds: 200), // log slow queries as warnings
    ),
  ),
);
```

Custom tracer implementation:

```dart
class MyTracer implements PgTracer {
  @override
  void onQuery(PgQueryTrace trace) {
    print('${trace.sql} took ${trace.duration.inMilliseconds}ms');
    if (trace.isError) print('  ERROR: ${trace.error}');
  }

  @override
  void onConnect(PgEndpoint endpoint, Duration duration, {Object? error}) {
    print('Connected to $endpoint in ${duration.inMilliseconds}ms');
  }

  @override
  void onNotice(PgNotice notice) {
    print('NOTICE [${notice.severity}]: ${notice.message}');
  }
}
```

---

## Type System

### Type Mapping

| PostgreSQL Type | Dart Type | `PgRow` Getter |
| :--- | :--- | :--- |
| `bool` / `boolean` | `bool` | `row.bool(col)` |
| `int2` / `smallint` | `int` | `row.int(col)` |
| `int4` / `integer` | `int` | `row.int(col)` |
| `int8` / `bigint` | `int`, `BigInt` | `row.int(col)`, `row.bigint(col)` |
| `float4` / `real` | `double` | `row.double(col)` |
| `float8` / `double precision` | `double` | `row.double(col)` |
| `numeric` / `decimal` | `PgNumeric` | `row.numeric(col)` |
| `text` / `varchar` / `char` / `name` / `bpchar` | `String` | `row.string(col)` |
| `bytea` | `Uint8List` | `row.bytes(col)` |
| `uuid` | `String` | `row.uuid(col)` |
| `date` | `PgDate` | `row.date(col)` |
| `time` | `PgTime` | `row.time(col)` |
| `timetz` | `PgTimeTz` | `row.timeTz(col)` |
| `timestamp` / `timestamptz` | `DateTime` | `row.dateTime(col)` |
| `interval` | `PgInterval`, `Duration` | `row.interval(col)`, `row.duration(col)` |
| `json` / `jsonb` | `String`, `T` | `row.rawJson(col)`, `row.json<T>(col)` |
| `point` | `PgPoint` | `row.point(col)` |
| `box` | `PgBox` | `row.box(col)` |
| `circle` | `PgCircle` | `row.circle(col)` |
| `polygon` | `PgPolygon` | `row.polygon(col)` |
| `int4range`, `daterange`, `tsrange`, `...` | `PgRange<T>` | `row.range<T>(col, codec)` |
| `tsvector` | `PgTsVector` | `row.tsVector(col)` |
| `tsquery` | `PgTsQuery` | `row.tsQuery(col)` |
| `T[]` (e.g. `int[]`, `text[]`, `bool[]`, `uuid[]`) | `List<T>` | `row.list<T>(col)` |

For nullable columns, use the `*OrNull` counterpart (e.g. `row.intOrNull(col)`, `row.stringOrNull(col)`).

### Custom Types & Codecs

```dart
// Define a codec
class MoneyCodec implements PgCodec<Money> {
  const MoneyCodec();

  @override
  Uint8List encodeBinary(Money value) {
    final bytes = Uint8List(8);
    ByteData.sublistView(bytes).setInt64(0, value.cents);
    return bytes;
  }

  @override
  Money decodeBinary(Uint8List bytes) {
    return Money(ByteData.sublistView(bytes).getInt64(0));
  }

  @override
  Uint8List encodeText(Money value) => utf8.encoder.convert(value.cents.toString());

  @override
  Money decodeText(Uint8List bytes) => Money(int.parse(utf8.decode(bytes)));
}

// Register with PgTypeRegistry (enables parameter encoding in queries)
PgTypeRegistry.defaults.register<Money>(
  oid: PgOid(790),             // PostgreSQL money type OID
  codec: const MoneyCodec(),
  arrayOid: PgOid(791),        // enables List<Money> support
);

// Define a row getter extension
const _moneyCodec = MoneyCodec();

extension MoneyRowGetter on PgRow {
  @pragma('vm:prefer-inline')
  Money? moneyOrNull(Object column) => decodeOrNull(column, _moneyCodec);

  @pragma('vm:prefer-inline')
  Money money(Object column) => decode(column, _moneyCodec);
}

// Use in queries
await client.query(
  r'INSERT INTO products (name, price) VALUES ($1, $2)',
  ['Coffee', Money(350)],
);

final rows = await client.query(
  r'SELECT name, price FROM products WHERE id = $1',
  [42],
);
final price = rows.first.money('price');
```