module Auth.CreateAccount
    exposing
        ( Form
        , initial
        , Msg
        , update
        , view
        , successView
        )

import Dict exposing (Dict)
import Html exposing (..)
import Html.Attributes exposing (id, class, for, type_, required, value, selected)
import Html.Events exposing (onInput, onSubmit, on, targetValue)
import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode exposing (Value)
import RemoteData exposing (WebData)
import Api
import Auth.Utils exposing (noCommandOrStatus)
import PageData
import Ports
import User exposing (AuthStatus)
import Views.HorizontalForm as Form
import Routing exposing (Route(CreateAccountSuccess), reverse)


-- MODEL


type alias Form =
    { email : String
    , password : String
    , passwordConfirm : String
    , firstName : String
    , lastName : String
    , street : String
    , addressTwo : String
    , city : String
    , state : String
    , zipCode : String
    , country : String
    , phoneNumber : String
    , errors : Api.FormErrors
    }


initial : Form
initial =
    { email = ""
    , password = ""
    , passwordConfirm = ""
    , firstName = ""
    , lastName = ""
    , street = ""
    , addressTwo = ""
    , city = ""
    , state = ""
    , zipCode = ""
    , country = "US"
    , phoneNumber = ""
    , errors = Api.initialErrors
    }


encode : Form -> Value
encode model =
    let
        encodedState =
            (,) "state" <|
                case model.country of
                    "US" ->
                        if List.member model.state [ "AA", "AE", "AP" ] then
                            stateWithKey "armedForces"
                        else
                            stateWithKey "state"

                    "CA" ->
                        stateWithKey "province"

                    _ ->
                        stateWithKey "custom"

        stateWithKey key =
            Encode.object [ ( key, Encode.string model.state ) ]
    in
        [ ( "email", model.email )
        , ( "password", model.password )
        , ( "firstName", model.firstName )
        , ( "lastName", model.lastName )
        , ( "addressOne", model.street )
        , ( "addressTwo", model.addressTwo )
        , ( "city", model.city )
        , ( "zipCode", model.zipCode )
        , ( "country", model.country )
        , ( "telephone", model.phoneNumber )
        ]
            |> List.map (Tuple.mapSecond Encode.string)
            |> ((::) encodedState)
            |> Encode.object



-- UPDATE


type Msg
    = Email String
    | Password String
    | PasswordConfirm String
    | FirstName String
    | LastName String
    | Street String
    | AddressTwo String
    | City String
    | State String
    | ZipCode String
    | Country String
    | PhoneNumber String
    | SubmitForm
    | SubmitResponse (WebData (Result Api.FormErrors AuthStatus))


update : Msg -> Form -> ( Form, Maybe AuthStatus, Cmd Msg )
update msg form =
    case msg of
        Email str ->
            { form | email = str }
                |> noCommandOrStatus

        Password str ->
            { form | password = str }
                |> noCommandOrStatus

        PasswordConfirm str ->
            { form | passwordConfirm = str }
                |> noCommandOrStatus

        FirstName str ->
            { form | firstName = str }
                |> noCommandOrStatus

        LastName str ->
            { form | lastName = str }
                |> noCommandOrStatus

        Street str ->
            { form | street = str }
                |> noCommandOrStatus

        AddressTwo str ->
            { form | addressTwo = str }
                |> noCommandOrStatus

        City str ->
            { form | city = str }
                |> noCommandOrStatus

        State str ->
            { form | state = str }
                |> noCommandOrStatus

        ZipCode str ->
            { form | zipCode = str }
                |> noCommandOrStatus

        Country str ->
            { form | country = str }
                |> noCommandOrStatus

        PhoneNumber str ->
            { form | phoneNumber = str }
                |> noCommandOrStatus

        SubmitForm ->
            if form.password /= form.passwordConfirm then
                ( { form
                    | errors =
                        Api.initialErrors
                            |> Api.addError "passwordConfirm" "Passwords do not match."
                            |> Api.addError "password" "Passwords do not match."
                  }
                , Nothing
                , Ports.scrollToID "form-errors-text"
                )
            else
                ( { form | errors = Api.initialErrors }, Nothing, createNewAccount form )

        -- TODO: Better error case handling/feedback
        SubmitResponse response ->
            case response of
                RemoteData.Success (Ok authStatus) ->
                    ( form
                    , Just authStatus
                    , Routing.newUrl CreateAccountSuccess
                    )

                RemoteData.Success (Err errors) ->
                    ( { form | errors = errors }
                    , Nothing
                    , Ports.scrollToID "form-errors-text"
                    )

                _ ->
                    form |> noCommandOrStatus


createNewAccount : Form -> Cmd Msg
createNewAccount form =
    Api.post "/api/customers/register/"
        |> Api.withJsonBody (encode form)
        |> Api.withJsonResponse User.decoder
        |> Api.withErrorHandler SubmitResponse



-- VIEW
-- TODO: This was the first form validation so it's pretty ad-hoc, refactor,
-- maybe with a custom type for each Fields & functions to pull proper data out
-- of each field? Maybe wait til we have multiple validation forms and pull out
-- commonalities? Brainstorm a bit.


view : (Msg -> msg) -> Form -> PageData.LocationData -> List (Html msg)
view tagger model locations =
    let
        errorText =
            if Dict.isEmpty model.errors then
                text ""
            else
                div [ id "form-errors-text", class "alert alert-danger" ]
                    [ text <|
                        "There were issues processing your information, "
                            ++ "please correct any errors detailed below "
                            ++ "& resubmit the form."
                    ]

        requiredField s msg =
            inputField s msg True

        optionalField s msg =
            inputField s msg False

        inputField selector msg =
            Form.inputRow model.errors (selector model) (tagger << msg)

        countrySelect =
            List.map (locationToOption .country) locations.countries
                |> select
                    [ id "Country"
                    , class "form-control"
                    , onSelect <| tagger << Country
                    ]
                |> List.singleton
                |> Form.withLabel "Country" True

        locationToOption selector { code, name } =
            option [ value code, selected <| selector model == code ]
                [ text name ]

        regionField =
            case model.country of
                "US" ->
                    regionSelect "State" (locations.states ++ locations.armedForces)

                "CA" ->
                    regionSelect "Province" locations.provinces

                _ ->
                    input
                        [ id "inputState/Province"
                        , class "form-control"
                        , type_ "text"
                        , onInput <| tagger << State
                        , value model.state
                        ]
                        []
                        |> List.singleton
                        |> Form.withLabel "State / Province" True

        regionSelect labelText =
            List.map (locationToOption .state)
                >> select
                    [ id <| "input" ++ labelText
                    , class "form-control"
                    , onSelect <| tagger << State
                    ]
                >> List.singleton
                >> Form.withLabel labelText True

        onSelect msg =
            targetValue
                |> Decode.map msg
                |> on "change"
    in
        [ h1 [] [ text "Create an Account" ]
        , hr [] []
        , errorText
        , form [ onSubmit <| tagger SubmitForm ]
            [ fieldset []
                [ legend [] [ text "Login Information" ]
                , requiredField .email Email "Email" "email" "email"
                , requiredField .password Password "Password" "password" "password"
                , requiredField .passwordConfirm PasswordConfirm "Confirm Password" "password" "passwordConfirm"
                ]
            , fieldset []
                [ legend [] [ text "Contact Information" ]
                , requiredField .firstName FirstName "First Name" "text" "firstName"
                , requiredField .lastName LastName "Last Name" "text" "lastName"
                , requiredField .street Street "Street Address" "text" "addressOne"
                , optionalField .addressTwo AddressTwo "Address Line 2" "text" ""
                , requiredField .city City "City" "text" "city"
                , regionField
                , requiredField .zipCode ZipCode "Zip Code" "text" "zipCode"
                , countrySelect
                , requiredField .phoneNumber PhoneNumber "Phone Number" "tel" "telephone"
                ]
            , Form.submitButton "Register" True
            ]
        ]


successView : List (Html msg)
successView =
    [ h1 [] [ text "Account Successfully Created" ]
    , hr [] []
    , p []
        [ text <|
            String.join " "
                [ "Congratulations, your new account has been successfully created!"
                , "A confirmation has been sent to your email address."
                ]
        ]
    ]