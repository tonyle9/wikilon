{-# LANGUAGE DeriveDataTypeable, OverloadedStrings, ViewPatterns, GeneralizedNewtypeDeriving #-}
-- | While Awelon Bytecode may be naively interpreted, doing so is
-- not efficient. Wikilon must pre-process and simplify bytecode and
-- implement various performance tweaks:
--
-- * bytecode held in relatively compact bytestrings
-- * pre-process quoted or partial-evaluated values
-- * avoid interpreter searching for bytestrings
-- * ABCD-like extended dictionary of accelerated ops
-- * larger-than-memory values and structure sharing
-- * support compressed storage and large code blocks
--
module Wikilon.ABC.Fast
    ( ABC
    , Op(..)
    , expandOps, compactOps
    , V(..), purifyV, block, fastQuote
    , ExtOp(..), extOpTable, extCharToOp, extOpToChar
    , PrimOp(..)
    , Token
    , Text

    , purifyABC
    , fromPureABC
    , fromPureABC'

    , copyable, droppable

    , Flags, f_aff, f_rel, f_lazy, f_fork
    ) where

import Control.Applicative
import Control.Monad
import Data.Typeable (Typeable)
import Data.Word
import Data.Int
import Data.Bits
import Data.Monoid
import Data.Maybe (mapMaybe)
import qualified Data.List as L
import qualified Data.ByteString as BS
import qualified Data.ByteString.Internal as BSI
import qualified Data.ByteString.Lazy.UTF8 as LazyUTF8
import qualified Data.ByteString.Lazy.Char8 as LBS
import qualified Data.ByteString.Lazy as LW8
import qualified Data.ByteString.Builder as BB
import qualified Data.ByteString.Builder.Extra as BB
import qualified Data.Array.IArray as A
import Foreign.ForeignPtr (newForeignPtr_) 
import System.IO.Unsafe (unsafeDupablePerformIO)
import qualified Codec.Compression.Snappy.Lazy as Snappy
import Database.VCache
import Binary.Utils
import Wikilon.ABC.Pure (PrimOp(..))
import qualified Wikilon.ABC.Pure as Pure
import Wikilon.Text
import Wikilon.Token

-- | Wikilon uses multiple representations of an extended ABC for
-- performance reasons. The primary representation, below, uses a
-- lazy bytestring for the common functional logic, plus pop-only
-- stacks for constant data and tokens.
--
-- This is a more compact representation of [Op] by means of stuffing
-- extended bytecodes into a large bytestring with a couple escapes
-- to pop stacks of tokens and values.
--
-- The monoid instance corresponds to forward functional composition,
-- i.e. (mappend a b) applies function `a` before function `b`.
-- 
data ABC = ABC
    { abc_code :: LazyUTF8.ByteString   -- ABC & Extensions
    , abc_toks :: [Token]               -- matched by '!' in code
    , abc_data :: [V]                   -- matched by '_' in code
    } deriving (Eq, Typeable)

-- | A simple ABC operation, with potential for accelerated
-- operations corresponding to common sequences of ABC, and
-- for ad-hoc values (rather than just texts and blocks).
data Op
    = ABC_Prim  !PrimOp     -- the basic 42 ABC operators
    | ABC_Ext   !ExtOp      -- ABCD-like performance extensions
    | ABC_Val   !V          -- a quoted value, block, or text
    | ABC_Tok   !Token      -- e.g. value sealers, annotations
    deriving (Eq, Typeable)

-- | Values that can be represented in ABC, with a simple
-- extension for larger than memory values. 
--
-- Values are strict. Any laziness or parallelism will be
-- modeled explicitly. Integers are constrained to match
-- Wikilon runtime (more or less).
data V 
    = N {-# UNPACK #-} !Int64   -- numbers (integers)
    | P !V !V                   -- product of values
    | L !V | R !V               -- sum of values (left or right)
    | U                         -- unit value
    | B !ABC {-# UNPACK #-} !Flags           -- block value
    | S !Token !V               -- sealed and special values
    | T !Text                   -- embedded text value
    | X !(VRef V) {-# UNPACK #-} !Flags    -- external value resource
    | Z !ABC V                  -- lazy application of block
    deriving (Eq, Typeable)

    -- todo: add support for parallel evaluation
    --       (maybe support laziness, too). 
    --       (maybe persistent laziness? could be cool.)

block :: ABC -> V
block abc = B abc zeroBits

-- | fast quote, but does not track substructure.
fastQuote :: V -> ABC
fastQuote v = ABC 
    { abc_code = "_"
    , abc_toks = []
    , abc_data = [v] 
    }

-- contemplating support for: 
--   binaries (a specialized vector?)
--   vectors (an interpretation of lists?)
--   fast copy/drop (value flags or extop?)
--   stacks of values (for simplification)
--   lazily applied blocks (for simplification)
--

-- | Flags for substructural or block decorator attributes.
-- For decorators, only one at a time may apply, but a block can
-- be wrapped e.g. [[block]{&lazy}vr$c]{&fork}. 
--
-- For parallelism, I'm going to favor a process function concept
-- that effectively shifts the computation into an alternative
-- thread that can enqueue multiple requests and provide future
-- results. Laziness is simpler and will generally be considered
-- non-copyable.
newtype Flags = Flags { unFlags :: Word8 } 
    deriving (Eq, Bits)


-- | Accelerated operations corresponding to common substrings of
-- Awelon Bytecode (and hence to common functions). These encode
-- as a single character and are processed by a dedicated function.
--
-- In general, ExtOp will use UTF8 encoding. But it may include some
-- ASCII characters for the more common extended operations.
data ExtOp
    = ExtOp_Inline  -- vr$c, also for tail calls
    | ExtOp_Swap    -- vrwlc 
    | ExtOp_Mirror  -- VRWLC
    -- I'll probably want:
    --  support for vectors and binaries (specialty lists + ops?)
    --  support for *affine* vectors (mutable vectors with explicit copy op)
    --  optimized list processing and list encodings (implicit sequences?)
    --  a heavily optimized fixpoint function operator 
    --  optimized rational and floating point model functions?
    --  
    --  optimize common data plumbing, esp. for stacks
    --
    deriving (Eq, Ord, A.Ix, Enum, Bounded)

-----------------------------------
-- ASSOCIATIONS FOR ACCELERATORS --
-----------------------------------

-- | Table of extended operations and semantics, extOpTable.
extOpTable :: [(ExtOp, Char, Pure.ABC)]
extOpTable =
    [(ExtOp_Inline, 'i', "vr$c")
    ,(ExtOp_Swap,   's', "vrwlc")
    ,(ExtOp_Mirror, 'S', "VRWLC")
    ]

extOpCharArray :: A.Array ExtOp Char
extOpCharArray = A.accumArray ins eUndef (minBound,maxBound) ops where
    ops = fmap (\(op,c,_) -> (op,c)) extOpTable
    eUndef = impossible "missing encoding for ExtOp" 
    ins _ c = c

extCharOpArray :: A.Array Char (Maybe ExtOp)
extCharOpArray = A.accumArray ins Nothing (lb,ub) tbl where
    tbl = fmap (\(op,c,_) -> (c, op)) extOpTable
    lb = L.minimum (fmap fst tbl)
    ub = L.maximum (fmap fst tbl)
    ins _ op = Just op

extOpToChar :: ExtOp -> Char
extOpToChar = (A.!) extOpCharArray

extCharToOp :: Char -> Maybe ExtOp
extCharToOp c | inBounds = extCharOpArray A.! c
              | otherwise = Nothing
    where inBounds = (lb <= c) && (c <= ub)
          (lb,ub) = A.bounds extCharOpArray

----------------------------------
-- SHOW INSTANCES FOR DEBUGGING --
----------------------------------

-- I'll show ABC in the expanded form, except with
-- {#v:address'kf} in place of stowed values.

instance Show ABC where
    showsPrec _ = showList . expandOps
       
instance Show V where 
    showsPrec _ = showsV

instance Show Op where
    showsPrec _ = showsOp
    showList (op:ops) = showsOp op . showList ops
    showList [] = id 

instance Show ExtOp where 
    showsPrec _ = showChar . extOpToChar 
    showList = showString . fmap extOpToChar

-- we'll show a value in an extended bytecode form, with 
-- resource tokens in place of stowed values.
showsV :: V -> ShowS
showsV (N n) = shows $ Pure.itoabc' (toInteger n)
showsV (P a b) = showsV a . showsV b . shows ABC_w . shows ABC_l
showsV (L a) = showsV a . shows ABC_V
showsV (R b) = showsV b . shows ABC_V . shows ExtOp_Mirror
showsV (U) = shows ABC_v . shows ExtOp_Swap
showsV (B abc kf) = showChar '[' . shows abc . showChar ']' . showsFlags kf
showsV (S tok v) = showsV v . shows tok
showsV (T txt) = shows (Pure.ABC_Text txt)
showsV (X ref kf) = showString "{#" . rsc . qv . showsFlags kf . showChar '}' where
    rsc = showString "V:" . shows (unsafeVRefAddr ref) -- local resource id
    qv = showChar '\'' -- resource represents a quoted value
showsV (Z abc v) = showsV v . showsV (B abc f_lazy) . shows ABC_apply

showsFlags :: Flags -> ShowS
showsFlags f = rel . aff . lazy . fork where
    rel = if f_includes f_rel f then showChar 'k' else id
    aff = if f_includes f_aff f then showChar 'f' else id
    lazy = if f_includes f_lazy f then showString "{&lazy}" else id
    fork = if f_includes f_fork f then showString "{&fork}" else id

showsOp :: Op -> ShowS
showsOp (ABC_Prim op) = shows op
showsOp (ABC_Ext op) = shows op
showsOp (ABC_Val v) = shows v
showsOp (ABC_Tok tok) = shows tok

---------------------------------------
-- EXPANDING AND COMPACTING BYTECODE --
---------------------------------------

-- combining the ExtOp and PrimOp arrays for faster lookup
charToOpArray :: A.Array Char (Maybe Op)
charToOpArray = A.accumArray ins Nothing (lb,ub) tbl where
    tbl = abc <> ext
    abc = fmap (\(op,c) -> (c, ABC_Prim op)) Pure.abcOpTable
    ext = fmap (\(op,c,_) -> (c, ABC_Ext op)) extOpTable
    lb = L.minimum (fmap fst tbl)
    ub = L.maximum (fmap fst tbl)
    ins _ op = Just op

charToOp :: Char -> Maybe Op
charToOp c | inBounds = charToOpArray A.! c
           | otherwise = Nothing
    where inBounds = (lb <= c) && (c <= ub)
          (lb,ub) = A.bounds charToOpArray

-- | Wikilon ABC is a compact representation for [Op].
expandOps :: ABC -> [Op]
expandOps abc = expandOps' (abc_toks abc) (abc_data abc) (abc_code abc)

expandOps' :: [Token] -> [V] -> LazyUTF8.ByteString -> [Op]
expandOps' toks vals s = case LazyUTF8.uncons s of
    Just (c, s') -> case c of
        (charToOp -> Just op) -> op : expandOps' toks vals s'
        '_' -> case vals of
            (v:vals') -> ABC_Val v : expandOps' toks vals' s'
            [] -> impossible "value stack underflow"
        '!' -> case toks of
            (t:toks') -> ABC_Tok t : expandOps' toks' vals s'
            [] -> impossible "token stack underflow"
        -- tokens, blocks, and texts are captured by _ and !.
        _ -> impossible (show c ++ " not recognized as ABC PrimOp or ExtOp")
    Nothing | bValsRemain -> impossible "value stack overflow"
            | bToksRemain -> impossible "token stack overflow"
            | otherwise -> [] -- done
            where bValsRemain = not (L.null vals)
                  bToksRemain = not (L.null toks)

-- | Obtain the compact encoding for a list of ABC operations.
--
-- Note: this is not an especially efficient computation. It applies
-- three separate filters over the input. However, the assumption is
-- that we'll be reading (expanding) bytecode far more frequently than
-- writing (compacting) it outside of the compilation process.
compactOps :: [Op] -> ABC
compactOps ops = ABC _code _toks _data where
    _code = LazyUTF8.fromString $ fmap opc ops
    _toks = mapMaybe mt ops
    _data = mapMaybe md ops
    mt op = case op of { ABC_Tok t -> return t; _ -> mzero }
    md op = case op of { ABC_Val v -> return v; _ -> mzero }
    opc (ABC_Prim op) = Pure.abcOpToChar op
    opc (ABC_Ext op) = extOpToChar op
    opc (ABC_Val _) = '_'
    opc (ABC_Tok _) = '!'

-------------------------------------
-- ENCODING FOR VCACHE PERSISTENCE --
--  AND LARGER-THAN-MEMORY VALUES  --
-------------------------------------

-- | Before encoding in VCache, we'll use an intermediate structure
-- that captures all the binary encodings. The goal here is to permit
-- a compressed encoding of larger binaries within VCache. I hope to
-- work with binaries of relatively large sizes (16-64kB) on a regular
-- basis.
data CacheEnc = CE ![VRef V] !LBS.ByteString
    deriving (Typeable, Show)

-- | intermediate structure for constructing a CacheEnc
type CacheBuilder = ([VRef V], BB.Builder)

-- | ABC is trivially encoded as a triple of code, tokens, and data.
cbABC :: ABC -> CacheBuilder
cbABC abc = mconcat 
    [cbCode (abc_code abc)
    ,cbToks (abc_toks abc)
    ,cbData (abc_data abc)
    ]

-- | Read ABC as a triple of code, tokens, and data.
rdABC :: CacheEnc -> (ABC, CacheEnc)
rdABC ce = 
    let (_code,cec) = rdCode ce in
    let (_toks,cet) = rdToks cec in
    let (_data,ce') = rdData cet in
    let abc = ABC _code _toks _data in
    (abc, ce')

-- | Code is trivially encoded as a sized slice.
cbCode :: LBS.ByteString -> CacheBuilder
cbCode = (,) mempty . bbSizedSlice

-- | Read our extended awelon bytecode 
rdCode :: CacheEnc -> (LBS.ByteString, CacheEnc)
rdCode (CE refs s) =
    let (code, s') = rdSizedSlice s in
    (code, CE refs s')

-- | Our list of tokens will simply be listed one per line, with a total
-- size. This allows a simple fast slicing and lazy parse for tokens.
cbToks :: [Token] -> CacheBuilder
cbToks = (,) mempty . bbToks where
    tokLen (Token tok) = BS.length tok
    toksLen = fromIntegral . L.sum . fmap ((+ 1) . tokLen) 
    bbTok (Token tok) = BB.byteString tok <> BB.char8 '\n'
    bbToks toks = bbVarNat (toksLen toks) <> mconcat (fmap bbTok toks)

rdToks :: CacheEnc -> ([Token], CacheEnc)
rdToks (CE refs s) =
    let (tokBytes, s') = rdSizedSlice s in
    (parseTokBytes tokBytes, (CE refs s'))

-- read each token to the end of the current line.
parseTokBytes :: LBS.ByteString -> [Token]
parseTokBytes s = case LBS.elemIndex '\n' s of
    Nothing -> []
    Just ix -> 
        let tok = LBS.toStrict $ LBS.take ix s in
        (Token tok) : parseTokBytes (LBS.drop (ix+1) s)

-- | Encode data to support a streaming lazy parse of the list of
-- values. This requires the size of the values encoding to slice
-- the bytestring, so we'll pay the price to buffer the values.
cbData :: [V] -> CacheBuilder
cbData vs = 
    let (lDataRefs, bbVals) = cbVals vs in
    let nDataRefs = fromIntegral (L.length lDataRefs) in
    let bytes = bbToBytes bbVals in -- need for size
    let bbData = bbVarNat nDataRefs <> bbSizedSlice bytes in
    (lDataRefs, bbData)

-- | When reading, we'll slice out as many value references and
-- bytes as we need, such that we can mostly skip past the data.
rdData :: CacheEnc -> ([V], CacheEnc)
rdData (CE refs s) = 
    let (nDataRefs, sAfterRefct) = rdVarNat s in
    let (lDataRefs, refs') = L.splitAt (fromIntegral nDataRefs) refs in
    let (bytes, s') = rdSizedSlice sAfterRefct in
    (rdVals (CE lDataRefs bytes), (CE refs' s'))
    
-- a list of values. 
cbVals :: [V] -> CacheBuilder
cbVals = mconcat . fmap cbVal where

-- parse values until cache is empty. Must be delimited
-- externally by sized slices (e.g. with cbData and rdData).
rdVals :: CacheEnc -> [V]
rdVals ce@(CE _ s) =
    if LBS.null s then [] else
    let (v,ce') = rdVal ce in
    v : rdVals ce'

cbChar8 :: Char -> CacheBuilder
cbChar8 = (,) mempty . BB.char8

cbFlags :: Flags -> CacheBuilder
cbFlags = (,) mempty . BB.word8 . unFlags

rdFlags :: CacheEnc -> (Flags, CacheEnc)
rdFlags (CE refs s) = case LW8.uncons s of
    Just (f,s') -> (Flags f, CE refs s')
    Nothing -> impossible "underflow attempting to read flags byte"

cbRef :: VRef V -> CacheBuilder
cbRef ref = ([ref],mempty)

rdRef :: CacheEnc -> (VRef V, CacheEnc)
rdRef (CE (r:refs) s) = (r, CE refs s)
rdRef _ = impossible "underflow reading stowed value reference"

-- | A compact, conventional prefix encoding for a single value.
--
-- This encoding does not admit a lazy parse. That is, we're forced to
-- finish reading the value once we start. However, this corresponds to
-- the normal processing needs if we encoded the value in ABC, and does
-- not need to be recomputed in each step of a loop.
cbVal :: V -> CacheBuilder
cbVal (N n) = (mempty, BB.char8 '#' <> bbVarInt (toInteger n))
cbVal (P a b) = cbChar8 'P' <> cbVal a <> cbVal b
cbVal (L a) = cbChar8 'L' <> cbVal a
cbVal (R b) = cbChar8 'R' <> cbVal b
cbVal (U) = cbChar8 'U'
cbVal (B abc kf) = cbChar8 '[' <> cbFlags kf <> cbABC abc
cbVal (S (Token tok) v) = (mempty,bbtok) <> cbVal v where
    bbtok = BB.char8 '{' <> BB.byteString tok <> BB.char8 '}'
cbVal (T txt) = (mempty, BB.char8 '"' <> bbSizedSlice txt)
cbVal (X ref kf) = cbChar8 'X' <> cbFlags kf <> cbRef ref
cbVal (Z abc v) = cbChar8 'Z' <> cbABC abc <> cbVal v

cbToCE :: CacheBuilder -> CacheEnc
cbToCE (refs,bb) = (CE refs bytes) where
    bytes = bbToBytes bb

rdVal :: CacheEnc -> (V, CacheEnc)
rdVal (CE refs sInit) = case LBS.uncons sInit of
    Nothing -> impossible "underflow attempting to read value"
    Just (c, s) -> case c of
        '#' -> let (n, s') = rdVarInt s in (N (fromInteger n), CE refs s')
        'P' ->
            let (a, cea) = rdVal (CE refs s) in
            let (b, ce') = rdVal cea in
            (P a b, ce')
        'L' -> let (a,ce') = rdVal (CE refs s) in (L a, ce')
        'R' -> let (b,ce') = rdVal (CE refs s) in (R b, ce')
        'U' -> (U, CE refs s)
        '[' -> 
            let (kf, cef) = rdFlags (CE refs s) in
            let (abc, ce') = rdABC cef in
            (B abc kf, ce')
        '{' -> case LBS.elemIndex '}' s of
            Just ix ->
                let tok = Token (LBS.toStrict (LBS.take ix s)) in
                let (v, ce') = rdVal $ CE refs (LBS.drop (ix + 1) s) in
                (S tok v, ce')
            Nothing -> impossible "underflow reading sealed value token"
        '"' -> 
            let (txt, s') = rdSizedSlice s in
            (T txt, CE refs s')
        'X' ->
            let (kf, cef) = rdFlags (CE refs s) in
            let (ref, ce') = rdRef cef in
            (X ref kf, ce')
        'Z' ->
            let (abc, cea) = rdABC (CE refs s) in
            let (val, ce') = rdVal cea in
            (Z abc val, ce')
        _ -> impossible $ show c ++ " unrecognized prefix for cached value"

-- as rdVal, but errors if there is any content remaining in the CacheEnc
rdValE :: CacheEnc -> V
rdValE ce =
    let (v, (CE r s)) = rdVal ce in
    let bDone = L.null r && LBS.null s in
    if bDone then v else
    impossible $ "information leftover after reading value: " ++
        show r ++ " " ++ show s

-- strategy assuming small, transient bytestrings
bbToBytes :: BB.Builder -> LBS.ByteString
bbToBytes = BB.toLazyByteStringWith strat mempty where
    strat = BB.untrimmedStrategy 240 BB.smallChunkSize

-------------------------------------------
-- CONVERSIONS BETWEEN PURE AND FAST ABC --
-------------------------------------------

-- | minimal, trivial conversion to pure ABC. This translates our
-- distinct ABC_Block and ABC_Text instances from pure ABC into 
-- ABC_Val instances, but otherwise performs no simplification or
-- acceleration.
fromPureABC :: Pure.ABC -> ABC
fromPureABC = fromPureABC' id

-- | This is a variation on fromPureABC that provides a hook for a
-- user-provided simplifier or optimizer. This optimizer is applied
-- before compacting the bytecode.
fromPureABC' :: ([Op] -> [Op]) -> Pure.ABC -> ABC
fromPureABC' fsimp = convertABC where
    convertABC = compactOps . fsimp . fmap convertOp . Pure.abcOps
    convertOp (Pure.ABC_Prim op) = ABC_Prim op
    convertOp (Pure.ABC_Block abc) = ABC_Val (B (convertABC abc) zeroBits)
    convertOp (Pure.ABC_Text txt) = ABC_Val (T txt)
    convertOp (Pure.ABC_Tok tok) = ABC_Tok tok

-- | We may 'purify' bytecode to recover the original ABC without any
-- special Wikilon extensions. This purification is direct and naive.
--
-- A `{&stow}` annotation is injected for encoding values that Wikilon
-- pushes to disk. So, we can preserve the on-disk encoding
purifyABC :: ABC -> Pure.ABC
purifyABC = Pure.ABC . purifyOps . expandOps

-- | Convert fast ABC operations to pure ABC.
purifyOps :: [Op] -> [Pure.Op]
purifyOps = flip purifyOps' []

-- using a diff list
purifyOps' :: [Op] -> [Pure.Op] -> [Pure.Op]
purifyOps' (op:ops) = purifyOp op . purifyOps' ops
purifyOps' [] = id

purifyOp :: Op -> [Pure.Op] -> [Pure.Op]
purifyOp (ABC_Prim op) = (:) (Pure.ABC_Prim op)
purifyOp (ABC_Tok tok) = (:) (Pure.ABC_Tok tok)
purifyOp (ABC_Ext extOp) = purifyExtOp extOp
purifyOp (ABC_Val v) = purifyV' v 

extOpExpansionArray :: A.Array ExtOp Pure.ABC
extOpExpansionArray = A.accumArray ins eUndef (minBound,maxBound) ops where
    eUndef = impossible "missing expansion for ExtOp"
    ops = fmap (\(op,_,abc) -> (op,abc)) extOpTable
    ins _ c = c

purifyExtOp :: ExtOp -> [Pure.Op] -> [Pure.Op]
purifyExtOp = (++) . Pure.abcOps . (A.!) extOpExpansionArray

-- | Convert a value into pure Awelon Bytecode (ABC) that will later
-- recompute the same value. External value references are annotated
-- with {&stow} to support recovery of deep structure.
purifyV :: V -> Pure.ABC
purifyV = Pure.ABC . flip purifyV' []

-- conversion with a difference list
purifyV' :: V -> [Pure.Op] -> [Pure.Op]
purifyV' = vops where
    abcStr = (++) . Pure.abcOps
    pureOp = (:)
    vops (N i) = abcStr $ Pure.itoabc (toInteger i)
    vops (P a b) = vops b . vops a . abcStr "l"
    vops (L a) = vops a . abcStr "V"
    vops (R b) = vops b . abcStr "VVRWLC"
    vops (U) = abcStr "vvrwlc"
    vops (B abc flags) = b . k . f . lazy . fork where
        -- might later need flags for parallelism, memoization, etc.
        b = pureOp (Pure.ABC_Block (purifyABC abc))
        k = if f_copyable flags then id else abcStr "k"
        f = if f_droppable flags then id else abcStr "f"
        lazy = if f_includes f_lazy flags then abcStr "{&lazy}" else id
        fork = if f_includes f_fork flags then abcStr "{&fork}" else id
    vops (S tok v) = vops v . pureOp (Pure.ABC_Tok tok)
    vops (T txt) = pureOp (Pure.ABC_Text txt)
    vops (X ref _) = vops (deref' ref) . abcStr "{&stow}"
    vops (Z abc v) = vops v . vops (B abc zeroBits) . abcStr "{&lazy}$"

-- Note: I'm using a transparent compression here, albeit only for 
-- sufficiently large objects having an acceptable compression ratio.
--
-- This is likely to save space, since ABC compresses very nicely.
-- For large value objects, it may help reduce paging and allocation,
-- which may improve performance.
instance VCacheable CacheEnc where
    put (CE refs bytes) =
        -- heuristic compression decision
        let nBytes = LBS.length bytes in
        let zBytes = Snappy.compress bytes in
        let nzBytes = LBS.length zBytes in

        let bSufficientlyLarge = (nBytes >= 2000) in
        let bAcceptableRatio = ((nzBytes * 3) <= (nBytes * 2)) in
        let bUseCompression = bSufficientlyLarge && bAcceptableRatio in

        if not bUseCompression
            then putWord8 0 >> put refs >> put bytes
            else putWord8 1 >> put refs >> 
                 putVarNat (fromIntegral nBytes) >>
                 putVarNat (fromIntegral nzBytes) >> 
                 putByteStringLazy zBytes

    get = getWord8 >>= \ vn -> case vn of
        0 -> CE <$> get <*> get
        1 -> get >>= \ refs ->
             fmap fromIntegral getVarNat >>= \ nBytes ->
             fmap fromIntegral getVarNat >>= \ nzBytes ->
             withBytes nzBytes $ \ pzBytes ->
                let fpzBytes = unsafeDupablePerformIO (newForeignPtr_ pzBytes) in
                let zBytes = LBS.fromStrict $ BSI.PS fpzBytes 0 nzBytes in
                let bytes = Snappy.decompress zBytes in
                if (LBS.length bytes /= nBytes) -- also forces strict bytes
                    then fail (abcErr $ "byte count mismatch on decompress")
                    else return (CE refs bytes)
        _ -> fail (abcErr $ "unrecognized cache encoding")

-- leveraging ValEnc as intermediate language where we make some
-- heuristic decisions about encoding...
instance VCacheable V where
    put = put . cbToCE . cbVal
    get = rdValE <$> get

-- I want to guarantee structure sharing between VRef ABC and VRef V
-- for simple block values. So I simply wrap ABC in a block before
-- encoding it. 
instance VCacheable ABC where
    put abc = put (B abc zeroBits)
    get = get >>= \ v -> case v of
        (B abc _kf) -> return abc
        _ -> fail (abcErr $ "invalid encoding for ABC content")

------------------------------------------
-- INTERPRETING AND EVALUATING BYTECODE --
------------------------------------------

-- | A flag indicating that a block is relevant (forbids drop), or
-- that an X ref is not droppable due to transitively containing
-- such a block.
f_rel :: Flags
f_rel = Flags $ 1 `shiftL` 0

-- | A flag indicating that a block is affine (forbids copy), or
-- that an X ref is not copyable due to transitively containing
-- such a block.
f_aff :: Flags
f_aff = Flags $ 1 `shiftL` 1

-- | A flag marking a block as 'lazy'. This delays the computation
-- of the whole block, representing a lazy value instead that may
-- be accessed via explicit `{&join}`. 
f_lazy :: Flags
f_lazy = Flags $ 1 `shiftL` 2

-- | A flag marking a block for 'parallel' evaluation. This assumes
-- the block is a process function, e.g. of the general form:
--
--    type PF i o = i -> (o, PF i o)
--    fork :: PF i o -> PF i (future o)
--
-- A forked PF will produce 'future' output values, which may later
-- be synchronized via `{&join}`.
f_fork :: Flags
f_fork = Flags $ 1 `shiftL` 3



-- In most interpretation contexts, I want the ability to halt on
-- a quota

-- Note that an ABC resource can be modeled by using an external
-- block then inlining it. Naked ABC can be encoded as a block for
-- structure sharing purposes.



f_copyable, f_droppable :: Flags -> Bool
f_copyable = not . f_includes f_aff
f_droppable = not . f_includes f_rel

f_includes :: Flags -> Flags -> Bool
f_includes f = (f ==) . (f .&.)

-- | Test whether a value is copyable by ^ (not affine)
copyable :: V -> Bool
copyable (N _) = True
copyable (P a b) = (copyable a) && (copyable b)
copyable (L a) = copyable a
copyable (R b) = copyable b
copyable (U) = True
copyable (B _ kf) = f_copyable kf
copyable (S _ v) = copyable v
copyable (T _) = True
copyable (X _ kf) = f_copyable kf
copyable (Z _ _) = False

-- | Test whether a value is droppable by % (not relevant)
droppable :: V -> Bool
droppable (N _) = True
droppable (P a b) = (droppable a) && (droppable b)
droppable (L a) = droppable a
droppable (R b) = droppable b
droppable (U) = True
droppable (B _ kf) = f_droppable kf
droppable (S _ v) = droppable v
droppable (T _) = True
droppable (X _ kf) = f_droppable kf
droppable (Z _ _) = False

-- monoid instance shall compose functionality, running all
-- operations (and popping all values) off the first function
-- before reaching any from the second.
instance Monoid ABC where
    mempty = ABC mempty mempty mempty
    mappend a b = mconcat [a,b]
    mconcat l = ABC
        { abc_code = mconcat (fmap abc_code l)
        , abc_data = mconcat (fmap abc_data l)
        , abc_toks = mconcat (fmap abc_toks l)
        }

impossible :: String -> a
impossible = error . abcErr

abcErr :: String -> String
abcErr = (++) "Wikilon.ABC.Fast: "
