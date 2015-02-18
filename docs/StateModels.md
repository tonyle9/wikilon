
# General Overview

In addition to the dictionary, Wikilon needs an auxiliary state model to support user workspaces, issue trackers, feature requests, new web applications, multi-user services, and so on. This will likely form the foundation for all resource models in Wikilon, much as filesystems do for conventional operating systems.

Unlike the dictionary, users will not typically have a 'frozen' view of the auxiliary state model. That said, it might be useful on occasion to experiment on a temporary fork or historical view of state resources, e.g. when initially developing and debugging. (Or even to run the same code on *all* the historical samples, as a quick form of regression testing.) I will be keeping a fair amount of historical state for various reasons - browsing, debugging, recovery from vandalism, archaeological digs, etc.. 

Given historical views, I would like some ability to track which objects were updated by a recent transaction or tick event. This could prove very useful. It might require keeping a timestamp or event stamp on every resource.

# Major Design Points

These are important conclusions that took me some time to reach...

1. **purely functional objects** are excellent for collaboration between mutually distrustful agents because they protect their own state, guard information, and leverage value sealing, yet don't have the entanglement issues of OO systems. A trivial example of a purely functional object model is `µObject.[Message → (Object * Answer)]`. However, I'll likely want to separate queries from updates (i.e. so I can optimize HTTP GET to use read-only queries), and simplify consistent views. Conveniently, [embedded literal objects](EmbeddedLiteralObjects.md) seem to be a pretty good fit for the role of state resources, ensuring consistent views for both readers and writers. Of course, to fit RDP, the update argument might be a a sorted list of structurally distinct demands (a set of demands) instead of a message.

2. **serialize imperative through a powerblock** AO/ABC can operate in imperative modes only by ensuring operations on any specific resource are linearized (otherwise we lose causal commutativity and spatial idempotence). However, precisely tracking which resources are 'in use' is difficult, especially if we want redirection, adapters, or attenuation features. As a programmer, I don't want to be burdened with 'already in use' errors. So, my plan is to logically serialize everything through "the powerblock". That said, we should be able to get a lot of asynchronous computation, e.g. returning the powerblock immediately while the query result is processed in another thread. 

3. **transactionalize imperative operations** If we model logical time as advancing between operations on a powerblock, we can observe writes by other imperative behaviors. This is a problem because it makes for difficult reasoning about code correctness, about partial failure and cleanup, and about consistency of stateful resources. It's also a problem because it would allow for productive polling loops, which is something I wish to strongly discourage. RDP should be the only option for long-running behavior in Wikilon. Console apps should at least transactionalize the commands; each command must terminate successfully to be productive.

4. **transactional & RDP updates don't mix** The concurrency control models are completely incompatible. RDP is long running, leverages anticipation, retroactive correction, generally allows multiple agents to collaboratively influence future state, prohibits observation of 'instantaneous' events. Transactions assume an authoritative view, a single writer, are logically instantaneous, and transactions are simply serialized with the different writers taking turns. The main consequence of this incompatibility is simply that we must distinguish 'resources updated via RDP' from 'resources updated via imperative'. Fortunately, cross-model *queries* don't seem to cause any problems.

5. **stateful resources are weakly isolated** Specifically, generic `{tokens}` are not allowed, with a few machine-independent exceptions like annotations, sealers, unsealers, and external resources. This is necessary to protect linearization of resources for imperative code, and to ensure compatible cross-model data queries between RDP and imperative, and potentially for logically continuous expiration of volatile capabilities via RDP behaviors. These 'live' tokens shall be treated as volatile capabilities within Wikilon. If we also assume purely functional objects, then we can reject tokens even in query or update messages. (Aside: in type system terms, location of code corresponds to a modality; isolation corresponds to a universal or unconstrained location.)

6. **capability-string based hyperlinking** We can't store live tokens, but we'll still want to model hypertext, directories, registries, relationships, etc.. So we'll need some form of capability values which may be passed to a powerblock to access resources without accidentally aliasing them. Also, we'll want to use *the exact same strings* for external programmability of Wikilon, e.g. via web APIs (PUT, POST, GET, etc.). These must be true capability strings, providing authority independent of user identity, no need for permissions (thus one less failure mode).

7. **memory cache at value granularity** If an object directly contains a map, it takes O(N) to load the map into memory or serialize it back to storage, so a O(lg(N)) update becomes mostly irrelevant. Serialization costs can quickly undermine benefits of structure. Performance pressures can drive developers to do nasty things, like divide structure into many smaller objects and use side-effects to entangle them. But, if we can treat partially-evaluated structures as external, memory-cached resources that are loaded as needed, we can obtain many advantages: relaxed alignment concerns, ad-hoc indexing, fine-grained structure sharing, relaxed memory-limit concerns, and so on. 

# Design Concepts

The space for stateful resources in Wikilon must be divided among public services (issue trackers, etc.), and users. Later, users will wish to divide their spaces in a similar manner - public spaces, spaces for each significant application they use, etc.. Applications might again do the same. In context of RDP, this division process must be stable, idempotent, and commutative. Stable names are also nice default attributes for imperative code, e.g. offering stability across rewind and replay of a transaction, though we certainly could model a counter and `new Object()` like behavior using imperative code.

A natural fit for this spatial organization is the simple tree data structure. We would delegate subdirectories to each agent or application. A critical constraint, then, is that authority to a child directory offers no inherent authority to the parent, i.e. no `..` path unless it is granted explicitly. 

Though, one property I dislike about trees is how easily applications become dependent upon the relatively arbitrary structures. We might mitigate this by offering an illusion of each agent or application having its own root authority. Usefully, we can potentially implement stable but opaque names by use of secure hash or HMAC. 

For now, let's take as a given: **tree structure semantics, but opaque IDs**

Besides directories, our tree structure will have many 'leaf objects', representing the user-defined resources. As mentioned earlier, I currently favor pure functional objects in this role, with a clean separation of read-only queries and write-only updates, e.g. based on embedded literal objects. But we may find some use for other objects, such as:

* **read-only access** to a directory should give us both the ability to browse a directory and query the objects within it, including read-only access to its subdirectories and their objects. This suggests every object would have a read-only variant on the capability. 

* **transparent redirects** transparently pass on all messages received by them (including read and write). You can distinguish a transparent redirect, or modify it, only by reading and writing at the level of the directory it is part of. Allows us to mount a shared "/public" directory within each user's space. Redirect also forms a basis for *transitive revocation*. 

* **scripts** allow transparent scatter-gather of data, lenses and data model transforms, ad-hoc attenuation, etc.. Usefully, we can have a clean separation of responsibilities: scripts are stateless, but instead are encoded as simple transactions or RDP behaviors. Scripts would be extremely beneficial for expressiveness and extensibility of the resource model. May have opportunity to attenuate authorities based on caller. Scripts should be capability secure, receiving no authority from location in the tree. 

* **identities** are also necessary for demand monitors, constraint models, and other stateless resources. They might also be useful for secure random number generators and other, related concepts.

I've already filtered the above list down to what I think are great ideas, worth implementing. 

So, what shall our capabilities look like?

* **authority descriptor** e.g. query only
* **stable identifier** specific to the object
* **path tracker** for transitive revocation
* **hmac of the above** to secure the capability
* **compacted into a string** suitable for use in a URL

Based on the idea that we'll mostly be working with objects and scripts (with their own built-in logic), I feel we need two primary layers of authority: one to update or query through the message interface (which allows objects to protect themselves), and another to read or write source code for administrative and maintenance purposes. So I propose the following:

        CODE    CLASS           AUTHORITIES         MNEMONIC
         M      message         query+update        Message
         P      update          update              Post, Push, uPdate
         Q      query           query               Query
         R      read            read                Read
         S      inspect         read+update         inSpect
         W      ownership       read+write          Write, oWn

            read implies query
            read+write implies update

Write authority on a directory is needed to create or delete objects, query to enumerate children. Write-only is not supported because I consider it unwise to blindly write without giving a model some opportunity to defend itself. Update-only is probably sufficient for a job where write-only might be considered, or you could use a script. More authorities are possible, e.g. to look at timestamp for a specific object, to verify the existence of an object, or to delete an object.

These authorities also attenuate objects discovered through enumeration of directories or by naming children. I'd like to support similar 'discovery attenuation' for capabilities held within scripts, at least as an optional transform.

To supply *opaque names*, I'll use the simple concept that every object has a simple text pet name relative to its parent directory (such as "foo" or "user2625"), and also an external opaque name. The external name of a child will then be `secureHash(parentExternalName '/' utf8(petName))`, the root should probably use a secret to provide global disambiguation. Names confer no authority, so the ability to guess them isn't an issue. (The `/` before the petName allows extensibility, naming attributes other than children.)

To model the path tracker, my best idea is to simply include the entire path (from root, through redirects, to the target) in the capability string. Of course, laying these out end-to-end would result in a very bulky string. So we'll overlap them instead:

        M               auth code
         AAAAAAAA       \
          BBBBBBBB       path, e.g.
           CCCCCCCC          /AAAAAAAA/BBBBBBBB/CCCCCCCC/DDDDDDDD
            DDDDDDDD    /
                HHHH    hmac (four bytes to right of last path element)

Then we'll simply XOR everything together. To relocate our object, we'll start at our root, find candidates that start with `A`, XOR candidates out of the string, which exposes `B`, then search for children whose names start with `B`, etc.. Collisions are gradually filtered out across multiple steps in the path, and the last step we expose four bytes to further reduce candidates. This search is essentially a tradeoff for a shorter capability string. 

The final element is an HMAC to protect the capability string from forgery, protecting the auth code. It's also a final disambiguating element. We can probably write a paper about the failure of a hash function if this effort failure of a hash function if this effort fails to disambiguate two items.

Unfortunately, our path now exposes structure to the user, reducing the semantic opacity. People might even (gasp!) try to write functions that discriminate on prefixes. So, to avoid this, I'll add one more step: a simple scrambler function, just to obfuscate hierarchy against casual observation. Ideally, the scrambler won't change the size of the output. I might be able to use AES-CFB to do this, running it from right to left, then just truncating the last cipher-block to match the size of the input text.

Concrete sizes: For 192-bit path element, 160-bit HMAC, cap size is N+24 bytes.

This should be sufficient. I'm tempted to bump up to 256/224. But we can change this whenever we create new Wikilon instances, or even support mixed-mode (i.e. by parsing both options). Ultimately, our capability strings should look a lot like this (this one for path of size 5):

        Mdpxgznkbmxftkjdphhgqsmbszdzmtnkypxqhzxqmzstsqmszqybtqskd

Alternatively, the auth code may also be encrypted. That might even be better, because auth codes aren't necessarily preserved in a meaningful way across scripts or redirects. The encoding of resource strings within bytecode should take the form of *cryptographically sealed values*. Something like:

        "Mdpxgznkbmxftkjdphhgqsmbszdzmtnkypxqhzxqmzstsqmszqybtqskd"{$:wiki}

This embedding offers several advantages. First, it's a semantically faithful representation. Capability strings fundamentally are cryptographically sealed values. Second, it hinders embedding of capability strings within AO code, since cryptographic seals are generally not valid AO code, and at least would be easy to locate. Third, it has potential to track which wiki each resource is associated with, along with any version indicators. 

Also, while I might permit forging text into capability strings in a few special cases, it will be easier to restrict and track these cases within the scope of the resource model and applications.

# Persistence of Structure

Assume an object contains a large, balanced tree structure, with 10k-100k nodes. 

We don't want to rebuild this tree every time to process it, since that would be O(N) to load the tree, and O(N) to serialize it back out again when saving the object. Manipulations on that tree would be O(lg(N)), but that would be minor compared to all the serialization costs.

Good caching could help, but only if we don't serialize out the whole object for every update. Something closer to **acid-state** where we serialize out only the intended action would be necessary. Then we'd serialize the whole object only when we're about to remove the object from memory cache. If active objects spend most of their time in memory cache, the serialization overheads could be mitigated.

Alternatively, developers could model the tree structure in terms of multiple smaller filesystem objects, glued together by a script. This would be able to directly leverage memory cache, i.e. loading only a necessary subset of objects. Unfortunately, it's a toxic idea. It prevents developers from expressing large objects and processes in a natural way, asking them to use side-effects. It entangles the object, making it more difficult to copy and reuse. Further, it exposes object substructure that would otherwise be encapsulated and protected by an object. 

Neither of these options is satisfactory. Both are complicated.

When I designed ABC, one assumption I made is that structured values can be precomputed. As a trivial example, while the number 123/457 might be encoded as ten operators `#123#457/*`, a runtime might benefit from processing this into a number during a partial evaluation phase, or even during the parse. For a number in a block that might be processed more than once, this prevents us from recomputing the number every time we replicate the block. When we serialize the bytecode, of course, we'll need to transform it back to the ten operators or something equivalent. 

Can we extend this assumption to a memory-cached computation? I believe we can. 

Doing so could be hugely advantageous. Very large objects become feasible since it would allow us to load objects and values at a granularity much finer than objects. Many ad-hoc indexing techniques become viable, unconstrained by concerns like page alignment or fixed-width serialization. Fine-grained structure sharing is viable, where lots of objects all reference the same values. Large computations become much simpler, beyond the limits of 

Failure to do so could be disastrous. Performance pressure will drive developers towards the toxic alternatives, tainting the AO dictionaries and the Awelon project's reputation with ugly design patterns. I think it reasonable to consider persistence of structure to be essential, values must be memory cached.

The existing approach to ABC resources is already a near fit for what I need. Indeed, ABC resources may directly be used. A value might be represented as follows:

        vvrwlc[{#resourceId for quoted value}c]{&lazy}$

Here, I'm representing a value resource with a lazy block of type `1→value`. This approach would have a significant advantage of working even in a distributed computation. However, this seems heavy weight, and its external nature will hinder precise garbage collection (we don't know whether the value is exposed to external services). 

A lighter weight variation seems a worthy investment.

The database I'm developing (wikilon-db) has potential to make this easy. Instead of serializing ABC to a simple stream, let's serialize it to a pair: a list or stack of 'value objects', and the bytecode extended with a simple 'escape' to pop a value object from the stack. When we load the bytecode into memory, we'll also pop all the values from the stack (and ensure the resulting stack is empty without underflowing). The 'escape' in this context might be relatively simple, such as an ASCII control code (e.g. FS, SUB, or DC1), or a UTF-8 invalid character (e.g. 0xFD). 

Usefully, we could accomplish this without revealing the 'address' of the referenced value even within the main Wikilon code. Thus, it would be much easier to reason about reference counting or garbage collection.

The remaining difficulty is how to tell Wikilon that a particular value should be given this treatment, make it easy to use - e.g. for balanced trees or sequences. Fortunately, this seems a pretty good candidate for an annotation. Proposed:

        {&stow} :: (a*e) → (a'*e)    tuck value into cold store

I suspect I'll actually want a few variants or attributes, e.g. to indicate whether I expect to need that value again this computation, or expected size, or to optionally use/refuse structure sharing. (All this might be a simple sequence of flags.) In addition, heuristics may apply - e.g. we might reject stowage if the argument is smaller than a few hundred bytes. Developers might tweak these heuristics with a flag (e.g. a single digit representing exponential sizes). 

When a stowed value is observed or accessed, it must automatically be loaded. After all, annotations don't affect observable semantics. To reduce loading latencies, we might wish to explicitly annotate this, e.g. with `{&load}`, so we begin asynchronously loading a value before we'll need it. To reduce risk of accidentally loading a stowed value, developers might be encouraged to wrap stowed values with discretionary sealers.

Usefully, stowed values would be strictly internal, and largely orthogonal to ABC resource model. ABC resources could still benefit from stowed values with regards to persistent, separate compilation. Stowage might also be disabled for read-only computations, such that they're also load-only.

# Stable or Unstable Capability Strings?

At the moment, I'm designing with an assumption of stable capability strings. I could easily destabilize names by using a counter, or a timestamp when an object is created, as contributing to its capability string. This would ensure that deleting and re-creating an object will also revoke all existing capabilities to it, as the default case. 

Do unstable names cause any big concerns with RDP?

For RDP to work effectively, I'll need a directory authority to create objects, and I'll have a 'continuous' model that conflates creation with acquisition. Use of a counter would be a problem, a violation of causal commutativity. But use of a timestamp to destabilize names should not be an issue. 

Potentially, we could model unstable names as stable names by controlling the 'timestamp', e.g. by fixing it to sentinel value, zero. Maybe this is a good way to do things. Developers can explicitly request a stable name when they want one, otherwise the names are always unstable.

# Large Directories

For large directories, e.g. with 4k objects, a filter factor of 256 is much too small.

A viable option is to dynamically expand a directory: at first we filter with one byte, but if there are more than some threshold for objects in the directory, we switch to two bytes, and so on. Each resource thus tracks how many bytes it uses for disambiguation, and we never need to search a given path more than once.

For unstable names, this value could be chosen when the object is constructed. For stable names, we'll need to use a stable overlap model, e.g. 2 bytes overlap for stable directory or redirect names. 

Good thresholds? Well, the goal is to limit the amount of searching we do, so perhaps something like 1/4 the maximum number of items in each class? So, with more than 64 items in a directory, we'll bump up to two-byte names. Meanwhile, stable names are possible.

# CRDTs

[Commutative Replicated Data Types](http://hal.upmc.fr/file/index/docid/555588/filename/techreport.pdf) seem a very simple and very promising approach to support coordination in a distributed system. Further, they may also offer some nicer integration properties between RDP and imperative programming, at least where I can add idempotence.

It seems to me that I should be able to model CRDTs as a special object type in the auxiliary state model as it is currently defined. But the question would be how CRDTs are to be shared. I suppose a read authority would be necessary for replication.


