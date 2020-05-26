{-# OPTIONS_GHC -Wall #-}
{-# LANGUAGE OverloadedStrings #-}
module ElmCompiler.Canonicalize.Environment
  ( Env(..)
  , Exposed
  , Qualified
  , Var(..)
  , Type(..)
  , Ctor(..)
  , addLocals
  , findType
  , findTypeQual
  , findCtor
  , findCtorQual
  , findBinop
  , Binop(..)
  )
  where


import qualified Data.Map.Merge.Strict as Map
import qualified Data.Map.Strict as Map
import qualified Data.Map.Strict.Internal as I
import qualified ElmCompiler.Data.Name as Name

import qualified ElmCompiler.AST.Utils.Binop as Binop
import qualified ElmCompiler.AST.Canonical as Can
import qualified ElmCompiler.Data.Index as Index
import qualified ElmCompiler.Elm.ModuleName as ModuleName
import qualified ElmCompiler.Reporting.Annotation as A
import qualified ElmCompiler.Reporting.Error.Canonicalize as Error
import qualified ElmCompiler.Reporting.Result as Result



-- RESULT


type Result i w a =
  Result.Result i w Error.Error a



-- ENVIRONMENT


data Env =
  Env
    { _home :: ModuleName.Canonical
    , _vars :: Map.Map Name.Name Var
    , _types :: Exposed Type
    , _ctors :: Exposed Ctor
    , _binops :: Exposed Binop
    , _q_vars :: Qualified Can.Annotation
    , _q_types :: Qualified Type
    , _q_ctors :: Qualified Ctor
    }


type Exposed a =
  Map.Map Name.Name (Map.Map ModuleName.Canonical a)


type Qualified a =
  Map.Map Name.Name (Map.Map Name.Name (Map.Map ModuleName.Canonical a))



-- VARIABLES


data Var
  = Local A.Region
  | TopLevel A.Region
  | Foreign (Map.Map ModuleName.Canonical Can.Annotation)



-- TYPES


data Type
  = Alias Int ModuleName.Canonical [Name.Name] Can.Type
  | Union Int ModuleName.Canonical



-- CTORS


data Ctor
  = RecordCtor ModuleName.Canonical [Name.Name] Can.Type
  | Ctor
      { _c_home :: ModuleName.Canonical
      , _c_type :: Name.Name
      , _c_union :: Can.Union
      , _c_index :: Index.ZeroBased
      , _c_args :: [Can.Type]
      }



-- BINOPS


data Binop =
  Binop
    { _op :: Name.Name
    , _op_home :: ModuleName.Canonical
    , _op_name :: Name.Name
    , _op_annotation :: Can.Annotation
    , _op_associativity :: Binop.Associativity
    , _op_precedence :: Binop.Precedence
    }



-- VARIABLE -- ADD LOCALS


addLocals :: Map.Map Name.Name A.Region -> Env -> Result i w Env
addLocals names (Env home vars ts cs bs qvs qts qcs) =
  do  newVars <-
        Map.mergeA
          (Map.mapMissing addLocalLeft)
          (Map.mapMissing (\_ homes -> homes))
          (Map.zipWithAMatched addLocalBoth)
          names
          vars

      Result.ok (Env home newVars ts cs bs qvs qts qcs)


addLocalLeft :: Name.Name -> A.Region -> Var
addLocalLeft _ region =
  Local region


addLocalBoth :: Name.Name -> A.Region -> Var -> Result i w Var
addLocalBoth name region var =
  case var of
    Foreign _ ->
      Result.ok (Local region)

    Local parentRegion ->
      Result.throw (Error.Shadowing name parentRegion region)

    TopLevel parentRegion ->
      Result.throw (Error.Shadowing name parentRegion region)



-- FIND TYPE


findType :: A.Region -> Env -> Name.Name -> Result i w Type
findType region (Env _ _ ts _ _ _ qts _) name =
  case Map.lookup name ts of
    Just (I.Bin 1 _ tipe _ _) ->
      Result.ok tipe

    Just homes ->
      Result.throw (Error.AmbiguousType region Nothing name (Map.keys homes))

    Nothing ->
      Result.throw (Error.NotFoundType region Nothing name (toPossibleNames ts qts))


findTypeQual :: A.Region -> Env -> Name.Name -> Name.Name -> Result i w Type
findTypeQual region (Env _ _ ts _ _ _ qts _) prefix name =
  case Map.lookup prefix qts of
    Just qualified ->
      case Map.lookup name qualified of
        Just (I.Bin 1 _ tipe _ _) ->
          Result.ok tipe

        Just homes ->
          Result.throw (Error.AmbiguousType region (Just prefix) name (Map.keys homes))

        Nothing ->
          Result.throw (Error.NotFoundType region (Just prefix) name (toPossibleNames ts qts))

    Nothing ->
      Result.throw (Error.NotFoundType region (Just prefix) name (toPossibleNames ts qts))



-- FIND CTOR


findCtor :: A.Region -> Env -> Name.Name -> Result i w Ctor
findCtor region (Env _ _ _ cs _ _ _ qcs) name =
  case Map.lookup name cs of
    Just (I.Bin 1 _ ctor _ _) ->
      Result.ok ctor

    Just homes ->
      Result.throw (Error.AmbiguousVariant region Nothing name (Map.keys homes))

    Nothing ->
      Result.throw (Error.NotFoundVariant region Nothing name (toPossibleNames cs qcs))


findCtorQual :: A.Region -> Env -> Name.Name -> Name.Name -> Result i w Ctor
findCtorQual region (Env _ _ _ cs _ _ _ qcs) prefix name =
  case Map.lookup prefix qcs of
    Just qualified ->
      case Map.lookup name qualified of
        Just (I.Bin 1 _ pattern _ _) ->
          Result.ok pattern

        Just homes ->
          Result.throw (Error.AmbiguousVariant region (Just prefix) name (Map.keys homes))

        Nothing ->
          Result.throw (Error.NotFoundVariant region (Just prefix) name (toPossibleNames cs qcs))

    Nothing ->
      Result.throw (Error.NotFoundVariant region (Just prefix) name (toPossibleNames cs qcs))



-- FIND BINOP


findBinop :: A.Region -> Env -> Name.Name -> Result i w Binop
findBinop region (Env _ _ _ _ binops _ _ _) name =
  case Map.lookup name binops of
    Just (I.Bin 1 _ binop _ _) ->
      Result.ok binop

    Just homes ->
      Result.throw (Error.AmbiguousBinop region name (Map.keys homes))

    Nothing ->
      Result.throw (Error.NotFoundBinop region name (Map.keysSet binops))



-- TO POSSIBLE NAMES


toPossibleNames :: Exposed a -> Qualified a -> Error.PossibleNames
toPossibleNames exposed qualified =
  Error.PossibleNames (Map.keysSet exposed) (Map.map Map.keysSet qualified)