import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:pg/src/client/rows.dart';
import 'package:pg/src/types/codec.dart';

/// Microsecond offset between Unix epoch (1970-01-01) and Postgres epoch
/// (2000-01-01).
const int pgEpochMicroseconds = 946684800000000;

/// Days offset between Unix epoch (1970-01-01) and Postgres epoch (2000-01-01).
const int pgEpochDays = 10957; // 2000-01-01 - 1970-01-01

/// Represents a PostgreSQL `date` (calendar date without time or timezone).
@immutable
class const PgDate(
  final int year,
  final int month,
  final int day,
) implements Comparable<PgDate> {
  /// Creates a [PgDate] from PostgreSQL binary representation (days since
  /// 2000-01-01).
  factory fromDaysSinceEpoch(int daysSincePgEpoch) {
    final dt = DateTime.fromMicrosecondsSinceEpoch(
      (daysSincePgEpoch + pgEpochDays) * 86400000000,
      isUtc: true,
    );
    return PgDate(dt.year, dt.month, dt.day);
  }

  /// Creates a [PgDate] from a [DateTime].
  factory fromDateTime(DateTime dt) => PgDate(dt.year, dt.month, dt.day);

  /// Parses an ISO 8601 date string (e.g. `2026-08-14`).
  factory parse(String formattedString) {
    final parts = formattedString.trim().split('-');
    if (parts.length == 3) {
      return PgDate(
        int.parse(parts[0]),
        int.parse(parts[1]),
        int.parse(parts[2]),
      );
    }
    final dt = DateTime.parse(formattedString);
    return PgDate(dt.year, dt.month, dt.day);
  }

  /// Number of days since Postgres epoch (2000-01-01).
  int get daysSinceEpoch {
    final dt = DateTime.utc(year, month, day);
    final unixDays = dt.microsecondsSinceEpoch ~/ 86400000000;
    return unixDays - pgEpochDays;
  }

  /// Converts this date to a UTC [DateTime] at 00:00:00.
  DateTime toDateTime() => DateTime.utc(year, month, day);

  @override
  int compareTo(PgDate other) {
    if (year != other.year) return year.compareTo(other.year);
    if (month != other.month) return month.compareTo(other.month);
    return day.compareTo(other.day);
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is PgDate &&
            year == other.year &&
            month == other.month &&
            day == other.day;
  }

  @override
  int get hashCode => Object.hash(year, month, day);

  @override
  String toString() {
    final y = year.toString().padLeft(4, '0');
    final m = month.toString().padLeft(2, '0');
    final d = day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }
}

/// Represents a PostgreSQL `time` (time of day without timezone).
@immutable
class const PgTime(
  final int hour,
  final int minute, [
  final int second = 0,
  final int microsecond = 0,
]) implements Comparable<PgTime> {
  /// Creates a [PgTime] from microseconds since midnight.
  factory fromMicroseconds(int microseconds) {
    var rem = microseconds;
    final h = rem ~/ 3600000000;
    rem %= 3600000000;
    final m = rem ~/ 60000000;
    rem %= 60000000;
    final s = rem ~/ 1000000;
    final us = rem % 1000000;
    return PgTime(h, m, s, us);
  }

  /// Parses a time string (e.g. `14:30:15.123456`).
  factory parse(String text) {
    final parts = text.trim().split(':');
    final h = int.parse(parts[0]);
    final m = int.parse(parts[1]);
    var s = 0;
    var us = 0;
    if (parts.length > 2) {
      final secParts = parts[2].split('.');
      s = int.parse(secParts[0]);
      if (secParts.length > 1) {
        us = int.parse(secParts[1].padRight(6, '0').substring(0, 6));
      }
    }
    return PgTime(h, m, s, us);
  }

  /// Total microseconds since midnight (00:00:00).
  int get inMicroseconds =>
      hour * 3600000000 + minute * 60000000 + second * 1000000 + microsecond;

  @override
  int compareTo(PgTime other) => inMicroseconds.compareTo(other.inMicroseconds);

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is PgTime &&
            hour == other.hour &&
            minute == other.minute &&
            second == other.second &&
            microsecond == other.microsecond;
  }

  @override
  int get hashCode => Object.hash(hour, minute, second, microsecond);

  @override
  String toString() {
    final h = hour.toString().padLeft(2, '0');
    final m = minute.toString().padLeft(2, '0');
    final s = second.toString().padLeft(2, '0');
    if (microsecond > 0) {
      final us = microsecond.toString().padLeft(6, '0');
      return '$h:$m:$s.$us';
    }
    return '$h:$m:$s';
  }
}

/// Represents a PostgreSQL `timetz` (time of day with UTC offset).
@immutable
class const PgTimeTz(
  final PgTime time,
  final int offsetSeconds,
) {
  /// Parses a `timetz` string (e.g. `14:30:00+03` or `14:30:00-05:00`).
  factory parse(String text) {
    final t = text.trim();
    final plusIdx = t.indexOf('+');
    final minusIdx = t.lastIndexOf('-');
    final signIdx = plusIdx != -1 ? plusIdx : (minusIdx > 2 ? minusIdx : -1);

    if (signIdx == -1) {
      return PgTimeTz(PgTime.parse(t), 0);
    }

    final timePart = t.substring(0, signIdx);
    final offsetPart = t.substring(signIdx);
    final sign = offsetPart.startsWith('+') ? 1 : -1;
    final rawOffset = offsetPart.substring(1);
    final offsetParts = rawOffset.split(':');
    final offsetHours = int.parse(offsetParts[0]);
    final offsetMins = offsetParts.length > 1 ? int.parse(offsetParts[1]) : 0;
    final totalOffset = sign * (offsetHours * 3600 + offsetMins * 60);

    return PgTimeTz(PgTime.parse(timePart), totalOffset);
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is PgTimeTz &&
            time == other.time &&
            offsetSeconds == other.offsetSeconds;
  }

  @override
  int get hashCode => Object.hash(time, offsetSeconds);

  @override
  String toString() {
    final sign = offsetSeconds >= 0 ? '+' : '-';
    final absOffset = offsetSeconds.abs();
    final h = (absOffset ~/ 3600).toString().padLeft(2, '0');
    final m = ((absOffset % 3600) ~/ 60).toString().padLeft(2, '0');
    return '$time$sign$h:$m';
  }
}

/// Represents a PostgreSQL `interval` (duration spanning months, days,
/// microseconds).
@immutable
class const PgInterval({
  final int months = 0,
  final int days = 0,
  final int microseconds = 0,
}) {
  /// Creates a [PgInterval] from a Dart [Duration].
  factory fromDuration(Duration d) {
    return PgInterval(microseconds: d.inMicroseconds);
  }

  /// Converts this interval into a Dart [Duration] assuming 30 days/month.
  Duration toDuration() {
    final totalMicros =
        microseconds + (days * 86400000000) + (months * 30 * 86400000000);
    return Duration(microseconds: totalMicros);
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is PgInterval &&
            months == other.months &&
            days == other.days &&
            microseconds == other.microseconds;
  }

  @override
  int get hashCode => Object.hash(months, days, microseconds);

  @override
  String toString() {
    final parts = <String>[];
    if (months != 0) {
      final years = months ~/ 12;
      final m = months % 12;
      if (years != 0) parts.add('$years year${years.abs() == 1 ? '' : 's'}');
      if (m != 0) parts.add('$m mon${m.abs() == 1 ? '' : 's'}');
    }
    if (days != 0) {
      parts.add('$days day${days.abs() == 1 ? '' : 's'}');
    }
    if (microseconds != 0 || parts.isEmpty) {
      final time = PgTime.fromMicroseconds(microseconds.abs());
      final sign = microseconds < 0 ? '-' : '';
      parts.add('$sign$time');
    }
    return parts.join(' ');
  }
}

/// Codec for PostgreSQL `date` type.
class const DateCodec() implements PgCodec<PgDate> {
  @override
  Uint8List encodeBinary(PgDate value) {
    final bytes = Uint8List(4);
    ByteData.sublistView(bytes).setInt32(0, value.daysSinceEpoch);
    return bytes;
  }

  @override
  Uint8List encodeText(PgDate value) {
    return Uint8List.fromList(utf8.encode(value.toString()));
  }

  @override
  PgDate decodeBinary(Uint8List bytes) {
    if (bytes.length == 4) {
      final days = ByteData.sublistView(bytes).getInt32(0);
      return PgDate.fromDaysSinceEpoch(days);
    }
    return PgDate.parse(utf8.decode(bytes));
  }

  @override
  PgDate decodeText(Uint8List bytes) => PgDate.parse(utf8.decode(bytes));
}

/// Codec for PostgreSQL `time` type.
class const TimeCodec() implements PgCodec<PgTime> {
  @override
  Uint8List encodeBinary(PgTime value) {
    final bytes = Uint8List(8);
    ByteData.sublistView(bytes).setInt64(0, value.inMicroseconds);
    return bytes;
  }

  @override
  Uint8List encodeText(PgTime value) {
    return Uint8List.fromList(utf8.encode(value.toString()));
  }

  @override
  PgTime decodeBinary(Uint8List bytes) {
    if (bytes.length == 8) {
      final micros = ByteData.sublistView(bytes).getInt64(0);
      if (micros >= 0 && micros <= 86400000000) {
        return PgTime.fromMicroseconds(micros);
      }
    }
    return PgTime.parse(utf8.decode(bytes));
  }

  @override
  PgTime decodeText(Uint8List bytes) => PgTime.parse(utf8.decode(bytes));
}

/// Codec for PostgreSQL `timetz` type.
class const TimeTzCodec() implements PgCodec<PgTimeTz> {
  @override
  Uint8List encodeBinary(PgTimeTz value) {
    final bytes = Uint8List(12);
    final bd = ByteData.sublistView(bytes);
    bd.setInt64(0, value.time.inMicroseconds);
    bd.setInt32(8, -value.offsetSeconds);
    return bytes;
  }

  @override
  Uint8List encodeText(PgTimeTz value) {
    return Uint8List.fromList(utf8.encode(value.toString()));
  }

  @override
  PgTimeTz decodeBinary(Uint8List bytes) {
    if (bytes.length == 12) {
      final bd = ByteData.sublistView(bytes);
      final micros = bd.getInt64(0);
      final negOffset = bd.getInt32(8);
      return PgTimeTz(PgTime.fromMicroseconds(micros), -negOffset);
    }
    return PgTimeTz.parse(utf8.decode(bytes));
  }

  @override
  PgTimeTz decodeText(Uint8List bytes) => PgTimeTz.parse(utf8.decode(bytes));
}

/// Codec for PostgreSQL `interval` type.
class const IntervalCodec() implements PgCodec<PgInterval> {
  @override
  Uint8List encodeBinary(PgInterval value) {
    final bytes = Uint8List(16);
    final bd = ByteData.sublistView(bytes);
    bd.setInt64(0, value.microseconds);
    bd.setInt32(8, value.days);
    bd.setInt32(12, value.months);
    return bytes;
  }

  @override
  Uint8List encodeText(PgInterval value) {
    return Uint8List.fromList(utf8.encode(value.toString()));
  }

  @override
  PgInterval decodeBinary(Uint8List bytes) {
    if (bytes.length == 16) {
      final bd = ByteData.sublistView(bytes);
      final micros = bd.getInt64(0);
      final days = bd.getInt32(8);
      final months = bd.getInt32(12);
      return PgInterval(months: months, days: days, microseconds: micros);
    }
    return _parseTextInterval(utf8.decode(bytes));
  }

  @override
  PgInterval decodeText(Uint8List bytes) {
    return _parseTextInterval(utf8.decode(bytes));
  }
}

PgInterval _parseTextInterval(String text) {
  final parts = text.trim().split(' ');
  var months = 0;
  var days = 0;
  var micros = 0;

  for (var i = 0; i < parts.length; i++) {
    final part = parts[i];
    if (part.contains(':')) {
      final timeParts = part.split(':');
      final h = int.tryParse(timeParts[0]) ?? 0;
      final m = int.tryParse(timeParts[1]) ?? 0;
      var s = 0;
      var us = 0;
      if (timeParts.length > 2) {
        final secParts = timeParts[2].split('.');
        s = int.tryParse(secParts[0]) ?? 0;
        if (secParts.length > 1) {
          us = int.tryParse(secParts[1].padRight(6, '0').substring(0, 6)) ?? 0;
        }
      }
      micros += h * 3600000000 + m * 60000000 + s * 1000000 + us;
    } else if (i + 1 < parts.length) {
      final count = int.tryParse(part);
      if (count != null) {
        final unit = parts[i + 1].toLowerCase();
        if (unit.startsWith('year')) {
          months += count * 12;
          i++;
        } else if (unit.startsWith('mon')) {
          months += count;
          i++;
        } else if (unit.startsWith('day')) {
          days += count;
          i++;
        }
      }
    }
  }

  return PgInterval(months: months, days: days, microseconds: micros);
}

/// Codec for PostgreSQL `timestamp` and `timestamptz` types mapped to
/// [DateTime].
class const TimestampCodec({
  /// If `true`, handles `timestamptz` (absolute point in time in UTC).
  /// If `false`, handles `timestamp` (wall-clock time without timezone).
  final bool isUtc = true,
}) implements PgCodec<DateTime> {
  @override
  Uint8List encodeBinary(DateTime value) {
    final int micros;
    if (isUtc) {
      micros = value.microsecondsSinceEpoch;
    } else {
      final offsetMicros = value.isUtc
          ? 0
          : value.timeZoneOffset.inMicroseconds;
      micros = value.microsecondsSinceEpoch + offsetMicros;
    }
    final pgMicros = micros - pgEpochMicroseconds;
    final bytes = Uint8List(8);
    ByteData.sublistView(bytes).setInt64(0, pgMicros);
    return bytes;
  }

  @override
  Uint8List encodeText(DateTime value) {
    if (isUtc) {
      return Uint8List.fromList(utf8.encode(value.toUtc().toIso8601String()));
    }
    final s = value.toIso8601String().replaceAll('Z', '');
    return Uint8List.fromList(utf8.encode(s));
  }

  @override
  DateTime decodeBinary(Uint8List bytes) {
    if (bytes.length == 8) {
      final pgMicros = ByteData.sublistView(bytes).getInt64(0);
      return DateTime.fromMicrosecondsSinceEpoch(
        pgEpochMicroseconds + pgMicros,
        isUtc: true,
      );
    }
    return _parseTextDateTime(utf8.decode(bytes), isUtc: isUtc);
  }

  @override
  DateTime decodeText(Uint8List bytes) {
    return _parseTextDateTime(utf8.decode(bytes), isUtc: isUtc);
  }
}

DateTime _parseTextDateTime(String str, {required bool isUtc}) {
  var s = str.trim();
  if (s.contains(' ') && !s.contains('T')) {
    s = s.replaceFirst(' ', 'T');
  }
  if (!s.endsWith('Z') && !RegExp(r'[+-]\d{2}(:\d{2})?$').hasMatch(s)) {
    s = '${s}Z';
  }
  final dt = DateTime.parse(s);
  return dt.toUtc();
}

const _dateCodec = DateCodec();
const _timeCodec = TimeCodec();
const _timeTzCodec = TimeTzCodec();
const _intervalCodec = IntervalCodec();
const _timestampCodec = TimestampCodec();

/// Temporal getters for [PgRow].
extension PgRowTemporalGetters on PgRow {
  /// Decodes column as [PgDate], or `null` if SQL NULL.
  @pragma('vm:prefer-inline')
  PgDate? dateOrNull(Object column) => decodeOrNull(column, _dateCodec);

  /// Decodes column as [PgDate]. Throws [StateError] if null.
  @pragma('vm:prefer-inline')
  PgDate date(Object column) => decode(column, _dateCodec);

  /// Decodes column as [PgTime], or `null` if SQL NULL.
  @pragma('vm:prefer-inline')
  PgTime? timeOrNull(Object column) => decodeOrNull(column, _timeCodec);

  /// Decodes column as [PgTime]. Throws [StateError] if null.
  @pragma('vm:prefer-inline')
  PgTime time(Object column) => decode(column, _timeCodec);

  /// Decodes column as [PgTimeTz], or `null` if SQL NULL.
  @pragma('vm:prefer-inline')
  PgTimeTz? timeTzOrNull(Object column) => decodeOrNull(column, _timeTzCodec);

  /// Decodes column as [PgTimeTz]. Throws [StateError] if null.
  @pragma('vm:prefer-inline')
  PgTimeTz timeTz(Object column) => decode(column, _timeTzCodec);

  /// Decodes column as [PgInterval], or `null` if SQL NULL.
  @pragma('vm:prefer-inline')
  PgInterval? intervalOrNull(Object column) =>
      decodeOrNull(column, _intervalCodec);

  /// Decodes column as [PgInterval]. Throws [StateError] if null.
  @pragma('vm:prefer-inline')
  PgInterval interval(Object column) => decode(column, _intervalCodec);

  /// Decodes column as [Duration], or `null` if SQL NULL.
  @pragma('vm:prefer-inline')
  Duration? durationOrNull(Object column) =>
      intervalOrNull(column)?.toDuration();

  /// Decodes column as [Duration]. Throws [StateError] if null.
  @pragma('vm:prefer-inline')
  Duration duration(Object column) =>
      durationOrNull(column) ?? (throw StateError('Column "$column" is null'));

  /// Decodes column as UTC [DateTime], or `null` if SQL NULL.
  @pragma('vm:prefer-inline')
  DateTime? dateTimeOrNull(Object column) =>
      decodeOrNull(column, _timestampCodec);

  /// Decodes column as UTC [DateTime]. Throws [StateError] if null.
  @pragma('vm:prefer-inline')
  DateTime dateTime(Object column) => decode(column, _timestampCodec);
}
