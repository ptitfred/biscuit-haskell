{-# LANGUAGE DerivingStrategies         #-}
{-# LANGUAGE DuplicateRecordFields      #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE NamedFieldPuns             #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE QuasiQuotes                #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE TupleSections              #-}
module Auth.Biscuit.Datalog.ScopedExecutor
  ( BlockWithRevocationId
  , runAuthorizer
  , runAuthorizerWithLimits
  , runAuthorizerNoTimeout
  , runFactGeneration
  , PureExecError (..)
  , AuthorizationSuccess (..)
  , getBindings
  , queryAuthorizerFacts
  , getVariableValues
  , getSingleVariableValue
  , FactGroup (..)
  ) where

import           Control.Monad                 (unless, when)
import           Control.Monad.State           (StateT (..), evalStateT, get,
                                                gets, lift, put)
import           Data.Bifunctor                (first)
import           Data.ByteString               (ByteString)
import           Data.Foldable                 (fold, traverse_)
import           Data.List                     (genericLength)
import           Data.List.NonEmpty            (NonEmpty)
import qualified Data.List.NonEmpty            as NE
import           Data.Map                      (Map)
import qualified Data.Map                      as Map
import           Data.Map.Strict               ((!?))
import           Data.Maybe                    (mapMaybe)
import           Data.Set                      (Set)
import qualified Data.Set                      as Set
import           Data.Text                     (Text)
import           Numeric.Natural               (Natural)
import           Validation                    (Validation (..))

import           Auth.Biscuit.Crypto           (PublicKey)
import           Auth.Biscuit.Datalog.AST
import           Auth.Biscuit.Datalog.Executor (Bindings, ExecutionError (..),
                                                FactGroup (..), Limits (..),
                                                MatchedQuery (..),
                                                ResultError (..), Scoped,
                                                checkCheck, checkPolicy,
                                                countFacts, defaultLimits,
                                                fromScopedFacts,
                                                getBindingsForRuleBody,
                                                getFactsForRule,
                                                keepAuthorized', toScopedFacts)
import           Auth.Biscuit.Datalog.Parser   (fact)
import           Auth.Biscuit.Timer            (timer)

type BlockWithRevocationId = (Block, ByteString, Maybe PublicKey)

-- | A subset of 'ExecutionError' that can only happen during fact generation
data PureExecError = Facts | Iterations | BadRule
  deriving (Eq, Show)

-- | Proof that a biscuit was authorized successfully. In addition to the matched
-- @allow query@, the generated facts are kept around for further querying.
-- Since only authority facts can be trusted, they are kept separate.
data AuthorizationSuccess
  = AuthorizationSuccess
  { matchedAllowQuery :: MatchedQuery
  -- ^ The allow query that matched
  , allFacts          :: FactGroup
  -- ^ All the facts that were generated by the biscuit, grouped by their origin
  , limits            :: Limits
  -- ^ Limits used when running datalog. It is kept around to allow further
  -- datalog computation when querying facts
  }
  deriving (Eq, Show)

-- | Get the matched variables from the @allow@ query used to authorize the biscuit.
-- This can be used in conjuction with 'getVariableValues' or 'getSingleVariableValue'
-- to extract the actual values
getBindings :: AuthorizationSuccess -> Set Bindings
getBindings AuthorizationSuccess{matchedAllowQuery=MatchedQuery{bindings}} = bindings

-- | Given a series of blocks and an authorizer, ensure that all
-- the checks and policies match
runAuthorizer :: BlockWithRevocationId
            -- ^ The authority block
            -> [BlockWithRevocationId]
            -- ^ The extra blocks
            -> Authorizer
            -- ^ A authorizer
            -> IO (Either ExecutionError AuthorizationSuccess)
runAuthorizer = runAuthorizerWithLimits defaultLimits

-- | Given a series of blocks and an authorizer, ensure that all
-- the checks and policies match, with provided execution
-- constraints
runAuthorizerWithLimits :: Limits
                      -- ^ custom limits
                      -> BlockWithRevocationId
                      -- ^ The authority block
                      -> [BlockWithRevocationId]
                      -- ^ The extra blocks
                      -> Authorizer
                      -- ^ A authorizer
                      -> IO (Either ExecutionError AuthorizationSuccess)
runAuthorizerWithLimits l@Limits{..} authority blocks v = do
  resultOrTimeout <- timer maxTime $ pure $ runAuthorizerNoTimeout l authority blocks v
  pure $ case resultOrTimeout of
    Nothing -> Left Timeout
    Just r  -> r


mkRevocationIdFacts :: BlockWithRevocationId -> [BlockWithRevocationId]
                    -> Set Fact
mkRevocationIdFacts authority blocks =
  let allIds :: [(Int, ByteString)]
      allIds = zip [0..] $ snd' <$> authority : blocks
      snd' (_,b,_) = b
      mkFact (index, rid) = [fact|revocation_id({index}, {rid})|]
   in Set.fromList $ mkFact <$> allIds

data ComputeState
  = ComputeState
  { sLimits     :: Limits -- readonly
  , sRules      :: Map Natural (Set EvalRule) -- readonly
  , sBlockCount :: Natural
  -- state
  , sIterations :: Int -- elapsed iterations
  , sFacts      :: FactGroup -- facts generated so far
  }
  deriving (Eq, Show)

mkInitState :: Limits -> BlockWithRevocationId -> [BlockWithRevocationId] -> Authorizer -> ComputeState
mkInitState limits authority blocks authorizer =
  let fst' (a,_,_) = a
      trd' (_,_,c) = c
      sBlockCount = 1 + genericLength blocks
      externalKeys = Nothing : (trd' <$> blocks)
      revocationWorld = (mempty, FactGroup $ Map.singleton (Set.singleton sBlockCount) $ mkRevocationIdFacts authority blocks)
      firstBlock = fst' authority
      otherBlocks = fst' <$> blocks
      allBlocks = zip [0..] (firstBlock : otherBlocks) <> [(sBlockCount, vBlock authorizer)]
      (sRules, sFacts) = revocationWorld <> fold (uncurry collectWorld . fmap (toEvaluation externalKeys) <$> allBlocks)
   in ComputeState
        { sLimits = limits
        , sRules
        , sBlockCount
        , sIterations = 0
        , sFacts
        }

runAuthorizerNoTimeout :: Limits
                       -> BlockWithRevocationId
                       -> [BlockWithRevocationId]
                       -> Authorizer
                       -> Either ExecutionError AuthorizationSuccess
runAuthorizerNoTimeout limits authority blocks authorizer = do
  let fst' (a,_,_) = a
      trd' (_,_,c) = c
      blockCount = 1 + genericLength blocks
      externalKeys = Nothing : (trd' <$> blocks)
      (<$$>) = fmap . fmap
      (<$$$>) = fmap . fmap . fmap
      initState = mkInitState limits authority blocks authorizer
      toExecutionError = \case
        Facts      -> TooManyFacts
        Iterations -> TooManyIterations
        BadRule    -> InvalidRule
  allFacts <- first toExecutionError $ computeAllFacts initState
  let checks = bChecks <$$> ( zip [0..] (fst' <$> authority : blocks)
                           <> [(blockCount,vBlock authorizer)]
                            )
      policies = vPolicies authorizer
      checkResults = checkChecks limits blockCount allFacts (checkToEvaluation externalKeys <$$$> checks)
      policyResults = checkPolicies limits blockCount allFacts (policyToEvaluation externalKeys <$> policies)
  case (checkResults, policyResults) of
    (Success (), Left Nothing)  -> Left $ ResultError $ NoPoliciesMatched []
    (Success (), Left (Just p)) -> Left $ ResultError $ DenyRuleMatched [] p
    (Failure cs, Left Nothing)  -> Left $ ResultError $ NoPoliciesMatched (NE.toList cs)
    (Failure cs, Left (Just p)) -> Left $ ResultError $ DenyRuleMatched (NE.toList cs) p
    (Failure cs, Right _)       -> Left $ ResultError $ FailedChecks cs
    (Success (), Right p)       -> Right $ AuthorizationSuccess { matchedAllowQuery = p
                                                                , allFacts
                                                                , limits
                                                                }

runStep :: StateT ComputeState (Either PureExecError) Int
runStep = do
  state@ComputeState{sLimits,sFacts,sRules,sBlockCount,sIterations} <- get
  let Limits{maxFacts, maxIterations} = sLimits
      previousCount = countFacts sFacts
      newFacts = sFacts <> extend sLimits sBlockCount sRules sFacts
      newCount = countFacts newFacts
      -- counting the facts returned by `extend` is not equivalent to
      -- comparing complete counts, as `extend` may return facts that
      -- are already present in `sFacts`
      addedFactsCount = newCount - previousCount
  when (newCount >= maxFacts) $ lift $ Left Facts
  when (sIterations >= maxIterations) $ lift $ Left Iterations
  put $ state { sIterations = sIterations + 1
              , sFacts = newFacts
              }
  return addedFactsCount

-- | Check if every variable from the head is present in the body
checkRuleHead :: EvalRule -> Bool
checkRuleHead Rule{rhead, body} =
  let headVars = extractVariables [rhead]
      bodyVars = extractVariables body
   in headVars `Set.isSubsetOf` bodyVars

-- | Repeatedly generate new facts until it converges (no new
-- facts are generated)
computeAllFacts :: ComputeState -> Either PureExecError FactGroup
computeAllFacts initState@ComputeState{sRules} = do
  let checkRules = all (all checkRuleHead) sRules
      go = do
        newFacts <- runStep
        if newFacts > 0 then go else gets sFacts

  unless checkRules $ Left BadRule
  evalStateT go initState

-- | Small helper used in tests to directly provide rules and facts without creating
-- a biscuit token
runFactGeneration :: Limits -> Natural -> Map Natural (Set EvalRule) -> FactGroup -> Either PureExecError FactGroup
runFactGeneration sLimits sBlockCount sRules sFacts =
  let initState = ComputeState{sIterations = 0, ..}
   in computeAllFacts initState

checkChecks :: Limits -> Natural -> FactGroup -> [(Natural, [EvalCheck])] -> Validation (NonEmpty Check) ()
checkChecks limits blockCount allFacts =
  traverse_ (uncurry $ checkChecksForGroup limits blockCount allFacts)

checkChecksForGroup :: Limits -> Natural -> FactGroup -> Natural -> [EvalCheck] -> Validation (NonEmpty Check) ()
checkChecksForGroup limits blockCount allFacts checksBlockId =
  traverse_ (checkCheck limits blockCount checksBlockId allFacts)

checkPolicies :: Limits -> Natural -> FactGroup -> [EvalPolicy] -> Either (Maybe MatchedQuery) MatchedQuery
checkPolicies limits blockCount allFacts policies =
  let results = mapMaybe (checkPolicy limits blockCount allFacts) policies
   in case results of
        p : _ -> first Just p
        []    -> Left Nothing

-- | Generate new facts by applying rules on existing facts
extend :: Limits -> Natural -> Map Natural (Set EvalRule) -> FactGroup -> FactGroup
extend l blockCount rules facts =
  let buildFacts :: Natural -> Set EvalRule -> FactGroup -> Set (Scoped Fact)
      buildFacts ruleBlockId ruleGroup factGroup =
        let extendRule :: EvalRule -> Set (Scoped Fact)
            extendRule r@Rule{scope} = getFactsForRule l (toScopedFacts $ keepAuthorized' False blockCount factGroup scope ruleBlockId) r
         in foldMap extendRule ruleGroup

      extendRuleGroup :: Natural -> Set EvalRule -> FactGroup
      extendRuleGroup ruleBlockId ruleGroup =
            -- todo pre-filter facts based on the weakest rule scope to avoid passing too many facts
            -- to buildFacts
        let authorizedFacts = facts -- test $ keepAuthorized facts $ Set.fromList [0..ruleBlockId]
            addRuleOrigin = FactGroup . Map.mapKeysWith (<>) (Set.insert ruleBlockId) . getFactGroup
         in addRuleOrigin . fromScopedFacts $ buildFacts ruleBlockId ruleGroup authorizedFacts

   in foldMap (uncurry extendRuleGroup) $ Map.toList rules


collectWorld :: Natural -> EvalBlock -> (Map Natural (Set EvalRule), FactGroup)
collectWorld blockId Block{..} =
  let -- a block can define a default scope for its rule
      -- which is used unless the rule itself has defined a scope
      applyScope r@Rule{scope} = r { scope = if null scope then bScope else scope }
   in ( Map.singleton blockId $ Set.map applyScope $ Set.fromList bRules
      , FactGroup $ Map.singleton (Set.singleton blockId) $ Set.fromList bFacts
      )

-- | Query the facts generated by the authority and authorizer blocks
-- during authorization. This can be used in conjuction with 'getVariableValues'
-- and 'getSingleVariableValue' to retrieve actual values.
--
-- ⚠ Only the facts generated by the authority and authorizer blocks are queried.
-- Block facts are not queried (since they can't be trusted).
--
-- 💁 If the facts you want to query are part of an allow query in the authorizer,
-- you can directly get values from 'AuthorizationSuccess'.
queryAuthorizerFacts :: AuthorizationSuccess -> Query -> Set Bindings
queryAuthorizerFacts AuthorizationSuccess{allFacts, limits} q =
  let authorityFacts = fold (Map.lookup (Set.singleton 0) $ getFactGroup allFacts)
      -- we've already ensured that we've kept only authority facts, we don't
      -- need to track their origin further
      getBindingsForQueryItem QueryItem{qBody,qExpressions} = Set.map snd $
        getBindingsForRuleBody limits (Set.map (mempty,) authorityFacts) qBody qExpressions
   in foldMap getBindingsForQueryItem q

-- | Extract a set of values from a matched variable for a specific type.
-- Returning @Set Value@ allows to get all values, whatever their type.
getVariableValues :: (Ord t, FromValue t)
                  => Set Bindings
                  -> Text
                  -> Set t
getVariableValues bindings variableName =
  let mapMaybeS f = foldMap (foldMap Set.singleton . f)
      getVar vars = fromValue =<< vars !? variableName
   in mapMaybeS getVar bindings

-- | Extract exactly one value from a matched variable. If the variable has 0
-- matches or more than one match, 'Nothing' will be returned
getSingleVariableValue :: (Ord t, FromValue t)
                       => Set Bindings
                       -> Text
                       -> Maybe t
getSingleVariableValue bindings variableName =
  let values = getVariableValues bindings variableName
   in case Set.toList values of
        [v] -> Just v
        _   -> Nothing
