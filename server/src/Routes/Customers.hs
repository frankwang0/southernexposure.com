{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators #-}
module Routes.Customers
    ( CustomerAPI
    , customerRoutes
    ) where

import Control.Monad ((>=>), when, void)
import Control.Monad.Trans (lift)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (ToJSON(..), FromJSON(..), (.=), (.:), (.:?), withObject, object)
import Data.Int (Int64)
import Data.Maybe (fromMaybe)
import Data.Text.Encoding (encodeUtf8, decodeUtf8)
import Database.Persist ((=.), Entity(..), get, getBy, insertUnique, update)
import Database.Persist.Sql (toSqlKey)
import Servant ((:>), (:<|>)(..), AuthProtect, ReqBody, JSON, Get, Post, Put, errBody, err403, err500, throwError)

import Auth
import Models
import Models.Fields (Country(..), Region, ArmedForcesRegionCode, armedForcesRegion)
import Server
import Validation (Validation(..))

import qualified Crypto.BCrypt as BCrypt
import qualified Data.ISO3166_CountryCodes as CountryCodes
import qualified Data.StateCodes as StateCodes
import qualified Data.Text as T
import qualified Data.UUID as UUID
import qualified Data.UUID.V4 as UUID4
import qualified Models.ProvinceCodes as ProvinceCodes
import qualified Validation as V


type CustomerAPI =
         "locations" :> LocationRoute
    :<|> "register" :> RegisterRoute
    :<|> "login" :> LoginRoute
    :<|> "authorize" :> AuthorizeRoute
    :<|> "edit" :> EditDetailsRoute

type CustomerRoutes =
         App LocationData
    :<|> (RegistrationParameters -> App AuthorizationData)
    :<|> (LoginParameters -> App AuthorizationData)
    :<|> (AuthorizeParameters -> App AuthorizationData)
    :<|> (AuthToken -> EditDetailsParameters -> App ())

customerRoutes :: CustomerRoutes
customerRoutes =
         locationRoute
    :<|> registrationRoute
    :<|> loginRoute
    :<|> authorizeRoute
    :<|> editDetailsRoute


-- AUTHORIZATION DATA


data AuthorizationData =
    AuthorizationData
        { adId :: CustomerId
        , adFirstName :: T.Text
        , adLastName :: T.Text
        , adEmail :: T.Text
        , adToken :: T.Text
        } deriving (Show)

instance ToJSON AuthorizationData where
    toJSON authData =
        object [ "id" .= toJSON (adId authData)
               , "firstName" .= toJSON (adFirstName authData)
               , "lastName" .= toJSON (adLastName authData)
               , "email" .= toJSON (adEmail authData)
               , "token" .= toJSON (adToken authData)
               ]

customerToAuthorizationData :: Entity Customer -> AuthorizationData
customerToAuthorizationData (Entity customerId customer) =
    AuthorizationData
        { adId = customerId
        , adFirstName = customerFirstName customer
        , adLastName = customerLastName customer
        , adEmail = customerEmail customer
        , adToken = customerAuthToken customer
        }


-- LOCATIONS


data Location a =
    Location
        { lCode :: a
        , lName :: T.Text
        }

instance (Show a) => ToJSON (Location a) where
    toJSON Location { lCode, lName } =
        object [ "code" .= toJSON (show lCode)
               , "name" .= toJSON lName
               ]

data LocationData =
    LocationData
        { ldCountries :: [Location CountryCodes.CountryCode]
        , ldUSStates :: [Location StateCodes.StateCode]
        , ldAFRegions :: [Location ArmedForcesRegionCode]
        , ldCAProvinces :: [Location ProvinceCodes.ProvinceCode]
        }

instance ToJSON LocationData where
    toJSON LocationData { ldCountries, ldUSStates, ldAFRegions, ldCAProvinces } =
        object [ "countries" .= toJSON ldCountries
               , "states" .= toJSON ldUSStates
               , "armedForces" .= toJSON ldAFRegions
               , "provinces" .= toJSON ldCAProvinces
               ]

type LocationRoute =
    Get '[JSON] LocationData

locationRoute :: App LocationData
locationRoute =
    let
        initialCountries =
            [CountryCodes.US, CountryCodes.CA, CountryCodes.MX]

        countries =
            map (\c -> Location c . T.pack $ CountryCodes.readableCountryName c)
                $ initialCountries
                ++ filter (`notElem` initialCountries)
                    (enumFromTo minBound maxBound)
        states =
            map (uncurry $ flip Location) StateCodes.stateList

        armedForcesRegions =
            map (\r -> Location r $ armedForcesRegion r)
                $ enumFrom minBound

        provinces =
            map (\c -> Location c $ ProvinceCodes.toName c) ProvinceCodes.all
    in
        return LocationData
            { ldCountries = countries
            , ldUSStates = states
            , ldAFRegions = armedForcesRegions
            , ldCAProvinces = provinces
            }



-- REGISTER


data RegistrationParameters =
    RegistrationParameters
        { rpEmail :: T.Text
        , rpPassword :: T.Text
        , rpFirstName :: T.Text
        , rpLastName :: T.Text
        , rpAddressOne :: T.Text
        , rpAddressTwo :: T.Text
        , rpCity :: T.Text
        , rpState :: Region
        , rpZipCode :: T.Text
        , rpCountry :: Country
        , rpTelephone :: T.Text
        } deriving (Show)

instance FromJSON RegistrationParameters where
    parseJSON =
        withObject "RegistrationParameters" $ \v ->
            RegistrationParameters
                <$> v .: "email"
                <*> v .: "password"
                <*> v .: "firstName"
                <*> v .: "lastName"
                <*> v .: "addressOne"
                <*> v .: "addressTwo"
                <*> v .: "city"
                <*> v .: "state"
                <*> v .: "zipCode"
                <*> v .: "country"
                <*> v .: "telephone"

instance Validation RegistrationParameters where
    -- TODO: Better validation, validate emails, compare to Zencart
    validators parameters = do
        emailDoesntExist <- V.doesntExist $ UniqueEmail $ rpEmail parameters
        return
            [ ( "email"
              , [ V.required $ rpEmail parameters
                  , ( "An Account with this Email already exists."
                    , emailDoesntExist )
                ]
              )
            , ( "password"
              , [ V.required $ rpPassword parameters
                , V.minimumLength 8 $ rpPassword parameters
                ]
              )
            , ( "firstName", [ V.required $ rpFirstName parameters ])
            , ( "lastName", [ V.required $ rpLastName parameters ])
            , ( "addressOne", [ V.required $ rpAddressOne parameters ])
            , ( "city", [ V.required $ rpCity parameters ])
            , ( "zipCode", [ V.required $ rpZipCode parameters ])
            , ( "telephone", [ V.required $ rpTelephone parameters ])
            ]

type RegisterRoute =
       ReqBody '[JSON] RegistrationParameters
    :> Post '[JSON] AuthorizationData

registrationRoute :: RegistrationParameters -> App AuthorizationData
registrationRoute = validate >=> \parameters -> do
    encryptedPass <- hashPassword $ rpPassword parameters
    authToken <- generateToken
    maybeCustomerId <- runDB . insertUnique $
        Customer
            { customerEmail = rpEmail parameters
            , customerEncryptedPassword = encryptedPass
            , customerAuthToken = authToken
            , customerIsAdmin = False
            , customerFirstName = rpFirstName parameters
            , customerLastName = rpLastName parameters
            , customerAddressOne = rpAddressOne parameters
            , customerAddressTwo = rpAddressTwo parameters
            , customerCity = rpCity parameters
            , customerState = rpState parameters
            , customerZipCode = rpZipCode parameters
            , customerCountry = rpCountry parameters
            , customerTelephone = rpTelephone parameters
            }
    case maybeCustomerId of
        Nothing ->
            lift $ throwError err500
        Just customerId ->
            return AuthorizationData
                { adId = customerId
                , adFirstName = rpFirstName parameters
                , adLastName = rpLastName parameters
                , adEmail = rpEmail parameters
                , adToken = authToken
                }

generateToken :: App T.Text
generateToken = do
    token <- UUID.toText <$> liftIO UUID4.nextRandom
    maybeCustomer <- runDB . getBy $ UniqueToken token
    case maybeCustomer of
        Just _ ->
            generateToken
        Nothing ->
            return token

hashPassword :: T.Text -> App T.Text
hashPassword password = do
    maybePass <- liftIO . BCrypt.hashPasswordUsingPolicy BCrypt.slowerBcryptHashingPolicy
        $ encodeUtf8 password
    case maybePass of
        Nothing ->
            lift . throwError
                $ err500 { errBody = "Misconfigured Hashing Policy" }
        Just pass ->
            return $ decodeUtf8 pass


-- LOGIN


data LoginParameters =
    LoginParameters
        { lpEmail :: T.Text
        , lpPassword :: T.Text
        }

instance FromJSON LoginParameters where
    parseJSON =
        withObject "LoginParameters" $ \v ->
            LoginParameters
                <$> v .: "email"
                <*> v .: "password"

type LoginRoute =
       ReqBody '[JSON] LoginParameters
    :> Post '[JSON] AuthorizationData

loginRoute :: LoginParameters -> App AuthorizationData
loginRoute LoginParameters { lpEmail, lpPassword } =
    let
        authorizationError =
            V.singleError "Invalid Email or Password."
        resetRequiredError =
            hashAnyways $ V.singleError
                "Sorry, you need to reset your password before logging in."
    in do
        maybeCustomer <- runDB . getBy $ UniqueEmail lpEmail
        case maybeCustomer of
            Just e@(Entity _ customer) -> do
                isValid <- validatePassword e
                when (customerEncryptedPassword customer == "") resetRequiredError
                if isValid then
                    return $ customerToAuthorizationData e
                else
                    authorizationError
            Nothing ->
                hashAnyways authorizationError
    where hashAnyways returnValue = do
            hash <- liftIO . BCrypt.hashPasswordUsingPolicy BCrypt.slowerBcryptHashingPolicy
                $ encodeUtf8 lpPassword
            const returnValue $! hash
          validatePassword (Entity customerId customer) =
            let
                hashedPassword =
                    encodeUtf8 $ customerEncryptedPassword customer
                isValid =
                    BCrypt.validatePassword hashedPassword
                        (encodeUtf8 lpPassword)
                usesPolicy =
                    BCrypt.hashUsesPolicy BCrypt.slowerBcryptHashingPolicy
                        hashedPassword
            in
                if isValid && usesPolicy then
                    return True
                else if isValid then do
                    maybeNewHash <- liftIO . BCrypt.hashPasswordUsingPolicy
                        BCrypt.slowerBcryptHashingPolicy
                        $ encodeUtf8 lpPassword
                    newHash <- maybe
                        (lift . throwError $ err500 { errBody = "Misconfigured Hashing Policy" })
                        (return . decodeUtf8) maybeNewHash
                    runDB $ update customerId [CustomerEncryptedPassword =. newHash]
                    return True
                else
                    return False


-- AUTHORIZE


data AuthorizeParameters =
    AuthorizeParameters
        { apUserId :: Int64
        , apToken :: T.Text
        }

instance FromJSON AuthorizeParameters where
    parseJSON = withObject "AuthorizeParameters" $ \v ->
        AuthorizeParameters
            <$> v .: "userId"
            <*> v .: "token"

type AuthorizeRoute =
       ReqBody '[JSON] AuthorizeParameters
    :> Post '[JSON] AuthorizationData

authorizeRoute :: AuthorizeParameters -> App AuthorizationData
authorizeRoute AuthorizeParameters { apUserId, apToken } =
    let
        userId = toSqlKey apUserId
    in do
        maybeCustomer <- runDB $ get userId
        case maybeCustomer of
            Just customer ->
                if apToken == customerAuthToken customer then
                    return $ customerToAuthorizationData (Entity userId customer )
                else
                    lift $ throwError err403
            Nothing ->
                lift $ throwError err403


-- EDIT DETAILS


data EditDetailsParameters =
    EditDetailsParameters
        { edpEmail :: Maybe T.Text
        , edpPassword :: Maybe T.Text
        }

instance FromJSON EditDetailsParameters where
    parseJSON = withObject "EditDetailsParameters" $ \v ->
        EditDetailsParameters
            <$> v .:? "email"
            <*> v .:? "password"

instance Validation (EditDetailsParameters, Customer) where
    validators (parameters, customer) = do
        maybeEmailDoesntExist <- mapM (V.doesntExist . UniqueEmail) $ edpEmail parameters
        return
            [ ( "email"
              , [ ( "An Account with this Email already exists."
                  , flip (maybe False) (edpEmail parameters) $ \e ->
                        (fromMaybe False maybeEmailDoesntExist)
                        && (e /= customerEmail customer)
                  )
                ]
              )
            , ( "password"
              , [ maybe ("", False) (V.minimumLength 8) $ edpPassword parameters
                ]
              )
            ]


type EditDetailsRoute =
       AuthProtect "auth-token"
    :> ReqBody '[JSON] EditDetailsParameters
    :> Put '[JSON] ()

editDetailsRoute :: AuthToken -> EditDetailsParameters -> App ()
editDetailsRoute token p = do
    (Entity customerId customer) <- validateToken token
    (parameters, _) <- validate (p, customer)
    maybeHash <- mapM hashPassword $ edpPassword parameters
    void . runDB . update customerId $ updateFields (edpEmail parameters) maybeHash
    where updateFields maybeEmail maybePassword =
            concat
                [ maybe [] (\e -> [CustomerEmail =. e]) maybeEmail
                , maybe [] (\e -> [CustomerEncryptedPassword =. e]) maybePassword
                ]