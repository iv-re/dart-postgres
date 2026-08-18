import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:pg/src/client/rows.dart';
import 'package:pg/src/types/codec.dart';

final _numericRegExp = RegExp(r'^(\d*)(\.\d*)?$');
final _leadingZerosRegExp = RegExp('^0+');
final _trailingZerosRegExp = RegExp(r'0+$');

/// Represents an arbitrary-precision PostgreSQL `numeric` / `decimal` value.
@immutable
class const PgNumeric(
  final String _text,
) implements Comparable<PgNumeric> {
  factory fromNum(num value) => PgNumeric(value.toString());
  factory fromBigInt(BigInt value) => PgNumeric(value.toString());

  /// Returns whether this value represents `NaN`.
  bool get isNaN => _text.toLowerCase() == 'nan';

  /// Returns whether this value is negative.
  bool get isNegative => _text.startsWith('-');

  /// Converts this numeric value to a Dart [double].
  double toDouble() => double.parse(_text);

  /// Converts this numeric value to a Dart [num].
  num toNum() => num.parse(_text);

  /// Converts this numeric value to a Dart [BigInt] (truncating fractions).
  BigInt toBigInt() {
    final dot = _text.indexOf('.');
    final integerPart = dot == -1 ? _text : _text.substring(0, dot);
    return BigInt.parse(integerPart.isEmpty ? '0' : integerPart);
  }

  /// Converts this numeric value to a Dart [int] (truncating fractions).
  int toInt() => toBigInt().toInt();

  @override
  int compareTo(PgNumeric other) {
    if (isNaN && other.isNaN) return 0;
    if (isNaN) return 1;
    if (other.isNaN) return -1;
    return toDouble().compareTo(other.toDouble());
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) || other is PgNumeric && _text == other._text;
  }

  @override
  int get hashCode => _text.hashCode;

  @override
  String toString() => _text;
}

/// Codec for PostgreSQL `numeric` / `decimal` type.
class const NumericCodec() implements PgCodec<PgNumeric> {
  @override
  Uint8List encodeBinary(PgNumeric value) {
    var str = value.toString().trim();
    var signByte = 0x0000;
    if (str.toLowerCase() == 'nan') {
      signByte = 0xc000;
      str = '';
    } else if (str.startsWith('-')) {
      str = str.substring(1);
      signByte = 0x4000;
    } else if (str.startsWith('+')) {
      str = str.substring(1);
    }

    if (signByte != 0xc000 && !_numericRegExp.hasMatch(str)) {
      throw FormatException('Invalid format for numeric value: $str');
    }

    if (signByte == 0xc000) {
      final bytes = Uint8List(8);
      final bd = ByteData.sublistView(bytes);
      bd.setInt16(0, 0); // nDigits = 0
      bd.setInt16(2, 0); // weight = 0
      bd.setUint16(4, 0xc000); // sign = NaN
      bd.setInt16(6, 0); // dScale = 0
      return bytes;
    }

    final parts = str.split('.');
    var intPart = parts[0].replaceAll(_leadingZerosRegExp, '');
    var intWeight = intPart.isEmpty ? -1 : (intPart.length - 1) ~/ 4;
    intPart = intPart.padLeft((intWeight + 1) * 4, '0');

    var fractPart = parts.length > 1 ? parts[1] : '';
    final dScale = fractPart.length;
    fractPart = fractPart.replaceAll(_trailingZerosRegExp, '');
    var fractWeight = fractPart.isEmpty ? -1 : (fractPart.length - 1) ~/ 4;
    fractPart = fractPart.padRight((fractWeight + 1) * 4, '0');

    var weight = intWeight;
    if (intWeight < 0) {
      if (fractPart.isEmpty) {
        weight = 0;
      } else {
        final leadingZeros = _leadingZerosRegExp
            .firstMatch(fractPart)
            ?.group(0);
        if (leadingZeros != null) {
          final leadingZerosWeight = leadingZeros.length ~/ 4;
          fractPart = fractPart.substring(leadingZerosWeight * 4);
          fractWeight -= leadingZerosWeight;
          weight = -(leadingZerosWeight + 1);
        }
      }
    } else if (fractWeight < 0) {
      final trailingZeros = _trailingZerosRegExp.firstMatch(intPart)?.group(0);
      if (trailingZeros != null) {
        final trailingZerosWeight = trailingZeros.length ~/ 4;
        intPart = intPart.substring(
          0,
          intPart.length - trailingZerosWeight * 4,
        );
        intWeight -= trailingZerosWeight;
      }
    }

    final nDigits = intWeight + fractWeight + 2;
    final totalBytes = 8 + (nDigits * 2);
    final bytes = Uint8List(totalBytes);
    final bd = ByteData.sublistView(bytes);

    bd.setInt16(0, nDigits);
    bd.setInt16(2, weight);
    bd.setUint16(4, signByte);
    bd.setInt16(6, dScale);

    var offset = 8;
    for (var i = 0; i <= intWeight; i++) {
      final digitStr = intPart.substring(i * 4, (i + 1) * 4);
      bd.setInt16(offset, int.parse(digitStr));
      offset += 2;
    }
    for (var i = 0; i <= fractWeight; i++) {
      final digitStr = fractPart.substring(i * 4, (i + 1) * 4);
      bd.setInt16(offset, int.parse(digitStr));
      offset += 2;
    }

    return bytes;
  }

  @override
  Uint8List encodeText(PgNumeric value) {
    return Uint8List.fromList(utf8.encode(value.toString()));
  }

  @override
  PgNumeric decodeBinary(Uint8List bytes) {
    if (bytes.length < 8) {
      return PgNumeric(utf8.decode(bytes));
    }

    final bd = ByteData.sublistView(bytes);
    final nDigits = bd.getInt16(0);
    final signByte = bd.getUint16(4);

    if (bytes.length != 8 + (nDigits * 2) ||
        (signByte != 0x0000 && signByte != 0x4000 && signByte != 0xc000)) {
      return PgNumeric(utf8.decode(bytes));
    }

    var weight = bd.getInt16(2);
    final dScale = bd.getInt16(6);

    if (signByte == 0xc000) return const PgNumeric('NaN');
    final sign = signByte == 0x4000 ? '-' : '';
    var intPart = '';
    var fractPart = '';

    final fractOmitted = -(weight + 1);
    if (fractOmitted > 0) {
      fractPart += '0000' * fractOmitted;
    }

    var offset = 8;
    for (var i = 0; i < nDigits; i++) {
      if (offset + 2 > bytes.length) break;
      final digitVal = bd.getInt16(offset);
      offset += 2;

      if (weight >= 0) {
        intPart += digitVal.toString().padLeft(4, '0');
      } else {
        fractPart += digitVal.toString().padLeft(4, '0');
      }
      weight--;
    }

    if (weight >= 0) {
      intPart += '0000' * (weight + 1);
    }

    var result = '$sign${intPart.replaceAll(_leadingZerosRegExp, '')}';
    if (result.isEmpty || result == '-') {
      result = '${sign}0';
    }
    if (dScale > 0) {
      result += '.${fractPart.padRight(dScale, '0').substring(0, dScale)}';
    }
    return PgNumeric(result);
  }

  @override
  PgNumeric decodeText(Uint8List bytes) => PgNumeric(utf8.decode(bytes));
}

const _numericCodec = NumericCodec();

/// Numeric getters for [PgRow].
extension PgRowNumericGetters on PgRow {
  /// Decodes column as [PgNumeric], or `null` if SQL NULL.
  @pragma('vm:prefer-inline')
  PgNumeric? numericOrNull(Object column) =>
      decodeOrNull(column, _numericCodec);

  /// Decodes column as [PgNumeric]. Throws [StateError] if null.
  @pragma('vm:prefer-inline')
  PgNumeric numeric(Object column) => decode(column, _numericCodec);
}
