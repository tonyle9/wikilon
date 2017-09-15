namespace Stowage
open Data.ByteString

/// A Log Structured Merge (LSM) Tree above Stowage
///
/// The LSM-tree is essentially a key-value tree with buffered update.
/// Recent updates are aggregated in memory and applied together. This
/// is highly suitable for write-heavy processes or on-disk storage.
/// Stowage is a form of on-disk storage and benefits from buffering.
///
/// The LSM-tree has some disadvantages, e.g. computing tree size is
/// non-trivial, and we potentially preserve multiple versions of a
/// value for a key.
///
/// To simplify the logic, this LSM-tree variant buffers only `add`
/// updates. Key removal is not buffered. Clients can work around
/// this a bit by use of logical deletion (adding an Empty or None)
/// and an occasional batch cleanup. Even so, key removal isn't worse
/// than for Stowage.CBTree.
module LSMTree =

    type Key = ByteString
    type Critbit = int
    let inline findCritbit cbMin a b = BTree.findCritbit cbMin a b
    let inline testCritbit cb k = BTree.testCritbit cb k

    // Buffer of updates (adds only!), represented in-memory.    
    // On disk we'll use a key-value array.
    type Updates<'V> = (BTree<'V> * Key) option

    type Node<'V> =
        | Leaf of 'V
        | INode of Critbit * Node<'V> * Key * Node<'V>              // Inner Tree Node
        | RNode of Critbit * Updates<'V> * LVRef<Node<'V>>          // Remote Node with Update Buffer

    type Tree<'V> =
        | Empty
        | Root of Key * Node<'V>

    let empty : Tree<_> = Empty
    let isEmpty (t:Tree<_>) : bool =
        match t with 
        | Empty -> true
        | _ -> false
    let inline singleton (k:Key) (v:'V) : Tree<'V> = Root(k, Leaf v)

    let private updTryFind k upd = 
        match upd with
        | None -> None
        | Some(buff,_) -> BTree.tryFind k buff

    let rec private getLKV (k:Key) (node:Node<'V>) : 'V =
        match node with
        | INode (_,l,_,_) -> getLKV k l
        | Leaf v -> v
        | RNode (_,upd,ref) -> 
            match updTryFind k upd with
            | None -> getLKV k (LVRef.load ref)
            | Some v -> v

    let rec private tryFindN (mb:Critbit) (k:Key) (kl:Key) (node:Node<'V>) : 'V option =
        match node with
        | INode (cb, l, kr, r) ->
            if testCritbit cb k 
                then tryFindN mb k kr r
                else tryFindN mb k kl l
        | Leaf v ->
            let keysMatch = Option.isNone (findCritbit mb k kl)
            if keysMatch then Some v else None
        | RNode (cb, None, ref) ->
            match findCritbit mb k kl with
            | None -> Some (getLKV kl (LVRef.load ref))
            | Some mb' ->
                // stop if diff in prefix or if smaller than least-key
                let stop = (mb' < cb) || (testCritbit mb' kl)
                if stop then None else
                tryFindN mb' k kl (LVRef.load ref)
        | RNode (cb, Some(buff,kl0), ref) ->
            let vInBuff = BTree.tryFind k buff
            if Option.isSome vInBuff then vInBuff else
            match findCritbit mb k kl0 with
            | None -> Some (getLKV kl0 (LVRef.load ref))
            | Some mb' ->
                let stop = (mb' < cb) || (testCritbit mb' kl0)
                if stop then None else
                tryFindN mb' k kl0 (LVRef.load ref)

    /// Find some value associated with a key, or return none.
    let tryFind (k:Key) (t:Tree<'V>) : 'V option =
        match t with
        | Root (kl,n) -> tryFindN 0 k kl n
        | Empty -> None

    /// Find value associated with key 
    ///   or raise `System.Collections.Generic.KeyNotFoundException()`.
    let find (k:Key) (t:Tree<'V>) : 'V =
        match tryFind k t with
        | Some v -> v
        | None -> raise (System.Collections.Generic.KeyNotFoundException())
        
    let rec private containsKeyN mb k kl node =
        match node with
        | INode (cb, l, kr, r) ->
            if testCritbit cb k 
                then containsKeyN mb k kr r
                else containsKeyN mb k kl l
        | Leaf v -> Option.isNone (findCritbit mb k kl)
        | RNode (cb, None, ref) ->
            match findCritbit mb k kl with
            | None -> true 
            | Some mb' ->
                let stop = (mb' < cb) || (testCritbit mb' kl)
                if stop then false else
                containsKeyN mb' k kl (LVRef.load ref)
        | RNode (cb, Some(buff,kl0), ref) ->
            let vInBuff = BTree.tryFind k buff
            if Option.isSome vInBuff then true else
            match findCritbit mb k kl0 with
            | None -> true
            | Some mb' ->
                let stop = (mb' < cb) || (testCritbit mb' kl0)
                if stop then false else
                containsKeyN mb' k kl0 (LVRef.load ref)

    /// Test whether a tree contains a specific key.
    let containsKey (k:Key) (t:Tree<'V>) : bool =
        match t with
        | Root (kl,n) -> containsKeyN 0 k kl n
        | Empty -> false

    let private updAdd (k:Key) (v:'V) (kl:Key) (upd:Updates<'V>) : Updates<'V> =
        match upd with
        | None -> Some(BTree.singleton k v, kl)
        | Some (buff, kl0) -> Some (BTree.add k v buff, kl0)

    let rec private setLKV (kl:Key) (v:'V) (node:Node<'V>) : Node<'V> =
        match node with
        | INode (cb, l, kr, r) -> 
            let l' = setLKV kl v l
            INode (cb, l', kr, r)
        | Leaf _ -> Leaf v
        | RNode (cb, upd, ref) -> 
            let upd' = updAdd kl v kl upd
            RNode (cb, upd', ref)

    let rec private addLKV (mb:Critbit) (k:Key) (v:'V) (kl:Key) (node:Node<'V>) : Node<'V> =
        match node with
        | INode (cb, l, kr, r) when (mb >= cb) ->
            assert(mb > cb)
            let l' = addLKV mb k v kl l
            INode (cb, l', kr, r)
        | RNode (cb, upd, ref) when (mb >= cb) ->
            assert(mb > cb)
            let upd' = updAdd k v kl upd
            RNode (cb, upd', ref)
        | _ -> 
            assert(testCritbit mb kl)
            INode(mb, Leaf v, kl, node)

    // assume k > kl at mb
    let rec private addRKV (mb:Critbit) (k:Key) (v:'V) (kl:Key) (node:Node<'V>) : Node<'V> =
        match node with
        | INode (cb, l, kr, r) when (mb >= cb) ->
            if (mb > cb) then
                let l' = addRKV mb k v kl l
                INode (cb, l', kr, r)
            else
                match findCritbit (1+cb) k kr with
                | Some mb' ->
                    if testCritbit mb' k 
                        then INode (cb, l, kr, addRKV mb' k v kr r)
                        else INode (cb, l, k,  addLKV mb' k v kr r)
                | None -> INode (cb, l, kr, setLKV kr v r)
        | RNode (cb, upd, ref) when (mb >= cb) -> 
            let upd' = updAdd k v kl upd
            RNode (cb, upd', ref)
        | _ -> INode (mb, node, k, Leaf v)


    /// Add a key-value association to a tree. 
    ///
    /// The Tree is persistent, so this returns a new tree with the
    /// specified modification. As a log-structured merge tree, add
    /// is buffered. Use explicit compaction to propagate oversized
    /// buffers into remote nodes.
    let add (k:Key) (v:'V) (t:Tree<'V>) : Tree<'V> =
        match t with
        | Root (kl, n) -> 
            match findCritbit 0 k kl with
            | Some mb -> 
                if testCritbit mb k
                    then Root (kl, addRKV mb k v kl n)
                    else Root (k,  addLKV mb k v kl n)
            | None -> Root (kl, setLKV kl v n)
        | Empty -> singleton k v

    let private applyUpdates (upd:Updates<'V>) (n:Node<'V>) : Node<'V> =
        match upd with
        | None -> n
        | Some (buff, kl0) ->
            let t' = BTree.fold (fun t k v -> add k v t) (Root(kl0,n)) buff
            match t' with
            | Root(_, n) -> n
            | Empty -> failwith "impossible state"

    // load ref and apply updates
    let inline private loadR (upd:Updates<'V>) (ref:LVRef<Node<'V>>) : Node<'V> =
        applyUpdates upd (LVRef.load' ref)

    // remove least-key value for a node, return a tree.
    let rec private removeLKV (node:Node<'V>) : Tree<'V> =
        match node with
        | INode (cb, l, kr, r) ->
            match removeLKV l with
            | Empty -> Root(kr, r)
            | Root(kl', l') -> Root(kl', INode(cb, l', kr, r))
        | Leaf _  -> Empty // key removed
        | RNode (_, upd, ref) -> 
            removeLKV (loadR upd ref)

    // remove a key from a node.
    let rec private removeN (mb:Critbit) (k:Key) (kl:Key) (node:Node<'V>) : Tree<'V> =
        match node with
        | INode (cb, l, kr, r) ->
            if testCritbit cb k
               then match removeN mb k kr r with
                    | Root(kr',r') -> Root(kl, INode(cb, l, kr', r'))
                    | Empty -> Root(kl,l)
               else match removeN mb k kl l with
                    | Root(kl',l') -> Root(kl', INode(cb, l', kr, r))
                    | Empty -> Root(kr,r)
        | Leaf _ ->
            let keysMatch = Option.isNone (findCritbit mb k kl)
            if keysMatch then Empty else Root(kl,node)
        | RNode (cb, upd, ref) ->
            match findCritbit mb k kl with
            | None -> removeLKV (loadR upd ref)
            | Some mb' ->
                let stop = (mb' < cb) || (testCritbit mb' kl)
                if stop then Root(kl,node) else
                removeN mb' k kl (loadR upd ref)

    /// Remove key from tree, returning modified tree.
    ///
    /// Note: Removal for LSM tree is not buffered. All versions for
    /// a key are removed. Further, it assumes the key is present. 
    /// A `containsKey` filter is wise for improbable keys.
    ///
    /// If removal is a frequent operation, consider a value type
    /// with logical deletion such that you may delete by 'adding'
    /// a value. You could eventually filter the tree.
    let remove (k:Key) (t:Tree<'V>) : Tree<'V> =
        match t with
        | Root (kl, node) -> removeN 0 k kl node
        | Empty -> Empty

(*

    // encoding the update buffer
    module EncBuff =
                                     // in context:
        let cNoUpdates = byte '='    // R={hash}
        let cSomeUpdates = byte '+'  // R+(updates)(oldKey){hash}

        let codec (cV:Codec<'V>) = 
            let cKV = EncPair.codec (EncBytes.codec) (EncOption.codec cV)
            { new Codec<Node<'V>> with
                member __.Write buff dst =
                    match buff with
                    | None -> EncByte.write cNoUpdates dst
                    | Some (t,oldLK) ->
                        assert(not (CBTree.isEmpty t))
                        EncByte.write cSomeUpdates dst
                        EncArray.write cKV (CBTree.toArray t) dst
                        EncBytes.write oldLK dst
                member __.Read db src =
                    let b0 = EncByte.read src
                    if (cNoUpdates = b0) then None 
                    elif (cSomeUpdates <> b0) then raise ByteStream.ReadError
                    else 
                        let t = CBTree.fromArray (EncArray.read cKV db src)
                        let oldLK = EncBytes.read src
                        Some (t, oldLK)
                member __.Compact db buff =
                    match buff with
                    | None -> struct(buff,1)
                    | Some (t,oldLK) ->
                        let struct(a,szB) = EncArray.compact' cKV db (CBTree.toArray t)
                        let t' = CBTree.fromArray a
                        struct(Some(t',oldLK), szB + EncBytes.size oldLK)
            }

    // Nodes are encoded almost directly, but require a special context
    // of the prior least-key when propagating updates 
    module EncNode =
        let cLeaf  : byte = byte 'L'
        let cINode : byte = byte 'N'
        let cRNode : byte = byte 'R'

        // heuristic size threshold for compaction of a node.
        // in this case, I'm favoring relatively large nodes.
        let compactThreshold : int = 14000

        let inline buffToArray buff = Array.ofSeq (CBTree.toSeq buff)
        let inline arrayToBuff arr = 
            Array.fold (fun buff (k,v) -> CBTree.add k v buff) (CBTree.empty) arr
        let kvCodec cV = EncPair.codec (EncBytes.codec) (EncOption.codec cV)

        let codec (cV:Codec<'V>) =
            let cBuff = EncBuff.codec cV
            { new Codec<Node<'V>> with
                member cN.Write node dst =
                    match node with
                    | Leaf v ->
                        EncByte.write cLeaf dst
                        cV.Write v dst
                    | RNode (buff, ref) ->
                        EncByte.write cRNode dst
                        cBuff.Write buff dst
                        EncLVRef.write ref dst
                    | INode (cb, l, kr, r) ->
                        EncByte.write cINode dst
                        EncVarNat.write (uint64 cb) dst
                        cN.Write l dst
                        EncBytes.write kr dst
                        cN.Write r dst
                member cN.Read db src =
                    let b0 = EncByte.read src
                    if(cLeaf = b0) then
                        Leaf (cV.Read db src)
                    elif(cRNode = b0) then
                        let buff = cBuff.Read db src
                        let ref = EncLVRef.read cN db src
                        RNode (buff,ref)
                    elif(cINode <> b0) then
                        raise ByteStream.ReadError
                    else
                        let cb = int (EncVarNat.read src)
                        let l = cN.Read db src
                        let kr = EncBytes.read src
                        let r = cN.Read db src
                        INode (cb, l, kr, r)
                member cN.Compact db node =
                    match node with
                    | Leaf v ->
                        let struct(v',szV) = cV.Compact db v
                        struct(Leaf v', 1 + szV)
                    | RNode (buff, ref) ->
                        let struct(buff', szBuff) = cBuff.Compact db buff
                        if(szBuff < compactThreshold) 
                            then struct(RNode(buff',ref), 1 + szBuff + EncLVRef.size)
                            else cN.Compact db (applyUpdates buff (LVRef.load' ref))
                    | INode (cb, l, kr, r) ->
                        let struct(l',szL) = cN.Compact db l
                        let struct(r',szR) = cN.Compact db r
                        let node' = INode (cb, l', kr, r')
                        let szN = 1 + EncVarNat.size (uint64 cb)
                                    + szL + EncBytes.size kr + szR
                        if(szN < compactThreshold) then struct(node',szN) else
                        let ref = LVRef.stow cN db node'
                        struct(RNode(None,ref), 2+EncLVRef.size) // R={hash}
            }
                 

*)