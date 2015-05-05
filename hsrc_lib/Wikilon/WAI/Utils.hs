{-# LANGUAGE OverloadedStrings #-}

-- | miscellaneous utility functions to create web services
module Wikilon.WAI.Utils
    -- MIDDLEWARE 
    ( routeOnMethod
    , routeOnMethod'
    , branchOnMedia
    , branchOnMedia'
    , mustAcceptCharsetUtf8

    -- APPS
    , defaultRouteOnMethod


    -- HEADERS
    , textHtml
    , plainText
    , noCache

    -- HTML
    , HTML
    , renderHTML
    , htmlMetaNoIndex
    , htmlMetaCharsetUtf8

    , module Wikilon.WAI.Types
    ) where

--import Control.Monad
import Control.Applicative
import Data.Maybe (listToMaybe)
import qualified Data.List as L
import qualified Data.ByteString as BS
--import qualified Data.ByteString.UTF8 as UTF8
import qualified Data.ByteString.Lazy as LBS
import qualified Data.ByteString.Lazy.UTF8 as LazyUTF8
import Text.Blaze.Html5 ((!))
import qualified Text.Blaze.Html5 as HTML
import qualified Text.Blaze.Html5.Attributes as Attrib
import qualified Text.Blaze.Html.Renderer.Utf8
import qualified Network.HTTP.Types as HTTP
import qualified Network.HTTP.Media as HTTP
-- import qualified Network.HTTP.Types.Header as HTTP
import qualified Network.Wai as Wai
import Wikilon.WAI.Types


-- | Route based on method. Also provides reasonable default
-- implementations for OPTIONS and HEAD.
routeOnMethod :: [(HTTP.Method, WikilonApp)] -> WikilonApp
routeOnMethod lms = routeOnMethod' lms (defaultRouteOnMethod lms)

-- | route on methods, with a fallback if none of the methods match
routeOnMethod' :: [(HTTP.Method, WikilonApp)] -> WikilonApp -> WikilonApp
routeOnMethod' lms def w cap rq k =
    case L.lookup (Wai.requestMethod rq) lms of
        Just app -> app w cap rq k
        Nothing -> def w cap rq k
{-# INLINE routeOnMethod' #-}

-- | Fallback behavior after every entry in the method table has failed.
-- This provides default implementations for OPTIONS and HEAD.
defaultRouteOnMethod :: [(HTTP.Method, WikilonApp)] -> WikilonApp
defaultRouteOnMethod lms w cap rq k = body where
    m = Wai.requestMethod rq
    body = 
        if (m == HTTP.methodOptions) then options else
        if (m == HTTP.methodHead) then tryHead else
        notAllowed
    tryHead = case L.lookup HTTP.methodGet lms of
        Nothing -> notAllowed
        Just app -> app w cap rq $ \ response ->
            let status = Wai.responseStatus response in
            let headers = Wai.responseHeaders response in
            k $ Wai.responseLBS status headers LBS.empty
    notAllowed = k $ eNotAllowed (fst <$> lms)
    options = k $ msgOptions (fst <$> lms)

eNotAllowed, msgOptions :: [HTTP.Method] -> Wai.Response

eNotAllowed methods = 
    let status = HTTP.methodNotAllowed405 in
    let headers = [allow methods, textHtml, noCache] in
    Wai.responseLBS status headers $ renderHTML $ do 
    HTML.head $ do
        htmlMetaCharsetUtf8
        htmlMetaNoIndex
        HTML.title "405 Method Not Allowed"
    HTML.body $ bodyMethodsAllowed methods

msgOptions methods =
    let status = HTTP.ok200 in
    let headers = [allow methods, textHtml] in
    Wai.responseLBS status headers $ renderHTML $ do
    HTML.head $ do
        htmlMetaCharsetUtf8
        HTML.title "OPTIONS"
    HTML.body $ bodyMethodsAllowed methods

allow :: [HTTP.Method] -> HTTP.Header
allow methods = ("Allow", BS.intercalate ", " methods)

bodyMethodsAllowed :: [HTTP.Method] -> HTML
bodyMethodsAllowed methods = do
    HTML.p "Methods specifically implemented for this resource: "
    HTML.ul $ mapM_ (HTML.li . HTML.string . show) methods
    HTML.p "HEAD and OPTIONS may have default implementations."

-- I might later wish to validate acceptability of the utf-8 charset
-- by the client. For now, however, I'm going to simply assume it.
-- For most user agents (and certainly for the few I care about)
-- this assumption is valid.
mustAcceptCharsetUtf8 :: WikilonApp -> WikilonApp
mustAcceptCharsetUtf8 = id

-- | Select an application based on a preferred media output. This
-- is mostly for GET requests. Branching on input content type for
-- PUT or POST will require a separate function.
branchOnMedia :: [(HTTP.MediaType, WikilonApp)] -> WikilonApp
branchOnMedia lms = branchOnMedia' lms $ \ _w _cap _rq k ->
    k $ eNotAcceptable (fst <$> lms)

-- somewhat ad-hoc for now...
eNotAcceptable :: [HTTP.MediaType] -> Wai.Response
eNotAcceptable mediaTypes = 
    let status = HTTP.notAcceptable406 in
    let headers = [noCache, textHtml] in
    Wai.responseLBS status headers $ renderHTML $ do
    HTML.head $ do
        htmlMetaCharsetUtf8
        htmlMetaNoIndex
        HTML.title (HTML.string "406 Not Acceptable")
    HTML.body $ do
        HTML.p $ HTML.string "Available media types for this resource: "
        HTML.ul $ mapM_ (HTML.li . HTML.string . show) mediaTypes  

-- | Select a media type based on preferred media output, with a
-- fallback behavior on 406 Not Acceptable. 
branchOnMedia' :: [(HTTP.MediaType, WikilonApp)] -> WikilonApp -> WikilonApp
branchOnMedia' lms e406 w cap rq k =
    let app0 = maybe e406 snd $ listToMaybe lms in -- first in list
    case L.lookup HTTP.hAccept (Wai.requestHeaders rq) of
        Nothing -> app0 w cap rq k -- no client preference
        Just hdrAccept -> case HTTP.mapAcceptMedia lms hdrAccept of
            Nothing -> e406 w cap rq k
            Just app -> app w cap rq k

-- | Content-Type: text\/html; charset=utf-8
textHtml :: HTTP.Header
textHtml = (HTTP.hContentType, "text/html; charset=utf-8")

-- | Content-Type: text\/plain; charset=utf-8
plainText :: HTTP.Header
plainText = (HTTP.hContentType,"text/plain; charset=utf-8")

-- | Cache-Control: no-cache
noCache :: HTTP.Header
noCache = (HTTP.hCacheControl, "no-cache")

-- | since I'm not fond of blaze-html's mixed-case abbreviations...
type HTML = HTML.Html

-- | Render HTML5 to a lazy bytestring. This also adds the outer
-- \<html\> tags and the doctype. Always renders to UTF-8. 
renderHTML :: HTML -> LazyUTF8.ByteString
renderHTML = Text.Blaze.Html.Renderer.Utf8.renderHtml . HTML.docTypeHtml
{-# INLINE renderHTML #-}

-- | A meta element (under \<head\>) to indicate a page's content
-- should not be indexed or followed. This is, of course, entirely
-- discretionary for the robots.
htmlMetaNoIndex :: HTML
htmlMetaNoIndex = HTML.meta ! Attrib.name "robots" ! Attrib.content "noindex, nofollow"

-- | Indicate charset utf-8 redundantly in html content    
htmlMetaCharsetUtf8 :: HTML
htmlMetaCharsetUtf8 = HTML.meta ! Attrib.charset "UTF-8"
