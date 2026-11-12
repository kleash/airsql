// Explain answers (executionStats) the Mongo lab's standalone (MongoDB 7.0, classic engine) gave for the queries
// MongoPipelineTests names, without their command, serverInfo and serverParameters. Our own fixture data.

enum MongoExplainFixtures {
    static let indexedFind = #"""
    {
     "explainVersion": "1",
     "queryPlanner": {
      "namespace": "fixture.many",
      "indexFilterSet": false,
      "parsedQuery": {
       "$and": [
        {
         "_id": {
          "$lt": 20
         }
        },
        {
         "_id": {
          "$gte": 10
         }
        }
       ]
      },
      "queryHash": "745C7D7A",
      "planCacheKey": "F36B5E67",
      "optimizationTimeMillis": 0,
      "maxIndexedOrSolutionsReached": false,
      "maxIndexedAndSolutionsReached": false,
      "maxScansToExplodeReached": false,
      "winningPlan": {
       "stage": "FETCH",
       "inputStage": {
        "stage": "IXSCAN",
        "keyPattern": {
         "_id": 1
        },
        "indexName": "_id_",
        "isMultiKey": false,
        "isUnique": true,
        "isSparse": false,
        "isPartial": false,
        "indexVersion": 2,
        "direction": "forward",
        "indexBounds": {
         "_id": [
          "[10, 20)"
         ]
        }
       }
      },
      "rejectedPlans": []
     },
     "executionStats": {
      "executionSuccess": true,
      "nReturned": 10,
      "executionTimeMillis": 0,
      "totalKeysExamined": 10,
      "totalDocsExamined": 10,
      "executionStages": {
       "stage": "FETCH",
       "nReturned": 10,
       "executionTimeMillisEstimate": 0,
       "works": 11,
       "advanced": 10,
       "needTime": 0,
       "needYield": 0,
       "saveState": 0,
       "restoreState": 0,
       "isEOF": 1,
       "docsExamined": 10,
       "alreadyHasObj": 0,
       "inputStage": {
        "stage": "IXSCAN",
        "nReturned": 10,
        "executionTimeMillisEstimate": 0,
        "works": 11,
        "advanced": 10,
        "needTime": 0,
        "needYield": 0,
        "saveState": 0,
        "restoreState": 0,
        "isEOF": 1,
        "keyPattern": {
         "_id": 1
        },
        "indexName": "_id_",
        "isMultiKey": false,
        "isUnique": true,
        "isSparse": false,
        "isPartial": false,
        "indexVersion": 2,
        "direction": "forward",
        "indexBounds": {
         "_id": [
          "[10, 20)"
         ]
        },
        "keysExamined": 10,
        "seeks": 1,
        "dupsTested": 0,
        "dupsDropped": 0
       }
      }
     },
     "ok": 1
    }
    """#

    static let unindexedFind = #"""
    {
     "explainVersion": "1",
     "queryPlanner": {
      "namespace": "fixture.many",
      "indexFilterSet": false,
      "parsedQuery": {
       "n": {
        "$gt": 990
       }
      },
      "queryHash": "E4164087",
      "planCacheKey": "E4164087",
      "optimizationTimeMillis": 0,
      "maxIndexedOrSolutionsReached": false,
      "maxIndexedAndSolutionsReached": false,
      "maxScansToExplodeReached": false,
      "winningPlan": {
       "stage": "COLLSCAN",
       "filter": {
        "n": {
         "$gt": 990
        }
       },
       "direction": "forward"
      },
      "rejectedPlans": []
     },
     "executionStats": {
      "executionSuccess": true,
      "nReturned": 9,
      "executionTimeMillis": 0,
      "totalKeysExamined": 0,
      "totalDocsExamined": 1000,
      "executionStages": {
       "stage": "COLLSCAN",
       "filter": {
        "n": {
         "$gt": 990
        }
       },
       "nReturned": 9,
       "executionTimeMillisEstimate": 0,
       "works": 1001,
       "advanced": 9,
       "needTime": 991,
       "needYield": 0,
       "saveState": 1,
       "restoreState": 1,
       "isEOF": 1,
       "direction": "forward",
       "docsExamined": 1000
      }
     },
     "ok": 1
    }
    """#

    static let sortedFind = #"""
    {
     "explainVersion": "1",
     "queryPlanner": {
      "namespace": "fixture.many",
      "indexFilterSet": false,
      "parsedQuery": {
       "n": {
        "$gte": 100
       }
      },
      "queryHash": "6CE8EEEC",
      "planCacheKey": "6CE8EEEC",
      "optimizationTimeMillis": 0,
      "maxIndexedOrSolutionsReached": false,
      "maxIndexedAndSolutionsReached": false,
      "maxScansToExplodeReached": false,
      "winningPlan": {
       "stage": "PROJECTION_SIMPLE",
       "transformBy": {
        "n": 1,
        "_id": 0
       },
       "inputStage": {
        "stage": "SKIP",
        "skipAmount": 2,
        "inputStage": {
         "stage": "SORT",
         "sortPattern": {
          "n": -1
         },
         "memLimit": 104857600,
         "limitAmount": 7,
         "type": "simple",
         "inputStage": {
          "stage": "COLLSCAN",
          "filter": {
           "n": {
            "$gte": 100
           }
          },
          "direction": "forward"
         }
        }
       }
      },
      "rejectedPlans": []
     },
     "executionStats": {
      "executionSuccess": true,
      "nReturned": 5,
      "executionTimeMillis": 1,
      "totalKeysExamined": 0,
      "totalDocsExamined": 1000,
      "executionStages": {
       "stage": "PROJECTION_SIMPLE",
       "nReturned": 5,
       "executionTimeMillisEstimate": 0,
       "works": 1009,
       "advanced": 5,
       "needTime": 1003,
       "needYield": 0,
       "saveState": 1,
       "restoreState": 1,
       "isEOF": 1,
       "transformBy": {
        "n": 1,
        "_id": 0
       },
       "inputStage": {
        "stage": "SKIP",
        "nReturned": 5,
        "executionTimeMillisEstimate": 0,
        "works": 1009,
        "advanced": 5,
        "needTime": 1003,
        "needYield": 0,
        "saveState": 1,
        "restoreState": 1,
        "isEOF": 1,
        "skipAmount": 2,
        "inputStage": {
         "stage": "SORT",
         "nReturned": 7,
         "executionTimeMillisEstimate": 0,
         "works": 1009,
         "advanced": 7,
         "needTime": 1001,
         "needYield": 0,
         "saveState": 1,
         "restoreState": 1,
         "isEOF": 1,
         "sortPattern": {
          "n": -1
         },
         "memLimit": 104857600,
         "limitAmount": 7,
         "type": "simple",
         "totalDataSizeSorted": 371,
         "usedDisk": false,
         "spills": 0,
         "spilledDataStorageSize": 0,
         "inputStage": {
          "stage": "COLLSCAN",
          "filter": {
           "n": {
            "$gte": 100
           }
          },
          "nReturned": 900,
          "executionTimeMillisEstimate": 0,
          "works": 1001,
          "advanced": 900,
          "needTime": 100,
          "needYield": 0,
          "saveState": 1,
          "restoreState": 1,
          "isEOF": 1,
          "direction": "forward",
          "docsExamined": 1000
         }
        }
       }
      }
     },
     "ok": 1
    }
    """#

    static let aggregate = #"""
    {
     "explainVersion": "1",
     "stages": [
      {
       "$cursor": {
        "queryPlanner": {
         "namespace": "fixture.many",
         "indexFilterSet": false,
         "parsedQuery": {
          "n": {
           "$lt": 50
          }
         },
         "queryHash": "6104EB9D",
         "planCacheKey": "6104EB9D",
         "optimizationTimeMillis": 1,
         "maxIndexedOrSolutionsReached": false,
         "maxIndexedAndSolutionsReached": false,
         "maxScansToExplodeReached": false,
         "winningPlan": {
          "stage": "PROJECTION_SIMPLE",
          "transformBy": {
           "n": 1,
           "_id": 0
          },
          "inputStage": {
           "stage": "COLLSCAN",
           "filter": {
            "n": {
             "$lt": 50
            }
           },
           "direction": "forward"
          }
         },
         "rejectedPlans": []
        },
        "executionStats": {
         "executionSuccess": true,
         "nReturned": 50,
         "executionTimeMillis": 14,
         "totalKeysExamined": 0,
         "totalDocsExamined": 1000,
         "executionStages": {
          "stage": "PROJECTION_SIMPLE",
          "nReturned": 50,
          "executionTimeMillisEstimate": 0,
          "works": 1001,
          "advanced": 50,
          "needTime": 950,
          "needYield": 0,
          "saveState": 2,
          "restoreState": 2,
          "isEOF": 1,
          "transformBy": {
           "n": 1,
           "_id": 0
          },
          "inputStage": {
           "stage": "COLLSCAN",
           "filter": {
            "n": {
             "$lt": 50
            }
           },
           "nReturned": 50,
           "executionTimeMillisEstimate": 0,
           "works": 1001,
           "advanced": 50,
           "needTime": 950,
           "needYield": 0,
           "saveState": 2,
           "restoreState": 2,
           "isEOF": 1,
           "direction": "forward",
           "docsExamined": 1000
          }
         }
        }
       },
       "nReturned": 50,
       "executionTimeMillisEstimate": 1
      },
      {
       "$group": {
        "_id": {
         "$mod": [
          "$n",
          {
           "$const": 5
          }
         ]
        },
        "c": {
         "$sum": {
          "$const": 1
         }
        }
       },
       "maxAccumulatorMemoryUsageBytes": {
        "c": 480
       },
       "totalOutputDataSizeBytes": 1225,
       "usedDisk": false,
       "spills": 0,
       "spilledDataStorageSize": 0,
       "numBytesSpilledEstimate": 0,
       "spilledRecords": 0,
       "nReturned": 5,
       "executionTimeMillisEstimate": 1
      },
      {
       "$sort": {
        "sortKey": {
         "_id": 1
        }
       },
       "totalDataSizeSortedBytesEstimate": 1265,
       "usedDisk": false,
       "spills": 0,
       "spilledDataStorageSize": 0,
       "nReturned": 5,
       "executionTimeMillisEstimate": 1
      },
      {
       "$lookup": {
        "from": "all_types",
        "as": "t",
        "localField": "_id",
        "foreignField": "_id"
       },
       "totalDocsExamined": 4,
       "totalKeysExamined": 4,
       "collectionScans": 0,
       "indexesUsed": [
        "_id_"
       ],
       "nReturned": 5,
       "executionTimeMillisEstimate": 12
      }
     ],
     "ok": 1
    }
    """#

    static let pushedDownAggregate = #"""
    {
     "explainVersion": "1",
     "queryPlanner": {
      "namespace": "fixture.many",
      "indexFilterSet": false,
      "parsedQuery": {
       "_id": {
        "$lt": 50
       }
      },
      "queryHash": "0F33124F",
      "planCacheKey": "CD362288",
      "optimizationTimeMillis": 0,
      "optimizedPipeline": true,
      "maxIndexedOrSolutionsReached": false,
      "maxIndexedAndSolutionsReached": false,
      "maxScansToExplodeReached": false,
      "winningPlan": {
       "stage": "LIMIT",
       "limitAmount": 3,
       "inputStage": {
        "stage": "FETCH",
        "inputStage": {
         "stage": "IXSCAN",
         "keyPattern": {
          "_id": 1
         },
         "indexName": "_id_",
         "isMultiKey": false,
         "isUnique": true,
         "isSparse": false,
         "isPartial": false,
         "indexVersion": 2,
         "direction": "backward",
         "indexBounds": {
          "_id": [
           "(50, -inf.0]"
          ]
         }
        }
       }
      },
      "rejectedPlans": []
     },
     "executionStats": {
      "executionSuccess": true,
      "nReturned": 3,
      "executionTimeMillis": 0,
      "totalKeysExamined": 3,
      "totalDocsExamined": 3,
      "executionStages": {
       "stage": "LIMIT",
       "nReturned": 3,
       "executionTimeMillisEstimate": 0,
       "works": 4,
       "advanced": 3,
       "needTime": 0,
       "needYield": 0,
       "saveState": 0,
       "restoreState": 0,
       "isEOF": 1,
       "limitAmount": 3,
       "inputStage": {
        "stage": "FETCH",
        "nReturned": 3,
        "executionTimeMillisEstimate": 0,
        "works": 3,
        "advanced": 3,
        "needTime": 0,
        "needYield": 0,
        "saveState": 0,
        "restoreState": 0,
        "isEOF": 0,
        "docsExamined": 3,
        "alreadyHasObj": 0,
        "inputStage": {
         "stage": "IXSCAN",
         "nReturned": 3,
         "executionTimeMillisEstimate": 0,
         "works": 3,
         "advanced": 3,
         "needTime": 0,
         "needYield": 0,
         "saveState": 0,
         "restoreState": 0,
         "isEOF": 0,
         "keyPattern": {
          "_id": 1
         },
         "indexName": "_id_",
         "isMultiKey": false,
         "isUnique": true,
         "isSparse": false,
         "isPartial": false,
         "indexVersion": 2,
         "direction": "backward",
         "indexBounds": {
          "_id": [
           "(50, -inf.0]"
          ]
         },
         "keysExamined": 3,
         "seeks": 1,
         "dupsTested": 0,
         "dupsDropped": 0
        }
       }
      }
     },
     "ok": 1
    }
    """#

    static let rejectedPlans = #"""
    {
     "explainVersion": "1",
     "queryPlanner": {
      "namespace": "lane_mongo_pipeline.t",
      "indexFilterSet": false,
      "parsedQuery": {
       "$and": [
        {
         "a": {
          "$eq": 3
         }
        },
        {
         "b": {
          "$eq": 4
         }
        }
       ]
      },
      "queryHash": "33DA1CF7",
      "planCacheKey": "57240689",
      "optimizationTimeMillis": 1,
      "maxIndexedOrSolutionsReached": false,
      "maxIndexedAndSolutionsReached": false,
      "maxScansToExplodeReached": false,
      "winningPlan": {
       "stage": "FETCH",
       "filter": {
        "b": {
         "$eq": 4
        }
       },
       "inputStage": {
        "stage": "IXSCAN",
        "keyPattern": {
         "a": 1
        },
        "indexName": "a_1",
        "isMultiKey": false,
        "multiKeyPaths": {
         "a": []
        },
        "isUnique": false,
        "isSparse": false,
        "isPartial": false,
        "indexVersion": 2,
        "direction": "forward",
        "indexBounds": {
         "a": [
          "[3, 3]"
         ]
        }
       }
      },
      "rejectedPlans": [
       {
        "stage": "FETCH",
        "filter": {
         "a": {
          "$eq": 3
         }
        },
        "inputStage": {
         "stage": "IXSCAN",
         "keyPattern": {
          "b": 1
         },
         "indexName": "b_1",
         "isMultiKey": false,
         "multiKeyPaths": {
          "b": []
         },
         "isUnique": false,
         "isSparse": false,
         "isPartial": false,
         "indexVersion": 2,
         "direction": "forward",
         "indexBounds": {
          "b": [
           "[4, 4]"
          ]
         }
        }
       },
       {
        "stage": "FETCH",
        "filter": {
         "$and": [
          {
           "a": {
            "$eq": 3
           }
          },
          {
           "b": {
            "$eq": 4
           }
          }
         ]
        },
        "inputStage": {
         "stage": "AND_SORTED",
         "inputStages": [
          {
           "stage": "IXSCAN",
           "keyPattern": {
            "a": 1
           },
           "indexName": "a_1",
           "isMultiKey": false,
           "multiKeyPaths": {
            "a": []
           },
           "isUnique": false,
           "isSparse": false,
           "isPartial": false,
           "indexVersion": 2,
           "direction": "forward",
           "indexBounds": {
            "a": [
             "[3, 3]"
            ]
           }
          },
          {
           "stage": "IXSCAN",
           "keyPattern": {
            "b": 1
           },
           "indexName": "b_1",
           "isMultiKey": false,
           "multiKeyPaths": {
            "b": []
           },
           "isUnique": false,
           "isSparse": false,
           "isPartial": false,
           "indexVersion": 2,
           "direction": "forward",
           "indexBounds": {
            "b": [
             "[4, 4]"
            ]
           }
          }
         ]
        }
       }
      ]
     },
     "executionStats": {
      "executionSuccess": true,
      "nReturned": 3,
      "executionTimeMillis": 1,
      "totalKeysExamined": 20,
      "totalDocsExamined": 20,
      "executionStages": {
       "stage": "FETCH",
       "filter": {
        "b": {
         "$eq": 4
        }
       },
       "nReturned": 3,
       "executionTimeMillisEstimate": 0,
       "works": 22,
       "advanced": 3,
       "needTime": 17,
       "needYield": 0,
       "saveState": 0,
       "restoreState": 0,
       "isEOF": 1,
       "docsExamined": 20,
       "alreadyHasObj": 0,
       "inputStage": {
        "stage": "IXSCAN",
        "nReturned": 20,
        "executionTimeMillisEstimate": 0,
        "works": 21,
        "advanced": 20,
        "needTime": 0,
        "needYield": 0,
        "saveState": 0,
        "restoreState": 0,
        "isEOF": 1,
        "keyPattern": {
         "a": 1
        },
        "indexName": "a_1",
        "isMultiKey": false,
        "multiKeyPaths": {
         "a": []
        },
        "isUnique": false,
        "isSparse": false,
        "isPartial": false,
        "indexVersion": 2,
        "direction": "forward",
        "indexBounds": {
         "a": [
          "[3, 3]"
         ]
        },
        "keysExamined": 20,
        "seeks": 1,
        "dupsTested": 0,
        "dupsDropped": 0
       }
      }
     },
     "ok": 1
    }
    """#
}
