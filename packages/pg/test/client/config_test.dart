import 'package:checks/checks.dart';
import 'package:pg/pg.dart';
import 'package:test/scaffolding.dart';

void main() {
  group('PgEndpoint', () {
    test('TCP endpoint properties', () {
      const ep = PgEndpoint('localhost');
      check(ep.host).equals('localhost');
      check(ep.port).equals(5432);
      check(ep.isUnixSocket).equals(false);
    });

    test('Unix socket endpoint properties', () {
      const ep = PgEndpoint('/tmp');
      check(ep.host).equals('/tmp');
      check(ep.isUnixSocket).equals(true);
    });

    test('equality and hashCode', () {
      const ep1 = PgEndpoint('h1');
      const ep2 = PgEndpoint('h1');
      const ep3 = PgEndpoint('h2');

      check(ep1).equals(ep2);
      check(ep1.hashCode).equals(ep2.hashCode);
      check(ep1).not((it) => it.equals(ep3));
    });
  });

  group('PgSslConfig', () {
    test('defaults to require mode', () {
      const sslConfig = PgSslConfig();
      check(sslConfig.mode).equals(.require);
      check(sslConfig.securityContext).isNull();
      check(sslConfig.onBadCertificate).isNull();
    });

    test('accepts custom options', () {
      const sslConfig = PgSslConfig(mode: .verifyFull);
      check(sslConfig.mode).equals(.verifyFull);
    });
  });

  group('PgConfig.fromUri', () {
    test('parses full standard URI', () {
      final uri = Uri.parse(
        'postgres://admin:secret123@db.example.com:5433/production_db',
      );
      final config = PgConfig.fromUri(uri);

      check(config.endpoints.first.host).equals('db.example.com');
      check(config.endpoints.first.port).equals(5433);
      check(config.user).equals('admin');
      check(config.password).equals('secret123');
      check(config.database).equals('production_db');
    });

    test('supports postgresql scheme', () {
      final uri = Uri.parse(
        'postgresql://admin:secret@localhost:5432/mydb',
      );
      final config = PgConfig.fromUri(uri);

      check(config.endpoints.first.host).equals('localhost');
      check(config.endpoints.first.port).equals(5432);
      check(config.user).equals('admin');
      check(config.password).equals('secret');
      check(config.database).equals('mydb');
    });

    test('throws ArgumentError on invalid scheme', () {
      final uri = Uri.parse('mysql://root:pass@localhost:3306/db');

      check(() => PgConfig.fromUri(uri)).throws<ArgumentError>();
    });

    test('defaults to localhost when host is omitted', () {
      final uri = Uri.parse('postgres:///mydb');
      final config = PgConfig.fromUri(uri);

      check(config.endpoints.first.host).equals('localhost');
      check(config.database).equals('mydb');
    });

    test('defaults to 5432 when port is omitted', () {
      final uri = Uri.parse('postgres://user:pass@localhost/mydb');
      final config = PgConfig.fromUri(uri);

      check(config.endpoints.first.port).equals(5432);
    });

    test('defaults to postgres user when userInfo is omitted', () {
      final uri = Uri.parse('postgres://localhost/mydb');
      final config = PgConfig.fromUri(uri);

      check(config.user).equals('postgres');
      check(config.password).equals('');
    });

    test('defaults database to username when database is omitted', () {
      final uri = Uri.parse('postgres://custom_user:pass@localhost:5432');
      final config = PgConfig.fromUri(uri);

      check(config.database).equals('custom_user');
    });

    test('handles password containing colons', () {
      final uri = Uri.parse('postgres://user:p:a:s:s@localhost/db');
      final config = PgConfig.fromUri(uri);

      check(config.user).equals('user');
      check(config.password).equals('p:a:s:s');
    });

    test('decodes percent-encoded credentials and database', () {
      final uri = Uri.parse(
        'postgres://user%40mail.com:p%40ss%23word@localhost/my%20db',
      );
      final config = PgConfig.fromUri(uri);

      check(config.user).equals('user@mail.com');
      check(config.password).equals('p@ss#word');
      check(config.database).equals('my db');
    });

    test('parses sslmode parameters correctly', () {
      final disableConfig = PgConfig.fromUri(
        Uri.parse('postgres://user:pass@localhost/mydb?sslmode=disable'),
      );
      check(disableConfig.sslConfig.mode).equals(PgSslMode.disable);

      final requireConfig = PgConfig.fromUri(
        Uri.parse('postgres://user:pass@localhost/mydb?sslmode=require'),
      );
      check(requireConfig.sslConfig.mode).equals(PgSslMode.require);

      final verifyCaConfig = PgConfig.fromUri(
        Uri.parse('postgres://user:pass@localhost/mydb?sslmode=verify-ca'),
      );
      check(verifyCaConfig.sslConfig.mode).equals(PgSslMode.verifyCa);

      final verifyFullConfig = PgConfig.fromUri(
        Uri.parse('postgres://user:pass@localhost/mydb?sslmode=verify-full'),
      );
      check(verifyFullConfig.sslConfig.mode).equals(PgSslMode.verifyFull);

      check(
        () => PgConfig.fromUri(
          Uri.parse('postgres://user:pass@localhost/mydb?sslmode=invalid'),
        ),
      ).throws<ArgumentError>();
    });

    test('parses channel_binding parameters correctly', () {
      final disableConfig = PgConfig.fromUri(
        Uri.parse(
          'postgres://user:pass@localhost/mydb?channel_binding=disable',
        ),
      );
      check(
        disableConfig.sslConfig.channelBinding,
      ).equals(PgChannelBinding.disable);

      final requireConfig = PgConfig.fromUri(
        Uri.parse(
          'postgres://user:pass@localhost/mydb?channel_binding=require',
        ),
      );
      check(
        requireConfig.sslConfig.channelBinding,
      ).equals(PgChannelBinding.require);

      final preferConfig = PgConfig.fromUri(
        Uri.parse('postgres://user:pass@localhost/mydb?channel_binding=prefer'),
      );
      check(
        preferConfig.sslConfig.channelBinding,
      ).equals(PgChannelBinding.prefer);

      final defaultConfig = PgConfig.fromUri(
        Uri.parse('postgres://user:pass@localhost/mydb'),
      );
      check(
        defaultConfig.sslConfig.channelBinding,
      ).equals(PgChannelBinding.prefer);

      check(
        () => PgConfig.fromUri(
          Uri.parse(
            'postgres://user:pass@localhost/mydb?channel_binding=invalid',
          ),
        ),
      ).throws<ArgumentError>();
    });

    test('parses query_mode parameters correctly', () {
      final unnamedConfig = PgConfig.fromUri(
        Uri.parse('postgres://user:pass@localhost/mydb?query_mode=unnamed'),
      );
      check(unnamedConfig.queryMode).equals(PgQueryMode.unnamed);

      final simpleConfig = PgConfig.fromUri(
        Uri.parse('postgres://user:pass@localhost/mydb?query_mode=simple'),
      );
      check(simpleConfig.queryMode).equals(PgQueryMode.simple);

      final preparedConfig = PgConfig.fromUri(
        Uri.parse('postgres://user:pass@localhost/mydb?query_mode=prepared'),
      );
      check(preparedConfig.queryMode).equals(PgQueryMode.prepared);

      check(
        () => PgConfig.fromUri(
          Uri.parse('postgres://user:pass@localhost/mydb?query_mode=invalid'),
        ),
      ).throws<ArgumentError>();
    });
  });

  group('PgConfig Multi-Host & Socket URI', () {
    test('PgConfig.multi constructor', () {
      final config = PgConfig.multi(
        endpoints: const [
          PgEndpoint('host1'),
          PgEndpoint('host2', 5433),
        ],
        user: 'user',
        password: 'pass',
        database: 'db',
        targetSessionAttrs: PgTargetSessionAttrs.readWrite,
      );

      check(config.endpoints.length).equals(2);
      check(config.endpoints[0]).equals(const PgEndpoint('host1'));
      check(config.endpoints[1]).equals(const PgEndpoint('host2', 5433));
      check(config.targetSessionAttrs).equals(PgTargetSessionAttrs.readWrite);
    });

    test('fromUri parses multi-host in host query parameter', () {
      final uri = Uri.parse(
        'postgres://user:pass@/mydb'
        '?host=host1:5432,host2:5433&target_session_attrs=read-write',
      );
      final config = PgConfig.fromUri(uri);

      check(config.endpoints.length).equals(2);
      check(config.endpoints[0].host).equals('host1');
      check(config.endpoints[0].port).equals(5432);
      check(config.endpoints[1].host).equals('host2');
      check(config.endpoints[1].port).equals(5433);
      check(config.targetSessionAttrs).equals(PgTargetSessionAttrs.readWrite);
    });

    test('fromUri parses unix domain socket host parameter', () {
      final uri = Uri.parse(
        'postgres://user:pass@/mydb?host=/var/run/postgresql',
      );
      final config = PgConfig.fromUri(uri);

      check(config.endpoints.length).equals(1);
      check(config.endpoints.first.host).equals('/var/run/postgresql');
      check(config.endpoints.first.isUnixSocket).equals(true);
    });

    test('fromUri parses load_balance_hosts and sslmode parameters', () {
      final config1 = PgConfig.fromUri(
        Uri.parse(
          'postgres://user:pass@/mydb?'
          'host=host1:5432,host2:5433&load_balance_hosts=random&sslmode=prefer',
        ),
      );

      check(config1.loadBalanceHosts).equals(PgLoadBalanceHosts.random);
      check(config1.sslConfig.mode).equals(PgSslMode.prefer);

      final config2 = PgConfig.fromUri(
        Uri.parse('postgres://user:pass@localhost:5432/mydb'),
      );
      check(config2.loadBalanceHosts).equals(PgLoadBalanceHosts.disable);

      check(
        () => PgConfig.fromUri(
          Uri.parse('postgres://u:p@localhost/db?load_balance_hosts=invalid'),
        ),
      ).throws<ArgumentError>();
    });

    test('throws ArgumentError on invalid target_session_attrs', () {
      check(
        () => PgConfig.fromUri(
          Uri.parse(
            'postgres://user:pass@localhost/mydb?target_session_attrs=invalid',
          ),
        ),
      ).throws<ArgumentError>();
    });
  });
}
