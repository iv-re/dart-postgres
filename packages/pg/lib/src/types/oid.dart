/// PostgreSQL Type Object Identifier (OID).
///
/// An extension type over [int] representing PostgreSQL type identifiers
/// with zero runtime overhead.
extension type const PgOid(int value) implements int {
  // Primitives & Numerics
  static const bool = PgOid(16);
  static const bytea = PgOid(17);
  static const char = PgOid(18);
  static const name = PgOid(19);
  static const int8 = PgOid(20);
  static const int2 = PgOid(21);
  static const int4 = PgOid(23);
  static const regproc = PgOid(24);
  static const text = PgOid(25);
  static const oid = PgOid(26);
  static const tid = PgOid(27);
  static const xid = PgOid(28);
  static const cid = PgOid(29);
  static const json = PgOid(114);
  static const xml = PgOid(142);
  static const float4 = PgOid(700);
  static const float8 = PgOid(701);
  static const unknown = PgOid(705);
  static const macaddr = PgOid(829);
  static const inet = PgOid(869);
  static const cidr = PgOid(650);
  static const macaddr8 = PgOid(774);
  static const bpchar = PgOid(1042);
  static const varchar = PgOid(1043);
  static const date = PgOid(1082);
  static const time = PgOid(1083);
  static const timestamp = PgOid(1114);
  static const timestamptz = PgOid(1184);
  static const interval = PgOid(1186);
  static const timetz = PgOid(1266);
  static const bit = PgOid(1560);
  static const varbit = PgOid(1562);
  static const numeric = PgOid(1700);
  static const record = PgOid(2249);
  static const voidType = PgOid(2278);
  static const uuid = PgOid(2950);
  static const jsonb = PgOid(3802);

  // Geometric Types
  static const point = PgOid(600);
  static const lseg = PgOid(601);
  static const path = PgOid(602);
  static const box = PgOid(603);
  static const polygon = PgOid(604);
  static const line = PgOid(628);
  static const circle = PgOid(718);

  // Text Search Types
  static const tsvector = PgOid(3614);
  static const tsquery = PgOid(3615);

  // Range Types
  static const int4range = PgOid(3904);
  static const numrange = PgOid(3906);
  static const tsrange = PgOid(3908);
  static const tstzrange = PgOid(3910);
  static const daterange = PgOid(3912);
  static const int8range = PgOid(3926);

  // Arrays
  static const boolArray = PgOid(1000);
  static const byteaArray = PgOid(1001);
  static const charArray = PgOid(1002);
  static const nameArray = PgOid(1003);
  static const int2Array = PgOid(1005);
  static const int4Array = PgOid(1007);
  static const textArray = PgOid(1009);
  static const bpcharArray = PgOid(1014);
  static const varcharArray = PgOid(1015);
  static const int8Array = PgOid(1016);
  static const pointArray = PgOid(1017);
  static const float4Array = PgOid(1021);
  static const float8Array = PgOid(1022);
  static const dateArray = PgOid(1182);
  static const timeArray = PgOid(1183);
  static const timestampArray = PgOid(1115);
  static const timestampTzArray = PgOid(1185);
  static const intervalArray = PgOid(1187);
  static const numericArray = PgOid(1231);
  static const uuidArray = PgOid(2951);
  static const jsonbArray = PgOid(3807);
  static const jsonArray = PgOid(199);
}
