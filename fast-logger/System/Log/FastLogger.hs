-- | This module provides a fast logging system which
--   scales on multicore environments (i.e. +RTS -N\<x\>).
{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}

module System.Log.FastLogger (
  -- * Creating a logger set
    LoggerSet
  , newFileLoggerSet
  , newStdoutLoggerSet
  , newStderrLoggerSet
  , newLoggerSet
  -- * Buffer size
  , BufSize
  , defaultBufSize
  -- * Renewing and removing a logger set
  , renewLoggerSet
  , rmLoggerSet
  -- * Log messages
  , LogStr
  , ToLogStr(..)
  , fromLogStr
  , logStrLength
  -- * Writing a log message
  , pushLogStr
  , pushLogStrLn
  -- * Flushing buffered log messages
  , flushLogStr
  -- * FastLogger
  , FastLogger(..)
  , LogType(..)
  , newFastLogger
  , newTimedFastLogger
  , simpleAppendTime
  , simpleTimeFormat
  -- * Date cache
  , module System.Log.FastLogger.Date
  -- * File rotation
  , module System.Log.FastLogger.File
  ) where

#if __GLASGOW_HASKELL__ < 709
import Control.Applicative ((<$>))
#endif
import Control.Debounce (mkDebounce, defaultDebounceSettings, debounceAction)
import Control.Concurrent (getNumCapabilities, myThreadId, threadCapability, takeMVar, MVar, newMVar, tryTakeMVar, putMVar)
import Control.Exception (handle, SomeException(..), bracket)
import Control.Monad (when, replicateM)
import Data.Array (Array, listArray, (!), bounds)
import Data.Maybe (isJust)
import Data.Text (Text)
import System.EasyFile (getFileSize)
import System.Log.FastLogger.File
import System.Log.FastLogger.IO
import System.Log.FastLogger.FileIO
import System.Log.FastLogger.IORef
import System.Log.FastLogger.LogStr
import System.Log.FastLogger.Logger
import System.Log.FastLogger.Date

----------------------------------------------------------------

-- | A set of loggers.
--   The number of loggers is the capabilities of GHC RTS.
--   You can specify it with \"+RTS -N\<x\>\".
--   A buffer is prepared for each capability.
data LoggerSet = LoggerSet (Maybe FilePath) (IORef FD) (Array Int Logger) (IO ())

-- | Creating a new 'LoggerSet' using a file.
newFileLoggerSet :: BufSize -> FilePath -> IO LoggerSet
newFileLoggerSet size file = openFileFD file >>= newFDLoggerSet size (Just file)

-- | Creating a new 'LoggerSet' using stdout.
newStdoutLoggerSet :: BufSize -> IO LoggerSet
newStdoutLoggerSet size = getStdoutFD >>= newFDLoggerSet size Nothing

-- | Creating a new 'LoggerSet' using stderr.
newStderrLoggerSet :: BufSize -> IO LoggerSet
newStderrLoggerSet size = getStderrFD >>= newFDLoggerSet size Nothing

{-# DEPRECATED newLoggerSet "Use newFileLoggerSet etc instead" #-}
-- | Creating a new 'LoggerSet'.
--   If 'Nothing' is specified to the second argument,
--   stdout is used.
--   Please note that the minimum 'BufSize' is 1.
newLoggerSet :: BufSize -> Maybe FilePath -> IO LoggerSet
newLoggerSet size = maybe (newStdoutLoggerSet size) (newFileLoggerSet size)

-- | Creating a new 'LoggerSet' using a FD.
newFDLoggerSet :: BufSize -> Maybe FilePath -> FD -> IO LoggerSet
newFDLoggerSet size mfile fd = do
    n <- getNumCapabilities
    loggers <- replicateM n $ newLogger (max 1 size)
    let arr = listArray (0,n-1) loggers
    fref <- newIORef fd
    flush <- mkDebounce defaultDebounceSettings
        { debounceAction = flushLogStrRaw fref arr
        }
    return $ LoggerSet mfile fref arr flush

-- | Writing a log message to the corresponding buffer.
--   If the buffer becomes full, the log messages in the buffer
--   are written to its corresponding file, stdout, or stderr.
pushLogStr :: LoggerSet -> LogStr -> IO ()
pushLogStr (LoggerSet _ fref arr flush) logmsg = do
    (i, _) <- myThreadId >>= threadCapability
    -- The number of capability could be dynamically changed.
    -- So, let's check the upper boundary of the array.
    let u = snd $ bounds arr
        lim = u + 1
        j | i < lim   = i
          | otherwise = i `mod` lim
    let logger' = arr ! j
    fd <- readIORef fref
    pushLog fd logger' logmsg
    flush

-- | Same as 'pushLogStr' but also appends a newline.
pushLogStrLn :: LoggerSet -> LogStr -> IO ()
pushLogStrLn loggerSet logStr = pushLogStr loggerSet (logStr <> toLogStr ("\n" :: Text))

-- | Flushing log messages in buffers.
--   This function must be called explicitly when the program is
--   being terminated.
--
--   Note: Since version 2.1.6, this function does not need to be
--   explicitly called, as every push includes an auto-debounced flush
--   courtesy of the auto-update package. Since version 2.2.2, this
--   function can be used to force flushing outside of the debounced
--   flush calls.
flushLogStr :: LoggerSet -> IO ()
flushLogStr (LoggerSet _ fref arr _) = flushLogStrRaw fref arr

flushLogStrRaw :: IORef FD -> Array Int Logger -> IO ()
flushLogStrRaw fref arr = do
    let (l,u) = bounds arr
    fd <- readIORef fref
    mapM_ (flushIt fd) [l .. u]
  where
    flushIt fd i = flushLog fd (arr ! i)

-- | Renewing the internal file information in 'LoggerSet'.
--   This does nothing for stdout and stderr.
renewLoggerSet :: LoggerSet -> IO ()
renewLoggerSet (LoggerSet Nothing     _    _ _) = return ()
renewLoggerSet (LoggerSet (Just file) fref _ _) = do
    newfd <- openFileFD file
    oldfd <- atomicModifyIORef' fref (\fd -> (newfd, fd))
    closeFD oldfd

-- | Flushing the buffers, closing the internal file information
--   and freeing the buffers.
rmLoggerSet :: LoggerSet -> IO ()
rmLoggerSet (LoggerSet mfile fref arr _) = do
    let (l,u) = bounds arr
    fd <- readIORef fref
    let nums = [l .. u]
    mapM_ (flushIt fd) nums
    mapM_ freeIt nums
    when (isJust mfile) $ closeFD fd
  where
    flushIt fd i = flushLog fd (arr ! i)
    freeIt i = do
        let (Logger mbuf _ _) = arr ! i
        takeMVar mbuf >>= freeBuffer

----------------------------------------------------------------

-- | 'FastLogger' contain an log action and a clean up action.
-- you should use 'bracket' to close log file safely.
-- the close action is a no-op for stdout/stderr logging.
data FastLogger = FastLogger {
        logger :: LogStr -> IO ()          -- ^ the log action
    ,   releaseLogger :: IO ()             -- ^ the clean up action
    }

-- | Logger Type.
data LogType = LogNone                     -- ^ No logging.
             | LogStdout BufSize           -- ^ Logging to stdout.
                                           --   'BufSize' is a buffer size
             | LogStderr BufSize           -- ^ Logging to stdout.
                                           --   'BufSize' is a buffer size
                                           --   for each capability.
             | LogFile FilePath BufSize    -- ^ Logging to a file.
                                           --   'BufSize' is a buffer size
                                           --   for each capability.
             | LogFileAutoRotate FileLogSpec BufSize -- ^ Logging to a file.
                                           --   'BufSize' is a buffer size
                                           --   for each capability.
                                           --   File rotation is done on-demand.
             | LogCallback (LogStr -> IO ()) (IO ()) -- ^ Logging with a log and flush action.
                                           -- run flush after log each message.

-- | Initialize a 'FastLogger' without attaching timestamp.
newFastLogger :: LogType -> IO FastLogger
newFastLogger LogNone = return FastLogger{
    logger = const $ return ()
  , releaseLogger = return ()
  }
newFastLogger typ = case typ of
    LogStdout bsize -> newStdoutLoggerSet bsize >>= stdLoggerInit
    LogStderr bsize -> newStderrLoggerSet bsize >>= stdLoggerInit
    LogFile fp bsize ->  newFileLoggerSet bsize fp >>= stdLoggerInit
    LogFileAutoRotate fspec bsize -> rotateLoggerInit fspec bsize
    LogCallback cb flush -> return FastLogger{
            logger = \ str -> cb str >> flush
        ,   releaseLogger = return ()
        }
  where
    stdLoggerInit lgrset = return FastLogger{
            logger = pushLogStr lgrset
        ,   releaseLogger = return ()
        }

    rotateLoggerInit fspec bsize = do
        lgrset <- newFileLoggerSet bsize $ log_file fspec
        ref <- newIORef (0 :: Int)
        mvar <- newMVar ()
        let logger' str = do
                cnt <- decrease ref
                pushLogStr lgrset str
                when (cnt <= 0) $ tryRotate lgrset fspec ref mvar
        return $ FastLogger logger' (rmLoggerSet lgrset)

-- | Initialize a 'FastLogger' with timestamp attached to each message.
newTimedFastLogger :: TimeFormat               -- ^ for example: 'simpleTimeFormat'
    -> (FormattedTime -> LogStr -> LogStr)     -- ^ How do we attach formatted time with message?
    -> LogType -> IO FastLogger
newTimedFastLogger _ _ LogNone = newFastLogger LogNone
newTimedFastLogger fmt logf typ = do
    tgetter <- newTimeCacher fmt
    case typ of
        LogStdout bsize -> newStdoutLoggerSet bsize >>= stdLoggerInit tgetter logf
        LogStderr bsize -> newStderrLoggerSet bsize >>= stdLoggerInit tgetter logf
        LogFile fp bsize ->  newFileLoggerSet bsize fp >>= stdLoggerInit tgetter logf
        LogFileAutoRotate fspec bsize -> rotateLoggerInit fspec bsize tgetter logf
        LogCallback cb flush -> return FastLogger{
                logger = \str -> do
                    t <- tgetter
                    cb (logf t str)
                    flush
            ,   releaseLogger = return ()
            }
  where
    stdLoggerInit tgetter logf' lgrset = return FastLogger{
            logger = \ str -> do
                t <- tgetter
                pushLogStr lgrset (logf' t str)
        ,   releaseLogger = return ()
        }


    rotateLoggerInit fspec bsize tgetter logf' = do
        lgrset <- newFileLoggerSet bsize $ log_file fspec
        ref <- newIORef (0 :: Int)
        mvar <- newMVar ()
        let logger' str = do
                cnt <- decrease ref
                t <- tgetter
                pushLogStr lgrset (logf' t str)
                when (cnt <= 0) $ tryRotate lgrset fspec ref mvar
        return $ FastLogger logger' (rmLoggerSet lgrset)


-- | Append formatted time at the end of the message, seperated with \"@"\.
simpleAppendTime :: FormattedTime -> LogStr -> LogStr
simpleAppendTime t l = l <> "@" <> (toLogStr t)

-- | A simple time format: @simpleTimeFormat = "%d/%b/%Y:%T %z"@
simpleTimeFormat :: TimeFormat
simpleTimeFormat = "%d/%b/%Y:%T %z"
----------------------------------------------------------------

decrease :: IORef Int -> IO Int
decrease ref = atomicModifyIORef' ref (\x -> (x - 1, x - 1))

tryRotate :: LoggerSet -> FileLogSpec -> IORef Int -> MVar () -> IO ()
tryRotate lgrset spec ref mvar = bracket lock unlock rotateFiles
  where
    lock           = tryTakeMVar mvar
    unlock Nothing = return ()
    unlock _       = putMVar mvar ()
    rotateFiles Nothing = return ()
    rotateFiles _       = do
        msiz <- getSize
        case msiz of
            -- A file is not available.
            -- So, let's set a big value to the counter so that
            -- this function is not called frequently.
            Nothing -> writeIORef ref 1000000
            Just siz
                | siz > limit -> do
                    rotate spec
                    renewLoggerSet lgrset
                    writeIORef ref $ estimate limit
                | otherwise -> do
                    writeIORef ref $ estimate (limit - siz)
    file = log_file spec
    limit = log_file_size spec
    getSize = handle (\(SomeException _) -> return Nothing) $ do
        -- The log file is locked by GHC.
        -- We need to get its file size by the way not using locks.
        Just . fromIntegral <$> getFileSize file
    -- 200 is an ad-hoc value for the length of log line.
    estimate x = fromInteger (x `div` 200)
