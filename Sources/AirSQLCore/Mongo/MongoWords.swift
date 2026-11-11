import Foundation

/// One word of MongoDB's query language: an operator, a stage or a system variable, with a line saying what it does
/// (completion's detail, agents' hints).
public struct MongoWord: Sendable, Equatable {
    public enum Kind: String, Sendable {
        /// In a filter: `{qty: {$gt: 1}}`, `{$or: […]}`.
        case query
        /// In an update document: `{$set: {…}}`.
        case update
        /// A pipeline stage.
        case stage
        /// An aggregation expression operator: `{$concat: […]}`.
        case expression
        /// Only as an output of `$group`, `$bucket`, `$bucketAuto` or `$setWindowFields` (`stages` says which).
        case accumulator
        /// `$$ROOT`, `$$NOW`, …
        case variable
    }

    /// What a key's value (or a stage's own value, `argument`) is.
    public enum Slot: String, Sendable {
        /// A collection of the same database (`from`).
        case collection
        /// A field path, without `$` (`localField`), or with it in `$unwind`'s path.
        case field
        /// A document whose keys are field paths (`$sort`, `$project`, `sortBy`).
        case fields
        /// A pipeline: an array of stages (`$facet`: a document of them).
        case pipeline
        /// An aggregation expression: `"$a"`, `{$add: […]}`, a literal.
        case expression
        /// A query document, as `$match` takes.
        case query
        /// A document of new fields, each an accumulator (`$group`, `output`).
        case accumulators
        /// A literal: a number, a string, a document of options.
        case value
    }

    public struct Key: Sendable, Equatable {
        public let name: String
        public let slot: Slot
        public let required: Bool
    }

    public let name: String
    public let kind: Kind
    public let summary: String
    /// The first MongoDB version that has it, when later than 4.4.
    public let since: String?
    /// Query and update operators: the `$type` names of the values it suits (`["string"]` for `$regex`); empty: any.
    public let types: [String]
    /// A query operator that stands at the top of a filter, not under a field (`$or`, `$expr`).
    public let topLevel: Bool
    /// A stage: what its value is (`$match`: a query; `$lookup`: a document of `keys`).
    public let argument: Slot?
    /// A stage's argument keys, in the order the manual lists them.
    public let keys: [Key]
    /// An accumulator: the stages where it may stand.
    public let stages: [String]

    /// The slot of `key` in this stage's argument document.
    public func slot(_ key: String) -> Slot? { keys.first { $0.name == key }?.slot }

    /// Whether a server of `version` ("7.0.45") has it.
    public func isAvailable(on version: String) -> Bool {
        guard let since else { return true }
        func parts(_ text: String) -> [Int] { text.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 } }
        let (have, need) = (parts(version), parts(since))
        for i in 0..<max(have.count, need.count) where (i < have.count ? have[i] : 0) != (i < need.count ? need[i] : 0) {
            return (i < have.count ? have[i] : 0) > (i < need.count ? need[i] : 0)
        }
        return true
    }
}

/// The one table of MongoDB's words: completion, the pipeline editor and the agents' hints read it. Data only.
public enum MongoWords {
    public static let all: [MongoWord] = query + update + stages + expressions + accumulators + variables
    private static let byName: [String: [MongoWord]] = Dictionary(grouping: all, by: \.name)

    /// The words named `name` ("$sum" is an expression and an accumulator), or only those of `kind`.
    public static func named(_ name: String, kind: MongoWord.Kind? = nil) -> [MongoWord] {
        (byName[name] ?? []).filter { kind == nil || $0.kind == kind }
    }
    public static func stage(_ name: String) -> MongoWord? { named(name, kind: .stage).first }
    /// Query operators for a field whose values have `type` (a `$type` name; nil: any): those for any type, and its own.
    public static func query(for type: String?) -> [MongoWord] {
        query.filter { !$0.topLevel && ($0.types.isEmpty || type.map($0.types.contains) == true) }
    }
    /// Update operators for a field whose values have `type`, as `query(for:)`.
    public static func update(for type: String?) -> [MongoWord] {
        update.filter { $0.types.isEmpty || type.map($0.types.contains) == true }
    }
    /// The accumulators `stage` takes.
    public static func accumulators(in stage: String) -> [MongoWord] { accumulators.filter { $0.stages.contains(stage) } }

    // MARK: The table

    private static func word(_ name: String, _ kind: MongoWord.Kind, _ summary: String, since: String? = nil,
                             types: [String] = [], topLevel: Bool = false, argument: MongoWord.Slot? = nil,
                             keys: [MongoWord.Key] = [], stages: [String] = []) -> MongoWord {
        MongoWord(name: name, kind: kind, summary: summary, since: since, types: types, topLevel: topLevel,
                  argument: argument, keys: keys, stages: stages)
    }
    private static func key(_ name: String, _ slot: MongoWord.Slot, required: Bool = false) -> MongoWord.Key {
        MongoWord.Key(name: name, slot: slot, required: required)
    }

    // The rows' types, given here so that the long literals type-check quickly.
    private static func typed(_ rows: [(String, String, [String])]) -> [(String, String, [String])] { rows }
    private static func untyped(_ rows: [(String, String)]) -> [(String, String)] { rows }
    private static func versioned(_ rows: [(String, String, String?)]) -> [(String, String, String?)] { rows }

    static let numbers = ["int", "long", "double", "decimal"]
    /// Values that order usefully: numbers, dates, strings, ids and timestamps.
    static let ordered = numbers + ["date", "string", "objectId", "timestamp"]

    public static let query: [MongoWord] = typed([
        ("$eq", "Equals the value", []), ("$ne", "Doesn't equal the value (or the field is missing)", []),
        ("$gt", "Greater than the value (a later date)", ordered), ("$gte", "Greater than or equal to the value", ordered),
        ("$lt", "Less than the value (an earlier date)", ordered), ("$lte", "Less than or equal to the value", ordered),
        ("$in", "Equals one of the array's values", []), ("$nin", "Equals none of the array's values", []),
        ("$exists", "The field is there (true) or missing (false)", []),
        ("$type", "The value has this BSON type (a name such as \"string\", or a number)", []),
        ("$not", "Doesn't match the operator expression", []),
        ("$regex", "Matches the regular expression", ["string"]), ("$options", "The $regex's flags: i, m, x, s", ["string"]),
        ("$mod", "Divided by the divisor leaves the remainder: [divisor, remainder]", numbers),
        ("$all", "The array holds every one of the values", ["array"]),
        ("$elemMatch", "An element of the array matches every condition", ["array"]),
        ("$size", "The array has this many elements", ["array"]),
        ("$bitsAllSet", "Every one of these bits is 1", numbers + ["binData"]),
        ("$bitsAnySet", "Any of these bits is 1", numbers + ["binData"]),
        ("$bitsAllClear", "Every one of these bits is 0", numbers + ["binData"]),
        ("$bitsAnyClear", "Any of these bits is 0", numbers + ["binData"]),
        ("$geoWithin", "The GeoJSON or legacy point lies within the shape", ["object", "array"]),
        ("$geoIntersects", "The GeoJSON shape intersects the shape", ["object", "array"]),
        ("$near", "Points nearest first, through a geo index", ["object", "array"]),
        ("$nearSphere", "Points nearest first on a sphere, through a geo index", ["object", "array"]),
    ]).map { word($0.0, .query, $0.1, types: $0.2) } + untyped([
        ("$and", "Every one of the array's filters matches"), ("$or", "At least one of the array's filters matches"),
        ("$nor", "None of the array's filters matches"),
        ("$expr", "An aggregation expression is true: compares fields of the same document"),
        ("$jsonSchema", "The document matches the JSON Schema"),
        ("$text", "A text search through the collection's text index: {$search: \"words\"}"),
        ("$comment", "A comment kept with the query in logs and the profiler"),
    ]).map { word($0.0, .query, $0.1, topLevel: true) }

    public static let update: [MongoWord] = typed([
        ("$set", "Sets fields to values", []), ("$unset", "Removes fields", []),
        ("$setOnInsert", "Sets fields only when an upsert inserts", []), ("$rename", "Renames fields", []),
        ("$inc", "Adds to a number", numbers), ("$mul", "Multiplies a number", numbers),
        ("$min", "Sets the field when the value is smaller", ordered), ("$max", "Sets the field when the value is larger", ordered),
        ("$currentDate", "Sets the field to the current date or timestamp", ["date", "timestamp"]),
        ("$push", "Appends to an array", ["array"]), ("$addToSet", "Appends to an array unless already there", ["array"]),
        ("$pop", "Removes the first (-1) or last (1) element", ["array"]),
        ("$pull", "Removes the elements that match a condition", ["array"]),
        ("$pullAll", "Removes every element equal to one of the values", ["array"]),
        ("$each", "$push or $addToSet several values", ["array"]),
        ("$position", "$push at this index", ["array"]), ("$slice", "$push, then keep this many elements", ["array"]),
        ("$sort", "$push, then sort the array", ["array"]),
        ("$bit", "A bitwise and, or or xor on an integer", ["int", "long"]),
    ]).map { word($0.0, .update, $0.1, types: $0.2) }

    public static let stages: [MongoWord] = [
        word("$match", .stage, "Keeps the documents that match the query", argument: .query),
        word("$project", .stage, "Keeps, removes or computes fields", argument: .fields),
        word("$addFields", .stage, "Adds or replaces fields with expressions", argument: .fields),
        word("$set", .stage, "Adds or replaces fields with expressions ($addFields)", argument: .fields),
        word("$unset", .stage, "Removes fields: a path or an array of them", argument: .field),
        word("$group", .stage, "Groups by _id's expression, with accumulators for the other fields", argument: .accumulators,
             keys: [key("_id", .expression, required: true)]),
        word("$sort", .stage, "Orders the documents: {field: 1 or -1}", argument: .fields),
        word("$limit", .stage, "Passes this many documents on", argument: .value),
        word("$skip", .stage, "Skips this many documents", argument: .value),
        word("$count", .stage, "One document with the number of documents, in the field named", argument: .value),
        word("$unwind", .stage, "One document per element of an array: \"$path\" or {path, …}", argument: .field,
             keys: [key("path", .field, required: true), key("includeArrayIndex", .field),
                    key("preserveNullAndEmptyArrays", .value)]),
        word("$sortByCount", .stage, "Groups by the expression and counts, most first", argument: .expression),
        word("$bucket", .stage, "Groups into ranges with the boundaries given", argument: .value,
             keys: [key("groupBy", .expression, required: true), key("boundaries", .value, required: true),
                    key("default", .value), key("output", .accumulators)]),
        word("$bucketAuto", .stage, "Groups into this many ranges of about the same size", argument: .value,
             keys: [key("groupBy", .expression, required: true), key("buckets", .value, required: true),
                    key("output", .accumulators), key("granularity", .value)]),
        word("$replaceRoot", .stage, "Replaces each document with newRoot's", argument: .value,
             keys: [key("newRoot", .expression, required: true)]),
        word("$replaceWith", .stage, "Replaces each document with the expression's", argument: .expression),
        word("$sample", .stage, "Picks this many documents at random", argument: .value, keys: [key("size", .value, required: true)]),
        word("$redact", .stage, "Keeps or prunes levels by an expression giving $$KEEP, $$PRUNE or $$DESCEND",
             argument: .expression),
        word("$densify", .stage, "Adds documents where a sequence of numbers or dates has gaps", since: "5.1", argument: .value,
             keys: [key("field", .field, required: true), key("partitionByFields", .field), key("range", .value, required: true)]),
        word("$fill", .stage, "Fills null and missing values", since: "5.3", argument: .value,
             keys: [key("partitionBy", .expression), key("partitionByFields", .field), key("sortBy", .fields),
                    key("output", .value, required: true)]),
        word("$setWindowFields", .stage, "Computes fields over windows of ordered documents", since: "5.0", argument: .value,
             keys: [key("partitionBy", .expression), key("sortBy", .fields), key("output", .accumulators, required: true)]),
        word("$geoNear", .stage, "Documents nearest a point first, through a geo index (the first stage)", argument: .value,
             keys: [key("near", .value, required: true), key("distanceField", .field, required: true), key("spherical", .value),
                    key("maxDistance", .value), key("minDistance", .value), key("query", .query), key("key", .field),
                    key("includeLocs", .field), key("distanceMultiplier", .value)]),
        word("$documents", .stage, "Documents written in the stage, read nothing (the first stage)", since: "5.1",
             argument: .value),
        word("$collStats", .stage, "The collection's figures: latencyStats, storageStats, count (the first stage)",
             argument: .value, keys: [key("latencyStats", .value), key("storageStats", .value), key("count", .value),
                                      key("queryExecStats", .value)]),
        word("$indexStats", .stage, "Each index's use since the server started (the first stage)", argument: .value),
        word("$lookup", .stage, "Joins: adds an array of another collection's matching documents", argument: .value,
             keys: [key("from", .collection), key("localField", .field), key("foreignField", .field), key("let", .expression),
                    key("pipeline", .pipeline), key("as", .field, required: true)]),
        word("$graphLookup", .stage, "Follows references through another collection, recursively", argument: .value,
             keys: [key("from", .collection, required: true), key("startWith", .expression, required: true),
                    key("connectFromField", .field, required: true), key("connectToField", .field, required: true),
                    key("as", .field, required: true), key("maxDepth", .value), key("depthField", .field),
                    key("restrictSearchWithMatch", .query)]),
        word("$unionWith", .stage, "Adds another collection's documents: a name or {coll, pipeline}", argument: .collection,
             keys: [key("coll", .collection, required: true), key("pipeline", .pipeline)]),
        word("$facet", .stage, "Runs several pipelines on the same documents: {name: [stages], …}", argument: .pipeline),
        word("$merge", .stage, "Writes the documents into a collection, merging (the last stage)", argument: .collection,
             keys: [key("into", .collection, required: true), key("on", .field), key("let", .expression),
                    key("whenMatched", .value), key("whenNotMatched", .value)]),
        word("$out", .stage, "Writes the documents into a collection, replacing it (the last stage)", argument: .collection),
    ]

    public static let expressions: [MongoWord] = versioned([
        // Arithmetic
        ("$add", "Adds numbers, or milliseconds to a date", nil), ("$subtract", "Subtracts: numbers, or dates", nil),
        ("$multiply", "Multiplies numbers", nil), ("$divide", "Divides the first number by the second", nil),
        ("$mod", "The remainder of a division", nil), ("$abs", "The absolute value", nil), ("$ceil", "Rounds up", nil),
        ("$floor", "Rounds down", nil), ("$round", "Rounds to a number of decimal places", nil),
        ("$trunc", "Truncates to a number of decimal places", nil), ("$sqrt", "The square root", nil),
        ("$pow", "Raises to a power", nil), ("$exp", "e to the power", nil), ("$ln", "The natural logarithm", nil),
        ("$log", "The logarithm in a base", nil), ("$log10", "The base-10 logarithm", nil),
        ("$rand", "A random number from 0 to 1", nil),
        ("$sum", "Adds numbers or an array's numbers", nil), ("$avg", "The average of numbers or an array's", nil),
        ("$min", "The smallest of the values or an array's", nil), ("$max", "The largest of the values or an array's", nil),
        ("$stdDevPop", "The population standard deviation", nil), ("$stdDevSamp", "The sample standard deviation", nil),
        ("$median", "The median of numbers or an array's", "7.0"),
        ("$percentile", "Percentiles of numbers or an array's", "7.0"),
        // Comparison and boolean
        ("$eq", "true when the values are equal", nil), ("$ne", "true when the values differ", nil),
        ("$gt", "true when the first is greater", nil), ("$gte", "true when the first is greater or equal", nil),
        ("$lt", "true when the first is less", nil), ("$lte", "true when the first is less or equal", nil),
        ("$cmp", "-1, 0 or 1 as the first is less, equal or greater", nil),
        ("$and", "true when every expression is", nil), ("$or", "true when any expression is", nil),
        ("$not", "The opposite of the expression", nil),
        // Conditional
        ("$cond", "if, then, else", nil), ("$ifNull", "The first value that isn't null or missing", nil),
        ("$switch", "The first branch whose case is true, else default", nil),
        // Strings
        ("$concat", "Joins strings", nil), ("$substrCP", "Part of a string, by code points", nil),
        ("$substrBytes", "Part of a string, by UTF-8 bytes", nil), ("$strLenCP", "A string's length in code points", nil),
        ("$toLower", "Lower case", nil), ("$toUpper", "Upper case", nil), ("$trim", "Removes white space at both ends", nil),
        ("$ltrim", "Removes white space at the start", nil), ("$rtrim", "Removes white space at the end", nil),
        ("$split", "Splits a string at a delimiter into an array", nil),
        ("$indexOfCP", "Where a substring starts, in code points (-1: absent)", nil),
        ("$strcasecmp", "Compares strings ignoring case: -1, 0 or 1", nil),
        ("$regexMatch", "true when the string matches the regular expression", nil),
        ("$regexFind", "The first match of a regular expression", nil), ("$regexFindAll", "Every match", nil),
        ("$replaceOne", "Replaces the first occurrence of a string", nil),
        ("$replaceAll", "Replaces every occurrence of a string", nil),
        // Arrays
        ("$arrayElemAt", "The element at an index (negative: from the end)", nil),
        ("$first", "An array's first element", nil), ("$last", "An array's last element", nil),
        ("$size", "An array's length", nil), ("$isArray", "true when the value is an array", nil),
        ("$in", "true when the value is in the array", nil), ("$indexOfArray", "Where the value is in the array (-1: absent)", nil),
        ("$filter", "The elements for which cond is true", nil), ("$map", "Each element through an expression", nil),
        ("$reduce", "Folds the elements into one value", nil), ("$slice", "Part of an array", nil),
        ("$concatArrays", "Joins arrays", nil), ("$reverseArray", "The elements in reverse order", nil),
        ("$range", "An array of numbers from start to end", nil), ("$zip", "Pairs arrays' elements", nil),
        ("$arrayToObject", "A document from [k, v] pairs or {k, v} documents", nil),
        ("$objectToArray", "A document's fields as {k, v} documents", nil),
        ("$sortArray", "An array sorted", "5.2"), ("$firstN", "An array's first n elements", "5.2"),
        ("$lastN", "An array's last n elements", "5.2"), ("$maxN", "An array's n largest elements", "5.2"),
        ("$minN", "An array's n smallest elements", "5.2"),
        // Sets
        ("$setUnion", "The elements in any of the arrays", nil), ("$setIntersection", "The elements in every array", nil),
        ("$setDifference", "The first array's elements not in the second", nil),
        ("$setEquals", "true when the arrays hold the same elements", nil),
        ("$setIsSubset", "true when every element of the first is in the second", nil),
        ("$anyElementTrue", "true when any element is true", nil), ("$allElementsTrue", "true when every element is true", nil),
        // Dates
        ("$year", "A date's year", nil), ("$month", "A date's month, 1 to 12", nil), ("$dayOfMonth", "A date's day, 1 to 31", nil),
        ("$dayOfWeek", "A date's weekday, 1 (Sunday) to 7", nil), ("$dayOfYear", "A date's day of the year, 1 to 366", nil),
        ("$hour", "A date's hour", nil), ("$minute", "A date's minute", nil), ("$second", "A date's second", nil),
        ("$millisecond", "A date's millisecond", nil), ("$week", "A date's week of the year, 0 to 53", nil),
        ("$isoWeek", "A date's ISO week", nil), ("$isoWeekYear", "A date's ISO week-numbering year", nil),
        ("$isoDayOfWeek", "A date's ISO weekday, 1 (Monday) to 7", nil),
        ("$dateToString", "A date as text in a format", nil), ("$dateFromString", "A date from text", nil),
        ("$dateToParts", "A date's parts as a document", nil), ("$dateFromParts", "A date from its parts", nil),
        ("$dateAdd", "A date plus an amount of a unit", "5.0"), ("$dateSubtract", "A date minus an amount of a unit", "5.0"),
        ("$dateDiff", "The difference between two dates in a unit", "5.0"),
        ("$dateTrunc", "A date truncated to a unit (the start of its month, week, …)", "5.0"),
        ("$tsSecond", "A timestamp's seconds", "5.1"), ("$tsIncrement", "A timestamp's increment", "5.1"),
        // Types
        ("$type", "The value's BSON type name", nil), ("$convert", "Converts to a type, with onError and onNull", nil),
        ("$toString", "Converts to a string", nil), ("$toInt", "Converts to an int", nil), ("$toLong", "Converts to a long", nil),
        ("$toDouble", "Converts to a double", nil), ("$toDecimal", "Converts to a decimal", nil),
        ("$toDate", "Converts to a date", nil), ("$toObjectId", "Converts a 24-digit hex string to an ObjectId", nil),
        ("$toBool", "Converts to a boolean", nil), ("$isNumber", "true when the value is a number", nil),
        // Documents and the rest
        ("$mergeObjects", "Merges documents, later fields winning", nil),
        ("$getField", "A field by name, also one with . or $ in it", "5.0"),
        ("$setField", "A document with a field added, changed or removed", "5.0"),
        ("$literal", "The value as it is, not read as an expression", nil), ("$let", "Defines variables for an expression", nil),
        ("$binarySize", "The size of a string or binary in bytes", nil), ("$bsonSize", "A document's size in bytes", nil),
        ("$bitAnd", "Bitwise and of integers", "6.3"), ("$bitOr", "Bitwise or of integers", "6.3"),
        ("$bitXor", "Bitwise xor of integers", "6.3"), ("$bitNot", "Bitwise not of an integer", "6.3"),
    ]).map { word($0.0, .expression, $0.1, since: $0.2) }

    /// The stages that take accumulators.
    public static let groupStages = ["$group", "$bucket", "$bucketAuto", "$setWindowFields"]

    public static let accumulators: [MongoWord] = versioned([
        ("$sum", "Adds the values (1 counts the documents)", nil), ("$avg", "The average of the values", nil),
        ("$min", "The smallest value", nil), ("$max", "The largest value", nil),
        ("$first", "The first document's value (by the order coming in)", nil), ("$last", "The last document's value", nil),
        ("$push", "An array of the values", nil), ("$addToSet", "An array of the distinct values", nil),
        ("$mergeObjects", "The documents merged", nil), ("$stdDevPop", "The population standard deviation", nil),
        ("$stdDevSamp", "The sample standard deviation", nil), ("$count", "The number of documents", "5.0"),
        ("$top", "The first document's value by sortBy", "5.2"), ("$bottom", "The last document's value by sortBy", "5.2"),
        ("$topN", "The first n documents' values by sortBy", "5.2"), ("$bottomN", "The last n by sortBy", "5.2"),
        ("$firstN", "The first n documents' values", "5.2"), ("$lastN", "The last n documents' values", "5.2"),
        ("$maxN", "The n largest values", "5.2"), ("$minN", "The n smallest values", "5.2"),
        ("$median", "The median value", "7.0"), ("$percentile", "Percentiles of the values", "7.0"),
    ]).map { word($0.0, .accumulator, $0.1, since: $0.2, stages: groupStages) } + versioned([
        ("$rank", "The document's rank by sortBy, with gaps after ties", "5.0"),
        ("$denseRank", "The document's rank by sortBy, without gaps", "5.0"),
        ("$documentNumber", "The document's position in its partition", "5.0"),
        ("$shift", "A value from a document a number of places before or after", "5.0"),
        ("$derivative", "The rate of change over the window", "5.0"), ("$integral", "The area under the window's curve", "5.0"),
        ("$expMovingAvg", "The exponential moving average", "5.0"),
        ("$covariancePop", "The population covariance of two expressions", "5.0"),
        ("$covarianceSamp", "The sample covariance of two expressions", "5.0"),
        ("$locf", "The last value seen for a null or missing one", "5.2"),
        ("$linearFill", "A null or missing value filled in by linear interpolation", "5.3"),
    ]).map { word($0.0, .accumulator, $0.1, since: $0.2, stages: ["$setWindowFields"]) }

    public static let variables: [MongoWord] = versioned([
        ("$$ROOT", "The whole document the pipeline is on", nil),
        ("$$CURRENT", "The document at this point (the same as $$ROOT unless changed)", nil),
        ("$$NOW", "The current date and time, the same through the whole command", nil),
        ("$$CLUSTER_TIME", "The cluster's current timestamp (replica sets and sharded clusters)", nil),
        ("$$REMOVE", "Leaves the field out: a value that removes it", nil),
        ("$$DESCEND", "$redact: keep this level and look at the levels below", nil),
        ("$$PRUNE", "$redact: drop this level and everything below it", nil),
        ("$$KEEP", "$redact: keep this level and everything below it", nil),
        ("$$USER_ROLES", "The roles of the user running the command", "7.0"),
    ]).map { word($0.0, .variable, $0.1, since: $0.2) }
}
