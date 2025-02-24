{-# LANGUAGE CPP                        #-}
{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE DeriveLift                 #-}
{-# LANGUAGE DerivingStrategies         #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE NamedFieldPuns             #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE StandaloneDeriving         #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE TypeApplications           #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE UndecidableInstances       #-}
{-|
  Module      : Auth.Biscuit.Datalog.AST
  Copyright   : © Clément Delafargue, 2021
  License     : MIT
  Maintainer  : clement@delafargue.name
  The Datalog elements
-}
module Auth.Biscuit.Datalog.AST
  (
    Binary (..)
  , Block
  , EvalBlock
  , Block' (..)
  , BlockElement' (..)
  , Check
  , EvalCheck
  , Check'
  , Expression
  , Expression' (..)
  , Fact
  , ToTerm (..)
  , FromValue (..)
  , Term
  , Term' (..)
  , IsWithinSet (..)
  , Op (..)
  , DatalogContext (..)
  , EvaluationContext (..)
  , Policy
  , EvalPolicy
  , Policy'
  , PolicyType (..)
  , Predicate
  , Predicate' (..)
  , PredicateOrFact (..)
  , QQTerm
  , Query
  , Query'
  , QueryItem' (..)
  , Rule
  , EvalRule
  , Rule' (..)
  , RuleScope' (..)
  , RuleScope
  , EvalRuleScope
  , SetType
  , Slice (..)
  , PkOrSlice (..)
  , SliceType
  , BlockIdType
  , Unary (..)
  , Value
  , VariableType
  , Authorizer
  , Authorizer' (..)
  , AuthorizerElement' (..)
  , ToEvaluation (..)
  , checkToEvaluation
  , policyToEvaluation
  , elementToBlock
  , elementToAuthorizer
  , fromStack
  , listSymbolsInBlock
  , listPublicKeysInBlock
  , queryHasNoScope
  , ruleHasNoScope
  , renderBlock
  , renderAuthorizer
  , renderFact
  , renderRule
  , toSetTerm
  , toStack
  ) where

import           Control.Applicative        ((<|>))
import           Control.Monad              ((<=<))
import           Data.ByteString            (ByteString)
import           Data.ByteString.Base16     as Hex
import           Data.Foldable              (fold)
import           Data.Map.Strict            (Map)
import qualified Data.Map.Strict            as Map
import           Data.Set                   (Set)
import qualified Data.Set                   as Set
import           Data.String                (IsString)
import           Data.Text                  (Text, intercalate, pack, unpack)
import           Data.Text.Encoding         (decodeUtf8)
import           Data.Time                  (UTCTime, defaultTimeLocale,
                                             formatTime)
import           Data.Void                  (Void, absurd)
import           Instances.TH.Lift          ()
import           Language.Haskell.TH
import           Language.Haskell.TH.Syntax
import           Numeric.Natural            (Natural)

import           Auth.Biscuit.Crypto        (PublicKey, pkBytes)

data IsWithinSet = NotWithinSet | WithinSet
data DatalogContext
  = WithSlices
  -- ^ Intermediate Datalog representation, which may contain references
  -- to external variables (currently, only sliced in through TemplateHaskell,
  -- but it could also be done at runtime, a bit like parameter substitution in
  -- SQL queries)
  | Representation
  -- ^ A datalog representation faithful to its text display. There are no external
  -- variables, and the authorized blocks are identified through their public keys

data EvaluationContext = Repr | Eval

data PredicateOrFact = InPredicate | InFact

type family VariableType (inSet :: IsWithinSet) (pof :: PredicateOrFact) where
  VariableType 'NotWithinSet 'InPredicate = Text
  VariableType inSet          pof         = Void

newtype Slice = Slice Text
  deriving newtype (Eq, Show, Ord, IsString)

instance Lift Slice where
  lift (Slice name) = [| toTerm $(varE $ mkName $ unpack name) |]
#if MIN_VERSION_template_haskell(2,17,0)
  liftTyped = liftCode . unsafeTExpCoerce . lift
#else
  liftTyped = unsafeTExpCoerce . lift
#endif

type family SliceType (ctx :: DatalogContext) where
  SliceType 'Representation = Void
  SliceType 'WithSlices     = Slice

data PkOrSlice
  = PkSlice Text
  | Pk PublicKey
  deriving (Eq, Show, Ord)

instance Lift PkOrSlice where
  lift (PkSlice name) = [| $(varE $ mkName $ unpack name) |]
  lift (Pk pk)        = [| pk |]
#if MIN_VERSION_template_haskell(2,17,0)
  liftTyped = liftCode . unsafeTExpCoerce . lift
#else
  liftTyped = unsafeTExpCoerce . lift
#endif

type family SetType (inSet :: IsWithinSet) (ctx :: DatalogContext) where
  SetType 'NotWithinSet ctx = Set (Term' 'WithinSet 'InFact ctx)
  SetType 'WithinSet    ctx = Void

type family BlockIdType (evalCtx :: EvaluationContext) (ctx :: DatalogContext) where
  BlockIdType 'Repr 'WithSlices     = PkOrSlice
  BlockIdType 'Repr 'Representation = PublicKey
  BlockIdType 'Eval 'Representation = (Set Natural, PublicKey)

-- | A single datalog item.
-- | This can be a value, a set of items, or a slice (a value that will be injected later),
-- | depending on the context
data Term' (inSet :: IsWithinSet) (pof :: PredicateOrFact) (ctx :: DatalogContext) =
    Variable (VariableType inSet pof)
  -- ^ A variable (eg. @$0@)
  | LInteger Int
  -- ^ An integer literal (eg. @42@)
  | LString Text
  -- ^ A string literal (eg. @"file1"@)
  | LDate UTCTime
  -- ^ A date literal (eg. @2021-05-26T18:00:00Z@)
  | LBytes ByteString
  -- ^ A hex literal (eg. @hex:ff9900@)
  | LBool Bool
  -- ^ A bool literal (eg. @true@)
  | Antiquote (SliceType ctx)
  -- ^ A slice (eg. @${name}@)
  | TermSet (SetType inSet ctx)
  -- ^ A set (eg. @[true, false]@)

deriving instance ( Eq (VariableType inSet pof)
                  , Eq (SliceType ctx)
                  , Eq (SetType inSet ctx)
                  ) => Eq (Term' inSet pof ctx)

deriving instance ( Ord (VariableType inSet pof)
                  , Ord (SliceType ctx)
                  , Ord (SetType inSet ctx)
                  ) => Ord (Term' inSet pof ctx)

deriving instance ( Show (VariableType inSet pof)
                  , Show (SliceType ctx)
                  , Show (SetType inSet ctx)
                  ) => Show (Term' inSet pof ctx)

-- | In a regular AST, slices have already been eliminated
type Term = Term' 'NotWithinSet 'InPredicate 'Representation
-- | In an AST parsed from a WithSlicesr, there might be references to haskell variables
type QQTerm = Term' 'NotWithinSet 'InPredicate 'WithSlices
-- | A term that is not a variable
type Value = Term' 'NotWithinSet 'InFact 'Representation
-- | An element of a set
type SetValue = Term' 'WithinSet 'InFact 'Representation

instance  ( Lift (VariableType inSet pof)
          , Lift (SetType inSet ctx)
          , Lift (SliceType ctx)
          )
         => Lift (Term' inSet pof ctx) where
  lift (Variable n)    = [| Variable n |]
  lift (LInteger i)    = [| LInteger i |]
  lift (LString s)     = [| LString s |]
  lift (LBytes bs)     = [| LBytes bs |]
  lift (LBool b)       = [| LBool  b |]
  lift (TermSet terms) = [| TermSet terms |]
  lift (LDate t)       = [| LDate (read $(lift $ show t)) |]
  lift (Antiquote s)   = [| s |]

#if MIN_VERSION_template_haskell(2,17,0)
  liftTyped = liftCode . unsafeTExpCoerce . lift
#else
  liftTyped = unsafeTExpCoerce . lift
#endif

-- | This class describes how to turn a haskell value into a datalog value.
-- | This is used when slicing a haskell variable in a datalog expression
class ToTerm t where
  -- | How to turn a value into a datalog item
  toTerm :: t -> Term' inSet pof 'Representation

-- | This class describes how to turn a datalog value into a regular haskell value.
class FromValue t where
  fromValue :: Value -> Maybe t

instance ToTerm Int where
  toTerm = LInteger

instance FromValue Int where
  fromValue (LInteger v) = Just v
  fromValue _            = Nothing

instance ToTerm Integer where
  toTerm = LInteger . fromIntegral

instance FromValue Integer where
  fromValue (LInteger v) = Just (fromIntegral v)
  fromValue _            = Nothing

instance ToTerm Text where
  toTerm = LString

instance FromValue Text where
  fromValue (LString t) = Just t
  fromValue _           = Nothing

instance ToTerm Bool where
  toTerm = LBool

instance FromValue Bool where
  fromValue (LBool b) = Just b
  fromValue _         = Nothing

instance ToTerm ByteString where
  toTerm = LBytes

instance FromValue ByteString where
  fromValue (LBytes bs) = Just bs
  fromValue _           = Nothing

instance ToTerm UTCTime where
  toTerm = LDate

instance FromValue UTCTime where
  fromValue (LDate t) = Just t
  fromValue _         = Nothing

instance FromValue Value where
  fromValue = Just

toSetTerm :: Value
          -> Maybe (Term' 'WithinSet 'InFact 'Representation)
toSetTerm = \case
  LInteger i  -> Just $ LInteger i
  LString i   -> Just $ LString i
  LDate i     -> Just $ LDate i
  LBytes i    -> Just $ LBytes i
  LBool i     -> Just $ LBool i
  TermSet _   -> Nothing
  Variable v  -> absurd v
  Antiquote v -> absurd v

renderId' :: (VariableType inSet pof -> Text)
          -> (SetType inSet ctx -> Text)
          -> (SliceType ctx -> Text)
          -> Term' inSet pof ctx -> Text
renderId' var set slice = \case
  Variable name -> var name
  LInteger int  -> pack $ show int
  LString str   -> pack $ show str
  LDate time    -> pack $ formatTime defaultTimeLocale "%FT%T%Q%EZ" time
  LBytes bs     -> "hex:" <> decodeUtf8 (Hex.encode bs)
  LBool True    -> "true"
  LBool False   -> "false"
  TermSet terms -> set terms -- "[" <> intercalate "," (renderInnerId <$> Set.toList terms) <> "]"
  Antiquote v   -> slice v

renderSet :: (SliceType ctx -> Text)
          -> Set (Term' 'WithinSet 'InFact ctx)
          -> Text
renderSet slice terms =
  "[" <> intercalate "," (renderId' absurd absurd slice <$> Set.toList terms) <> "]"

renderId :: Term -> Text
renderId = renderId' ("$" <>) (renderSet absurd) absurd

renderFactId :: Term' 'NotWithinSet 'InFact 'Representation -> Text
renderFactId = renderId' absurd (renderSet absurd) absurd

listSymbolsInTerm :: Term -> Set.Set Text
listSymbolsInTerm = \case
  LString  v    -> Set.singleton v
  Variable name -> Set.singleton name
  TermSet terms -> foldMap listSymbolsInSetValue terms
  Antiquote v   -> absurd v
  _             -> mempty

listSymbolsInValue :: Value -> Set.Set Text
listSymbolsInValue = \case
  LString  v    -> Set.singleton v
  TermSet terms -> foldMap listSymbolsInSetValue terms
  Variable  v   -> absurd v
  Antiquote v   -> absurd v
  _             -> mempty

listSymbolsInSetValue :: SetValue -> Set.Set Text
listSymbolsInSetValue = \case
  LString  v  -> Set.singleton v
  TermSet   v -> absurd v
  Variable  v -> absurd v
  Antiquote v -> absurd v
  _           -> mempty

data Predicate' (pof :: PredicateOrFact) (ctx :: DatalogContext) = Predicate
  { name  :: Text
  , terms :: [Term' 'NotWithinSet pof ctx]
  }

deriving instance ( Eq (Term' 'NotWithinSet pof ctx)
                  ) => Eq (Predicate' pof ctx)
deriving instance ( Ord (Term' 'NotWithinSet pof ctx)
                  ) => Ord (Predicate' pof ctx)
deriving instance ( Show (Term' 'NotWithinSet pof ctx)
                  ) => Show (Predicate' pof ctx)

deriving instance Lift (Term' 'NotWithinSet pof ctx) => Lift (Predicate' pof ctx)

type Predicate = Predicate' 'InPredicate 'Representation
type Fact = Predicate' 'InFact 'Representation

renderPredicate :: Predicate -> Text
renderPredicate Predicate{name,terms} =
  name <> "(" <> intercalate ", " (fmap renderId terms) <> ")"

renderFact :: Fact -> Text
renderFact Predicate{name,terms} =
  name <> "(" <> intercalate ", " (fmap renderFactId terms) <> ")"

listSymbolsInFact :: Fact -> Set.Set Text
listSymbolsInFact Predicate{..} =
     Set.singleton name
  <> foldMap listSymbolsInValue terms

listSymbolsInPredicate :: Predicate -> Set.Set Text
listSymbolsInPredicate Predicate{..} =
     Set.singleton name
  <> foldMap listSymbolsInTerm terms

data QueryItem' evalCtx ctx = QueryItem
  { qBody        :: [Predicate' 'InPredicate ctx]
  , qExpressions :: [Expression' ctx]
  , qScope       :: Set (RuleScope' evalCtx ctx)
  }

type Query' evalCtx ctx = [QueryItem' evalCtx ctx]
type Query = Query' 'Repr 'Representation

queryHasNoScope :: Query -> Bool
queryHasNoScope = all (Set.null . qScope)

type Check' evalCtx ctx = Query' evalCtx ctx
type Check = Check' 'Repr 'Representation
type EvalCheck = Check' 'Eval 'Representation
data PolicyType = Allow | Deny
  deriving (Eq, Show, Ord, Lift)
type Policy' evalCtx ctx = (PolicyType, Query' evalCtx ctx)
type Policy = Policy' 'Repr 'Representation
type EvalPolicy = Policy' 'Eval 'Representation

deriving instance ( Eq (Predicate' 'InPredicate ctx)
                  , Eq (Expression' ctx)
                  , Eq (RuleScope' evalCtx ctx)
                  ) => Eq (QueryItem' evalCtx ctx)
deriving instance ( Ord (Predicate' 'InPredicate ctx)
                  , Ord (Expression' ctx)
                  , Ord (RuleScope' evalCtx ctx)
                  ) => Ord (QueryItem' evalCtx ctx)
deriving instance ( Show (Predicate' 'InPredicate ctx)
                  , Show (Expression' ctx)
                  , Show (RuleScope' evalCtx ctx)
                  ) => Show (QueryItem' evalCtx ctx)
deriving instance ( Lift (Predicate' 'InPredicate ctx)
                  , Lift (Expression' ctx)
                  , Lift (RuleScope' evalCtx ctx)
                  ) => Lift (QueryItem' evalCtx ctx)

renderPolicy :: Policy -> Text
renderPolicy (pType, query) =
  let prefix = case pType of
        Allow -> "allow if "
        Deny  -> "deny if "
   in prefix <> intercalate " or \n" (renderQueryItem <$> query) <> ";"

renderQueryItem :: QueryItem' 'Repr 'Representation -> Text
renderQueryItem QueryItem{..} =
  intercalate ",\n" (fold
    [ renderPredicate <$> qBody
    , renderExpression <$> qExpressions
    ])
  <> if null qScope then ""
                   else " trusting " <> renderRuleScope qScope

renderCheck :: Check -> Text
renderCheck is = "check if " <>
  intercalate "\n or " (renderQueryItem <$> is)

listSymbolsInQueryItem :: QueryItem' evalCtx 'Representation -> Set.Set Text
listSymbolsInQueryItem QueryItem{..} =
     Set.singleton "query" -- query items are serialized as `Rule`s
                           -- so an empty rule head is added: `query()`
                           -- It means that query items implicitly depend on
                           -- the `query` symbol being defined.
  <> foldMap listSymbolsInPredicate qBody
  <> foldMap listSymbolsInExpression qExpressions

listSymbolsInCheck :: Check -> Set.Set Text
listSymbolsInCheck =
  foldMap listSymbolsInQueryItem

listPublicKeysInQueryItem :: QueryItem' 'Repr 'Representation -> Set.Set PublicKey
listPublicKeysInQueryItem QueryItem{qScope} =
  listPublicKeysInScope qScope

listPublicKeysInCheck :: Check -> Set.Set PublicKey
listPublicKeysInCheck = foldMap listPublicKeysInQueryItem


type RuleScope = RuleScope' 'Repr 'Representation
type EvalRuleScope = RuleScope' 'Eval 'Representation

data RuleScope' (evalCtx :: EvaluationContext) (ctx :: DatalogContext) =
    OnlyAuthority
  | Previous
  | BlockId (BlockIdType evalCtx ctx)

deriving instance Eq (BlockIdType evalCtx ctx) => Eq (RuleScope' evalCtx ctx)
deriving instance Ord (BlockIdType evalCtx ctx) => Ord (RuleScope' evalCtx ctx)
deriving instance Show (BlockIdType evalCtx ctx) => Show (RuleScope' evalCtx ctx)
deriving instance Lift (BlockIdType evalCtx ctx) => Lift (RuleScope' evalCtx ctx)

listPublicKeysInScope :: Set.Set RuleScope -> Set.Set PublicKey
listPublicKeysInScope = foldMap $
  \case BlockId pk -> Set.singleton pk
        _          -> Set.empty


data Rule' evalCtx ctx = Rule
  { rhead       :: Predicate' 'InPredicate ctx
  , body        :: [Predicate' 'InPredicate ctx]
  , expressions :: [Expression' ctx]
  , scope       :: Set (RuleScope' evalCtx ctx)
  }

deriving instance ( Eq (Predicate' 'InPredicate ctx)
                  , Eq (Expression' ctx)
                  , Eq (RuleScope' evalCtx ctx)
                  ) => Eq (Rule' evalCtx ctx)
deriving instance ( Ord (Predicate' 'InPredicate ctx)
                  , Ord (Expression' ctx)
                  , Ord (RuleScope' evalCtx ctx)
                  ) => Ord (Rule' evalCtx ctx)
deriving instance ( Show (Predicate' 'InPredicate ctx)
                  , Show (Expression' ctx)
                  , Show (RuleScope' evalCtx ctx)
                  ) => Show (Rule' evalCtx ctx)
deriving instance ( Lift (Predicate' 'InPredicate ctx)
                  , Lift (Expression' ctx)
                  , Lift (RuleScope' evalCtx ctx)
                  ) => Lift (Rule' evalCtx ctx)

type Rule = Rule' 'Repr 'Representation
type EvalRule = Rule' 'Eval 'Representation

ruleHasNoScope :: Rule -> Bool
ruleHasNoScope Rule{scope} = Set.null scope

renderRule :: Rule -> Text
renderRule Rule{rhead,body,expressions,scope} =
     renderPredicate rhead <> " <- "
  <> intercalate ", " (fmap renderPredicate body <> fmap renderExpression expressions)
  <> if null scope then ""
                   else " trusting " <> renderRuleScope scope

listSymbolsInRule :: Rule -> Set.Set Text
listSymbolsInRule Rule{..} =
     listSymbolsInPredicate rhead
  <> foldMap listSymbolsInPredicate body
  <> foldMap listSymbolsInExpression expressions

listPublicKeysInRule :: Rule -> Set.Set PublicKey
listPublicKeysInRule Rule{scope} = listPublicKeysInScope scope

data Unary =
    Negate
  | Parens
  | Length
  deriving (Eq, Ord, Show, Lift)

data Binary =
    LessThan
  | GreaterThan
  | LessOrEqual
  | GreaterOrEqual
  | Equal
  | Contains
  | Prefix
  | Suffix
  | Regex
  | Add
  | Sub
  | Mul
  | Div
  | And
  | Or
  | Intersection
  | Union
  deriving (Eq, Ord, Show, Lift)

data Expression' (ctx :: DatalogContext) =
    EValue (Term' 'NotWithinSet 'InPredicate ctx)
  | EUnary Unary (Expression' ctx)
  | EBinary Binary (Expression' ctx) (Expression' ctx)

deriving instance Eq   (Term' 'NotWithinSet 'InPredicate ctx) => Eq (Expression' ctx)
deriving instance Ord  (Term' 'NotWithinSet 'InPredicate ctx) => Ord (Expression' ctx)
deriving instance Lift (Term' 'NotWithinSet 'InPredicate ctx) => Lift (Expression' ctx)
deriving instance Show (Term' 'NotWithinSet 'InPredicate ctx) => Show (Expression' ctx)

type Expression = Expression' 'Representation

listSymbolsInExpression :: Expression -> Set.Set Text
listSymbolsInExpression = \case
  EValue t       -> listSymbolsInTerm t
  EUnary _ e     -> listSymbolsInExpression e
  EBinary _ e e' -> foldMap listSymbolsInExpression [e, e']

data Op =
    VOp Term
  | UOp Unary
  | BOp Binary

fromStack :: [Op] -> Either String Expression
fromStack =
  let go stack []                    = Right stack
      go stack        (VOp t : rest) = go (EValue t : stack) rest
      go (e:stack)    (UOp o : rest) = go (EUnary o e : stack) rest
      go []           (UOp _ : _)    = Left "Empty stack on unary op"
      go (e:e':stack) (BOp o : rest) = go (EBinary o e' e : stack) rest
      go [_]          (BOp _ : _)    = Left "Unary stack on binary op"
      go []           (BOp _ : _)    = Left "Empty stack on binary op"
      final []  = Left "Empty stack"
      final [x] = Right x
      final _   = Left "Stack containing more than one element"
   in final <=< go []

toStack :: Expression -> [Op]
toStack expr =
  let go e s = case e of
        EValue t      -> VOp t : s
        EUnary o i    -> go i $ UOp o : s
        EBinary o l r -> go l $ go r $ BOp o : s
   in go expr []

renderExpression :: Expression -> Text
renderExpression =
  let rOp t e e' = renderExpression e
                <> " " <> t <> " "
                <> renderExpression e'
      rm m e e' = renderExpression e
               <> "." <> m <> "("
               <> renderExpression e'
               <> ")"
   in \case
        EValue t                    -> renderId t
        EUnary Negate e             -> "!" <> renderExpression e
        EUnary Parens e             -> "(" <> renderExpression e <> ")"
        EUnary Length e             -> renderExpression e <> ".length()"
        EBinary LessThan e e'       -> rOp "<" e e'
        EBinary GreaterThan e e'    -> rOp ">" e e'
        EBinary LessOrEqual e e'    -> rOp "<=" e e'
        EBinary GreaterOrEqual e e' -> rOp ">=" e e'
        EBinary Equal e e'          -> rOp "==" e e'
        EBinary Contains e e'       -> rm "contains" e e'
        EBinary Prefix e e'         -> rm "starts_with" e e'
        EBinary Suffix e e'         -> rm "ends_with" e e'
        EBinary Regex e e'          -> rm "matches" e e'
        EBinary Intersection e e'   -> rm "intersection" e e'
        EBinary Union e e'          -> rm "union" e e'
        EBinary Add e e'            -> rOp "+" e e'
        EBinary Sub e e'            -> rOp "-" e e'
        EBinary Mul e e'            -> rOp "*" e e'
        EBinary Div e e'            -> rOp "/" e e'
        EBinary And e e'            -> rOp "&&" e e'
        EBinary Or e e'             -> rOp "||" e e'

-- | A biscuit block, containing facts, rules and checks.
--
-- 'Block' has a 'Monoid' instance, which is the expected way
-- to build composite blocks (eg if you need to generate a list of facts):
--
-- > -- build a block from multiple variables v1, v2, v3
-- > [block| value(${v1}); |] <>
-- > [block| value(${v2}); |] <>
-- > [block| value(${v3}); |]
type Block = Block' 'Repr 'Representation
type EvalBlock = Block' 'Eval 'Representation

-- | A biscuit block, that may or may not contain slices referencing
-- haskell variables
data Block' (evalCtx :: EvaluationContext) (ctx :: DatalogContext) = Block
  { bRules   :: [Rule' evalCtx ctx]
  , bFacts   :: [Predicate' 'InFact ctx]
  , bChecks  :: [Check' evalCtx ctx]
  , bContext :: Maybe Text
  , bScope   :: Set (RuleScope' evalCtx ctx)
  }

deriving instance ( Eq (Predicate' 'InFact ctx)
                  , Eq (Rule' evalCtx ctx)
                  , Eq (QueryItem' evalCtx ctx)
                  , Eq (RuleScope' evalCtx ctx)
                  ) => Eq (Block' evalCtx ctx)
deriving instance ( Lift (Predicate' 'InFact ctx)
                  , Lift (Rule' evalCtx ctx)
                  , Lift (QueryItem' evalCtx ctx)
                  , Lift (RuleScope' evalCtx ctx)
                  ) => Lift (Block' evalCtx ctx)

instance Show Block where
  show = unpack . renderBlock

instance Semigroup (Block' evalCtx ctx) where
  b1 <> b2 = Block { bRules = bRules b1 <> bRules b2
                   , bFacts = bFacts b1 <> bFacts b2
                   , bChecks = bChecks b1 <> bChecks b2
                   , bContext = bContext b2 <|> bContext b1
                   -- `trusting` declarations in blocks override
                   -- each other, they don't accumulate
                   , bScope = if null (bScope b1)
                              then bScope b2
                              else bScope b1
                   }

instance Monoid (Block' evalCtx ctx) where
  mempty = Block { bRules = []
                 , bFacts = []
                 , bChecks = []
                 , bContext = Nothing
                 , bScope = Set.empty
                 }

renderRuleScope :: Set RuleScope -> Text
renderRuleScope =
  let renderScopeElem = \case
        OnlyAuthority -> "authority"
        Previous      -> "previous"
        BlockId bs    -> "ed25519/hex:" <> decodeUtf8 (Hex.encode $ pkBytes bs)
   in intercalate ", " . Set.toList . Set.map renderScopeElem

renderBlock :: Block -> Text
renderBlock Block{..} =
  let renderScopeLine = ("trusting " <>) . renderRuleScope
   in foldMap (<> ";\n") $ fold
         [ [renderScopeLine bScope | not (null bScope)]
         , renderRule <$> bRules
         , renderFact <$> bFacts
         , renderCheck <$> bChecks
         ]

listSymbolsInBlock :: Block -> Set.Set Text
listSymbolsInBlock Block {..} = fold
  [ foldMap listSymbolsInRule bRules
  , foldMap listSymbolsInFact bFacts
  , foldMap listSymbolsInCheck bChecks
  ]

listPublicKeysInBlock :: Block -> Set.Set PublicKey
listPublicKeysInBlock Block{..} = fold
  [ foldMap listPublicKeysInRule bRules
  , foldMap listPublicKeysInCheck bChecks
  , listPublicKeysInScope bScope
  ]

-- | A biscuit authorizer, containing, facts, rules, checks and policies
type Authorizer = Authorizer' 'Repr 'Representation

-- | The context in which a biscuit policies and checks are verified.
-- A authorizer may add policies (`deny if` / `allow if` conditions), as well as rules, facts, and checks.
-- A authorizer may or may not contain slices referencing haskell variables.
data Authorizer' (evalCtx :: EvaluationContext) (ctx :: DatalogContext) = Authorizer
  { vPolicies :: [Policy' evalCtx ctx]
  -- ^ the allow / deny policies.
  , vBlock    :: Block' evalCtx ctx
  -- ^ the facts, rules and checks
  }

instance Semigroup (Authorizer' evalCtx ctx) where
  v1 <> v2 = Authorizer { vPolicies = vPolicies v1 <> vPolicies v2
                      , vBlock = vBlock v1 <> vBlock v2
                      }

instance Monoid (Authorizer' evalCtx ctx) where
  mempty = Authorizer { vPolicies = []
                    , vBlock = mempty
                    }

deriving instance ( Eq (Block' evalCtx ctx)
                  , Eq (QueryItem' evalCtx ctx)
                  ) => Eq (Authorizer' evalCtx ctx)

deriving instance ( Show (Block' evalCtx ctx)
                  , Show (QueryItem' evalCtx ctx)
                  ) => Show (Authorizer' evalCtx ctx)

deriving instance ( Lift (Block' evalCtx ctx)
                  , Lift (QueryItem' evalCtx ctx)
                  ) => Lift (Authorizer' evalCtx ctx)

renderAuthorizer :: Authorizer -> Text
renderAuthorizer Authorizer{..} =
  renderBlock vBlock <> "\n" <>
  intercalate "\n" (renderPolicy <$> vPolicies)

data BlockElement' evalCtx ctx
  = BlockFact (Predicate' 'InFact ctx)
  | BlockRule (Rule' evalCtx ctx)
  | BlockCheck (Check' evalCtx ctx)
  | BlockComment

deriving instance ( Show (Predicate' 'InFact ctx)
                  , Show (Rule' evalCtx ctx)
                  , Show (QueryItem' evalCtx ctx)
                  ) => Show (BlockElement' evalCtx ctx)

elementToBlock :: BlockElement' evalCtx ctx -> Block' evalCtx ctx
elementToBlock = \case
   BlockRule r  -> Block [r] [] [] Nothing Set.empty
   BlockFact f  -> Block [] [f] [] Nothing Set.empty
   BlockCheck c -> Block [] [] [c] Nothing Set.empty
   BlockComment -> mempty

data AuthorizerElement' evalCtx ctx
  = AuthorizerPolicy (Policy' evalCtx ctx)
  | BlockElement (BlockElement' evalCtx ctx)

deriving instance ( Show (Predicate' 'InFact ctx)
                  , Show (Rule' evalCtx ctx)
                  , Show (QueryItem' evalCtx ctx)
                  ) => Show (AuthorizerElement' evalCtx ctx)

elementToAuthorizer :: AuthorizerElement' evalCtx ctx -> Authorizer' evalCtx ctx
elementToAuthorizer = \case
  AuthorizerPolicy p -> Authorizer [p] mempty
  BlockElement be    -> Authorizer [] (elementToBlock be)

class ToEvaluation elem where
  toEvaluation :: [Maybe PublicKey] -> elem 'Repr 'Representation -> elem 'Eval 'Representation
  toRepresentation :: elem 'Eval 'Representation -> elem 'Repr 'Representation

translateScope :: [Maybe PublicKey] -> Set RuleScope -> Set EvalRuleScope
translateScope ePks =
  let indexedPks :: Map PublicKey (Set Natural)
      indexedPks =
        let makeEntry (Just bPk, bId) = [(bPk, Set.singleton bId)]
            makeEntry _               = []
         in Map.fromListWith (<>) $ foldMap makeEntry $ zip ePks [0..]
      translateElem = \case
        Previous      -> Previous
        OnlyAuthority -> OnlyAuthority
        BlockId bPk   -> BlockId (fold $ Map.lookup bPk indexedPks, bPk)
   in Set.map translateElem

renderBlockIds :: Set EvalRuleScope -> Set RuleScope
renderBlockIds =
  let renderElem = \case
        Previous         -> Previous
        OnlyAuthority    -> OnlyAuthority
        BlockId (_, ePk) -> BlockId ePk
   in Set.map renderElem

instance ToEvaluation Rule' where
  toEvaluation ePks r = r { scope = translateScope ePks $ scope r }
  toRepresentation r  = r { scope = renderBlockIds $ scope r }

instance ToEvaluation QueryItem' where
  toEvaluation ePks qi = qi{ qScope = translateScope ePks $ qScope qi}
  toRepresentation qi  = qi { qScope = renderBlockIds $ qScope qi}

instance ToEvaluation Block' where
  toEvaluation ePks b = b
    { bScope = translateScope ePks $ bScope b
    , bRules = toEvaluation ePks <$> bRules b
    , bChecks = checkToEvaluation ePks <$> bChecks b
    }
  toRepresentation b  = b
    { bScope = renderBlockIds $ bScope b
    , bRules = toRepresentation <$> bRules b
    , bChecks = fmap toRepresentation <$> bChecks b
    }

instance ToEvaluation Authorizer' where
  toEvaluation ePks a = a
    { vBlock = toEvaluation ePks (vBlock a)
    , vPolicies = policyToEvaluation ePks <$> vPolicies a
    }
  toRepresentation a = a
    { vBlock = toRepresentation (vBlock a)
    , vPolicies = fmap (fmap toRepresentation) <$> vPolicies a
    }

checkToEvaluation :: [Maybe PublicKey] -> Check -> EvalCheck
checkToEvaluation = fmap . toEvaluation

policyToEvaluation :: [Maybe PublicKey] -> Policy -> EvalPolicy
policyToEvaluation ePks = fmap (fmap (toEvaluation ePks))
