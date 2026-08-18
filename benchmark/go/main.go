package main

import (
	"context"
	"fmt"
	"math"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type Config struct {
	Host     string
	Port     int
	User     string
	Password string
	Database string
}

func loadConfig() Config {
	host := os.Getenv("PGHOST")
	if host == "" {
		host = "localhost"
	}
	portStr := os.Getenv("PGPORT")
	port, err := strconv.Atoi(portStr)
	if err != nil || port == 0 {
		port = 5432
	}
	user := os.Getenv("PGUSER")
	if user == "" {
		user = "postgres"
	}
	password := os.Getenv("PGPASSWORD")
	if password == "" {
		password = "postgres"
	}
	database := os.Getenv("PGDATABASE")
	if database == "" {
		database = "postgres"
	}
	return Config{
		Host:     host,
		Port:     port,
		User:     user,
		Password: password,
		Database: database,
	}
}

func (c Config) ConnString() string {
	return fmt.Sprintf("postgres://%s:%s@%s:%d/%s?sslmode=disable",
		c.User, c.Password, c.Host, c.Port, c.Database)
}

type BenchResult struct {
	Name              string
	Iterations        int
	ItemsPerIteration int
	Unit              string
	Duration          time.Duration
}

func (r BenchResult) TotalItems() int {
	return r.Iterations * r.ItemsPerIteration
}

func (r BenchResult) OpsSec() double {
	sec := r.Duration.Seconds()
	if sec == 0 {
		return 0
	}
	return float64(r.TotalItems()) / sec
}

func (r BenchResult) AvgDuration() time.Duration {
	if r.TotalItems() == 0 {
		return 0
	}
	return time.Duration(int64(r.Duration) / int64(r.TotalItems()))
}

type double = float64

type BenchmarkRunner struct {
	results []BenchResult
}

func (r *BenchmarkRunner) Measure(
	name string,
	iterations int,
	itemsPerIteration int,
	unit string,
	fn func() error,
) (*BenchResult, error) {
	if itemsPerIteration <= 0 {
		itemsPerIteration = 1
	}

	warmupCount := int(math.Min(10, math.Max(2, float64(iterations)*0.05)))
	for i := 0; i < warmupCount; i++ {
		if err := fn(); err != nil {
			return nil, fmt.Errorf("warmup error in %s: %w", name, err)
		}
	}

	start := time.Now()
	for i := 0; i < iterations; i++ {
		if err := fn(); err != nil {
			return nil, fmt.Errorf("iteration error in %s: %w", name, err)
		}
	}
	elapsed := time.Since(start)

	res := BenchResult{
		Name:              name,
		Iterations:        iterations,
		ItemsPerIteration: itemsPerIteration,
		Unit:              unit,
		Duration:          elapsed,
	}
	r.results = append(r.results, res)
	r.printRow(res)
	return &res, nil
}

func (r *BenchmarkRunner) PrintHeader() {
	fmt.Println()
	fmt.Println(strings.Repeat("-", 60))
	fmt.Printf("%-32s | %-24s\n", "Benchmark", "go pgx (v5)")
	fmt.Println(strings.Repeat("-", 60))
}

func (r *BenchmarkRunner) PrintFooter() {
	fmt.Println(strings.Repeat("-", 60))
	fmt.Println()
}

func (r *BenchmarkRunner) printRow(res BenchResult) {
	ops := formatThroughput(res.OpsSec(), res.Unit)
	lat := formatDuration(res.AvgDuration())
	cell := fmt.Sprintf("%s (%s)", ops, lat)
	fmt.Printf("%-32s | %-24s\n", res.Name, cell)
}

func formatThroughput(ops float64, unit string) string {
	if ops >= 1_000_000 {
		return fmt.Sprintf("%.2fM %s", ops/1_000_000, unit)
	}
	if ops >= 1_000 {
		return fmt.Sprintf("%.1fk %s", ops/1_000, unit)
	}
	return fmt.Sprintf("%.0f %s", ops, unit)
}

func formatDuration(d time.Duration) string {
	us := float64(d.Nanoseconds()) / 1000.0
	if us >= 1000 {
		return fmt.Sprintf("%.2fms", us/1000.0)
	}
	return fmt.Sprintf("%.1fµs", us)
}

// WebAppCluster simulates 4 workers each with a 4-connection pool.
type WebAppCluster struct {
	pools []*pgxpool.Pool
}

func createWebAppCluster(ctx context.Context, cfg Config, workerCount, poolSize int) (*WebAppCluster, error) {
	pools := make([]*pgxpool.Pool, workerCount)
	for i := 0; i < workerCount; i++ {
		poolCfg, err := pgxpool.ParseConfig(cfg.ConnString())
		if err != nil {
			return nil, err
		}
		poolCfg.MinConns = int32(poolSize)
		poolCfg.MaxConns = int32(poolSize)
		p, err := pgxpool.NewWithConfig(ctx, poolCfg)
		if err != nil {
			return nil, err
		}
		pools[i] = p
	}
	return &WebAppCluster{pools: pools}, nil
}

func (c *WebAppCluster) Close() {
	for _, p := range c.pools {
		p.Close()
	}
}

const userQuerySql = `SELECT 1::int AS id, 'Alex'::text AS first_name, NULL::text AS last_name, now() AS created_at;`

func (c *WebAppCluster) Run(ctx context.Context, queriesPerWorker int) error {
	var wg sync.WaitGroup
	errCh := make(chan error, len(c.pools))

	for _, pool := range c.pools {
		wg.Add(1)
		go func(p *pgxpool.Pool) {
			defer wg.Done()
			var innerWg sync.WaitGroup
			for i := 0; i < queriesPerWorker; i++ {
				innerWg.Add(1)
				go func() {
					defer innerWg.Done()
					var id int
					var firstName string
					var lastName *string
					var createdAt time.Time
					err := p.QueryRow(ctx, userQuerySql).Scan(&id, &firstName, &lastName, &createdAt)
					if err != nil {
						select {
						case errCh <- err:
						default:
						}
					}
				}()
			}
			innerWg.Wait()
		}(pool)
	}

	wg.Wait()
	select {
	case err := <-errCh:
		return err
	default:
		return nil
	}
}

func main() {
	ctx := context.Background()
	cfg := loadConfig()

	fmt.Printf("Connecting to PostgreSQL at %s:%d/%s...\n", cfg.Host, cfg.Port, cfg.Database)

	// Single connection
	conn, err := pgx.Connect(ctx, cfg.ConnString())
	if err != nil {
		fmt.Fprintf(os.Stderr, "Failed to connect to database: %v\n", err)
		os.Exit(1)
	}
	defer conn.Close(ctx)

	// Connection pool (10 connections)
	poolCfg, err := pgxpool.ParseConfig(cfg.ConnString())
	if err != nil {
		fmt.Fprintf(os.Stderr, "Failed to parse pool config: %v\n", err)
		os.Exit(1)
	}
	poolCfg.MaxConns = 10
	pool, err := pgxpool.NewWithConfig(ctx, poolCfg)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Failed to create pool: %v\n", err)
		os.Exit(1)
	}
	defer pool.Close()

	// Web App Cluster (4 workers x 4 conn pool)
	cluster, err := createWebAppCluster(ctx, cfg, 4, 4)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Failed to create web app cluster: %v\n", err)
		os.Exit(1)
	}
	defer cluster.Close()

	runner := &BenchmarkRunner{}
	runner.PrintHeader()

	// 1. Simple Query (SELECT 1)
	_, err = runner.Measure("Simple Query (SELECT 1)", 2000, 1, "qps", func() error {
		var n int
		return conn.QueryRow(ctx, "SELECT 1;").Scan(&n)
	})
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}

	// 2. Parameterized Query
	_, err = runner.Measure("Parameterized Query", 2000, 1, "qps", func() error {
		var id int
		var name string
		return conn.QueryRow(ctx, `SELECT $1::int as id, $2::text as name;`, 42, "dart_pg").Scan(&id, &name)
	})
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}

	// 3. Multi-Row Query (100 rows fetch)
	const multiRowSql = `SELECT id, md5(id::text) as name, now() as created_at FROM generate_series(1, 100) id;`
	_, err = runner.Measure("Multi-Row Fetch (100 rows)", 500, 100, "rows/s", func() error {
		rows, err := conn.Query(ctx, multiRowSql)
		if err != nil {
			return err
		}
		defer rows.Close()

		for rows.Next() {
			var id int
			var name string
			var createdAt time.Time
			if err := rows.Scan(&id, &name, &createdAt); err != nil {
				return err
			}
		}
		return rows.Err()
	})
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}

	// 4. Short Transactions
	_, err = runner.Measure("Short Transactions", 1000, 1, "tx/s", func() error {
		tx, err := conn.Begin(ctx)
		if err != nil {
			return err
		}
		defer tx.Rollback(ctx)

		var n int
		if err := tx.QueryRow(ctx, "SELECT 1;").Scan(&n); err != nil {
			return err
		}
		return tx.Commit(ctx)
	})
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}

	// 5. Concurrent Pool (50 workers, 10 connections)
	_, err = runner.Measure("Concurrent Pool (50 workers)", 100, 50, "qps", func() error {
		var wg sync.WaitGroup
		errCh := make(chan error, 50)
		for i := 0; i < 50; i++ {
			wg.Add(1)
			go func() {
				defer wg.Done()
				var n int
				if err := pool.QueryRow(ctx, "SELECT 1;").Scan(&n); err != nil {
					select {
					case errCh <- err:
					default:
					}
				}
			}()
		}
		wg.Wait()
		select {
		case err := <-errCh:
			return err
		default:
			return nil
		}
	})
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}

	// 6. Web App (4 workers x 4 conn)
	_, err = runner.Measure("Web App (4 isolates x 4 conn)", 50, 4*100, "qps", func() error {
		return cluster.Run(ctx, 100)
	})
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}

	runner.PrintFooter()
}
