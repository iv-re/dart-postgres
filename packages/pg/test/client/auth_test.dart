import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:crypto/crypto.dart';
import 'package:pg/src/client/auth.dart';
import 'package:test/scaffolding.dart';

void main() {
  group('md5Password', () {
    test('computes valid postgres md5 hash format', () {
      final salt = [1, 2, 3, 4];
      final hash = md5Password(
        username: 'postgres',
        password: 'secret_password',
        salt: salt,
      );

      // Expected format: 'md5' + 32-hex-characters = 35 characters
      check(hash).startsWith('md5');
      check(hash.length).equals(35);

      // Validate against manual two-step MD5
      final step1 = md5
          .convert(utf8.encode('secret_passwordpostgres'))
          .toString();
      final step2 = md5.convert([...utf8.encode(step1), ...salt]).toString();
      final expected = 'md5$step2';

      check(hash).equals(expected);
    });
  });
}
