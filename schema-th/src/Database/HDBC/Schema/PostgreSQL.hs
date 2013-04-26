{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Database.HDBC.Schema.PostgreSQL
-- Copyright   : 2013 Kei Hibino
-- License     : BSD3
--
-- Maintainer  : ex8k.hibino@gmail.com
-- Stability   : experimental
-- Portability : unknown
module Database.HDBC.Schema.PostgreSQL (
  driverPostgreSQL
  ) where

import Language.Haskell.TH (Q, Type)

import Data.Int (Int16, Int32, Int64)
import Data.Char (toLower)
import Data.Map (Map, fromList, (!))
import qualified Data.Map as Map
import Data.Time
  (DiffTime, NominalDiffTime,
   LocalTime, ZonedTime, Day, TimeOfDay)

import Database.HDBC (IConnection)

import Database.HDBC.SqlValueExtra ()
import qualified Database.HDBC.TH as Base
import Database.Record.Persistable (Singleton, singleton, runSingleton)
import Database.HDBC.Record.Query (Query(..), typedQuery, runQuery', listToUnique)

import Database.HDBC.Schema.PgCatalog.PgAttribute (PgAttribute, tableOfPgAttribute, fieldsOfPgAttribute)
import qualified Database.HDBC.Schema.PgCatalog.PgAttribute as Attr
import Database.HDBC.Schema.PgCatalog.PgType (PgType(..), tableOfPgType, fieldsOfPgType)
import qualified Database.HDBC.Schema.PgCatalog.PgType as Type

import Language.SQL.Keyword (Keyword(..), (<.>), (.=.))
import qualified Language.SQL.Keyword as SQL

import Database.HDBC.Schema.Driver
  (TypeMap, Driver, getFieldsWithMap, getPrimaryKey, emptyDriver)

mapFromSqlDefault :: Map String (Q Type)
mapFromSqlDefault =
  fromList [("bool",         [t| Bool |]),
            ("char",         [t| String |]),
            ("name",         [t| String |]),
            ("int8",         [t| Int64 |]),
            ("int2",         [t| Int16 |]),
            ("int4",         [t| Int32 |]),
            -- ("regproc",      [t| Int32 |]),
            ("text",         [t| String |]),
            ("oid",          [t| Int32 |]),
            -- ("pg_node_tree", [t| String |]),
            ("float4",       [t| Float |]),
            ("float8",       [t| Double |]),
            ("abstime",      [t| LocalTime |]),
            ("reltime",      [t| NominalDiffTime |]),
            ("tinterval",    [t| DiffTime |]),
            -- ("money",        [t| Decimal |]),
            ("bpchar",       [t| String |]),
            ("varchar",      [t| String |]),
            ("date",         [t| Day |]),
            ("time",         [t| TimeOfDay |]),
            ("timestamp",    [t| LocalTime |]),
            ("timestamptz",  [t| ZonedTime |]),
            ("interval",     [t| DiffTime |]),
            ("timetz",       [t| ZonedTime |])

            -- ("bit", [t|  |]),
            -- ("varbit", [t|  |]),
            -- ("numeric", [t| Decimal |])
           ]

normalizeField :: String -> String
normalizeField =  map toLower

type Column = (PgAttribute, PgType)

notNull :: Column -> Bool
notNull =  Attr.attnotnull . fst

getType :: Map String (Q Type) -> Column -> (String, Q Type)
getType mapFromSql column@(pgAttr, pgType) =
  (normalizeField $ Attr.attname pgAttr,
   mayNull $ mapFromSql ! Type.typname pgType)
  where
    mayNull typ = if notNull column
                  then typ
                  else [t| Maybe $typ |]

pgCatalog :: SQL.Keyword
pgCatalog =  "PG_CATALOG"

relOidQuerySQL :: Query (Singleton String, Singleton String) (Singleton Int32)
relOidQuerySQL =
  typedQuery .
  SQL.unwordsSQL
  $ [SELECT,
     "rel" <.> "oid", AS, "rel_object_id",
     FROM,
     pgCatalog <.> "pg_namespace", AS, "nsp", ",",
     pgCatalog <.> "pg_class",     AS, "rel",
     WHERE,
     "rel" <.> "relnamespace" .=. "nsp" <.> "oid",  AND,

     "nspname" .=. "?", AND, "relname" .=. "?"
    ]

attributeQuerySQL :: Query (Singleton String, Singleton String) PgAttribute
attributeQuerySQL =
  typedQuery .
  SQL.unwordsSQL
  $ [SELECT,
     map (("att" <.>) . SQL.word) fieldsOfPgAttribute `SQL.sepBy` ", ",
     FROM,
     "(", SQL.word $ untypeQuery relOidQuerySQL, ")", AS, "rel", ",",
     SQL.word tableOfPgAttribute,                      AS, "att",
     WHERE,
     "attrelid" .=. "rel_object_id", AND,
     "attnum", ">", "0" -- attnum of normal attributes begins from 1
    ]

columnQuerySQL :: Query (Singleton String, Singleton String) Column
columnQuerySQL =
  typedQuery .
  SQL.unwordsSQL
  $ [SELECT,
     (map (("att" <.>) . SQL.word) fieldsOfPgAttribute ++
      map (("typ"  <.>) . SQL.word) fieldsOfPgType)
     `SQL.sepBy` ", ",
     FROM,
     "(", SQL.word $ untypeQuery attributeQuerySQL, ")", AS, "att", ",",
     SQL.word tableOfPgType,                              AS, "typ",
     WHERE,
     "atttypid" .=. "typ" <.> "oid", AND,
     "typ" <.> "typtype" .=. "'b'",  AND,
     "(",
     "typcategory = 'B'", OR,
     "typcategory = 'D'", OR,
     "typcategory = 'N'", OR,
     "typcategory = 'S'", OR,
     "typcategory = 'T'",
     ")" ]

primaryKeyQuerySQL :: Query (Singleton String, Singleton String) (Singleton String)
primaryKeyQuerySQL =
  typedQuery .
  SQL.unwordsSQL
  $ [SELECT, "attname", FROM,
     "(", SQL.word $ untypeQuery attributeQuerySQL, ")", AS, "att", ",",
     pgCatalog <.> "pg_constraint",                      AS, "con",
     WHERE,
     "conrelid"  .=. "attrelid", AND,
     "conkey[1]" .=. "attnum",   AND,

     "attnotnull" .=. "TRUE",    AND,
     "contype" .=. "'p'",        AND,
     "array_length (conkey, 1)" .=. "1"]

logPrefix :: String -> String
logPrefix =  ("PostgreSQL: " ++)

putLog :: String -> IO ()
putLog =  putStrLn . logPrefix

compileErrorIO :: String -> IO a
compileErrorIO =  Base.compileErrorIO . logPrefix

getPrimaryKey' :: IConnection conn
              => conn
              -> String
              -> String
              -> IO (Maybe String)
getPrimaryKey' conn scm' tbl' = do
  let scm = map toLower scm'
      tbl = map toLower tbl'
  mayPrim <- runQuery' conn (singleton scm, singleton tbl) primaryKeyQuerySQL
             >>= listToUnique
  return $ (normalizeField . runSingleton) `fmap` mayPrim

getFields' :: IConnection conn
          => TypeMap
          -> conn
          -> String
          -> String
          -> IO ([(String, Q Type)], [Int])
getFields' tmap conn scm' tbl' = do
  let scm = map toLower scm'
      tbl = map toLower tbl'
  cols <- runQuery' conn (singleton scm, singleton tbl) columnQuerySQL
  case cols of
    [] ->  compileErrorIO
           $ "getFields: No columns found: schema = " ++ scm ++ ", table = " ++ tbl
    _  ->  return ()

  let notNullIdxs = map fst . filter (notNull . snd) . zip [0..] $ cols
  putLog
    $  "getFields: num of columns = " ++ show (length cols)
    ++ ", not null columns = " ++ show notNullIdxs
  let mapFromSql = fromList tmap `Map.union` mapFromSqlDefault

  return $ (map (getType mapFromSql) cols, notNullIdxs)

driverPostgreSQL :: IConnection conn => Driver conn
driverPostgreSQL =
  emptyDriver { getFieldsWithMap = getFields' }
              { getPrimaryKey    = getPrimaryKey' }

