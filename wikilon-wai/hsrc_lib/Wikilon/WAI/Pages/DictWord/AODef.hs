{-# LANGUAGE OverloadedStrings #-}

module Wikilon.WAI.Pages.DictWord.AODef
    ( dictWordAODef
    , getDictWordAODef
    , putDictWordAODef
    , dictWordAODefEdit
    , formDictWordAODefEdit
    ) where

import Data.Monoid
import qualified Data.ByteString.Lazy.UTF8 as LazyUTF8
import qualified Network.HTTP.Types as HTTP
import qualified Network.HTTP.Media as HTTP
import Text.Blaze.Html5 ((!))
import qualified Text.Blaze.Html5 as H
import qualified Text.Blaze.Html5.Attributes as A
import qualified Network.Wai as Wai

import Awelon.ABC

import Wikilon.Time
import Wikilon.Dict.Word
import qualified Wikilon.Dict as Dict

import Wikilon.WAI.Utils
import Wikilon.WAI.Routes
import Wikilon.WAI.RecvFormPost


-- | an endpoint that forces content to the 'aodef' media type.
dictWordAODef :: WikilonApp
dictWordAODef = app where
    app = routeOnMethod $
        [(HTTP.methodGet, onGet)
        ,(HTTP.methodPut, onPut)
        ]
    onGet = branchOnOutputMedia [(mediaTypeAODef, getDictWordAODef)]
    onPut = branchOnInputMedia [(mediaTypeAODef, putDictWordAODef)]

-- | Return just the AO definition. This will always succeed, though
-- it may return an empty string if an undefined word is requested.
getDictWordAODef :: WikilonApp
getDictWordAODef = dictWordApp $ \ w dn dw _rq k ->
    wikilon_action w (loadDictAndTime dn) >>= \ (d,tMod) ->
    let status = HTTP.ok200 in
    let hMedia = (HTTP.hContentType, HTTP.renderHeader mediaTypeAODef) in
    let headers = [hMedia, eTagTW tMod] in
    k $ Wai.responseLBS status headers $ Dict.lookupBytes d dw 


putDictWordAODef :: WikilonApp
putDictWordAODef = toBeImplementedLater "PUT word definition"

-- | a page with just the edit form, and also the recipient of POST
-- actions to update a word via the AO definition.
dictWordAODefEdit :: WikilonApp
dictWordAODefEdit = app where
    app = routeOnMethod [(HTTP.methodGet, onGet),(HTTP.methodPost, onPost)]
    onGet = branchOnOutputMedia [(mediaTypeTextHTML, getAODefEditPage)]
    onPost = branchOnOutputMedia [(mediaTypeTextHTML, recvFormPost recvAODefEdit)]

getAODefEditPage :: WikilonApp
getAODefEditPage = dictWordApp $ \ w dn dw _rq k ->
    wikilon_action w (loadDictAndTime dn) >>= \ (d,tMod) ->
    let abcBytes = Dict.lookupBytes d dw in
    let title = "AO Definition Editor" in
    let status = HTTP.ok200 in
    let headers = [textHtml, eTagTW tMod] in
    k $ Wai.responseLBS status headers $ renderHTML $ do
        H.head $ do
            htmlHeaderCommon w
            H.title title
        H.body $ do
            H.h1 title
            H.p $ (H.strong "Word: ") <> hrefDictWord dn dw
            let sOrigin = showEditOrigin tMod
            formAODefEdit' dn dw sOrigin abcBytes 

recvAODefEdit :: PostParams -> WikilonApp
recvAODefEdit _pp = toBeImplementedLater "recv AODef POST"

formDictWordAODefEdit :: BranchName -> Word -> T -> ABC -> HTML
formDictWordAODefEdit d w t abc = 
    formAODefEdit' d w (showEditOrigin t) (encode abc)

formAODefEdit' :: BranchName -> Word -> String -> LazyUTF8.ByteString -> HTML
formAODefEdit' d w sOrigin sInit =
    let uriAction = H.unsafeByteStringValue $ uriAODefEdit d w in
    H.form ! A.method "POST" ! A.action uriAction ! A.id "formAODefEdit" $ do
        H.textarea ! A.name "aodef" ! A.rows "4" ! A.cols "60" $
            H.string $ LazyUTF8.toString sInit -- escapes string for HTML
        H.br
        H.string "Edit Origin: "
        H.input ! A.type_ "text" ! A.name "editOrigin" ! A.value (H.stringValue sOrigin)
        H.string " "
        H.input ! A.type_ "submit" ! A.value "Edit AO Definition"
        let aoDef = href uriAODictDocs "aodef"
        H.small $ " (cf. " <> aoDef <> ")"


