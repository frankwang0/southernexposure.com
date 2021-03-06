{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeFamilies #-}
module Routes.Utils
    ( -- * Products
      paginatedSelect
    , activeVariantExists
      -- * Customers
    , generateUniqueToken
    , hashPassword
      -- * Images
    , makeImageFromBase64
      -- * Servant
    , XML
      -- * General
    , extractRowCount
    , buildWhereQuery
    , mapUpdate
    , mapUpdateWith
    , sanitize
    ) where

import Control.Monad (void)
import Control.Monad.Reader (asks)
import Control.Monad.Trans (liftIO)
import Data.Int (Int64)
import Data.Maybe (fromMaybe, listToMaybe, mapMaybe)
import Data.Text.Encoding (encodeUtf8, decodeUtf8)
import Database.Persist
    ( (=.), Entity(..), PersistEntityBackend, PersistEntity, Update, getBy
    )
import Database.Persist.Sql (SqlBackend)
import Servant (Accept(..), MimeRender(..), errBody, err500)
import System.FilePath ((</>), takeFileName)
import Text.HTML.SanitizeXSS (filterTags, safeTagName, sanitizeAttribute)
import Text.HTML.TagSoup (Tag(TagOpen, TagClose))

import Config (Config(..))
import Images (saveOriginalImage)
import Models
import Models.Fields (Cents(..))
import Server
import Workers (Task(OptimizeImage), enqueueTask)

import qualified Crypto.BCrypt as BCrypt
import qualified Data.ByteString as BS
import qualified Data.ByteString.Base64 as Base64
import qualified Data.ByteString.Lazy as LBS
import qualified Data.Text as T
import qualified Data.UUID as UUID
import qualified Data.UUID.V4 as UUID4
import qualified Database.Esqueleto as E
import qualified Network.HTTP.Media as Media


-- PRODUCTS


paginatedSelect :: Maybe T.Text -> Maybe Int -> Maybe Int
                -> (E.SqlExpr (Entity Product) -> E.SqlExpr (Maybe (Entity SeedAttribute)) -> E.SqlExpr (Maybe (Entity ProductToCategory)) -> E.SqlExpr (E.Value Bool))
                -> AppSQL ([Entity Product], Int)
paginatedSelect maybeSorting maybePage maybePerPage productFilters =
    let sorting = fromMaybe "" maybeSorting in
    case sorting of
        "name-asc" ->
            productsSelect (\p -> E.orderBy [E.asc $ p E.^. ProductName])
        "name-desc" ->
            productsSelect (\p -> E.orderBy [E.desc $ p E.^. ProductName])
        "number-asc" ->
            productsSelect (\p -> E.orderBy [E.asc $ p E.^. ProductBaseSku])
        "price-asc" ->
            variantSorted (\f -> [E.asc f]) offset perPage productFilters
        "price-desc" ->
            variantSorted (\f -> [E.desc f]) offset perPage productFilters
        "created-asc" ->
            productsSelect (\p -> E.orderBy [E.asc $ p E.^. ProductCreatedAt])
        "created-desc" ->
            productsSelect (\p -> E.orderBy [E.desc $ p E.^. ProductCreatedAt])
        _ ->
            productsSelect (\p -> E.orderBy [E.asc $ p E.^. ProductName])
    where perPage =
            fromIntegral $ fromMaybe 25 maybePerPage
          page =
            fromIntegral $ fromMaybe 1 maybePage
          offset =
            (page - 1) * perPage
          productsSelect ordering = do
            products <- E.select $ E.from $ \(p `E.LeftOuterJoin` sa `E.LeftOuterJoin` pToC) -> do
                E.on (E.just (p E.^. ProductId) E.==. pToC E.?. ProductToCategoryProductId)
                E.on (E.just (p E.^. ProductId) E.==. sa E.?. SeedAttributeProductId)
                E.where_ $ productFilters p sa pToC E.&&. activeVariantExists p
                void $ ordering p
                E.limit perPage
                E.offset offset
                return p
            productsCount <- countProducts productFilters
            return (products, productsCount)

variantSorted :: (E.SqlExpr (E.Value (Maybe Cents)) -> [E.SqlExpr E.OrderBy])
              -> Int64 -> Int64
              -> (E.SqlExpr (Entity Product) -> E.SqlExpr (Maybe (Entity SeedAttribute)) -> E.SqlExpr (Maybe (Entity ProductToCategory)) -> E.SqlExpr (E.Value Bool))
              -> AppSQL ([Entity Product], Int)
variantSorted ordering offset perPage filters = do
    productsAndPrice <- E.select $ E.from $ \(p `E.InnerJoin` v `E.LeftOuterJoin` sa `E.LeftOuterJoin` pToC) ->
        let minPrice = E.min_ $ v E.^. ProductVariantPrice in
        E.distinctOnOrderBy (ordering minPrice ++ [E.asc $ p E.^. ProductName]) $ do
        E.on (E.just (p E.^. ProductId) E.==. pToC E.?. ProductToCategoryProductId)
        E.on (E.just (p E.^. ProductId) E.==. sa E.?. SeedAttributeProductId)
        E.on (p E.^. ProductId E.==. v E.^. ProductVariantProductId
                E.&&. v E.^. ProductVariantIsActive E.==. E.val True)
        E.groupBy $ p E.^. ProductId
        E.where_ $ filters p sa pToC
        E.limit perPage
        E.offset offset
        return (p, minPrice)
    pCount <- countProducts filters
    let (ps, _) = unzip productsAndPrice
    return (ps, pCount)

-- | Count the number of results with the given filters.
countProducts
    :: (E.SqlExpr (Entity Product) -> E.SqlExpr (Maybe (Entity SeedAttribute)) -> E.SqlExpr (Maybe (Entity ProductToCategory)) -> E.SqlExpr (E.Value Bool))
    -> AppSQL Int
countProducts filters =
    extractRowCount . E.select $ E.from $ \(p `E.LeftOuterJoin` sa `E.LeftOuterJoin` pToC) -> do
        E.on (E.just (p E.^. ProductId) E.==. pToC E.?. ProductToCategoryProductId)
        E.on (E.just (p E.^. ProductId) E.==. sa E.?. SeedAttributeProductId)
        E.where_ $ filters p sa pToC E.&&. activeVariantExists p
        return (E.countRows :: E.SqlExpr (E.Value Int))

-- | Determine if the Product has an active ProductVariant.
activeVariantExists :: E.SqlExpr (Entity Product) -> E.SqlExpr (E.Value Bool)
activeVariantExists p =  E.exists $ E.from $ \v -> E.where_ $
    p E.^. ProductId E.==. v E.^. ProductVariantProductId E.&&.
    v E.^. ProductVariantIsActive E.==. E.val True


-- CUSTOMERS


generateUniqueToken :: (PersistEntityBackend r ~ SqlBackend, PersistEntity r)
                    => (T.Text -> Unique r) -> AppSQL T.Text
generateUniqueToken uniqueConstraint = do
    token <- UUID.toText <$> liftIO UUID4.nextRandom
    maybeCustomer <- getBy $ uniqueConstraint token
    case maybeCustomer of
        Just _ ->
            generateUniqueToken uniqueConstraint
        Nothing ->
            return token

hashPassword :: T.Text -> App T.Text
hashPassword password = do
    maybePass <- liftIO . BCrypt.hashPasswordUsingPolicy BCrypt.slowerBcryptHashingPolicy
        $ encodeUtf8 password
    case maybePass of
        Nothing ->
            serverError $ err500 { errBody = "Misconfigured Hashing Policy" }
        Just pass ->
            return $ decodeUtf8 pass


-- IMAGES

-- | Save an Image encoded in a Base64 ByteString, returning the new filename
-- with the content hash appended to the original. Enqueue a Task to
-- optimize the images.
makeImageFromBase64 :: FilePath -> T.Text -> BS.ByteString -> App T.Text
makeImageFromBase64 basePath fileName imageData =
    if BS.null imageData then
        return ""
    else case Base64.decode imageData of
        Left _ ->
            return ""
        Right rawImageData -> do
            mediaDirectory <- asks getMediaDirectory
            originalPath <- saveOriginalImage fileName (mediaDirectory </> basePath)
                rawImageData
            runDB $ enqueueTask Nothing
                $ OptimizeImage originalPath (mediaDirectory </> basePath)
            return . T.pack $ takeFileName originalPath


-- SERVANT

-- | A Content-Type Allowing Serving of XML Responses
data XML

instance Accept XML where
    contentType _ = "application" Media.// "xml" Media./: ("charset", "utf-8")

instance MimeRender XML LBS.ByteString where
    mimeRender _ = id


-- GENERAL

-- | Extract a row count from a query that uses functions like 'E.count' or
-- 'E.countRows'. Defaults to 0 if the query returns no rows.
extractRowCount :: AppSQL [E.Value Int] -> AppSQL Int
extractRowCount =
    fmap $ maybe 0 E.unValue . listToMaybe

-- | A helper function to build an 'esqueleto' 'E.where_' query using
-- a search query.
--
-- The query will be split at space characters into a list of search terms.
--
-- The passed function should generates a list of matches for a single
-- term. These matches will be ORed together with 'E.||.' and each
-- resulting sub-expression will be ANDed together with 'E.&&.'.
--
-- E.g., if the function generates `[term == CustomerId, term ==
-- CustomerEmail]` and you pass in the search query `1234 @gmail.com`, the
-- following expression will be generated:
--
-- @
--  (1234 == CustomerId OR 1234 == CustomerEmail)
--  AND
--  (@gmail == CustomerId OR @gmail == CustomerEmail)
-- @
--
-- If the passed `query` is empty, this will simply return 'True'.
buildWhereQuery :: (T.Text -> [E.SqlExpr (E.Value Bool)]) -> T.Text -> E.SqlExpr (E.Value Bool)
buildWhereQuery generator query =
    foldr (\term expr -> expr E.&&. singleTermExpr term) (E.val True)
        $ T.words query
  where
    singleTermExpr :: T.Text -> E.SqlExpr (E.Value Bool)
    singleTermExpr term =
        foldr (E.||.) (E.val False) $ generator term

-- | Create an 'Update' for an Entity's field if there is a value inside
-- the Maybe.
mapUpdate :: E.PersistField a => EntityField e a -> Maybe a -> Maybe (Update e)
mapUpdate field =
    fmap (field =.)

-- | Similar to 'mapUpdate', but transforms the inner Maybe value before
-- creating the 'Update'.
mapUpdateWith :: E.PersistField b => EntityField e b -> Maybe a -> (a -> b) -> Maybe (Update e)
mapUpdateWith field param transform =
    mapUpdate field $ transform <$> param

-- | Sanitize text to be displayed as HTML to prevent XSS vulnerabilities.
--
-- Extends the 'sanitize' function to allow @iframe@ elements.
sanitize :: T.Text -> T.Text
sanitize = filterTags $
    safeTagsCustom (\n -> safeTagName n || customSafeTagName n) sanitizeAttribute
  where
    customSafeTagName :: T.Text -> Bool
    customSafeTagName n =
        n == "iframe"

-- Lifted from v0.3.6 of the xss-santize package.
-- TODO: Remove when upgrading to LTS 11.17+
safeTagsCustom
    :: (T.Text -> Bool)
    -> ((T.Text, T.Text) -> Maybe (T.Text, T.Text))
    -> [Tag T.Text]
    -> [Tag T.Text]
safeTagsCustom _ _ [] = []
safeTagsCustom safeName sanitizeAttr (t@(TagClose name):tags)
    | safeName name = t : safeTagsCustom safeName sanitizeAttr tags
    | otherwise = safeTagsCustom safeName sanitizeAttr tags
safeTagsCustom safeName sanitizeAttr (TagOpen name attributes:tags)
  | safeName name = TagOpen name (mapMaybe sanitizeAttr attributes) :
      safeTagsCustom safeName sanitizeAttr tags
  | otherwise = safeTagsCustom safeName sanitizeAttr tags
safeTagsCustom n a (t:tags) = t : safeTagsCustom n a tags
