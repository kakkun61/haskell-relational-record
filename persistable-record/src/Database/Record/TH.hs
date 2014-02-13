{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}

-- |
-- Module      : Database.Record.TH
-- Copyright   : 2013 Kei Hibino
-- License     : BSD3
--
-- Maintainer  : ex8k.hibino@gmail.com
-- Stability   : experimental
-- Portability : unknown
--
-- This module defines templates for Haskell record type and
-- type class instances to map between list of untyped SQL type and Haskell record type.
module Database.Record.TH (
  -- * Generate all templates about record
  defineRecord,
  defineRecordDefault,

  -- * Deriving class symbols
  derivingEq, derivingShow, derivingRead, derivingData, derivingTypable,

  -- * Table constraint specified by key
  defineHasColumnConstraintInstance,
  defineHasPrimaryConstraintInstanceDerived,
  defineHasNotNullKeyInstance,
  defineHasPrimaryKeyInstance,
  defineHasPrimaryKeyInstanceDefault,
  defineHasNotNullKeyInstanceDefault,

  -- * Record type
  defineRecordType, defineRecordTypeDefault,

  -- * Function declarations depending on SQL type
  defineRecordWithSqlType,
  defineRecordWithSqlTypeDefault,

  defineRecordWithSqlTypeFromDefined,
  defineRecordWithSqlTypeDefaultFromDefined,

  defineRecordConstructFunction,
  defineRecordDecomposeFunction,

  definePersistableInstance,

  -- * Record type name
  recordTypeNameDefault, recordTypeDefault,

  -- * Not nullable single column type
  deriveNotNullType
  ) where


import Language.Haskell.TH.Name.CamelCase
  (ConName(conName), VarName(varName),
   conCamelcaseName, varCamelcaseName, varNameWithPrefix,
   toTypeCon, toVarExp)
import Language.Haskell.TH.Lib.Extra (integralE, compileError)
import Language.Haskell.TH
  (Q, mkName, reify, Info(TyConI),
   TypeQ, conT, Con (RecC),
   Dec(DataD), dataD, sigD, funD,
   appsE, conE, varE, listE, stringE,
   listP, varP, conP, wildP,
   normalB, recC, clause, cxt,
   varStrictType, strictType, isStrict)
import Language.Haskell.TH.Syntax (VarStrictType)

import Database.Record
  (HasColumnConstraint(columnConstraint), Primary, NotNull,
   HasKeyConstraint(keyConstraint), derivedCompositePrimary,
   Persistable(persistable), PersistableWidth(persistableWidth),
   fromSql, toSql,
   FromSql(recordFromSql), recordFromSql',
   ToSql(recordToSql), recordToSql')

import Database.Record.KeyConstraint
  (unsafeSpecifyColumnConstraint, unsafeSpecifyNotNullValue, unsafeSpecifyKeyConstraint)
import Database.Record.Persistable
  (persistableRecord, unsafePersistableRecordWidth)
import qualified Database.Record.Persistable as Persistable


-- | Generate default name of record type constructor from SQL table name 'String'
recordTypeNameDefault :: String  -- ^ Table name in SQL
                      -> ConName -- ^ Result name
recordTypeNameDefault =  conCamelcaseName

-- | Record type constructor template from SQL table name 'String'.
--   Type name is generated by 'recordTypeNameDefault'.
recordTypeDefault :: String -- ^ Table name in SQL
                  -> TypeQ  -- ^ Result type template
recordTypeDefault =  toTypeCon . recordTypeNameDefault

-- | Template of 'HasColumnConstraint' instance.
defineHasColumnConstraintInstance :: TypeQ   -- ^ Type which represent constraint type
                                  -> TypeQ   -- ^ Type constructor of record
                                  -> Int     -- ^ Key index which specifies this constraint
                                  -> Q [Dec] -- ^ Result declaration template
defineHasColumnConstraintInstance constraint typeCon index =
  [d| instance HasColumnConstraint $constraint $typeCon where
        columnConstraint = unsafeSpecifyColumnConstraint $(integralE index) |]

-- | Template of 'HasKeyConstraint' instance.
defineHasPrimaryConstraintInstanceDerived ::TypeQ    -- ^ Type constructor of record
                                          -> Q [Dec] -- ^ Result declaration template
defineHasPrimaryConstraintInstanceDerived typeCon =
  [d| instance HasKeyConstraint Primary $typeCon where
        keyConstraint = derivedCompositePrimary |]

-- | Template of 'HasColumnConstraint' 'Primary' instance.
defineHasPrimaryKeyInstance :: TypeQ   -- ^ Type constructor of record
                            -> [Int]   -- ^ Key index which specifies this constraint
                            -> Q [Dec] -- ^ Declaration of primary key constraint instance
defineHasPrimaryKeyInstance typeCon = d  where
  d []   = return []
  d [ix] = do
    col  <- defineHasColumnConstraintInstance [t| Primary |] typeCon ix
    comp <- defineHasPrimaryConstraintInstanceDerived typeCon
    return $ col ++ comp
  d ixs  =
    [d| instance HasKeyConstraint Primary $typeCon where
          keyConstraint = unsafeSpecifyKeyConstraint
                          $(listE [integralE ix | ix <- ixs ])
      |]

-- | Template of 'HasColumnConstraint' 'NotNull' instance.
defineHasNotNullKeyInstance :: TypeQ   -- ^ Type constructor of record
                            -> Int     -- ^ Key index which specifies this constraint
                            -> Q [Dec] -- ^ Declaration of not null key constraint instance
defineHasNotNullKeyInstance =
  defineHasColumnConstraintInstance [t| NotNull |]

-- | Template of 'HasColumnConstraint' 'Primary' instance
--   from SQL table name 'String' and key index.
defineHasPrimaryKeyInstanceDefault :: String  -- ^ Table name
                                   -> [Int]   -- ^ Key index which specifies this constraint
                                   -> Q [Dec] -- ^ Declaration of primary key constraint instance
defineHasPrimaryKeyInstanceDefault =
  defineHasPrimaryKeyInstance . recordTypeDefault

-- | Template of 'HasColumnConstraint' 'NotNull' instance
--   from SQL table name 'String' and key index.
defineHasNotNullKeyInstanceDefault :: String  -- ^ Table name
                                   -> Int     -- ^ Key index which specifies this constraint
                                   -> Q [Dec] -- ^ Declaration of not null key constraint instance
defineHasNotNullKeyInstanceDefault =
  defineHasNotNullKeyInstance . recordTypeDefault

-- | Name to specify deriving 'Eq'
derivingEq :: ConName
derivingEq   = conCamelcaseName "Eq"

-- | Name to specify deriving 'Show'
derivingShow :: ConName
derivingShow = conCamelcaseName "Show"

-- | Name to specify deriving 'Read'
derivingRead :: ConName
derivingRead = conCamelcaseName "Read"

-- | Name to specify deriving 'Data'
derivingData :: ConName
derivingData = conCamelcaseName "Data"

-- | Name to specify deriving 'Typable'
derivingTypable :: ConName
derivingTypable = conCamelcaseName "Typable"

-- | Record type declaration template.
defineRecordType :: ConName            -- ^ Name of the data type of table record type.
                 -> [(VarName, TypeQ)] -- ^ List of columns in the table. Must be legal, properly cased record columns.
                 -> [ConName]          -- ^ Deriving type class names.
                 -> Q [Dec]            -- ^ The data type record declaration.
defineRecordType typeName' columns derives = do
  let typeName = conName typeName'
      fld (n, tq) = varStrictType (varName n) (strictType isStrict tq)
  rec <- dataD (cxt []) typeName [] [recC typeName (map fld columns)] (map conName derives)
  let typeCon = toTypeCon typeName'
  ins <- [d| instance PersistableWidth $typeCon where
               persistableWidth = unsafePersistableRecordWidth $(integralE $ length columns)

           |]
  return $ rec : ins

-- | Generate column name from 'String'.
columnDefault :: String -> TypeQ -> (VarName, TypeQ)
columnDefault n t = (varCamelcaseName n, t)

-- | Record type declaration template from SQL table name 'String'
--   and column name 'String' - type pairs, derivings.
defineRecordTypeDefault :: String -> [(String, TypeQ)] -> [ConName] -> Q [Dec]
defineRecordTypeDefault table columns =
  defineRecordType
  (recordTypeNameDefault table)
  [ columnDefault n t | (n, t) <- columns ]


-- | Record construction function template.
defineRecordConstructFunction :: TypeQ     -- ^ SQL value type.
                              -> VarName   -- ^ Name of record construct function.
                              -> ConName   -- ^ Name of record type.
                              -> Int       -- ^ Count of record columns.
                              -> Q [Dec]   -- ^ Declaration of record construct function from SQL values.
defineRecordConstructFunction sqlValType funName' typeName' width = do
  let funName = varName funName'
      typeName = conName typeName'
      names = map (mkName . ('f':) . show) [1 .. width]
      fromSqlE n = [| fromSql $(varE n) |]
  sig <- sigD funName [t| [$(sqlValType)] -> $(conT typeName) |]
  var <- funD funName
         [ clause
           [listP (map varP names)]
           (normalB . appsE $ conE typeName : map fromSqlE names)
           [],
           clause [wildP]
           (normalB
            [| error
               $(stringE
                 $ "Generated code of 'defineRecordConstructFunction': Fail to pattern match in: "
                 ++ show funName
                 ++ ", count of columns is " ++ show width) |])
           [] ]
  return [sig, var]

-- | Record decomposition function template.
defineRecordDecomposeFunction :: TypeQ   -- ^ SQL value type.
                              -> VarName -- ^ Name of record decompose function.
                              -> ConName -- ^ Name of record type.
                              -> Int     -- ^ Count of record columns.
                              -> Q [Dec] -- ^ Declaration of record construct function from SQL values.
defineRecordDecomposeFunction sqlValType funName' typeName' width = do
  let funName = varName funName'
      typeCon = toTypeCon typeName'
  sig <- sigD funName [t| $typeCon -> [$(sqlValType)] |]
  let typeName = conName typeName'
      names = map (mkName . ('f':) . show) [1 .. width]
  var <- funD funName [ clause [conP typeName [ varP n | n <- names ] ]
                        (normalB . listE $ [ [| toSql $(varE n) |] | n <- names ])
                        [] ]
  return [sig, var]

-- | Instance templates for converting between list of SQL type and Haskell record type.
definePersistableInstance :: TypeQ   -- ^ SQL value type
                          -> TypeQ   -- ^ Record type
                          -> VarName -- ^ Construct function name
                          -> VarName -- ^ Decompose function name
                          -> Int     -- ^ Record width
                          -> Q [Dec] -- ^ Instance declarations for 'Persistable'
definePersistableInstance sqlType typeCon consFunName' decompFunName' width = do
  [d| instance Persistable $sqlType $typeCon where
        persistable = persistableRecord
                      persistableWidth
                      $(toVarExp consFunName')
                      $(toVarExp decompFunName')

      instance FromSql $sqlType $typeCon where
        recordFromSql = recordFromSql'

      instance ToSql $sqlType $typeCon where
        recordToSql = recordToSql'
    |]

-- | All templates depending on SQL value type.
defineRecordWithSqlType :: TypeQ              -- ^ SQL value type
                        -> (VarName, VarName) -- ^ Constructor function name and decompose function name
                        -> ConName            -- ^ Record type name
                        -> Int                -- ^ Record width
                        -> Q [Dec]            -- ^ Result declarations
defineRecordWithSqlType
  sqlValueType
  (cF, dF) tyC
  width = do
  let typeCon = toTypeCon tyC
  fromSQL  <- defineRecordConstructFunction sqlValueType cF tyC width
  toSQL    <- defineRecordDecomposeFunction sqlValueType dF tyC width
  instSQL  <- definePersistableInstance sqlValueType typeCon cF dF width
  return $ fromSQL ++ toSQL ++ instSQL

-- | Default name of record construction function from SQL table name.
fromSqlNameDefault :: String -> VarName
fromSqlNameDefault =  (`varNameWithPrefix` "fromSqlOf")

-- | Default name of record decomposition function from SQL table name.
toSqlNameDefault :: String -> VarName
toSqlNameDefault =  (`varNameWithPrefix` "toSqlOf")

-- | All templates depending on SQL value type with default names.
defineRecordWithSqlTypeDefault :: TypeQ             -- ^ SQL value type
                               -> String            -- ^ Table name of database
                               -> [(String, TypeQ)] -- ^ Column names and types
                               -> Q [Dec]           -- ^ Result declarations
defineRecordWithSqlTypeDefault sqlValueType table columns = do
  defineRecordWithSqlType
    sqlValueType
    (fromSqlNameDefault table, toSqlNameDefault table)
    (recordTypeNameDefault table)
    (length columns)

recordInfo :: Info -> Maybe [VarStrictType]
recordInfo =  d  where
  d (TyConI (DataD _cxt _n _bs [RecC _dn vs] _ds)) = Just vs
  d _                                              = Nothing

-- | All templates depending on SQL value type. Defined record type information is used.
defineRecordWithSqlTypeFromDefined :: TypeQ              -- ^ SQL value type
                                   -> (VarName, VarName) -- ^ Constructor function name and decompose function name
                                   -> ConName            -- ^ Record type constructor name
                                   -> Q [Dec]            -- ^ Result declarations
defineRecordWithSqlTypeFromDefined sqlValueType fnames recTypeName' = do
  let recTypeName = conName recTypeName'
  tyConInfo <- reify recTypeName
  vs        <- maybe
               (compileError $ "Defined record type constructor not found: " ++ show recTypeName)
               return
               (recordInfo tyConInfo)
  defineRecordWithSqlType sqlValueType fnames recTypeName' (length vs)

-- | All templates depending on SQL value type with default names. Defined record type information is used.
defineRecordWithSqlTypeDefaultFromDefined :: TypeQ   -- ^ SQL value type
                                          -> String  -- ^ Table name of database
                                          -> Q [Dec] -- ^ Result declarations
defineRecordWithSqlTypeDefaultFromDefined sqlValueType table =
  defineRecordWithSqlTypeFromDefined sqlValueType
  (fromSqlNameDefault table, toSqlNameDefault table)
  (recordTypeNameDefault table)


-- | All templates for record type.
defineRecord :: TypeQ              -- ^ SQL value type
             -> (VarName, VarName) -- ^ Constructor function name and decompose function name
             -> ConName            -- ^ Record type name
             -> [(VarName, TypeQ)] -- ^ Column schema
             -> [ConName]          -- ^ Record derivings
             -> Q [Dec]            -- ^ Result declarations
defineRecord
  sqlValueType
  fnames tyC
  columns drvs = do

  typ     <- defineRecordType tyC columns drvs
  withSql <- defineRecordWithSqlType sqlValueType fnames tyC $ length columns
  return $ typ ++ withSql

-- | All templates for record type with default names.
defineRecordDefault :: TypeQ             -- ^ SQL value type
                    -> String            -- ^ Table name
                    -> [(String, TypeQ)] -- ^ Column names and types
                    -> [ConName]         -- ^ Record derivings
                    -> Q [Dec]           -- ^ Result declarations
defineRecordDefault sqlValueType table columns derives = do
  typ     <- defineRecordTypeDefault table columns derives
  withSql <- defineRecordWithSqlTypeDefault sqlValueType table columns
  return $ typ ++ withSql


-- | Templates for single column value type.
deriveNotNullType :: TypeQ -> Q [Dec]
deriveNotNullType typeCon =
  [d| instance PersistableWidth $typeCon where
        persistableWidth = Persistable.unsafeValueWidth

      instance HasColumnConstraint NotNull $typeCon where
        columnConstraint = unsafeSpecifyNotNullValue
    |]
