module Main exposing (main)

import Html exposing (Html, text, div, h1, h3, h4, hr, node, br, a, img, span, button, ul, li, small, table, tbody, tr, td, b, label, select, option)
import Html.Attributes exposing (attribute, id, class, href, src, type_, target, tabindex, title, value, for, selected)
import Html.Attributes.Extra exposing (innerHtml)
import Html.Events exposing (on, targetValue)
import Http
import Json.Decode as Decode
import Navigation
import Paginate exposing (PaginatedList)
import RemoteData exposing (WebData)
import Messages exposing (Msg(..))
import PageData exposing (PageData)
import Products.Pagination as Pagination
import Products.Sorting as Sorting
import Routing exposing (Route(..), reverse, parseRoute)
import SeedAttribute exposing (SeedAttribute)
import SiteUI exposing (NavigationData)
import SiteUI.Footer as SiteFooter
import SiteUI.Header as SiteHeader
import SiteUI.Navigation as SiteNavigation
import SiteUI.Sidebar as SiteSidebar
import Views.Images as Images
import Views.Utils exposing (routeLinkAttributes, htmlOrBlank)


main : Program Never Model Msg
main =
    Navigation.program (parseRoute >> UrlUpdate)
        { init = init
        , update = update
        , subscriptions = always Sub.none
        , view = view
        }



-- MODEL


type alias Model =
    { navigationData : WebData NavigationData
    , route : Route
    , pageData : PageData
    }


init : Navigation.Location -> ( Model, Cmd Msg )
init location =
    let
        route =
            parseRoute location

        ( model, cmd ) =
            fetchDataForRoute
                { navigationData = RemoteData.Loading
                , route = route
                , pageData = PageData.initial
                }
    in
        ( model
        , Cmd.batch
            [ cmd
            , getNavigationData
            ]
        )



-- COMMANDS


fetchDataForRoute : Model -> ( Model, Cmd Msg )
fetchDataForRoute ({ route, pageData } as model) =
    let
        ( data, cmd ) =
            case route of
                ProductDetails slug ->
                    ( { pageData | productDetails = RemoteData.Loading }
                    , getProductDetailsData slug
                    )

                CategoryDetails slug _ _ ->
                    ( { pageData | categoryDetails = RemoteData.Loading }
                    , getCategoryDetailsData slug
                    )
    in
        ( { model | pageData = data }, cmd )


getProductDetailsData : String -> Cmd Msg
getProductDetailsData slug =
    Http.get ("/api/products/" ++ slug ++ "/")
        PageData.productDetailsDecoder
        |> RemoteData.sendRequest
        |> Cmd.map GetProductDetailsData


getCategoryDetailsData : String -> Cmd Msg
getCategoryDetailsData slug =
    Http.get ("/api/categories/details/" ++ slug ++ "/")
        PageData.categoryDetailsDecoder
        |> RemoteData.sendRequest
        |> Cmd.map GetCategoryDetailsData


getNavigationData : Cmd Msg
getNavigationData =
    Http.get "/api/categories/nav/" SiteUI.navigationDecoder
        |> RemoteData.sendRequest
        |> Cmd.map GetNavigationData



-- UPDATE


urlUpdate : Route -> Model -> ( Model, Cmd Msg )
urlUpdate newRoute ({ pageData } as model) =
    let
        modelWithNewRoute =
            { model | route = newRoute }
    in
        case ( newRoute, model.route ) of
            ( CategoryDetails newSlug newPagination newSort, CategoryDetails oldSlug _ _ ) ->
                if newSlug /= oldSlug then
                    fetchDataForRoute modelWithNewRoute
                else
                    ( { modelWithNewRoute | pageData = PageData.update newRoute pageData }
                    , Cmd.none
                    )

            _ ->
                fetchDataForRoute modelWithNewRoute


update : Msg -> Model -> ( Model, Cmd Msg )
update msg ({ pageData } as model) =
    case msg of
        UrlUpdate route ->
            urlUpdate route model

        NavigateTo route ->
            ( model, Navigation.newUrl <| reverse route )

        GetProductDetailsData response ->
            let
                updatedPageData =
                    { pageData | productDetails = response }
            in
                ( { model | pageData = updatedPageData }, Cmd.none )

        GetCategoryDetailsData response ->
            let
                updatedPageData =
                    { pageData | categoryDetails = response }
                        |> PageData.update model.route
            in
                ( { model | pageData = updatedPageData }, Cmd.none )

        GetNavigationData response ->
            ( { model | navigationData = logUnsuccessfulRequest response }, Cmd.none )


logUnsuccessfulRequest : WebData a -> WebData a
logUnsuccessfulRequest response =
    case response of
        RemoteData.Success _ ->
            response

        _ ->
            Debug.log "Unsuccessful Request Returned" response



-- VIEW


view : Model -> Html Msg
view { route, pageData, navigationData } =
    let
        middleContent =
            div [ class "container" ]
                [ div [ class "row" ]
                    [ div [ class "col order-md-2" ] pageContent
                    , SiteSidebar.view
                    ]
                ]

        pageContent =
            case route of
                ProductDetails _ ->
                    withIntermediateText productDetailsView pageData.productDetails

                CategoryDetails _ pagination sortData ->
                    withIntermediateText (categoryDetailsView pagination sortData) pageData.categoryDetails
    in
        div []
            [ SiteHeader.view
            , SiteNavigation.view navigationData
            , middleContent
            , SiteFooter.view
            ]


withIntermediateText : (a -> List (Html msg)) -> WebData a -> List (Html msg)
withIntermediateText view data =
    case data of
        RemoteData.Loading ->
            [ text "Loading..." ]

        RemoteData.Success d ->
            view d

        e ->
            [ text <| toString e ]


productDetailsView : PageData.ProductDetails -> List (Html Msg)
productDetailsView { product, variants, maybeSeedAttribute, categories } =
    let
        categoryBlocks =
            List.filter (not << String.isEmpty << .description) categories
                |> List.map
                    (\category ->
                        div [ class "product-category" ]
                            [ h3 [ class "mt-3" ]
                                [ a (routeLinkAttributes <| CategoryDetails category.slug Pagination.default Sorting.default)
                                    [ text category.name ]
                                ]
                            , div [ innerHtml category.description ] []
                            ]
                    )
    in
        [ h1 []
            [ text product.name
            , htmlOrBlank SeedAttribute.icons maybeSeedAttribute
            ]
        , hr [] []
        , div [ class "product-details" ]
            [ div [ class "clearfix" ]
                [ div [ class "float-left col-sm-4 col-md-5 col-lg-4" ]
                    [ div
                        [ class "card" ]
                        [ div [ class "card-body text-center p-1" ]
                            [ img
                                [ src << Images.media <| "products/" ++ product.imageURL
                                , class "img-fluid"
                                ]
                                []
                            ]
                        ]
                    ]
                , div [ class "float-right col-sm-4 col-md-3 col-lg-3" ]
                    [ div [ class "card" ]
                        [ div [ class "card-body text-center p-2" ]
                            [ h4 [] [ text "$999.99" ]
                            , text "ADD TO CART BUTTON"
                            , small [ class "text-muted d-block" ]
                                [ text <| "Item #" ++ product.baseSKU
                                ]
                            ]
                        ]
                    ]
                , div [ class "col" ]
                    [ div [ innerHtml product.longDescription ] [] ]
                , div [ class "col-12" ] categoryBlocks
                ]
            ]
        ]


categoryDetailsView : Pagination.Data -> Sorting.Option -> PageData.CategoryDetails -> List (Html Msg)
categoryDetailsView pagination sortData { category, subCategories, products } =
    let
        subCategoryCards =
            if List.length subCategories > 0 then
                List.map subCategoryCard subCategories
                    |> div [ class "row" ]
            else
                text ""

        subCategoryCard category =
            div [ class "col-6 col-sm-4 col-md-3 mb-2" ]
                [ a (routeLinkAttributes <| CategoryDetails category.slug Pagination.default Sorting.default)
                    [ div [ class "h-100 text-center" ]
                        [ img [ class "img-fluid mx-auto", src <| Images.media category.imageURL ] []
                        , div [ class "my-auto" ] [ text category.name ]
                        ]
                    ]
                ]

        sortHtml =
            if Paginate.length products > 1 then
                div [ class "d-flex mb-2 justify-content-between align-items-center" ] [ sortingInput ]
            else
                text ""

        sortingInput : Html Msg
        sortingInput =
            div [ class "form-inline" ]
                [ label [ class "col-form-label font-weight-bold", for "product-sort-select" ]
                    [ text "Sort by:" ]
                , text " "
                , select
                    [ id "product-sort-select"
                    , class "form-control form-control-sm ml-2"
                    , onProductsSortSelect (NavigateTo << CategoryDetails category.slug pagination)
                    ]
                  <|
                    List.map
                        (\data ->
                            option
                                [ value <| Sorting.toQueryValue data
                                , selected (data == sortData)
                                ]
                                [ text <| Sorting.toDescription data ]
                        )
                        Sorting.all
                ]

        onProductsSortSelect : (Sorting.Option -> msg) -> Html.Attribute msg
        onProductsSortSelect msg =
            targetValue
                |> Decode.map (Sorting.fromQueryValue >> msg)
                |> on "change"

        paginationHtml =
            div [ class "d-flex mb-2 justify-content-between align-items-center" ] [ pagingText, pager ]

        pagingText =
            if Paginate.length products == 0 then
                text ""
            else
                span []
                    [ text "Displaying "
                    , b [] [ text <| pagingStart () ]
                    , text " to "
                    , b [] [ text <| pagingEnd () ]
                    , text " (of "
                    , b [] [ text <| toString <| Paginate.length products ]
                    , text " products)"
                    ]

        pagingStart _ =
            toString <|
                (Paginate.currentPage products - 1)
                    * pagination.perPage
                    + 1

        pagingEnd _ =
            toString <|
                if Paginate.isLast products || Paginate.length products < pagination.perPage then
                    Paginate.length products
                else
                    (Paginate.currentPage products * pagination.perPage)

        pager =
            if Paginate.totalPages products <= 1 then
                text ""
            else
                node "nav"
                    [ attribute "aria-label" "Category Product Pages" ]
                    [ ul [ class "pagination pagination-sm mb-0" ] <|
                        previousLink ()
                            :: Paginate.pager renderPager products
                            ++ [ nextLink () ]
                    ]

        previousLink _ =
            let
                previousPage =
                    max 1 (pagination.page - 1)

                previousRoute =
                    CategoryDetails category.slug { pagination | page = previousPage } sortData
            in
                prevNextLink Paginate.isFirst previousRoute "« Prev"

        nextLink _ =
            let
                nextPage =
                    min (Paginate.totalPages products) (pagination.page + 1)

                nextRoute =
                    CategoryDetails category.slug { pagination | page = nextPage } sortData
            in
                prevNextLink Paginate.isLast nextRoute "Next »"

        prevNextLink isDisabled route content =
            let
                ( itemClass, linkAttrs ) =
                    if isDisabled products then
                        ( " disabled", [ tabindex -1 ] )
                    else
                        ( "", [] )
            in
                li [ class <| "page-item" ++ itemClass ]
                    [ a (class "page-link" :: linkAttrs ++ routeLinkAttributes route)
                        [ text content ]
                    ]

        renderPager page isCurrent =
            let
                itemClass =
                    if isCurrent then
                        "page-item active"
                    else
                        "page-item"
            in
                li [ class itemClass ]
                    [ a
                        ([ class "page-link" ]
                            ++ routeLinkAttributes
                                (CategoryDetails category.slug
                                    { pagination | page = page }
                                    sortData
                                )
                        )
                        [ text <| toString page ]
                    ]

        productRows =
            flip List.map (Paginate.page products) <|
                \( product, variants, maybeSeedAttribute ) ->
                    tr []
                        [ td [ class "category-product-image text-center align-middle" ]
                            [ a (routeLinkAttributes <| ProductDetails product.slug)
                                [ img
                                    [ src << Images.media <| "products/" ++ product.imageURL
                                    ]
                                    []
                                ]
                            ]
                        , td []
                            [ h3 [ class "mb-0" ]
                                [ a
                                    ([ innerHtml product.name ]
                                        ++ (routeLinkAttributes <| ProductDetails product.slug)
                                    )
                                    []
                                , htmlOrBlank SeedAttribute.icons maybeSeedAttribute
                                ]
                            , div [ innerHtml product.longDescription ] []
                            ]
                        , td [ class "text-center align-middle" ]
                            [ div []
                                [ div [ class "font-weight-bold" ] [ text "$999.99" ]
                                , div [] [ text "CART_INPUT" ]
                                , small [ class "text-muted" ]
                                    [ text <| "Item # " ++ product.baseSKU ]
                                ]
                            ]
                        ]
    in
        [ div [ class "d-flex align-items-center" ]
            [ img [ class "img-fluid", src <| Images.media category.imageURL ] []
            , h1 [ class "mb-0 pl-2" ] [ text category.name ]
            ]
        , hr [ class "mt-2" ] []
        , div [ innerHtml category.description ] []
        , subCategoryCards
        , sortHtml
        , paginationHtml
        , table [ class "category-products table table-striped table-sm mb-2" ]
            [ tbody [] <| productRows ]
        , paginationHtml
        , SeedAttribute.legend
        ]
