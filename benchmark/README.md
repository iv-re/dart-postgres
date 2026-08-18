# PostgreSQL Benchmarks

Benchmark suite comparing PostgreSQL client implementations:
- **`package:pg`** (Dart)
- **`package:postgres`** (Dart)
- **`github.com/jackc/pgx/v5`** (Go)

## Prerequisites

PostgreSQL running locally (or configured via environment variables):

```bash
export PGHOST=localhost
export PGPORT=5432
export PGUSER=postgres
export PGPASSWORD=postgres
export PGDATABASE=postgres
```

## Running Benchmarks

### Dart

```bash
dart compile exe bin/benchmark.dart -o bin/benchmark
./bin/benchmark
```

### Go (pgx)

```bash
cd go && go run main.go
```
