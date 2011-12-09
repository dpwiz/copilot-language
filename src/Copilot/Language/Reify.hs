--------------------------------------------------------------------------------
-- Copyright © 2011 National Institute of Aerospace / Galois, Inc.
--------------------------------------------------------------------------------

-- | Transforms a Copilot Language specification into a Copilot Core
-- specification.

{-# LANGUAGE ExistentialQuantification, Rank2Types #-}

module Copilot.Language.Reify
  ( reify
  ) where

import Copilot.Core (Typed, Type, Id, typeOf, impossible)
import qualified Copilot.Core as Core
--import Copilot.Language.Reify.Sharing (makeSharingExplicit)
import Copilot.Language.Analyze (analyze)
import Copilot.Language.Spec
import Copilot.Language.Stream (Stream (..), FunArg (..))
import Data.IORef
import Prelude hiding (id)
import System.Mem.StableName.Dynamic
import System.Mem.StableName.Dynamic.Map (Map)
import qualified System.Mem.StableName.Dynamic.Map as M

--------------------------------------------------------------------------------

reify :: Spec -> IO Core.Spec
reify spec =
  do
    analyze spec
    let trigs = triggers  $ runSpec spec
    let obsvs = observers $ runSpec spec
    refMkId      <- newIORef 0
    refVisited    <- newIORef M.empty
    refMap        <- newIORef []
    coreTriggers  <- mapM (mkTrigger  refMkId refVisited refMap) trigs
    coreObservers <- mapM (mkObserver refMkId refVisited refMap) obsvs
    coreStreams   <- readIORef refMap
    return $
      Core.Spec
        { Core.specStreams   = reverse coreStreams
        , Core.specObservers = coreObservers
        , Core.specTriggers  = coreTriggers }

--------------------------------------------------------------------------------

{-# INLINE mkObserver #-}
mkObserver
  :: IORef Int
  -> IORef (Map Core.Id)
  -> IORef [Core.Stream]
  -> Observer
  -> IO Core.Observer
mkObserver refMkId refStreams refMap (Observer name e) = do
    w <- mkExpr refMkId refStreams refMap e
    return $
      Core.Observer
         { Core.observerName     = name
         , Core.observerExpr     = w
         , Core.observerExprType = typeOf }

--------------------------------------------------------------------------------

{-# INLINE mkTrigger #-}
mkTrigger
  :: IORef Int
  -> IORef (Map Core.Id)
  -> IORef [Core.Stream]
  -> Trigger
  -> IO Core.Trigger
mkTrigger refMkId refStreams refMap (Trigger name guard args) = do
    w1 <- mkExpr refMkId refStreams refMap guard 
    args' <- mapM mkTriggerArg args
    return $
      Core.Trigger
        { Core.triggerName  = name
        , Core.triggerGuard = w1 
        , Core.triggerArgs  = args' }

  where

  mkTriggerArg :: TriggerArg -> IO Core.UExpr
  mkTriggerArg (TriggerArg e) = do
      w <- mkExpr refMkId refStreams refMap e
      return $ Core.UExpr typeOf w

--------------------------------------------------------------------------------

{-# INLINE mkExpr #-}
mkExpr
  :: Typed a
  => IORef Int
  -> IORef (Map Core.Id)
  -> IORef [Core.Stream]
  -> Stream a
  -> IO (Core.Expr a)
mkExpr refMkId refStreams refMap = go

--  (>>= go) . makeSharingExplicit refMkId

  where
  go :: Typed a => Stream a -> IO (Core.Expr a)
  go e0 =
    case e0 of

      ------------------------------------------------------

      Append _ _ _ -> do
        s <- mkStream refMkId refStreams refMap e0
        return $ Core.Drop typeOf 0 s

      ------------------------------------------------------

      Drop k e1 ->
        case e1 of
          Append _ _ _ -> do
              s <- mkStream refMkId refStreams refMap e1
              return $ Core.Drop typeOf (fromIntegral k) s
          _ -> impossible "mkExpr" "copilot-language"

      ------------------------------------------------------

      Const x -> return $ Core.Const typeOf x

      ------------------------------------------------------

      Local e f -> do
          id <- mkId refMkId
          let cs = "local_" ++ show id
          w1 <- go e
          w2 <- go (f (Var cs))
          return $ Core.Local typeOf typeOf cs w1 w2

      ------------------------------------------------------

      Var cs -> return $ Core.Var typeOf cs

      ------------------------------------------------------

      Extern cs -> return $ Core.ExternVar typeOf cs

      ------------------------------------------------------

      ExternFun cs args -> do
          args' <- mapM mkFunArg args
          return $ Core.ExternFun typeOf cs args' Nothing

      ------------------------------------------------------

      ExternArray cs e size -> do
          w <- go e
          return $ Core.ExternArray typeOf typeOf cs size w Nothing

      ------------------------------------------------------

      Op1 op e -> do
          w <- go e
          return $ Core.Op1 op w

      ------------------------------------------------------

      Op2 op e1 e2 -> do
          w1 <- go e1
          w2 <- go e2
          return $ Core.Op2 op w1 w2

      ------------------------------------------------------

      Op3 op e1 e2 e3 -> do
          w1 <- go e1
          w2 <- go e2
          w3 <- go e3
          return $ Core.Op3 op w1 w2 w3

      ------------------------------------------------------

  mkFunArg :: FunArg -> IO Core.UExpr
  mkFunArg (FunArg e) = do
      w <- mkExpr refMkId refStreams refMap e
      return $ Core.UExpr typeOf w

--------------------------------------------------------------------------------

{-# INLINE mkStream #-}
mkStream
  :: Typed a
  => IORef Int
  -> IORef (Map Core.Id)
  -> IORef [Core.Stream]
  -> Stream a
  -> IO Id
mkStream refMkId refStreams refMap e0 =
  do
    dstn <- makeDynStableName e0
    let Append buf _ e = e0 -- avoids warning
    mk <- haveVisited dstn
    case mk of
      Just id_ -> return id_
      Nothing  -> addToVisited dstn buf e

  where

  {-# INLINE haveVisited #-}
  haveVisited :: DynStableName -> IO (Maybe Int)
  haveVisited dstn =
    do
      tab <- readIORef refStreams
      return (M.lookup dstn tab)

  {-# INLINE addToVisited #-}
  addToVisited
    :: Typed a
    => DynStableName
    -> [a]
    -> Stream a
    -> IO Id
  addToVisited dstn buf e =
    do
      id <- mkId refMkId
      modifyIORef refStreams (M.insert dstn id)
      w <- mkExpr refMkId refStreams refMap e
      modifyIORef refMap $ (:)
        Core.Stream
          { Core.streamId         = id
          , Core.streamBuffer     = buf
          , Core.streamGuard      = Core.Const (typeOf :: Type Bool) True
          , Core.streamExpr       = w
          , Core.streamExprType   = typeOf }
      return id

--------------------------------------------------------------------------------

mkId :: IORef Int -> IO Id
mkId refMkId = atomicModifyIORef refMkId $ \ n -> (succ n, n)
