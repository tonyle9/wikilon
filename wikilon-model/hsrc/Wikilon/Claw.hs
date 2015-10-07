{-# LANGUAGE OverloadedStrings, ViewPatterns, PatternGuards, BangPatterns #-}
-- | 'Command Language for Awelon' (or Claw) 
--
-- Claw is a syntactic sugar or lense for Awelon Object (AO) code.
-- AO code is a subset of pure Awelon Bytecode (ABC) constrained to
-- use a pure, portable subset of tokens. (cf. Wikilon.AODef).
--
-- Claw aims at a Forth-like programmer experience, suitable for one
-- liner programs, command lines, and REPLs. Claw primarily optimizes
-- representation of words, numbers, small texts, short lists. Claw 
-- operates by simple, reversible expansion rules.
--
-- Examples:
--
--      2\/3        2 3 ratio
--      4\/10       4 10 ratio
--      3.141       3141 3 decimal
--      -1.20       -120 2 decimal
--      6.02e23     6.02 23 exp10
--      42          \\#42 integer
--      -7          \\#7- integer
--      {1,2,3}     lbrace 1 comma 2 comma 3 rbrace
--      ratio       \\{%ratio}
--      "foo"       \\"foo
--                  ~ literal
--      [foo]       \\[foo] block
--
-- Claw is easily extensible by adding new expansion rules. Wikilon
-- will simply hard-code a particular set of extensions or features
-- that will work well enough for most use cases. If a few specific
-- variants are needed, I'll model them in separate modules.
--
-- A simple namespace concept provides claw code just enough context
-- sensitivity get an inattentive programmer into trouble.
--
--      #X 2\/3     {&ns:X}#2{%Xinteger}#3{%Xinteger}{%Xratio}
--
-- A namespace applies as a prefix for every word when expanding a
-- stream. Within a block of code, a namespace only extends to the
-- end of said block. Namespaces allow a dictionary to model many
-- programming environments or styles.
--
-- 
module Wikilon.Claw
    ( ClawCode(..)
    , ClawOp(..)
    , Namespace
    , ClawInt
    , ClawRatio(..)
    , ClawExp10(..)
    , ClawDecimal
    , clawToABC, clawToABC'
    , clawFromABC, clawFromABC'
    , isInlineableText

    , encode
    , encode'

    , decode
    , runDecoder
    , DecoderState(..)
    , DecoderCont(..)

    , PrimOp(..)
    , module Awelon.Word
    ) where

import Control.Applicative
import Control.Monad
import Data.Monoid
import Data.Char
import qualified Data.ByteString.Char8 as BS
import qualified Data.ByteString.UTF8 as UTF8
import qualified Data.ByteString.Lazy.Char8 as LBS
import qualified Data.ByteString.Lazy.UTF8 as LazyUTF8
import qualified Data.ByteString.Builder as BB
import qualified Data.List as L
import qualified Data.Decimal as D
import Data.String (IsString(..))
import Wikilon.Word
import Wikilon.ABC.Pure (ABC, Op(..), PrimOp(..), Text, Token)
import qualified Wikilon.ABC.Pure as ABC

-- | Command Language for Awelon (claw)
newtype ClawCode = ClawCode { clawOps :: [ClawOp] } deriving (Eq, Ord)

data ClawOp 
    = NS !Namespace     -- #bar:
    | CW !Word          -- mul inc
    | T0 !Text          -- escaped text
    | K0 !Token         -- escaped token
    | P0 !PrimOp        -- escaped ABC ops
    | B0 ![ClawOp]      -- escaped blocks
    | NI !ClawInt       -- integer
    | NR !ClawRatio     -- ratio
    | ND !ClawDecimal   -- decimal
    | NE !ClawExp10     -- exponential
    | TL !ABC.Text      -- text literal
    | BC ![ClawOp]      -- block of code
    deriving (Ord, Eq)
    
type ClawInt = Integer
type ClawDecimal = D.Decimal -- current limit 255 decimal places
data ClawRatio = ClawRatio !ClawInt !ClawInt deriving (Eq, Ord)
data ClawExp10 = ClawExp10 !ClawDecimal !ClawInt deriving (Eq, Ord)

instance Show ClawRatio where 
    showsPrec _ (ClawRatio n d) = shows n . showChar '/' . shows d
instance Show ClawExp10 where 
    showsPrec _ (ClawExp10 c e) = shows c . showChar 'e' . shows e    

-- | A region of claw code has exactly one namespace. This serves as
-- a prefix for all words within that region of code. Claw namespace
-- is the only source of context sensitivity in claw code.
type Namespace = UTF8.ByteString

wInteger, wLiteral, wBlock :: Word
wRatio, wDecimal, wExp10 :: Word
wLBrace, wRBrace, wComma, wSemicolon :: Word

wInteger = "integer"
wLiteral = "literal"
wBlock = "block"
wRatio = "ratio"
wDecimal = "decimal"
wExp10 = "exp10"

-- TODO: punctuation for easy encoding of lists and sequences
wLBrace = "lbrace"
wRBrace = "rbrace"
wComma = "comma"
wSemicolon = "semicolon"

nsTokPrefix :: UTF8.ByteString
nsTokPrefix = "&ns:"

-- | Convert claw code to ABC for interpretation or storage. This is
-- essentially a 'compiler' for Claw code, though resulting bytecode 
-- will usually need linking and processing for performance.
clawToABC :: ClawCode -> ABC
clawToABC = clawToABC' BS.empty

clawToABC' :: Namespace -> ClawCode -> ABC
clawToABC' ns = mconcat . zns opToABC ns . clawOps

zns :: (Namespace -> ClawOp -> a) -> Namespace -> [ClawOp] -> [a]
zns f _ (op@(NS ns) : ops) = f ns op : zns f ns ops
zns f ns (op : ops) = f ns op : zns f ns ops
zns _ _ [] = []

oneOp :: ABC.Op -> ABC
oneOp = ABC . return

expand :: Namespace -> [ClawOp] -> ABC
expand ns = clawToABC' ns . ClawCode 

opToABC :: Namespace -> ClawOp -> ABC
-- low level
opToABC _ (NS ns) = oneOp $ ABC_Tok $ nsTokPrefix <> ns
opToABC ns (CW (Word w)) = oneOp $ ABC_Tok $ mconcat ["%", ns, w]
opToABC _ (P0 op) = oneOp $ ABC_Prim op
opToABC _ (T0 txt) = oneOp $ ABC_Text txt
opToABC _ (K0 tok) = oneOp $ ABC_Tok tok
opToABC ns (B0 cc) = oneOp $ ABC_Block $ expand ns cc
-- expansions
opToABC ns (NI i) = expand ns (escInt ++ [CW wInteger]) where
    escInt = fmap P0 $ ABC.primQuoteInteger i []
opToABC ns (NR (ClawRatio n d)) = expand ns [NI n, NI d, CW wRatio]
opToABC ns (ND (D.Decimal dp m)) = 
    expand ns [NI m, NI (fromIntegral dp), CW wDecimal]
opToABC ns (NE (ClawExp10 d x)) = expand ns [ND d, NI x, CW wExp10]
opToABC ns (TL lit) = expand ns [T0 lit, CW wLiteral]
opToABC ns (BC cc) = expand ns [B0 cc, CW wBlock]

-- | Parse Claw structure from bytecode.
clawFromABC :: ABC -> ClawCode
clawFromABC = clawFromABC' BS.empty

-- | parse Claw code from bytecode. This requires the current
-- namespace in order to provide some useful context.
clawFromABC' :: Namespace -> ABC -> ClawCode
clawFromABC' ns = ClawCode . reduceClaw . escABC ns . ABC.abcOps

-- | recognize claw words from bytecode 
--
--   {%foo:word} → word 
--
-- if namespace is `foo:` 
--   and `word` doesn't start with digits, etc.
escWord :: Namespace -> ABC.Token -> Maybe Word
escWord ns tok = case BS.uncons tok of
    Just ('%', fullWord) ->
        let bOkPrefix = ns `BS.isPrefixOf` fullWord in
        let w = Word $ BS.drop (BS.length ns) fullWord in
        guard (bOkPrefix && isValidWord w) >> return w
    _ -> Nothing

-- | recognize claw namespace tokens {&ns:NS} → #NS
-- namespace must also be valid word (or empty string)
escNSTok :: ABC.Token -> Maybe Namespace
escNSTok tok =
    let bMatchPrefix = nsTokPrefix `BS.isPrefixOf` tok in
    let ns = BS.drop 4 tok in  -- `&ns:` is four characters 
    guard (bMatchPrefix && validNS ns) >> return ns

-- | a namespace must be a valid word or the empty string.
validNS :: Namespace -> Bool
validNS ns = BS.null ns || isValidWord (Word ns)

-- | Identify SP and LF identity operators from ABC-layer formatting.
abcWS :: ABC.PrimOp -> Bool
abcWS ABC_SP = True
abcWS ABC_LF = True
abcWS _ = False

-- | recognize basic claw operations and handle namespace context.
-- This will also filter all ABC_SP and ABC_LF elements from the
-- input (which simplifies further processing)
escABC :: Namespace -> [ABC.Op] -> [ClawOp]
escABC ns (ABC_Tok tok : ops) 
  | Just w <- escWord ns tok = CW w : escABC ns ops
  | Just ns' <- escNSTok tok = NS ns' : escABC ns' ops
  | otherwise = K0 tok : escABC ns ops
escABC ns (ABC_Prim op : ops)  
  | abcWS op = escABC ns ops -- ignore whitespace
  | otherwise = P0 op : escABC ns ops
escABC ns (ABC_Text txt : ops) = T0 txt : escABC ns ops
escABC ns (ABC_Block abc : ops) = B0 cc : escABC ns ops where
    cc = escABC ns (ABC.abcOps abc)
escABC _ [] = []

-- | collapse structured values from lower level claw code.
--
-- Targets:
--  full blocks
--  texts
--  integers
--  ratios
--  decimals
--  e-notation
--
-- At the moment, this is not a streaming reducer but rather a
-- zipper-based implementation. 
--
reduceClaw :: [ClawOp] -> [ClawOp]
reduceClaw = rdz []

rdz :: [ClawOp] -> [ClawOp] -> [ClawOp]
rdz lhs (CW w : rhs)
    | (w == wInteger)
    , Just (lhs', n) <- parseIntR lhs
    = rdz (NI n : lhs') rhs
rdz (NI d : NI n : lhs) (CW w : rhs)
    | (w == wRatio) && (d > 0)
    = rdz (NR r : lhs) rhs
    where r = ClawRatio n d
rdz (NI dp : NI m : lhs) (CW w : rhs) 
    | (w == wDecimal) && (dp > 0) && (dp <= 255)
    = rdz (ND dec : lhs) rhs
    where dec = D.Decimal (fromIntegral dp) m
rdz (NI e : ND d : lhs) (CW w : rhs)
    | (w == wExp10)
    = rdz (NE ne : lhs) rhs
    where ne = ClawExp10 d e
rdz (T0 txt : lhs) (CW w : rhs)
    | (w == wLiteral) && (isInlineableText txt)
    = rdz (TL txt : lhs) rhs
rdz (B0 cc : lhs) (CW w : rhs)
    | (w == wBlock)
    = rdz (BC cc : lhs) rhs
rdz lhs (B0 cc : rhs) = rdz (B0 (reduceClaw cc) : lhs) rhs -- recursion
rdz lhs (op : rhs) = rdz (op : lhs) rhs -- step
rdz lhs [] = L.reverse lhs -- all done

-- | parse raw integer (e.g. #42) from lhs in the zipper-based
-- reduction, i.e. we'll see #42 from the left hand side, parse
-- back to the '#', and accumulate the operations on the way.
--
-- This uses a simple strategy. We obtain a list of numeric operations
-- for building the integer up to '#', then we process it.
parseIntR :: [ClawOp] -> Maybe ([ClawOp], ClawInt)
parseIntR = run where
  run ops = 
    collectR [] ops >>= \(fs, ops') ->
    return (ops', composeList fs 0)
  collectR fs (P0 op : ops)
    | Just f <- intOp op = collectR (f:fs) ops -- include value
    | (op == ABC_newZero) = Just (fs, ops) -- done
    | abcWS op = collectR fs ops
    | otherwise = Nothing
  collectR _ _ = Nothing -- 

composeList :: [a -> a] -> a -> a
composeList = L.foldr (flip (.)) id

intOp :: ABC.PrimOp -> Maybe (ClawInt -> ClawInt)
intOp (digitOp -> Just d) = Just step where
    step !n = ((10*n)+d)
intOp ABC_negate = Just negate
intOp _ = Nothing

digitOp :: ABC.PrimOp -> Maybe ClawInt
digitOp = digitFromChar . ABC.abcOpToChar

digitFromChar :: Char -> Maybe ClawInt
digitFromChar !c =
    let bOK = ('0' <= c) && (c <= '9') in
    if not bOK then mzero else
    return $! fromIntegral $ ord c - ord '0'

-- | Test whether the text is valid for inline representation.
-- This minimally requires the text does not use `"` or LF.
isInlineableText :: ABC.Text -> Bool
isInlineableText s = LBS.notElem '"' s && LBS.notElem '\n' s

-- | Render claw code as a lazy utf-8 bytestring for human use and
-- editing. Note that the current implementation isn't optimal for
-- large 
encode :: ClawCode -> LazyUTF8.ByteString
encode = BB.toLazyByteString . encode'

encode' :: ClawCode -> BB.Builder
encode' = encodeOps . clawOps

-- collect non-whitespace operators for display together
joinP0 :: [ABC.PrimOp] -> [ClawOp] -> ([ABC.PrimOp],[ClawOp])
joinP0 abc (P0 op : ops) | not (abcWS op) = joinP0 (op:abc) ops
joinP0 abc ops = (L.reverse abc, ops)

-- encode a list of operations, with special case to encode long
-- strings of primitive operations into a single escape string.
encodeOps :: [ClawOp] -> BB.Builder
encodeOps (P0 op : ops) | not (abcWS op) = output where
    output = BB.char8 '\\' <> encPrims abc <> moreOps ops'
    encPrims = BB.string8 . fmap ABC.abcOpToChar
    (abc,ops') = joinP0 [op] ops
encodeOps (op:ops) = encodeOp op <> moreOps ops
encodeOps [] = mempty

-- encode operators after adding a space character
moreOps :: [ClawOp] -> BB.Builder
moreOps [] = mempty
moreOps ops = BB.char8 ' ' <> encodeOps ops

-- encode a singular operation.
encodeOp :: ClawOp -> BB.Builder
encodeOp (NS ns) = BB.char8 '#' <> BB.byteString ns
encodeOp (CW (Word w)) = BB.byteString w
encodeOp (TL txt) = BB.char8 '"' <> BB.lazyByteString txt <> BB.char8 '"'
encodeOp (BC cc) = encBlock cc
encodeOp (NI i) = BB.string8 (show i)
encodeOp (ND d) = BB.string8 (show d)
encodeOp (NR r) = BB.string8 (show r) 
encodeOp (NE e) = BB.string8 (show e)
encodeOp (P0 op) -- should not happen normally
    | abcWS op = mempty
    | otherwise = BB.char8 '\\' <> c
    where c = BB.char8 $ ABC.abcOpToChar op
encodeOp (T0 txt) = BB.char8 '\n' <> BB.char8 '\\' <> ABC.encodeTextBB txt
encodeOp (K0 tok) = BB.char8 '\\' <> ABC.encodeTokenBB tok
encodeOp (B0 cc) = BB.char8 '\\' <> encBlock cc

encBlock :: [ClawOp] -> BB.Builder
encBlock cc = BB.char8 '[' <> encodeOps cc <> BB.char8 ']'

instance Show ClawOp where
    showsPrec _ = showList . (:[])
    showList = (++) . LazyUTF8.toString . BB.toLazyByteString . encodeOps
instance Show ClawCode where
    showsPrec _ = showList . clawOps


-- | Decode Claw from text, e.g. from a command line. Text decodes
-- into a sequence of claw operations, so you'll additionally need
-- to know the namespace (or require one be provided with the text).
--
-- If the decoder is 'stuck' at any point, we'll return the final
-- decoder state. This allows more precise error reports to the
-- client.
decode :: LazyUTF8.ByteString -> Either DecoderState ClawCode
decode t = runDecoder $ DecoderState
    { dcs_text = t
    , dcs_cont = DecodeDone
    , dcs_ws = True
    , dcs_ops = []
    }

runDecoder :: DecoderState -> Either DecoderState ClawCode
runDecoder dcs = decode' cc bWS ops txt where
    cc = dcs_cont dcs
    bWS = dcs_ws dcs
    ops = dcs_ops dcs
    txt = dcs_text dcs 

-- | our precision for parse errors is some location within 
-- a possible hierarchical blocks. Blocks may be escaped.
data DecoderCont 
    = DecodeDone
    | DecodeBlock IsEscBlock [ClawOp] DecoderCont  
    deriving (Show)
type IsEscBlock = Bool
data DecoderState = DecoderState
    { dcs_text :: LazyUTF8.ByteString   -- ^ text to parse
    , dcs_cont :: DecoderCont           -- ^ location in hierarchical blocks
    , dcs_ws   :: Bool                  -- ^ recently seen a word separator?
    , dcs_ops  :: [ClawOp]              -- ^ operators parsed, reverse order
    } deriving (Show)

decode' :: DecoderCont -> Bool -> [ClawOp] -> LazyUTF8.ByteString -> Either DecoderState ClawCode
decode' cc bWS r txt0 =
    let decoderIsStuck = Left (DecoderState txt0 cc bWS r) in
    case LBS.uncons txt0 of
        Nothing -> case cc of
            DecodeDone -> Right $ ClawCode $ L.reverse r
            _ -> decoderIsStuck
        Just (c, txt) -> case c of
            ' ' -> decode' cc True r txt
            '\n' -> decode' cc True r txt
            ']' -> case cc of
                DecodeBlock bEsc ops cc' -> decode' cc' False (b:ops) txt where
                    b = bType $ L.reverse r
                    bType = if bEsc then B0 else BC
                _ -> decoderIsStuck
            -- everything else requires a word separator
            _ | not bWS -> decoderIsStuck
            '[' -> decode' (DecodeBlock False r cc) True [] txt
            '"' -> case LBS.elemIndex '"' txt of
                Nothing -> decoderIsStuck
                Just idx ->
                    let (lit, litEnd) = LBS.splitAt idx txt in
                    let bOK = LBS.notElem '\n' lit in
                    if not bOK then decoderIsStuck else
                    decode' cc False (TL lit : r) (LBS.drop 1 litEnd)
            '#' -> 
                let (lns, txt') = LazyUTF8.span isValidWordChar txt in
                let ns = LBS.toStrict lns in
                let bOK = validNS ns in
                if not bOK then decoderIsStuck else
                decode' cc False (NS ns : r) txt'
            '\\' -> case LBS.uncons txt of -- escaped content
                Nothing -> decoderIsStuck
                Just (c', escTxt) -> case c' of
                    '[' -> decode' (DecodeBlock True r cc) True [] escTxt
                    '"' -> case ABC.decodeLiteral escTxt of
                        Just (lit, litEnd) -> case LBS.uncons litEnd of
                            Just ('~', txt') -> decode' cc False (T0 lit : r) txt'
                            _ -> decoderIsStuck
                        _ -> decoderIsStuck
                    '{' -> case LBS.elemIndex '}' escTxt of
                        Nothing -> decoderIsStuck
                        Just idx -> 
                            let (lzt, tokEnd) = LBS.splitAt idx escTxt in
                            let tok = LBS.toStrict lzt in
                            let bOK = BS.notElem '{' tok && BS.notElem '\n' tok in
                            if not bOK then decoderIsStuck else
                            tok `seq` decode' cc False (K0 tok : r) (LBS.drop 1 tokEnd)
                    (charToEscPrim -> Just op0) ->
                        let loop ops t = case takeEscPrim t of
                                Just (op, t') -> loop (P0 op : ops) t'
                                Nothing -> (ops, t)
                        in
                        let (r', txt') = loop (P0 op0 : r) escTxt in
                        decode' cc False r' txt'
                    _ -> decoderIsStuck -- not a recognized escape
            _ -> case decodeWordOrNumber txt0 of
                Just (op, txt') -> decode' cc False (op:r) txt'
                _ -> decoderIsStuck

takeEscPrim :: ABC.Text -> Maybe (ABC.PrimOp, ABC.Text)
takeEscPrim txt =
    LBS.uncons txt >>= \ (c, txt') ->
    charToEscPrim c >>= \ op ->
    return (op, txt')

-- any primitive except ABC_SP and ABC_LF
charToEscPrim :: Char -> Maybe ABC.PrimOp
charToEscPrim c = 
    ABC.abcCharToOp c >>= \ op ->
    guard (not (abcWS op)) >>
    return op

decodeWordOrNumber :: ABC.Text -> Maybe (ClawOp, ABC.Text)
decodeWordOrNumber txt = dn <|> dw where
    dn = decodeNumber txt
    dw = decodeWord txt >>= \ (w, txt') -> return (CW w, txt')
    
decodeWord :: ABC.Text -> Maybe (Word, ABC.Text)
decodeWord txt =
    let (s, txt') = LazyUTF8.span isValidWordChar txt in
    let w = Word (LBS.toStrict s) in
    guard (isValidWord w) >>
    return (w, txt')

-- | decode NI, NR, ND, or NE. (Or Nothing.)
decodeNumber :: ABC.Text -> Maybe (ClawOp, ABC.Text)
decodeNumber txt = de <|> ir where 
    ir = decodeInteger txt >>= \ (n, txtAfterNum) ->
         case LBS.uncons txtAfterNum of
            Just ('/', txtDenom) -> 
                decodePosInt txtDenom >>= \ (d, txtAfterDenom) ->
                return (NR (ClawRatio n d), txtAfterDenom)
            _ -> return (NI n, txtAfterNum)
    de = 
        decodeDecimal txt >>= \ (c, txtAfterDecimal) ->
        case LBS.uncons txtAfterDecimal of
            Just ('e', txtExp10) ->
                decodeInteger txtExp10 >>= \ (e, txtAfterExp10) ->
                return (NE (ClawExp10 c e), txtAfterExp10)
            _ -> return (ND c, txtAfterDecimal)

decodeDecimal :: ABC.Text -> Maybe (ClawDecimal, ABC.Text)
decodeDecimal (LBS.uncons -> Just ('-', txt)) = 
    -- simplified handling for negative values
    -- also need to permit '-0.01' and similar
    decodeDecimal txt >>= \ (dAbs, txt') ->
    guard (dAbs > 0) >> -- forbid negative zero
    return (negate dAbs, txt')
decodeDecimal txt =
    decodeInteger txt >>= \ (m0, txtAfterIntPart) ->
    LBS.uncons txtAfterIntPart >>= \ (decimalPoint, txtDecimal) ->
    guard ('.' == decimalPoint) >>
    let (m, dp, txtAfterDecimal) = accumDecimal m0 0 txtDecimal in
    -- at least one decimal place for visual distinction (e.g. 1.0)
    -- at most 255 decimal places due to Data.Decimal limitations
    guard ((0 < dp) && (dp <= 255)) >>
    return (D.Decimal (fromIntegral dp) m, txtAfterDecimal)

-- decode content after the decimal point (a sequence of 0-9 digits)
-- while counting number of digits and accumulating the mantissa.
accumDecimal :: ClawInt -> Int -> ABC.Text -> (ClawInt, Int, ABC.Text)
accumDecimal !m !dp (takeDigit -> Just (d, txt)) =
    accumDecimal ((10*m)+d) (1+dp) txt
accumDecimal !m !dp !txt = (m,dp,txt)

takeDigit :: ABC.Text -> Maybe (ClawInt, ABC.Text)
takeDigit (LBS.uncons -> Just (c, txt)) = 
    digitFromChar c >>= \ d -> return (d, txt)
takeDigit _ = Nothing

decodeInteger :: ABC.Text -> Maybe (ClawInt, ABC.Text)
decodeInteger txt = case LBS.uncons txt of
    Nothing -> Nothing
    Just ('0', txtAfterZero) -> 
        return (0, txtAfterZero)
    Just ('-', txtAfterNeg) ->
        decodePosInt txtAfterNeg >>= \ (n, txtAfterNum) ->
        return (negate n, txtAfterNum)
    Just (c, txtAfterD0) ->
        digitFromChar c >>= \ d0 ->
        return (accumPosInt d0 txtAfterD0)

decodePosInt :: ABC.Text -> Maybe (ClawInt, ABC.Text)
decodePosInt txt =
    takeDigit txt >>= \ (d0, txtAfterD0) ->
    guard (d0 > 0) >> -- start with 1..9
    return (accumPosInt d0 txtAfterD0)

accumPosInt :: ClawInt -> ABC.Text -> (ClawInt, ABC.Text)
accumPosInt !n (takeDigit -> Just (d, txt)) = accumPosInt ((10*n)+d) txt
accumPosInt !n !txt = (n,txt)

instance IsString ClawCode where
    fromString s =
        case decode (LazyUTF8.fromString s) of
            Right cc -> cc
            Left dcs ->
                let sLoc = L.take 40 $ LazyUTF8.toString $ dcs_text dcs in
                error $ clawCodeErr $ "parse failure @ " ++ sLoc

clawCodeErr :: String -> String
clawCodeErr = (++) "Awelon.ClawCode: " 
