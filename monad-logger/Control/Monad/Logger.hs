{-# LANGUAGE CPP #-}
#if WITH_TEMPLATE_HASKELL
{-# LANGUAGE TemplateHaskell #-}
#endif
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE FunctionalDependencies #-}
-- |  This module provides the facilities needed for a decoupled logging system.
--
-- The 'MonadLogger' class is implemented by monads that give access to a
-- logging facility.  If you're defining a custom monad, then you may define an
-- instance of 'MonadLogger' that routes the log messages to the appropriate
-- place (e.g., that's what @yesod-core@'s @GHandler@ does).  Otherwise, you
-- may use the 'LoggingT' monad included in this module (see
-- 'runStderrLoggingT'). To simply discard log message, use 'NoLoggingT'.
--
-- As a user of the logging facility, we provide you some convenient Template
-- Haskell splices that use the 'MonadLogger' class.  They will record their
-- source file and position, which is very helpful when debugging.  See
-- 'logDebug' for more information.
module Control.Monad.Logger
    ( -- * MonadLogger
      MonadLogger(..)
    , LogLevel(..)
    , LogSource
    -- * Helper transformer
    , LoggingT (..)
    , runStderrLoggingT
    , runStdoutLoggingT
    , withChannelLogger
    , NoLoggingT (..)
    , LoggerT (..)
    , UpgradeMessage (..)
    , mapLog
    , LogFunc
    , mapLoggingT
#if WITH_TEMPLATE_HASKELL
    -- * TH logging
    , logDebug
    , logInfo
    , logWarn
    , logError
    , logOther
    -- * TH logging with source
    , logDebugS
    , logInfoS
    , logWarnS
    , logErrorS
    , logOtherS
    -- * TH util
    , liftLoc
#endif
    -- * Non-TH logging
    , logDebugN
    , logInfoN
    , logWarnN
    , logErrorN
    , logOtherN
    -- * Non-TH logging with source
    , logDebugNS
    , logInfoNS
    , logWarnNS
    , logErrorNS
    , logOtherNS

    -- * utilities for defining your own loggers
    , defaultLogStr
    , Loc
    ) where

#if WITH_TEMPLATE_HASKELL
import Language.Haskell.TH.Syntax (Lift (lift), Q, Exp, Loc (..), qLocation)
#endif

import Data.Monoid (Monoid)

import Control.Applicative (Applicative (..))
import Control.Concurrent.STM
import Control.Concurrent.STM.TBChan
import Control.Exception.Lifted (onException)
import Control.Monad (liftM, ap, when, void)
import Control.Monad.Base (MonadBase (liftBase))
import Control.Monad.Loops (untilM)
import Control.Monad.Trans.Control (MonadBaseControl (..), MonadTransControl (..))
import qualified Control.Monad.Trans.Class as Trans

import Control.Monad.IO.Class (MonadIO (liftIO))
import Control.Monad.Trans.Resource (MonadResource (liftResourceT), MonadThrow, monadThrow)
#if MIN_VERSION_resourcet(1,1,0)
import Control.Monad.Trans.Resource (throwM)
import Control.Monad.Catch (MonadCatch (..)
#if MIN_VERSION_exceptions(0,6,0)
    , MonadMask (..)
#endif
    )
#endif

import Control.Monad.Trans.Identity ( IdentityT)
import Control.Monad.Trans.List     ( ListT    )
import Control.Monad.Trans.Maybe    ( MaybeT   )
import Control.Monad.Trans.Error    ( ErrorT, Error)
import Control.Monad.Trans.Reader   ( ReaderT  )
import Control.Monad.Trans.Cont     ( ContT  )
import Control.Monad.Trans.State    ( StateT   )
import Control.Monad.Trans.Writer   ( WriterT  )
import Control.Monad.Trans.RWS      ( RWST     )
import Control.Monad.Trans.Resource ( ResourceT)
import Data.Conduit.Internal        ( Pipe, ConduitM )

import qualified Control.Monad.Trans.RWS.Strict    as Strict ( RWST   )
import qualified Control.Monad.Trans.State.Strict  as Strict ( StateT )
import qualified Control.Monad.Trans.Writer.Strict as Strict ( WriterT )

import Data.Text (Text, pack, unpack)
import qualified Data.Text as T
import qualified Data.ByteString.Char8 as S8

import Data.Monoid (mappend, mempty)
import System.Log.FastLogger
import System.IO (Handle, stdout, stderr)

import Control.Monad.Cont.Class   ( MonadCont (..) )
import Control.Monad.Error.Class  ( MonadError (..) )
import Control.Monad.RWS.Class    ( MonadRWS )
import Control.Monad.Reader.Class ( MonadReader (..) )
import Control.Monad.State.Class  ( MonadState (..) )
import Control.Monad.Writer.Class ( MonadWriter (..) )

import Blaze.ByteString.Builder (toByteString)

import Prelude hiding (catch)

#if !MIN_VERSION_fast_logger(2, 1, 0) && MIN_VERSION_bytestring(0, 10, 2)
import qualified Data.ByteString.Lazy as L
import Data.ByteString.Builder (toLazyByteString)
#endif

#if MIN_VERSION_conduit_extra(1,1,0)
import Data.Conduit.Lazy (MonadActive, monadActive)
#endif

data LogLevel = LevelDebug | LevelInfo | LevelWarn | LevelError | LevelOther Text
    deriving (Eq, Prelude.Show, Prelude.Read, Ord)

type LogSource = Text

#if WITH_TEMPLATE_HASKELL

instance Lift LogLevel where
    lift LevelDebug = [|LevelDebug|]
    lift LevelInfo  = [|LevelInfo|]
    lift LevelWarn  = [|LevelWarn|]
    lift LevelError = [|LevelError|]
    lift (LevelOther x) = [|LevelOther $ pack $(lift $ unpack x)|]

#else

data Loc
  = Loc { loc_filename :: String
    , loc_package  :: String
    , loc_module   :: String
    , loc_start    :: CharPos
    , loc_end      :: CharPos }
type CharPos = (Int, Int)

#endif

class Monad m => MonadLogger msg m | m -> msg where
    monadLoggerLog :: LogFunc msg m


{-
instance MonadLogger IO          where monadLoggerLog _ _ _ = return ()
instance MonadLogger Identity    where monadLoggerLog _ _ _ = return ()
instance MonadLogger (ST s)      where monadLoggerLog _ _ _ = return ()
instance MonadLogger (Lazy.ST s) where monadLoggerLog _ _ _ = return ()
-}

#define DEF monadLoggerLog a b c d = Trans.lift $ monadLoggerLog a b c d
instance MonadLogger msg m => MonadLogger msg (IdentityT m) where DEF
instance MonadLogger msg m => MonadLogger msg (ListT m) where DEF
instance MonadLogger msg m => MonadLogger msg (MaybeT m) where DEF
instance (MonadLogger msg m, Error e) => MonadLogger msg (ErrorT e m) where DEF
instance MonadLogger msg m => MonadLogger msg (ReaderT r m) where DEF
instance MonadLogger msg m => MonadLogger msg (ContT r m) where DEF
instance MonadLogger msg m => MonadLogger msg (StateT s m) where DEF
instance (MonadLogger msg m, Monoid w) => MonadLogger msg (WriterT w m) where DEF
instance (MonadLogger msg m, Monoid w) => MonadLogger msg (RWST r w s m) where DEF
instance MonadLogger msg m => MonadLogger msg (ResourceT m) where DEF
instance MonadLogger msg m => MonadLogger msg (Pipe l i o u m) where DEF
instance MonadLogger msg m => MonadLogger msg (ConduitM i o m) where DEF
instance MonadLogger msg m => MonadLogger msg (Strict.StateT s m) where DEF
instance (MonadLogger msg m, Monoid w) => MonadLogger msg (Strict.WriterT w m) where DEF
instance (MonadLogger msg m, Monoid w) => MonadLogger msg (Strict.RWST r w s m) where DEF
#undef DEF

#if WITH_TEMPLATE_HASKELL
logTH :: LogLevel -> Q Exp
logTH level =
    [|monadLoggerLog $(qLocation >>= liftLoc) (pack "") $(lift level) . (id :: Text -> Text)|]

-- | Generates a function that takes a 'Text' and logs a 'LevelDebug' message. Usage:
--
-- > $(logDebug) "This is a debug log message"
logDebug :: Q Exp
logDebug = logTH LevelDebug

-- | See 'logDebug'
logInfo :: Q Exp
logInfo = logTH LevelInfo
-- | See 'logDebug'
logWarn :: Q Exp
logWarn = logTH LevelWarn
-- | See 'logDebug'
logError :: Q Exp
logError = logTH LevelError

-- | Generates a function that takes a 'Text' and logs a 'LevelOther' message. Usage:
--
-- > $(logOther "My new level") "This is a log message"
logOther :: Text -> Q Exp
logOther = logTH . LevelOther

-- | Lift a location into an Exp.
--
-- Since 0.3.1
liftLoc :: Loc -> Q Exp
liftLoc (Loc a b c (d1, d2) (e1, e2)) = [|Loc
    $(lift a)
    $(lift b)
    $(lift c)
    ($(lift d1), $(lift d2))
    ($(lift e1), $(lift e2))
    |]

-- | Generates a function that takes a 'LogSource' and 'Text' and logs a 'LevelDebug' message. Usage:
--
-- > $logDebugS "SomeSource" "This is a debug log message"
logDebugS :: Q Exp
logDebugS = [|\a b -> monadLoggerLog $(qLocation >>= liftLoc) a LevelDebug (b :: Text)|]

-- | See 'logDebugS'
logInfoS :: Q Exp
logInfoS = [|\a b -> monadLoggerLog $(qLocation >>= liftLoc) a LevelInfo (b :: Text)|]
-- | See 'logDebugS'
logWarnS :: Q Exp
logWarnS = [|\a b -> monadLoggerLog $(qLocation >>= liftLoc) a LevelWarn (b :: Text)|]
-- | See 'logDebugS'
logErrorS :: Q Exp
logErrorS = [|\a b -> monadLoggerLog $(qLocation >>= liftLoc) a LevelError (b :: Text)|]

-- | Generates a function that takes a 'LogSource', a level name and a 'Text' and logs a 'LevelOther' message. Usage:
--
-- > $logOtherS "SomeSource" "My new level" "This is a log message"
logOtherS :: Q Exp
logOtherS = [|\src level msg -> monadLoggerLog $(qLocation >>= liftLoc) src (LevelOther level) (msg :: Text)|]
#endif

-- | Monad transformer that disables logging.
--
-- Since 0.2.4
newtype NoLoggingT msg m a = NoLoggingT { runNoLoggingT :: m a }

instance Monad m => Functor (NoLoggingT msg m) where
    fmap = liftM

instance Monad m => Applicative (NoLoggingT msg m) where
    pure = return
    (<*>) = ap

instance Monad m => Monad (NoLoggingT msg m) where
    return = NoLoggingT . return
    NoLoggingT ma >>= f = NoLoggingT $ ma >>= runNoLoggingT . f

instance MonadIO m => MonadIO (NoLoggingT msg m) where
    liftIO = Trans.lift . liftIO

#if MIN_VERSION_resourcet(1,1,0)
instance MonadThrow m => MonadThrow (NoLoggingT msg m) where
    throwM = Trans.lift . throwM

instance MonadCatch m => MonadCatch (NoLoggingT msg m) where
    catch (NoLoggingT m) c =
        NoLoggingT $ m `catch` \e -> runNoLoggingT (c e)
#if MIN_VERSION_exceptions(0,6,0)
instance MonadMask m => MonadMask (NoLoggingT msg m) where
#endif
    mask a = NoLoggingT $ mask $ \u -> runNoLoggingT (a $ q u)
      where q u (NoLoggingT b) = NoLoggingT $ u b
    uninterruptibleMask a =
        NoLoggingT $ uninterruptibleMask $ \u -> runNoLoggingT (a $ q u)
      where q u (NoLoggingT b) = NoLoggingT $ u b
#else
instance MonadThrow m => MonadThrow (NoLoggingT msg m) where
    monadThrow = Trans.lift . monadThrow
#endif

#if MIN_VERSION_conduit_extra(1,1,0)
instance MonadActive m => MonadActive (NoLoggingT msg m) where
    monadActive = Trans.lift monadActive
instance MonadActive m => MonadActive (LoggingT msg m) where
    monadActive = Trans.lift monadActive
#endif

instance MonadResource m => MonadResource (NoLoggingT msg m) where
    liftResourceT = Trans.lift . liftResourceT

instance MonadBase b m => MonadBase b (NoLoggingT msg m) where
    liftBase = Trans.lift . liftBase

instance Trans.MonadTrans (NoLoggingT msg) where
    lift = NoLoggingT

instance MonadTransControl (NoLoggingT msg) where
    type StT (NoLoggingT msg) a = a
    liftWith f = NoLoggingT $ f $ \(NoLoggingT t) -> t
    restoreT = NoLoggingT
    {-# INLINE liftWith #-}
    {-# INLINE restoreT #-}

instance MonadBaseControl b m => MonadBaseControl b (NoLoggingT msg m) where
     type StM (NoLoggingT msg m) a = StM m a
     liftBaseWith f = NoLoggingT $
         liftBaseWith $ \runInBase ->
             f $ runInBase . (\(NoLoggingT r) -> r)
     restoreM base = NoLoggingT $ restoreM base

instance MonadIO m => MonadLogger msg (NoLoggingT msg m) where
    monadLoggerLog _ _ _ _ = return ()

-- |
--
-- Since 0.4.0
type LogFunc msg m = Loc -> LogSource -> LogLevel -> msg -> m ()

-- | Generalization of @LoggingT@ allowing arbitrary message types.
--
-- Since 0.4.0
newtype LoggerT msg m a = LoggerT
    { runLoggerT :: LogFunc msg m -> m a
    }

class UpgradeMessage msg1 msg2 where
    upgradeMessage :: msg1 -> msg2
instance UpgradeMessage Text Text where
    upgradeMessage = id
instance UpgradeMessage Text LogStr where
    upgradeMessage = toLogStr

-- | Transform the log messages generated by a sub-computation.
--
-- Since 0.4.0
mapLog :: (msg1 -> msg2) -> LoggingT msg1 m a -> LoggingT msg2 m a
mapLog f (LoggingT g) =
    LoggingT $ \lf1 ->
        let lf2 loc src level msg1 = lf1 loc src level (f msg1)
         in g lf2

instance Monad m => Functor (LoggerT msg m) where
    fmap = liftM

instance Monad m => Applicative (LoggerT msg m) where
    pure = return
    (<*>) = ap

instance Monad m => Monad (LoggerT msg m) where
    return = LoggerT . const . return
    LoggerT ma >>= f = LoggerT $ \r -> do
        a <- ma r
        let LoggerT f' = f a
        f' r

instance MonadIO m => MonadIO (LoggerT msg m) where
    liftIO = Trans.lift . liftIO

#if MIN_VERSION_resourcet(1,1,0)
instance MonadThrow m => MonadThrow (LoggerT msg m) where
    throwM = Trans.lift . throwM
instance MonadCatch m => MonadCatch (LoggerT msg m) where
  catch (LoggerT m) c =
      LoggerT $ \r -> m r `catch` \e -> runLoggerT (c e) r
#if MIN_VERSION_exceptions(0,6,0)
instance MonadMask m => MonadMask (LoggerT msg m) where
#endif
  mask a = LoggerT $ \e -> mask $ \u -> runLoggerT (a $ q u) e
    where q u (LoggerT b) = LoggerT (u . b)
  uninterruptibleMask a =
    LoggerT $ \e -> uninterruptibleMask $ \u -> runLoggerT (a $ q u) e
      where q u (LoggerT b) = LoggerT (u . b)
#else
instance MonadThrow m => MonadThrow (LoggerT msg m) where
    monadThrow = Trans.lift . monadThrow
#endif

instance MonadResource m => MonadResource (LoggerT msg m) where
    liftResourceT = Trans.lift . liftResourceT

instance MonadBase b m => MonadBase b (LoggerT msg m) where
    liftBase = Trans.lift . liftBase

instance Trans.MonadTrans (LoggerT msg) where
    lift = LoggerT . const

{- No valid instance exists!
instance MonadTransControl (LoggerT msg) where
    newtype StT (LoggerT msg) a = StLogger {unStLogger :: a}
    liftWith f = LoggerT $ \r -> f $ \(LoggerT t) -> liftM StLogger $ t r
    restoreT = LoggerT . const . liftM unStLogger
    {-# INLINE liftWith #-}
    {-# INLINE restoreT #-}
-}

instance MonadBaseControl b m => MonadBaseControl b (LoggerT msg m) where
     type StM (LoggerT msg m) a = StM m a
     liftBaseWith f = LoggerT $ \reader' ->
         liftBaseWith $ \runInBase ->
             f $ runInBase . (\(LoggerT r) -> r reader')
     restoreM base = LoggerT $ const $ restoreM base
--instance (Monad m, UpgradeMessage msg1 msg2) => MonadLogger msg1 (LoggerT msg2 m) where
--    monadLoggerLog a b c d = LoggerT $ \f -> f a b c (upgradeMessage d)

-- | Monad transformer that adds a new logging function.
--
-- Since 0.2.2
newtype LoggingT msg m a = LoggingT
    { runLoggingT :: LogFunc msg IO -> m a
    }

instance Monad m => Functor (LoggingT msg m) where
    fmap = liftM

instance Monad m => Applicative (LoggingT msg m) where
    pure = return
    (<*>) = ap

instance Monad m => Monad (LoggingT msg m) where
    return = LoggingT . const . return
    LoggingT ma >>= f = LoggingT $ \r -> do
        a <- ma r
        let LoggingT f' = f a
        f' r

instance MonadIO m => MonadIO (LoggingT msg m) where
    liftIO = Trans.lift . liftIO

#if MIN_VERSION_resourcet(1,1,0)
instance MonadThrow m => MonadThrow (LoggingT msg m) where
    throwM = Trans.lift . throwM
instance MonadCatch m => MonadCatch (LoggingT msg m) where
  catch (LoggingT m) c =
      LoggingT $ \r -> m r `catch` \e -> runLoggingT (c e) r
#if MIN_VERSION_exceptions(0,6,0)
instance MonadMask m => MonadMask (LoggingT msg m) where
#endif
  mask a = LoggingT $ \e -> mask $ \u -> runLoggingT (a $ q u) e
    where q u (LoggingT b) = LoggingT (u . b)
  uninterruptibleMask a =
    LoggingT $ \e -> uninterruptibleMask $ \u -> runLoggingT (a $ q u) e
      where q u (LoggingT b) = LoggingT (u . b)
#else
instance MonadThrow m => MonadThrow (LoggingT msg m) where
    monadThrow = Trans.lift . monadThrow
#endif

instance MonadResource m => MonadResource (LoggingT msg m) where
    liftResourceT = Trans.lift . liftResourceT

instance MonadBase b m => MonadBase b (LoggingT msg m) where
    liftBase = Trans.lift . liftBase

instance Trans.MonadTrans (LoggingT msg) where
    lift = LoggingT . const

instance MonadTransControl (LoggingT msg) where
    type StT (LoggingT msg) a = a
    liftWith f = LoggingT $ \r -> f $ \(LoggingT t) -> t r
    restoreT = LoggingT . const
    {-# INLINE liftWith #-}
    {-# INLINE restoreT #-}

instance MonadBaseControl b m => MonadBaseControl b (LoggingT msg m) where
     type StM (LoggingT msg m) a = StM m a
     liftBaseWith f = LoggingT $ \reader' ->
         liftBaseWith $ \runInBase ->
             f $ runInBase . (\(LoggingT r) -> r reader')
     restoreM base = LoggingT $ const $ restoreM base

instance (MonadIO m) => MonadLogger msg (LoggingT msg m) where
    monadLoggerLog a b c d = LoggingT $ \f -> liftIO $ f a b c d

defaultOutput :: ToLogStr msg
              => Handle
              -> Loc
              -> LogSource
              -> LogLevel
              -> msg
              -> IO ()
defaultOutput h loc src level msg =
    S8.hPutStrLn h ls
  where
    ls = defaultLogStrBS loc src level (toLogStr msg)

defaultLogStrBS :: Loc
                -> LogSource
                -> LogLevel
                -> LogStr
                -> S8.ByteString
defaultLogStrBS a b c d =
    toBS $ defaultLogStr a b c d
  where
    toBS = fromLogStr

defaultLogLevelStr :: LogLevel -> LogStr
defaultLogLevelStr level = case level of
    LevelOther t -> toLogStr t
    _            -> toLogStr $ S8.pack $ drop 5 $ show level

defaultLogStr :: Loc
              -> LogSource
              -> LogLevel
              -> LogStr
              -> LogStr
defaultLogStr loc src level msg =
    "[" `mappend` defaultLogLevelStr level `mappend`
    (if T.null src
        then mempty
        else "#" `mappend` toLogStr src) `mappend`
    "] " `mappend`
    msg `mappend`
    " @(" `mappend`
    toLogStr (S8.pack fileLocStr) `mappend`
    ")\n"
  where
    -- taken from file-location package
    -- turn the TH Loc loaction information into a human readable string
    -- leaving out the loc_end parameter
    fileLocStr = (loc_package loc) ++ ':' : (loc_module loc) ++
      ' ' : (loc_filename loc) ++ ':' : (line loc) ++ ':' : (char loc)
      where
        line = show . fst . loc_start
        char = show . snd . loc_start
{-
defaultLogStrWithoutLoc ::
    LogSource -> LogLevel -> LogStr -> LogStr
defaultLogStrWithoutLoc loc src level msg =
    "[" `mappend` defaultLogLevelStr level `mappend`
    (if T.null src
        then mempty
        else "#" `mappend` toLogStr src) `mappend`
    "] " `mappend`
    msg `mappend` "\n"
-}


-- | Run a block using a @MonadLogger@ instance which prints to stderr.
--
-- Since 0.2.2
runStderrLoggingT :: (MonadIO m, ToLogStr msg) => LoggingT msg m a -> m a
runStderrLoggingT = (`runLoggingT` defaultOutput stderr)

-- | Run a block using a @MonadLogger@ instance which prints to stdout.
--
-- Since 0.2.2
runStdoutLoggingT :: (MonadIO m, ToLogStr msg) => LoggingT msg m a -> m a
runStdoutLoggingT = (`runLoggingT` defaultOutput stdout)

-- | Within the 'LoggingT' monad, capture all log messages to a bounded
--   channel of the indicated size, and only actually log them if there is an
--   exception.
--
-- Since 0.3.2
withChannelLogger :: (MonadBaseControl IO m, MonadIO m)
                  => Int         -- ^ Number of mesasges to keep
                  -> LoggingT msg m a
                  -> LoggingT msg m a
withChannelLogger size action = LoggingT $ \logger -> do
    chan <- liftIO $ newTBChanIO size
    runLoggingT action (channelLogger chan logger) `onException` dumpLogs chan
  where
    channelLogger chan logger loc src lvl str = atomically $ do
        full <- isFullTBChan chan
        when full $ void $ readTBChan chan
        writeTBChan chan $ logger loc src lvl str

    dumpLogs chan = liftIO $
        sequence_ =<< atomically (untilM (readTBChan chan) (isEmptyTBChan chan))

instance MonadCont m => MonadCont (LoggingT msg m) where
  callCC f = LoggingT $ \i -> callCC $ \c -> runLoggingT (f (LoggingT . const . c)) i

instance MonadError e m => MonadError e (LoggingT msg m) where
  throwError = Trans.lift . throwError
  catchError r h = LoggingT $ \i -> runLoggingT r i `catchError` \e -> runLoggingT (h e) i

instance MonadRWS r w s m => MonadRWS r w s (LoggingT msg m)

instance MonadReader r m => MonadReader r (LoggingT msg m) where
  ask = Trans.lift ask
  local = mapLoggingT . local

mapLoggingT :: (m a -> n b) -> LoggingT msg m a -> LoggingT msg n b
mapLoggingT f = LoggingT . (f .) . runLoggingT

instance MonadState s m => MonadState s (LoggingT msg m) where
  get = Trans.lift get
  put = Trans.lift . put

instance MonadWriter w m => MonadWriter w (LoggingT msg m) where
  tell   = Trans.lift . tell
  listen = mapLoggingT listen
  pass   = mapLoggingT pass

defaultLoc :: Loc
defaultLoc = Loc "<unknown>" "<unknown>" "<unknown>" (0,0) (0,0)

logWithoutLoc :: (MonadLogger msg m, ToLogStr msg) => LogSource -> LogLevel -> msg -> m ()
logWithoutLoc = monadLoggerLog defaultLoc

logDebugN :: MonadLogger Text m => Text -> m ()
logDebugN msg =
    logWithoutLoc "" LevelDebug msg

logInfoN :: MonadLogger Text m => Text -> m ()
logInfoN msg =
    logWithoutLoc "" LevelInfo msg

logWarnN :: MonadLogger Text m => Text -> m ()
logWarnN msg =
    logWithoutLoc "" LevelWarn msg

logErrorN :: MonadLogger Text m => Text -> m ()
logErrorN msg =
    logWithoutLoc "" LevelError msg

logOtherN :: MonadLogger Text m => LogLevel -> Text -> m ()
logOtherN level msg =
    logWithoutLoc "" level msg

logDebugNS :: MonadLogger Text m => LogSource -> Text -> m ()
logDebugNS src msg =
    logWithoutLoc src LevelDebug msg

logInfoNS :: MonadLogger Text m => LogSource -> Text -> m ()
logInfoNS src msg =
    logWithoutLoc src LevelInfo msg

logWarnNS :: MonadLogger Text m => LogSource -> Text -> m ()
logWarnNS src msg =
    logWithoutLoc src LevelWarn msg

logErrorNS :: MonadLogger Text m => LogSource -> Text -> m ()
logErrorNS src msg =
    logWithoutLoc src LevelError msg

logOtherNS :: MonadLogger Text m => LogSource -> LogLevel -> Text -> m ()
logOtherNS src level msg =
    logWithoutLoc src level msg
