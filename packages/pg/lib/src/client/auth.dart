import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Hashes password using MD5 with username and salt according to Postgres
/// specs.
///
/// Format: `md5 + md5(md5(password + username) + salt)`
String md5Password({
  required String username,
  required String password,
  required List<int> salt,
}) {
  final step1 = md5.convert(utf8.encode('$password$username')).toString();
  final step2Input = [...utf8.encode(step1), ...salt];
  final step2 = md5.convert(step2Input).toString();
  return 'md5$step2';
}

/// Helper for SASL SCRAM-SHA-256 and SCRAM-SHA-256-PLUS authentication
/// according to RFC 7677, RFC 5802 & RFC 5929.
class ScramAuthenticator {
  ScramAuthenticator({
    required this.username,
    required this.password,
    String? nonce,
    this._serverCertificateDer,
  }) : clientNonce = nonce ?? _generateNonce();

  final String username;
  final String password;
  final String clientNonce;
  final Uint8List? _serverCertificateDer;

  late String _clientFirstMessageBare;
  late String _serverFirstMessage;
  late Uint8List _saltedPassword;

  /// Whether TLS channel binding is used (SCRAM-SHA-256-PLUS).
  bool get isChannelBinding => _serverCertificateDer != null;

  String get _cValue {
    if (_serverCertificateDer case final certDer?) {
      final certHash = sha256.convert(certDer).bytes;
      final cbBytes = [...utf8.encode('p=tls-server-end-point,,'), ...certHash];
      return base64.encode(cbBytes);
    }
    return 'biws';
  }

  static String _generateNonce() {
    final random = Random.secure();
    final bytes = Uint8List(18);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = random.nextInt(256);
    }
    return base64.encode(bytes);
  }

  static String _escapeUsername(String username) {
    return username.replaceAll('=', '=3D').replaceAll(',', '=2C');
  }

  /// Generates initial SASL SCRAM client-first-message bytes
  /// (`n,,n=...,r=...` or `p=tls-server-end-point,,n=...,r=...`).
  Uint8List createInitialMessage() {
    final gs2Header = isChannelBinding ? 'p=tls-server-end-point,,' : 'n,,';
    final escapedUser = _escapeUsername(username);
    _clientFirstMessageBare = 'n=$escapedUser,r=$clientNonce';
    final clientFirstMessage = '$gs2Header$_clientFirstMessageBare';
    return Uint8List.fromList(utf8.encode(clientFirstMessage));
  }

  /// Processes server-first-message (`r=...,s=...,i=...`) and returns
  /// client-final-message bytes with proof (`c=...,r=...,p=...`).
  Uint8List processServerFirstMessage(Uint8List data) {
    _serverFirstMessage = utf8.decode(data);
    final params = _parseAttributeString(_serverFirstMessage);

    final serverNonce = params['r'];
    final saltBase64 = params['s'];
    final iterStr = params['i'];

    if (serverNonce == null || saltBase64 == null || iterStr == null) {
      throw const FormatException('Invalid SCRAM server-first-message');
    }

    if (!serverNonce.startsWith(clientNonce)) {
      throw const FormatException(
        'SCRAM server nonce does not match client nonce prefix',
      );
    }

    final iterations = int.parse(iterStr);
    final salt = base64.decode(saltBase64);

    _saltedPassword = _hi(utf8.encode(password), salt, iterations);

    final clientKey = _hmacSha256(_saltedPassword, utf8.encode('Client Key'));
    final storedKey = Uint8List.fromList(sha256.convert(clientKey).bytes);

    final clientFinalMessageWithoutProof = 'c=$_cValue,r=$serverNonce';
    final authMessage =
        '$_clientFirstMessageBare,'
        '$_serverFirstMessage,'
        '$clientFinalMessageWithoutProof';

    final clientSignature = _hmacSha256(storedKey, utf8.encode(authMessage));

    final clientProof = Uint8List(clientKey.length);
    for (var i = 0; i < clientKey.length; i++) {
      clientProof[i] = clientKey[i] ^ clientSignature[i];
    }

    final clientFinalMessage =
        '$clientFinalMessageWithoutProof,p=${base64.encode(clientProof)}';
    return Uint8List.fromList(utf8.encode(clientFinalMessage));
  }

  /// Verifies server-final-message (`v=...`) signature against expected
  /// signature.
  void verifyServerFinalMessage(Uint8List data) {
    final serverFinalMessage = utf8.decode(data);
    final params = _parseAttributeString(serverFinalMessage);

    if (params.containsKey('e')) {
      throw StateError('SCRAM server authentication error: ${params['e']}');
    }

    final serverSignatureBase64 = params['v'];
    if (serverSignatureBase64 == null) {
      throw const FormatException(
        'Missing server signature in SCRAM final message',
      );
    }

    final serverNonce = _parseAttributeString(_serverFirstMessage)['r'];
    final clientFinalMessageWithoutProof = _serverFirstMessage.isEmpty
        ? ''
        : 'c=$_cValue,r=$serverNonce';
    final authMessage =
        '$_clientFirstMessageBare,'
        '$_serverFirstMessage,'
        '$clientFinalMessageWithoutProof';

    final serverKey = _hmacSha256(_saltedPassword, utf8.encode('Server Key'));
    final expectedServerSignature = base64.encode(
      _hmacSha256(serverKey, utf8.encode(authMessage)),
    );

    if (serverSignatureBase64 != expectedServerSignature) {
      throw StateError('SCRAM server signature verification failed');
    }
  }

  static Uint8List _hmacSha256(List<int> key, List<int> data) {
    final hmac = Hmac(sha256, key);
    return Uint8List.fromList(hmac.convert(data).bytes);
  }

  /// PBKDF2 (HMAC-SHA256) implementation (RFC 2898 / RFC 7677).
  static Uint8List _hi(List<int> password, Uint8List salt, int iterations) {
    final hmac = Hmac(sha256, password);
    final saltWithOne = Uint8List(salt.length + 4);
    saltWithOne.setRange(0, salt.length, salt);
    saltWithOne[salt.length + 3] = 1;

    var u = Uint8List.fromList(hmac.convert(saltWithOne).bytes);
    final result = Uint8List.fromList(u);

    for (var i = 1; i < iterations; i++) {
      u = Uint8List.fromList(hmac.convert(u).bytes);
      for (var j = 0; j < result.length; j++) {
        result[j] ^= u[j];
      }
    }

    return result;
  }

  static Map<String, String> _parseAttributeString(String src) {
    final map = <String, String>{};
    final parts = src.split(',');
    for (final part in parts) {
      if (part.length >= 2 && part[1] == '=') {
        final key = part[0];
        final val = part.substring(2);
        map[key] = val;
      }
    }
    return map;
  }
}
