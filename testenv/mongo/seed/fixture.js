// The MongoDB lab's logins and the database `fixture` (testenv/AGENT.md), for the standalone (the image runs it at its
// first start, as root) and the replica set (up.sh runs it on the primary). Throwaway lab passwords.
const admin = db.getSiblingDB('admin');
admin.createUser({user: 'airsql', pwd: 'airsql-pass', roles: ['root'], mechanisms: ['SCRAM-SHA-256']});
admin.createUser({user: 'reader', pwd: 'reader-pass', roles: [{role: 'read', db: 'fixture'}]});

const fixture = db.getSiblingDB('fixture');
// One document per BSON type (by `type`, the $type alias), then one with every type at once.
const values = {
  double: 1.5, string: 'héllo, wörld', object: {a: 1, nested: {b: [1, 2]}}, array: [1, 'two', {three: 3}],
  binData: BinData(0, 'AAECAwQ='), uuid: UUID('3b241101-e2bb-4255-8caf-4136c566a962'), objectId: ObjectId('65f000000000000000000001'),
  bool: true, date: ISODate('2024-02-29T12:34:56.789Z'), null: null, regex: /^air.*sql$/i,
  javascript: Code('function () { return 1; }'), int: NumberInt(42), timestamp: Timestamp({t: 1700000000, i: 7}),
  long: NumberLong('9007199254740993'), decimal: NumberDecimal('1234567890.123456789012345678901234'),
  minKey: MinKey(), maxKey: MaxKey(),
};
fixture.all_types.insertMany(Object.entries(values).map(([type, value], i) => ({_id: i + 1, type, value})));
fixture.all_types.insertOne({_id: 100, type: 'every', ...values});
// A case-insensitive default collation: 'Alice' and 'alice' are equal here.
fixture.createCollection('names_ci', {collation: {locale: 'en', strength: 2}});
fixture.names_ci.insertMany([{name: 'Alice'}, {name: 'alice'}, {name: 'Bob'}]);
fixture.createView('all_types_names', 'all_types', [{$project: {type: 1}}]);
fixture.createCollection('readings', {timeseries: {timeField: 'ts', metaField: 'sensor', granularity: 'minutes'}});
fixture.readings.insertMany([0, 1, 2, 3].map(i => ({ts: new Date(Date.UTC(2024, 0, 1, 0, i)), sensor: 'a', celsius: 20 + i})));
// Enough documents for a query that runs a while ($where with sleep), for Cancel and maxTimeMS.
fixture.many.insertMany(Array.from({length: 1000}, (_, i) => ({_id: i, n: i})));
