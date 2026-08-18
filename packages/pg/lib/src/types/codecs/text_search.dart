import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:pg/src/client/rows.dart';
import 'package:pg/src/types/codec.dart';

/// Weight assigned to a word position in [PgTsVector].
enum PgTsWeight { d, c, b, a }

/// Position and weight descriptor for a word in [PgTsVector].
@immutable
class const PgTsWordPos(
  final int position, {
  final PgTsWeight weight = .d,
}) {
  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is PgTsWordPos &&
            position == other.position &&
            weight == other.weight;
  }

  @override
  int get hashCode => Object.hash(position, weight);

  @override
  String toString() => '$position${weight.name.toUpperCase()}';
}

/// A lexeme / word entry within a [PgTsVector].
@immutable
class const PgTsWord(
  final String word, {
  final List<PgTsWordPos> positions = const [],
}) {
  /// Alias for [word] for compatibility.
  String get text => word;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is PgTsWord &&
            word == other.word &&
            positions.length == other.positions.length &&
            List.generate(
              positions.length,
              (i) => positions[i] == other.positions[i],
            ).every((eq) => eq);
  }

  @override
  int get hashCode => Object.hash(word, Object.hashAll(positions));

  @override
  String toString() {
    if (positions.isEmpty) return "'$word'";
    return "'$word':${positions.map((p) => p.toString()).join(',')}";
  }
}

/// Represents a PostgreSQL `tsvector` (searchable vector of lexemes).
@immutable
class const PgTsVector(final List<PgTsWord> words) {
  factory parse(String text) {
    final t = text.trim();
    if (t.isEmpty) return const PgTsVector([]);

    final wordsList = <PgTsWord>[];
    final tokens = t.split(RegExp(r'\s+'));

    for (final tok in tokens) {
      if (tok.isEmpty) continue;
      final colonIdx = tok.lastIndexOf(':');
      if (colonIdx == -1) {
        final word = tok.replaceAll("'", '');
        wordsList.add(PgTsWord(word));
      } else {
        final word = tok.substring(0, colonIdx).replaceAll("'", '');
        final posListStr = tok.substring(colonIdx + 1).split(',');
        final posList = <PgTsWordPos>[];
        for (final p in posListStr) {
          if (p.isEmpty) continue;
          final lastChar = p[p.length - 1].toUpperCase();
          if (lastChar == 'A' ||
              lastChar == 'B' ||
              lastChar == 'C' ||
              lastChar == 'D') {
            final posNum = int.parse(p.substring(0, p.length - 1));
            final weight = PgTsWeight.values.byName(lastChar.toLowerCase());
            posList.add(PgTsWordPos(posNum, weight: weight));
          } else {
            posList.add(PgTsWordPos(int.parse(p)));
          }
        }
        wordsList.add(PgTsWord(word, positions: posList));
      }
    }
    return PgTsVector(wordsList);
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is PgTsVector &&
            words.length == other.words.length &&
            List.generate(
              words.length,
              (i) => words[i] == other.words[i],
            ).every((eq) => eq);
  }

  @override
  int get hashCode => Object.hashAll(words);

  @override
  String toString() => words.map((w) => w.toString()).join(' ');
}

/// Represents a PostgreSQL `tsquery` AST node.
@immutable
sealed class const PgTsQuery() {
  const factory word(
    String word, {
    PgTsWeight? weight,
    bool prefix,
  }) = PgTsQueryWord;
  const factory and(PgTsQuery left, PgTsQuery right) = PgTsQueryAnd;
  const factory or(PgTsQuery left, PgTsQuery right) = PgTsQueryOr;
  const factory not(PgTsQuery child) = PgTsQueryNot;

  factory parse(String text) {
    final tokens = _tokenizeTsQuery(text);
    if (tokens.isEmpty) return const PgTsQueryWord('');
    final parser = _TsQueryParser(tokens);
    return parser.parseQuery();
  }

  /// Combines two queries with logical AND.
  PgTsQuery operator &(PgTsQuery other) => PgTsQuery.and(this, other);

  /// Combines two queries with logical OR.
  PgTsQuery operator |(PgTsQuery other) => PgTsQuery.or(this, other);
}

/// A word node in a [PgTsQuery].
@immutable
class const PgTsQueryWord(
  final String word, {
  final PgTsWeight? weight,
  final bool prefix = false,
}) extends PgTsQuery {
  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is PgTsQueryWord &&
            word == other.word &&
            weight == other.weight &&
            prefix == other.prefix;
  }

  @override
  int get hashCode => Object.hash(word, weight, prefix);

  @override
  String toString() {
    final w = weight != null ? ':${weight!.name.toUpperCase()}' : '';
    final p = prefix ? ':*' : '';
    return '$word$w$p';
  }
}

/// Logical AND operator node in a [PgTsQuery].
@immutable
class const PgTsQueryAnd(
  final PgTsQuery left,
  final PgTsQuery right,
) extends PgTsQuery {
  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is PgTsQueryAnd && left == other.left && right == other.right;
  }

  @override
  int get hashCode => Object.hash(left, right);

  @override
  String toString() => '($left & $right)';
}

/// Logical OR operator node in a [PgTsQuery].
@immutable
class const PgTsQueryOr(
  final PgTsQuery left,
  final PgTsQuery right,
) extends PgTsQuery {
  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is PgTsQueryOr && left == other.left && right == other.right;
  }

  @override
  int get hashCode => Object.hash(left, right);

  @override
  String toString() => '($left | $right)';
}

/// Logical NOT operator node in a [PgTsQuery].
@immutable
class const PgTsQueryNot(
  final PgTsQuery child,
) extends PgTsQuery {
  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is PgTsQueryNot && child == other.child;
  }

  @override
  int get hashCode => child.hashCode;

  @override
  String toString() => '!($child)';
}

int _countTsQueryNodes(PgTsQuery node) {
  return switch (node) {
    PgTsQueryWord() => 1,
    PgTsQueryNot(:final child) => 1 + _countTsQueryNodes(child),
    PgTsQueryAnd(:final left, :final right) =>
      1 + _countTsQueryNodes(left) + _countTsQueryNodes(right),
    PgTsQueryOr(:final left, :final right) =>
      1 + _countTsQueryNodes(left) + _countTsQueryNodes(right),
  };
}

void _encodeTsQueryNode(PgTsQuery node, BytesBuilder builder) {
  switch (node) {
    case final PgTsQueryWord w:
      builder.addByte(1); // QI_VAL
      var weightMask = 0;
      if (w.weight case final wt?) {
        switch (wt) {
          case PgTsWeight.d:
            weightMask = 1;
          case PgTsWeight.c:
            weightMask = 2;
          case PgTsWeight.b:
            weightMask = 4;
          case PgTsWeight.a:
            weightMask = 8;
        }
      }
      builder.addByte(weightMask);
      builder.addByte(w.prefix ? 1 : 0);
      builder.add(utf8.encode(w.word));
      builder.addByte(0);

    case final PgTsQueryNot n:
      builder.addByte(2); // QI_OPR
      builder.addByte(1); // OP_NOT
      _encodeTsQueryNode(n.child, builder);

    case final PgTsQueryAnd a:
      builder.addByte(2); // QI_OPR
      builder.addByte(2); // OP_AND
      _encodeTsQueryNode(a.left, builder);
      _encodeTsQueryNode(a.right, builder);

    case final PgTsQueryOr o:
      builder.addByte(2); // QI_OPR
      builder.addByte(3); // OP_OR
      _encodeTsQueryNode(o.left, builder);
      _encodeTsQueryNode(o.right, builder);
  }
}

class _TsOffsetRef {
  _TsOffsetRef(this.offset);
  int offset;
}

PgTsQuery _decodeTsQueryNode(Uint8List bytes, _TsOffsetRef ref) {
  if (ref.offset >= bytes.length) return const PgTsQueryWord('');
  final type = bytes[ref.offset++];
  if (type == 1) {
    // QI_VAL
    if (ref.offset + 2 > bytes.length) return const PgTsQueryWord('');
    final weightMask = bytes[ref.offset++];
    final prefix = bytes[ref.offset++] == 1;
    final start = ref.offset;
    while (ref.offset < bytes.length && bytes[ref.offset] != 0) {
      ref.offset++;
    }
    final word = utf8.decode(bytes.sublist(start, ref.offset));
    if (ref.offset < bytes.length && bytes[ref.offset] == 0) {
      ref.offset++; // skip null byte
    }
    PgTsWeight? weight;
    if (weightMask & 8 != 0) {
      weight = PgTsWeight.a;
    } else if (weightMask & 4 != 0) {
      weight = PgTsWeight.b;
    } else if (weightMask & 2 != 0) {
      weight = PgTsWeight.c;
    } else if (weightMask & 1 != 0) {
      weight = PgTsWeight.d;
    }
    return PgTsQueryWord(word, weight: weight, prefix: prefix);
  } else if (type == 2) {
    // QI_OPR
    if (ref.offset >= bytes.length) return const PgTsQueryWord('');
    final oper = bytes[ref.offset++];
    if (oper == 1) {
      final child = _decodeTsQueryNode(bytes, ref);
      return PgTsQueryNot(child);
    } else if (oper == 2) {
      final left = _decodeTsQueryNode(bytes, ref);
      final right = _decodeTsQueryNode(bytes, ref);
      return PgTsQueryAnd(left, right);
    } else if (oper == 3) {
      final left = _decodeTsQueryNode(bytes, ref);
      final right = _decodeTsQueryNode(bytes, ref);
      return PgTsQueryOr(left, right);
    }
  }
  return const PgTsQueryWord('');
}

List<String> _tokenizeTsQuery(String text) {
  final tokens = <String>[];
  final buffer = StringBuffer();

  void flush() {
    if (buffer.isNotEmpty) {
      tokens.add(buffer.toString());
      buffer.clear();
    }
  }

  for (var i = 0; i < text.length; i++) {
    final char = text[i];
    if (char == ' ' || char == '\t' || char == '\n') {
      flush();
    } else if (char == '(' ||
        char == ')' ||
        char == '&' ||
        char == '|' ||
        char == '!') {
      flush();
      tokens.add(char);
    } else {
      buffer.write(char);
    }
  }
  flush();
  return tokens;
}

class _TsQueryParser {
  _TsQueryParser(this._tokens);
  final List<String> _tokens;
  var _pos = 0;

  PgTsQuery parseQuery() => _parseOr();

  PgTsQuery _parseOr() {
    var node = _parseAnd();
    while (_pos < _tokens.length && _tokens[_pos] == '|') {
      _pos++;
      final right = _parseAnd();
      node = PgTsQueryOr(node, right);
    }
    return node;
  }

  PgTsQuery _parseAnd() {
    var node = _parseUnary();
    while (_pos < _tokens.length &&
        (_tokens[_pos] == '&' ||
            (_tokens[_pos] != '|' && _tokens[_pos] != ')'))) {
      if (_tokens[_pos] == '&') _pos++;
      final right = _parseUnary();
      node = PgTsQueryAnd(node, right);
    }
    return node;
  }

  PgTsQuery _parseUnary() {
    if (_pos < _tokens.length && _tokens[_pos] == '!') {
      _pos++;
      return PgTsQueryNot(_parseUnary());
    }
    return _parsePrimary();
  }

  PgTsQuery _parsePrimary() {
    if (_pos >= _tokens.length) return const PgTsQueryWord('');
    final tok = _tokens[_pos++];
    if (tok == '(') {
      final node = _parseOr();
      if (_pos < _tokens.length && _tokens[_pos] == ')') {
        _pos++;
      }
      return node;
    }

    var word = tok;
    var prefix = false;
    PgTsWeight? weight;

    if (word.endsWith(':*')) {
      prefix = true;
      word = word.substring(0, word.length - 2);
    }
    final colonIdx = word.lastIndexOf(':');
    if (colonIdx != -1) {
      final wPart = word.substring(colonIdx + 1).toLowerCase();
      if (wPart == 'a' || wPart == 'b' || wPart == 'c' || wPart == 'd') {
        weight = PgTsWeight.values.byName(wPart);
        word = word.substring(0, colonIdx);
      }
    }

    if (word.startsWith("'") && word.endsWith("'") && word.length >= 2) {
      word = word.substring(1, word.length - 1);
    }

    return PgTsQueryWord(word, weight: weight, prefix: prefix);
  }
}

/// Codec for PostgreSQL `tsvector` type.
class const TsVectorCodec() implements PgCodec<PgTsVector> {
  @override
  Uint8List encodeBinary(PgTsVector value) {
    final builder = BytesBuilder();
    final countBytes = Uint8List(4);
    ByteData.sublistView(countBytes).setInt32(0, value.words.length);
    builder.add(countBytes);

    for (final w in value.words) {
      final utfBytes = utf8.encode(w.word);
      builder.add(utfBytes);
      builder.addByte(0); // null terminator

      final posCountBytes = Uint8List(2);
      ByteData.sublistView(posCountBytes).setInt16(0, w.positions.length);
      builder.add(posCountBytes);

      for (final p in w.positions) {
        final posInt = (p.weight.index << 14) | (p.position & 0x3FFF);
        final pBytes = Uint8List(2);
        ByteData.sublistView(pBytes).setUint16(0, posInt);
        builder.add(pBytes);
      }
    }

    return builder.takeBytes();
  }

  @override
  Uint8List encodeText(PgTsVector value) {
    return Uint8List.fromList(utf8.encode(value.toString()));
  }

  @override
  PgTsVector decodeBinary(Uint8List bytes) {
    if (bytes.length < 4 || bytes.contains(0x27) || bytes.contains(0x20)) {
      return decodeText(bytes);
    }

    final bd = ByteData.sublistView(bytes);
    final wordCount = bd.getInt32(0);
    var offset = 4;
    final words = <PgTsWord>[];

    for (var i = 0; i < wordCount; i++) {
      if (offset >= bytes.length) break;
      final start = offset;
      while (offset < bytes.length && bytes[offset] != 0) {
        offset++;
      }
      final word = utf8.decode(bytes.sublist(start, offset));
      offset++; // skip null byte

      if (offset + 2 > bytes.length) break;
      final posCount = bd.getInt16(offset);
      offset += 2;

      final positions = <PgTsWordPos>[];
      for (var j = 0; j < posCount; j++) {
        if (offset + 2 > bytes.length) break;
        final rawPos = bd.getUint16(offset);
        offset += 2;
        final weightIndex = (rawPos >> 14) & 0x03;
        final posNum = rawPos & 0x3FFF;
        positions.add(
          PgTsWordPos(posNum, weight: PgTsWeight.values[weightIndex]),
        );
      }
      words.add(PgTsWord(word, positions: positions));
    }

    return PgTsVector(words);
  }

  @override
  PgTsVector decodeText(Uint8List bytes) {
    return PgTsVector.parse(utf8.decode(bytes));
  }
}

/// Codec for PostgreSQL `tsquery` type.
class const TsQueryCodec() implements PgCodec<PgTsQuery> {
  @override
  Uint8List encodeBinary(PgTsQuery value) {
    final builder = BytesBuilder();
    final count = _countTsQueryNodes(value);
    final countBytes = Uint8List(4);
    ByteData.sublistView(countBytes).setInt32(0, count);
    builder.add(countBytes);
    _encodeTsQueryNode(value, builder);
    return builder.takeBytes();
  }

  @override
  Uint8List encodeText(PgTsQuery value) {
    return Uint8List.fromList(utf8.encode(value.toString()));
  }

  @override
  PgTsQuery decodeBinary(Uint8List bytes) {
    if (bytes.length < 4) return const PgTsQueryWord('');
    final bd = ByteData.sublistView(bytes);
    final count = bd.getInt32(0);
    if (count == 0) return const PgTsQueryWord('');
    final ref = _TsOffsetRef(4);
    return _decodeTsQueryNode(bytes, ref);
  }

  @override
  PgTsQuery decodeText(Uint8List bytes) => PgTsQuery.parse(utf8.decode(bytes));
}

const _tsVectorCodec = TsVectorCodec();
const _tsQueryCodec = TsQueryCodec();

/// Full-text search getters for [PgRow].
extension PgRowTextSearchGetters on PgRow {
  /// Decodes column as [PgTsVector], or `null` if SQL NULL.
  @pragma('vm:prefer-inline')
  PgTsVector? tsVectorOrNull(Object column) =>
      decodeOrNull(column, _tsVectorCodec);

  /// Decodes column as [PgTsVector]. Throws [StateError] if null.
  @pragma('vm:prefer-inline')
  PgTsVector tsVector(Object column) => decode(column, _tsVectorCodec);

  /// Decodes column as [PgTsQuery], or `null` if SQL NULL.
  @pragma('vm:prefer-inline')
  PgTsQuery? tsQueryOrNull(Object column) =>
      decodeOrNull(column, _tsQueryCodec);

  /// Decodes column as [PgTsQuery]. Throws [StateError] if null.
  @pragma('vm:prefer-inline')
  PgTsQuery tsQuery(Object column) => decode(column, _tsQueryCodec);
}
