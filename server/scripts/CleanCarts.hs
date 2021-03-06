{-# LANGUAGE OverloadedStrings #-}
{- | Remove any inactive variants from Carts & remove Carts for customers
that haven't logged in to the new site yet.
-}
import Control.Monad.Logger (runNoLoggingT)
import Database.Persist.Postgresql

import Models

import qualified Database.Esqueleto as E


main :: IO ()
main = do
    psql <- connectToPostgres
    flip runSqlPool psql $ removeInactiveVariants >> removeOldCarts

connectToPostgres :: IO ConnectionPool
connectToPostgres =
    runNoLoggingT $ createPostgresqlPool "dbname=sese-website" 1

removeInactiveVariants :: SqlPersistT IO ()
removeInactiveVariants = do
    variantIds <- selectKeysList [ProductVariantIsActive ==. False] []
    deleteWhere [CartItemProductVariantId <-. variantIds]

removeOldCarts :: SqlPersistT IO ()
removeOldCarts = do
    oldCartIds <- fmap (map E.unValue) $ E.select $ E.from $ \(c `E.InnerJoin` cart) -> do
        E.on $ cart E.^. CartCustomerId E.==. E.just (c E.^. CustomerId)
        E.where_ $ c E.^. CustomerEncryptedPassword `E.ilike` E.concat_ [(E.%), E.val ":", (E.%)]
        return $ cart E.^. CartId
    deleteWhere [CartItemCartId <-. oldCartIds]
    deleteWhere [CartId <-. oldCartIds]
