{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
module Main where

import Control.Concurrent (newEmptyMVar, takeMVar, putMVar, threadDelay)
import Control.Concurrent.Async (async, cancel, race_)
import Control.Concurrent.STM.TVar (newTVarIO)
import Control.Exception (Exception(..), SomeException)
import Control.Immortal.Queue (processImmortalQueue, closeImmortalQueue)
import Control.Monad (when, forever, void)
import Control.Monad.IO.Class (MonadIO)
import Control.Monad.Trans.Control (MonadBaseControl)
import Control.Monad.Logger (MonadLogger, runNoLoggingT, runStderrLoggingT)
import Data.Maybe (fromMaybe)
import Data.Monoid ((<>))
import Data.Pool (destroyAllResources)
import Data.Text.Encoding (decodeUtf8)
import Data.Version (showVersion)
import Database.Persist.Postgresql
import Network.Wai (Request, requestMethod, rawPathInfo, rawQueryString)
import Network.Wai.Middleware.RequestLogger (logStdoutDev, logStdout)
import System.Directory (getCurrentDirectory, createDirectoryIfMissing)
import System.Environment (lookupEnv)
import System.Log.FastLogger
     ( LogType(LogStdout, LogFile), FileLogSpec(..), TimedFastLogger
     , newTimeCache, newTimedFastLogger, defaultBufSize
     )
import System.Posix.Signals (installHandler, sigTERM, Handler(CatchOnce))
import Web.Stripe.Client (StripeConfig(..), StripeKey(..))

import Api
import Auth (sessionEntropy, mkPersistentServerKey)
import Cache (initializeCaches)
import Config
import Models
import Paths_sese_website (version)
import StoneEdge (StoneEdgeCredentials(..))
import Workers (taskQueueConfig)

import qualified Avalara
import qualified Data.ByteString.Char8 as C
import qualified Data.Text as T
import qualified Network.Wai.Handler.Warp as Warp

import Prelude hiding (log)


-- | Connect to the database, configure the application, & start the server.
--
-- TODO: Document enviornmental variables in README.
main :: IO ()
main = do
    env <- lookupSetting "ENV" Development
    (avalaraLogger, stripeLogger, serverLogger, cleanupLoggers) <- makeLoggers env
    let log = logMsg serverLogger
    log "SESE API Server starting up."
    port <- lookupSetting "PORT" 3000
    mediaDir <- lookupDirectory "MEDIA" "/media/"
    log $ "Media directory initialized at " <> T.pack mediaDir <> "."
    smtpServer <- fromMaybe "" <$> lookupEnv "SMTP_SERVER"
    smtpUser <- fromMaybe "" <$> lookupEnv "SMTP_USER"
    smtpPass <- fromMaybe "" <$> lookupEnv "SMTP_PASS"
    emailPool <- smtpPool smtpServer (poolSize env)
    log $ "Initialized SMTP Pool at " <> T.pack smtpServer <> "."
    stripeToken <- fromMaybe "" <$> lookupEnv "STRIPE_TOKEN"
    cookieSecret <- mkPersistentServerKey . C.pack . fromMaybe ""
        <$> lookupEnv "COOKIE_SECRET"
    entropySource <- sessionEntropy
    stoneEdgeAuth <- makeStoneEdgeAuth
    avalaraStatus <- lookupSetting "AVATAX_STATUS" AvalaraTesting
    avalaraConfig <- makeAvalaraConfig
    avalaraCompanyId <- Avalara.CompanyId <$> lookupSetting "AVATAX_COMPANY_ID" 0
    avalaraCompanyCode <- Avalara.CompanyCode . T.pack <$> requireSetting "AVATAX_COMPANY_CODE"
    avalaraSourceLocation <- T.pack . fromMaybe "DEFAULT" <$> lookupEnv "AVATAX_LOCATION_CODE"
    dbPool <- makePool env
    log "Initialized database pool."
    cache <- runSqlPool initializeCaches dbPool >>= newTVarIO
    log "Initialized database cache."
    let cfg = defaultConfig
            { getPool = dbPool
            , getEnv = env
            , getCaches = cache
            , getMediaDirectory = mediaDir
            , getSmtpPool = emailPool
            , getSmtpUser = smtpUser
            , getSmtpPass = smtpPass
            , getStripeConfig = StripeConfig $ StripeKey $ C.pack stripeToken
            , getStoneEdgeAuth = stoneEdgeAuth
            , getCookieSecret = cookieSecret
            , getCookieEntropySource = entropySource
            , getAvalaraStatus = avalaraStatus
            , getAvalaraConfig = avalaraConfig
            , getAvalaraCompanyId = avalaraCompanyId
            , getAvalaraCompanyCode = avalaraCompanyCode
            , getAvalaraSourceLocationCode = avalaraSourceLocation
            , getAvalaraLogger = avalaraLogger
            , getStripeLogger = stripeLogger
            , getServerLogger = serverLogger
            }
    log "Starting 2 worker threads."
    workers <- processImmortalQueue $ taskQueueConfig 2 cfg
    log $ "Serving HTTP requests on port " <> T.pack (show port) <> "."
    shutdownMVar <- newEmptyMVar
    void $ installHandler sigTERM (CatchOnce $ putMVar shutdownMVar ()) Nothing
    asyncWarp <- async
        $ Warp.runSettings (warpSettings port serverLogger) . httpLogger env
        $ app cfg
    race_ (takeMVar shutdownMVar) (forever $ threadDelay maxBound)
    log "Received SIGTERM, starting clean shutdown."
    log "Waiting for worker queue to finish..."
    closeImmortalQueue workers
    log "Worker queue closed."
    cancel asyncWarp
    log "HTTP server stopped."
    destroyAllResources emailPool
    log "SMTP pool closed."
    destroyAllResources dbPool
    log "PostgreSQL pool closed."
    log "Shutdown completed successfully."
    cleanupLoggers
    where lookupSetting env def =
            maybe def read <$> lookupEnv env
          requireSetting :: String -> IO String
          requireSetting env =
            lookupEnv env
                >>= maybe (error $ "Could not find required env variable: " ++ env) return
          makePool :: Environment -> IO ConnectionPool
          makePool env =
            case env of
                Production ->
                    runNoLoggingT $ makeSqlPool env
                Development ->
                    runStderrLoggingT $ makeSqlPool env
          makeSqlPool :: (MonadIO m, MonadLogger m, MonadBaseControl IO m) => Environment -> m ConnectionPool
          makeSqlPool env = do
                pool <- createPostgresqlPool "dbname=sese-website" $ poolSize env
                runSqlPool (runMigration migrateAll) pool
                return pool
          poolSize env =
            case env of
                Production ->
                    8
                Development ->
                    2
          warpSettings port serverLogger =
              Warp.setServerName ""
              $ Warp.setOnException (exceptionHandler serverLogger)
              $ Warp.setPort port Warp.defaultSettings
          exceptionHandler :: TimedFastLogger -> Maybe Request -> SomeException -> IO ()
          exceptionHandler logger mReq e =
            let reqString = flip (maybe "") mReq $ \req ->
                    decodeUtf8 $
                        "("
                        <> requestMethod req
                        <> " "
                        <> rawPathInfo req
                        <> rawQueryString req
                        <> ")"
            in
            when (Warp.defaultShouldDisplayException e) $
                logMsg logger $ T.concat
                    [ "Exception while processing request"
                    , reqString
                    , ": "
                    , T.pack $ displayException e
                    ]
          logMsg :: TimedFastLogger -> T.Text -> IO ()
          logMsg logger =
            logger . timedLogStr
          httpLogger env =
              case env of
                Production ->
                    logStdout
                Development ->
                    logStdoutDev
          makeStoneEdgeAuth = do
            secUsername <- T.pack . fromMaybe "" <$> lookupEnv "STONE_EDGE_USER"
            secPassword <- T.pack . fromMaybe "" <$> lookupEnv "STONE_EDGE_PASS"
            secStoreCode <- T.pack . fromMaybe "" <$> lookupEnv "STONE_EDGE_CODE"
            return StoneEdgeCredentials {..}
          makeAvalaraConfig :: IO Avalara.Config
          makeAvalaraConfig = do
            let cAppName = "SESE Retail Website"
                cAppVersion = T.pack $ showVersion version
            cAccountId <- Avalara.AccountId . T.pack
                <$> requireSetting "AVATAX_ACCOUNT_ID"
            cLicenseKey <- Avalara.LicenseKey . T.pack
                <$> requireSetting "AVATAX_LICENSE_KEY"
            rawEnvironment <- T.pack <$> requireSetting "AVATAX_ENVIRONMENT"
            cServiceEnvironment <- case T.toLower rawEnvironment of
                "sandbox" ->
                    return Avalara.SandboxEnvironment
                "production" ->
                    return Avalara.ProductionEnvironment
                _ ->
                    error $ "Invalid AVATAX_ENVIRONMENT: " ++ T.unpack rawEnvironment
                        ++ "\n\n\tValid value are `Production` or `Sandbox`"
            return Avalara.Config {..}
          makeLoggers :: Environment -> IO (TimedFastLogger, TimedFastLogger, TimedFastLogger, IO ())
          makeLoggers env = do
            timeCache <- newTimeCache "%Y-%m-%dT%T"
            case env of
                Development -> do
                    let makeLogger = newTimedFastLogger timeCache
                    (avalara, aClean) <- makeLogger (LogStdout defaultBufSize)
                    (stripe, stripeClean) <- makeLogger (LogStdout defaultBufSize)
                    (server, servClean) <- makeLogger (LogStdout defaultBufSize)
                    return (avalara, stripe, server, aClean >> stripeClean >> servClean)
                Production -> do
                    logDir <- lookupDirectory "LOGS" "/logs/"
                    let makeLogger fp = newTimedFastLogger timeCache
                            $ LogFile (FileLogSpec fp (1024 * 1024 * 50) 5)
                                defaultBufSize
                    (avalara, aClean) <- makeLogger $ logDir ++ "/avalara.log"
                    (stripe, stripeClean) <- makeLogger $ logDir ++ "/stripe.log"
                    (server, servClean) <- makeLogger $ logDir ++ "/server.log"
                    return (avalara, stripe, server, aClean >> stripeClean >> servClean)
          lookupDirectory :: String -> FilePath -> IO FilePath
          lookupDirectory envName defaultPath = do
                dir <- lookupEnv envName
                    >>= maybe ((++ defaultPath) <$> getCurrentDirectory) return
                createDirectoryIfMissing True dir
                return dir
