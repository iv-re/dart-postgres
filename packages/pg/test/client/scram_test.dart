import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:crypto/crypto.dart';
import 'package:pg/pg.dart';
import 'package:pg/src/client/auth.dart';
import 'package:pg/src/client/operation.dart';
import 'package:pg/src/protocol/backend.dart';
import 'package:pg/src/protocol/frontend.dart';
import 'package:test/scaffolding.dart';

void main() {
  group('ScramAuthenticator', () {
    test('creates valid client initial message (n,,n=user,r=nonce)', () {
      final scram = ScramAuthenticator(
        username: 'user',
        password: 'password',
        nonce: 'fyko+d2lbbFgAZfeEz/uA1Bi',
      );

      final initialBytes = scram.createInitialMessage();
      final initialStr = utf8.decode(initialBytes);

      check(
        initialStr,
      ).equals('n,,n=user,r=fyko+d2lbbFgAZfeEz/uA1Bi');
    });

    test('escapes username with = and , per RFC 5802', () {
      final scram = ScramAuthenticator(
        username: 'user,name=test',
        password: 'password',
        nonce: 'fyko+d2lbbFgAZfeEz/uA1Bi',
      );

      final initialStr = utf8.decode(scram.createInitialMessage());
      check(
        initialStr,
      ).equals('n,,n=user=2Cname=3Dtest,r=fyko+d2lbbFgAZfeEz/uA1Bi');
    });

    test(
      'processes server-first-message and produces client-final-message',
      () {
        final scram = ScramAuthenticator(
          username: 'user',
          password: 'pencil',
          nonce: 'fyko+d2lbbFgAZfeEz/uA1Bi',
        );

        scram.createInitialMessage();

        // RFC 7677 / RFC 5802 test vector server first message
        final serverFirstMsg = utf8.encode(
          'r=fyko+d2lbbFgAZfeEz/uA1Bi3rGp34D234,s=QSXCR+v6sek8bf92,i=4096',
        );

        final clientFinalBytes = scram.processServerFirstMessage(
          Uint8List.fromList(serverFirstMsg),
        );
        final clientFinalStr = utf8.decode(clientFinalBytes);

        check(
          clientFinalStr,
        ).startsWith('c=biws,r=fyko+d2lbbFgAZfeEz/uA1Bi3rGp34D234,p=');
      },
    );

    test('verifies server final message signature successfully', () {
      final scram = ScramAuthenticator(
        username: 'user',
        password: 'pencil',
        nonce: 'fyko+d2lbbFgAZfeEz/uA1Bi',
      );

      scram.createInitialMessage();

      final serverFirstMsg = utf8.encode(
        'r=fyko+d2lbbFgAZfeEz/uA1Bi3rGp34D234,s=QSXCR+v6sek8bf92,i=4096',
      );
      scram.processServerFirstMessage(Uint8List.fromList(serverFirstMsg));

      check(
        () => scram.verifyServerFinalMessage(
          Uint8List.fromList(utf8.encode('v=invalid_sig')),
        ),
      ).throws<StateError>();
    });
  });

  group('ScramAuthenticator SCRAM-SHA-256-PLUS', () {
    final dummyCertDer = Uint8List.fromList([
      0x30,
      0x82,
      0x01,
      0x0a,
      0x02,
      0x82,
      0x01,
      0x01,
      0x00,
      0xab,
      0xcd,
      0xef,
    ]);

    test(
      'creates valid client initial message with channel binding',
      () {
        final scram = ScramAuthenticator(
          username: 'user',
          password: 'password',
          nonce: 'fyko+d2lbbFgAZfeEz/uA1Bi',
          serverCertificateDer: dummyCertDer,
        );

        final initialBytes = scram.createInitialMessage();
        final initialStr = utf8.decode(initialBytes);

        check(
          initialStr,
        ).equals('p=tls-server-end-point,,n=user,r=fyko+d2lbbFgAZfeEz/uA1Bi');
      },
    );

    test('processes server-first-message with channel binding data', () {
      final scram = ScramAuthenticator(
        username: 'user',
        password: 'pencil',
        nonce: 'fyko+d2lbbFgAZfeEz/uA1Bi',
        serverCertificateDer: dummyCertDer,
      );

      scram.createInitialMessage();

      final serverFirstMsg = utf8.encode(
        'r=fyko+d2lbbFgAZfeEz/uA1Bi3rGp34D234,s=QSXCR+v6sek8bf92,i=4096',
      );

      final clientFinalBytes = scram.processServerFirstMessage(
        Uint8List.fromList(serverFirstMsg),
      );
      final clientFinalStr = utf8.decode(clientFinalBytes);

      final certHash = sha256.convert(dummyCertDer).bytes;
      final expectedC = base64.encode([
        ...utf8.encode('p=tls-server-end-point,,'),
        ...certHash,
      ]);

      check(
        clientFinalStr,
      ).startsWith('c=$expectedC,r=fyko+d2lbbFgAZfeEz/uA1Bi3rGp34D234,p=');
    });
  });

  group('HandshakeOperation SASL negotiation', () {
    final dummyCertDer = Uint8List.fromList([1, 2, 3, 4]);

    test(
      'selects SCRAM-SHA-256-PLUS when TLS and PLUS supported (prefer mode)',
      () {
        final sent = <FrontendMessage>[];
        final completer = Completer<BackendKeyData>();
        final config = PgConfig(
          host: 'localhost',
          user: 'postgres',
          password: 'secret_password',
          database: 'db',
        );

        final op = HandshakeOperation(
          config: config,
          send: sent.add,
          completer: completer,
          serverCertificateDer: dummyCertDer,
        );

        op.onMessage(
          const AuthenticationSasl(['SCRAM-SHA-256-PLUS', 'SCRAM-SHA-256']),
        );

        check(sent.length).equals(1);
        final msg = sent.first as SaslInitialResponseMessage;
        check(msg.mechanism).equals('SCRAM-SHA-256-PLUS');
        check(utf8.decode(msg.data)).startsWith('p=tls-server-end-point,,');
      },
    );

    test('selects SCRAM-SHA-256 when channel binding is disabled', () {
      final sent = <FrontendMessage>[];
      final completer = Completer<BackendKeyData>();
      final config = PgConfig(
        host: 'localhost',
        user: 'postgres',
        password: 'secret_password',
        database: 'db',
        sslConfig: const PgSslConfig(channelBinding: .disable),
      );

      final op = HandshakeOperation(
        config: config,
        send: sent.add,
        completer: completer,
        serverCertificateDer: dummyCertDer,
      );

      op.onMessage(
        const AuthenticationSasl(['SCRAM-SHA-256-PLUS', 'SCRAM-SHA-256']),
      );

      check(sent.length).equals(1);
      final msg = sent.first as SaslInitialResponseMessage;
      check(msg.mechanism).equals('SCRAM-SHA-256');
      check(utf8.decode(msg.data)).startsWith('n,,');
    });

    test(
      'fails when channel binding is required but TLS is not active',
      () async {
        final completer = Completer<BackendKeyData>();
        final config = PgConfig(
          host: 'localhost',
          user: 'postgres',
          password: 'secret_password',
          database: 'db',
          sslConfig: const PgSslConfig(
            mode: .disable,
            channelBinding: .require,
          ),
        );

        final op = HandshakeOperation(
          config: config,
          send: (_) {},
          completer: completer,
        );

        op.onMessage(
          const AuthenticationSasl(['SCRAM-SHA-256-PLUS', 'SCRAM-SHA-256']),
        );

        await check(completer.future).throws<StateError>();
      },
    );

    test(
      'fails when channel binding is required but server lacks PLUS',
      () async {
        final completer = Completer<BackendKeyData>();
        final config = PgConfig(
          host: 'localhost',
          user: 'postgres',
          password: 'secret_password',
          database: 'db',
          sslConfig: const PgSslConfig(channelBinding: .require),
        );

        final op = HandshakeOperation(
          config: config,
          send: (_) {},
          completer: completer,
          serverCertificateDer: dummyCertDer,
        );

        op.onMessage(
          const AuthenticationSasl(['SCRAM-SHA-256']),
        );

        await check(completer.future).throws<UnsupportedError>();
      },
    );

    test('fails if password is empty when server requests auth', () async {
      final completer = Completer<BackendKeyData>();
      final config = PgConfig(
        host: 'localhost',
        user: 'postgres',
        password: '',
        database: 'db',
      );

      final op = HandshakeOperation(
        config: config,
        send: (_) {},
        completer: completer,
      );

      op.onMessage(
        const AuthenticationSasl(['SCRAM-SHA-256']),
      );

      await check(completer.future).throws<ArgumentError>();
    });
  });
}
