namespace Stowage
open Data.ByteString

/// Estimated Serialization Size (in bytes).
type SizeEst = uint64

/// Abstract encoder-decoder type for data in Stowage.
///
/// This uses the stream-oriented read and write from Data.ByteString
/// to avoid constructing too many intermediate buffers. It decodes
/// in context of a DB so we can usefully decode reference values into
/// VRefs, BRefs, or LVRefs.
///
/// Stowage data structures frequently supports a "compaction" step 
/// that rewrites large, stable fragments of a value as VRefs. This 
/// is accessible through the Stowage codec, and compaction returns
/// an estimated write size to aid heuristics.
///
/// Compaction is a special step in context of stowage, whereby the
/// components of a large value are replaced by value refs that can
/// be loaded, cached, and efficiently serialized via secure hashes.
/// For heuristic compaction, a size estimate is also returned.
///
/// Compaction should ideally be idempotent, but this isn't enforced.
type Codec<'T> =
    abstract member Write : 'T -> ByteDst -> unit
    abstract member Read : Stowage -> ByteSrc -> 'T
    abstract member Compact : Stowage -> 'T -> struct('T * SizeEst)

module Codec =

    let inline write (c:Codec<'T>) (v:'T) (dst:ByteDst) : unit = c.Write v dst

    let inline read (c:Codec<'T>) (db:Stowage) (src:ByteSrc) : 'T = c.Read db src

    let inline compactSz (c:Codec<'T>) (db:Stowage) (v:'T) : struct('T * SizeEst) = c.Compact db v

    let inline compact (c:Codec<'T>) (db:Stowage) (v:'T) : 'T =
        let struct(v',_) = compactSz c db v
        v'

    let inline writeBytes (c:Codec<'T>) (v:'T) : ByteString =
        ByteStream.write (write c v)

    /// Read full bytestring as value, or raise ByteStream.ReadError
    let inline readBytes (c:Codec<'T>) (db:Stowage) (b:ByteString) : 'T =
        ByteStream.read (read c db) b

    /// Read full bytestring as value, or return None.
    let inline tryReadBytes (c:Codec<'T>) (db:Stowage) (b:ByteString) : 'T option =
        try readBytes c db b |> Some
        with 
        | ByteStream.ReadError -> None

    /// Stow a value.
    ///
    /// Note: You'll have a reference to the resulting RscHash, so
    /// you'll need to use db.Decref later, or wrap into VRef. See
    /// VRef.stow for a more convenient .Net reference type.
    let inline stow (c:Codec<'T>) (db:Stowage) (v:'T) : RscHash =
        let result = db.Stow (writeBytes c v)
        System.GC.KeepAlive v // prevent GC of VRefs in v during write
        result

    /// Load a stowed value from RscHash.
    let inline load (c:Codec<'T>) (db:Stowage) (h:RscHash) : 'T =
        readBytes c db (db.Load h)

    /// Encode 'Val via 'Rep. 
    ///
    /// This is very useful for building codec combinators. It should be
    /// the case that get and set compose to identity, and the translation
    /// should ideally be inexpensive in each direction.
    let view (cRep : Codec<'Rep>) (get : 'Rep -> 'Val) (set : 'Val -> 'Rep) =
        { new Codec<'Val> with
            member __.Write v dst = cRep.Write (set v) dst
            member __.Read db src = get (cRep.Read db src)
            member __.Compact db v = 
                let struct(rep, szRep) = cRep.Compact db (set v)
                struct(get rep, szRep)
        } 

    /// Boxed Codec, to unify various codec types.
    let inline boxed (cV : Codec<'V>) : Codec<System.Object> =
        view cV (box<'V>) (unbox<'V>)

    /// Invalid Codec - raises `invalidOp` for every operation.
    ///
    /// This is intended as a temporary placeholder for construction of
    /// recursively structured codecs (for example, the Trie codec).
    let invalid : Codec<'Val> =
        { new Codec<'Val> with
            member __.Write _ _ = invalidOp "invalid Codec cannot write"
            member __.Read _ _ = invalidOp "invalid Codec cannot read"
            member __.Compact _ _ = invalidOp "invalid Codec cannot compact"
        }


