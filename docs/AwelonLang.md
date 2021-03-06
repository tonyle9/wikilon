
# Awelon Language

Awelon is a Turing complete, purely functional language based on concatenative combinators with confluent rewrite rules. Specifically, Awelon has four primitive combinators:

        [B][A]a == A[B]         (apply)
        [B][A]b == [[B]A]       (bind)
           [A]c == [A][A]       (copy)
           [A]d ==              (drop)

Beyond these four primitives, programmers develop a *Dictionary* where each word is defined by an Awelon encoded function. For example, if we want an inline function `[A]i == A` then we could define `i = [[]] a a d`. Evaluation proceeds by rewriting according to the primitive combinators and lazily substituting words by their definitions when doing so permits further progress. Hence, the result of evaluation is an equivalent program. To work with data, Awelon has special support for natural numbers, records, texts, and binaries.

Those `[]` square brackets contain Awelon code and represent first-class functions. Values in Awelon are always first-class functions, typically using [Church encodings](https://en.wikipedia.org/wiki/Church_encoding) or [Scott encodings](https://en.wikipedia.org/wiki/Mogensen%E2%80%93Scott_encoding). However, effective Awelon compilers or interpreters should recognize and optimize common functions and value types. This is a concept of software *Accleration* to improve efficient use of CPU and memory, extending the set of language performance primitives. Acceleration for collections-oriented operations, such as matrix multiplication and linear algebra, can feasibly leverage SIMD instructions or GPGPU.

Compilers or interpreters will also recognize a set of *Annotations*, represented by parenthetical words. For example, `[A](par)` can request parallel evaluation for the subprogram `A`, or `[F](accel)` might indicate that `F` should be recognized and accelerated. Annotations have identity semantics. Ignoring them won't affect observations within the program. However, external observers will be affected. Annotations serve roles in debugging and guiding performance.

By itself, Awelon is a very simplistic language - a purely functional assembly. 

The intention is to leverage [projectional editing tools](http://martinfowler.com/bliki/ProjectionalEditing.html) to render programs with a rich structural or graphical syntax. Because Awelon evaluates by rewriting, the same projections can render evaluated results and intermediate states. The purpose of Awelon language is to develop [application and data models](ApplicationModel.md) that are accessible, sharable, and composable by end users.

## Words

Words are the user-definable unit for Awelon code. Syntactically, a word has regex `[a-z][a-z0-9-]*`. That is, a word consists of lower case alphanumerics and hyphens, and starts with an alpha. Definitions of words are acyclic, Awelon encoded functions. (Recursive definitions must use anonymous recursion; see *Loops*.)

The formal meaning of a word within Awelon code is equivalence to its definition. But words are often given special connotations in context of an environment. For example, `foo-doc` may associate documentation with word `foo`, or `main` may serve as the default entry point for a monadic process.

## Natural Numbers

Awelon has native support for natural numbers. Syntactically, numbers are represented by regex `0 | [1-9][0-9]*` wherever a word may appear. 

        0 = [zero]
        1 = [0 succ]
        2 = [1 succ]
        3 = [2 succ]
        ...
        42 = [41 succ]
        (et cetera)

Definitions for `zero` and `succ` are left to the dictionary. However, in practice you'll want to use definitions that are recognized and accelerated. Awelon does not have any built-in support for signed integers, floating point numbers, etc.. Those should be introduced using an *Editable View* through a projectional editor.

## Embedded Texts

Awelon has limited native support for embedding texts inline between double quotes such as `"Hello, world!"`. Embedded texts are limited to ASCII, specifically the subset valid in Awelon code (32-126) minus the double quote `"` (34). There are no escape characters. Semantically, a text represents an ASCII binary list.

        ""      = [null]
        "hello" = [104 "ello" cons]

Embedded texts are suitable for lightweight DSLs, test data, rendering hints, comments, and similar use cases. Large or sophisticated texts can be represented as external *Secure Hash Resources* or supported by *Editable View*. For example, `["hello\nmulti-line\nworld" literal]` could be presented to a user as an editable multi-line text-box that automatically splices in escapes. Although there are no built-in escape characters, we can effectively define our own in this manner. Like natural numbers, definitions for `null` and `cons` are left to the user, but in practice are guided by available acceleration.

Structured data, like XML, is better modeled as an Awelon data type to permit flexible abstraction, templating, procedural generation, and large-scale via secure hash resources. 

## Secure Hash Resources

It is possible to identify binaries by *secure hash*. Doing so has many nice properties: immutable and acyclic by construction, cacheable, securable, provider-independent, self-authenticating, implicitly shared, automatically named, uniformly sized references, and smaller than full URLs or file paths. Awelon systems widely leverage secure hashes to reference binaries:

* external binary data may be referenced via `%secureHash`
* code and structured data is referenced via `$secureHash`
* dictionary tree nodes are referenced using `/prefix secureHash`

Use of `$secureHash` is essentially an anonymous word, whereas `%secureHash` is widely used as an alternative to external data file references. The semantics for `%secureHash` is to expand the binary as a list of bytes, much like embedded texts. Storage of resources is unspecified. We simply assume that Awelon systems have built-in or configurable knowledge about where to seek secure hashes - whether that be fileystem, database, web service, content delivery network, etc.. 

In practice, the size for any single secure hash resource may be limited to several megabytes. This maximum block size would be determined by our runtime. Larger binaries should be sliced apart, explicitly represented as a list or tree of smaller binary fragments to permit flexible streaming or efficient update.

Awelon uses the 320-bit [BLAKE2b](https://blake2.net/) algorithm, encoding the hash using 64 characters in a [base32](https://en.wikipedia.org/wiki/Base32) alphabet.

        Base32 Alphabet: bcdfghjklmnpqrstBCDFGHJKLMNPQRST
            encoding 0..31 respectively

        Example hashes, chained from "test":

        rmqJNQQmpNmKlkRtsbjnjdmbLQdpKqNlndkNKKpnGDLkmtQLPNgBBQTRrJgjdhdl
        cctqFDRNPkprCkMhKbsTDnfqCFTfSHlTfhBMLHmhGkmgJkrBblNTtQhgkQGQbffF
        bKHFQfbHrdkGsLmGhGNqDBdfbPhnjJQjNmjmgHmMntStsNgtmdqmngNnNFllcrNb
        qLDGfKtQHhhTthNTDMMqDMDKnrCTpSSBHHBjDNtsKrTdNRGgtmtqQFTdGjsnfJDR

We can safely neglect the theoretical concern of secure hash collisions. If BLAKE2b is cracked in the future, we can address it then by transitively rewriting all secure hashes in our Awelon dictionaries. I won't further belabor the issue. 

*Security Note:* Secure hash resources may embed sensitive information, yet are not subject to conventional access control. Awelon systems should treat each secure hash as an [object capability](https://en.wikipedia.org/wiki/Object-capability_model) - a bearer token that grants read authority. Relevantly, Awelon systems should guard against timing attacks that might leak these secure hashes. Favor constant-time comparisons when using hashes as lookup keys, for example. In context of distributed storage, it may prove useful to use the first half of each hash for lookups and the remainder as a key for AES decryption. Finally, for resources with private, low-entropy data (like a phone number or credit card number), embedding a comment with a random string can help resist "does this data exist?" attacks. 

## Annotations

Annotations in Awelon take the form of a parenthetical word, such as `(par)` or `(error)`. Annotations must formally have identity semantics, but may inform an interpreter or compiler to verify assumptions, fail fast on assertions, optimize representations, influence evaluation order, manage quotas, and render or breakpoint intermediate states for debugging. Annotations represent a programmer's assumptions or intentions that cannot be encoded using `a b c d` primitives. The set of supported annotations depends on the runtime system and should be documented carefully and adhere to de-facto standards.

Potential annotations:

* `(trace)` - print argument to debug console or log
* `(error)` - prevent progress within a computation
* `(par)` - evaluate argument in parallel, in background
* `(eval)` - evaluate argument before progressing further
* `(stow)` - move large values to disk, load on demand
* `(accel)` - assert software acceleration of a function
* `(optimize)` - rewrite function for efficient evaluation
* `(jit)` - compile a function for multiple future uses
* `(stat)` - assert a value is computed statically
* `(memo)` - memoize a computation for incremental computing
* `(nat)` - assert argument should be a natural number
* `(type)` - describe type of stack at given location
* `(quota)` - impose limits on argument evaluation effort

Some annotations such as `(jit)` are tags. They attach to a value:

        [A](tag) [B]b ==  [[A](tag) B]

Some annotations, such as `(type)` may require an additional argument: 

        [Type Descriptor](type)d

Awelon does not constrain annotations beyond requirement for identity semantics. 

## Acceleration

Accelerators are essentially "built-in" functions with reference implementation provided in the Awelon dictionary. For example, if we accelerate 32-bit or 64-bit modulo arithmetic for natural numbers, then we could leverage CPU-native words and operations. Accelerators may further be supported by annotations such as `(nat)` or `(nat-32)` that suggest optimized representations for common value types.

Acceleration of collection-oriented operations and data structures (for matrices, vectors, streams, etc.) could support high levels of SIMD parallelism. But more sophisticated accelerators might embed DSLs within Awelon. For example, to support GPGPU processing, it is feasible to accelerate a pure subset of OpenCL. Large scale cloud computing could be supported by accelerating evaluation of Kahn Process Networks.

For robust, predictable performance, accelerated subprograms should always be indicated by annotation, e.g. `[reference impl](accel)`. An explicit annotation makes it easy to warn developers when the assumption fails, due to deprecation or porting of code between systems. Further, it simplifies recognition of accelerated code by an interpreter or compiler.

## Stowage

Stowage is a simple idea, summarized by rewrite rules:

        [large value](stow) => [$secureHash]
        [small value](stow) => [small value]

Stowage uses the *Secure Hash Resources* space to offload data from working memory. This actual offload would usually apply lazily, when space is needed. The data will be loaded again when observed. Essentially, this gives us an immutable virtual memory model suitable for persistent data structures. What "large" means is heuristic, but should be simple to understand, predict, and reproduce. A simple rule like "1600 bytes is the lower bound of large" should be sufficient. Configurable variants are feasible, e.g. `(stow-large)` vs. `(stow-small)`. We can also support binary variants.

## Dictionary

Awelon words are defined in a codebase called a "dictionary". A dictionary is simply an association between words and Awelon encoded functions. However, for Awelon project's goals, we require a standard import/export representation that supports efficient update, sharing, snapshots, versioning, and diffs at scales of many gigabytes or terabytes. Legibility is also a goal, to simplify debugging or inference of implementation.

The proposed representation:

        /prefix1 secureHash1
        /prefix2 secureHash2
        :symbol1 definition1
        :symbol2 definition2
        ~symbol3

A dictionary 'node' is represented with dense, line-oriented ASCII text, representing an update log. Each line will define or delete a symbol (`:` or `~` respectively), or index another node (via `/`). Blank lines and comments are not permitted. Symbols usually correspond to Awelon words, definitions to Awelon code. Indexed nodes are identified by secure hash, cf. *Secure Hash Resources*. Symbols for inner nodes are stripped of the matched prefix, hence `:poke` under `/p` becomes `:oke`. For lookup, only the final update for a given symbol or prefix is used. Hence, `/p` will mask all prior updates with prefix `p` such as `/prod` and `:poke`. We normalize a dictionary node by erasing irrelevant entries then sorting what remains.

For oversized definitions, this representation can be inefficient. We can ameliorate this by moving oversized definitions into the resource layer via `$secureHash` redirect.

This representation combines characteristics of the LSM-tree, radix tree, and Merkle tree. It supports deeply immutable structure, structure sharing, lightweight version snapshots, lazy compaction, distributed storage, efficient diffs, and soft real-time streaming updates. The empty prefix `/ secureHash` can be leveraged to represent prototype inheritance or a stream reset. Like other LSM-trees, this does allow capture of multiple definitions for a symbol. But even that can be useful to optimize separate compilation based on relative stability of definitions.

*Note:* Comments and metadata should be embedded within definitions. We can use forms such as `"remark"(a2)d` for second-class embedded comments. But we can also dedicate volumes of a dictionary using ad-hoc naming conventions, e.g. such that `foo-meta-doc` is widely recognized as a place to put documentation for `foo`. Full dictionary concerns such as bug trackers could also be recorded within the dictionary.

### Software Packaging and Distribution

For Awelon project, the intention is that we'll usually curate and share entire dictionaries - ensuring all definitions are versioned, managed, tested together. Instead of libraries, software distribution would be modeled via DVCS-inspired mechanisms - pull requests, bug reports, etc.. 

However, we can still support a more conventional software library/package model. In this case, all words in our package could define words with a common prefix such as `math-`. A line such as `/math- secureHash` would then embed the package in the dictionary. The secure hash serves as a fully specified, verifiable, provider-independent version number, albeit without any semantic versioning. We can also define `:math-meta-version "1.0.34"` if users insist. Although Awelon does not have namespaces built-in, we can leverage *Editable Views* to mask long prefixes.

### Hierarchical Dictionary Structure

Several of Awelon's proposed [application models](ApplicationModel.md) rely on storing data into the dictionary. In this context, the dictionary serves as a filesystem or database with spreadsheet-like characteristics. But with multiple humans and software agents maintaining the data, we introduce several concerns related to name conflicts and information security for data flows. To simplify these issues, Awelon permits hierarchically embedding one dictionary within another. A dictionary is confined, unable to access its host. But the host can easily access embedded dictionaries through extended words of form `dictname/foo`. We can also interpret other Awelon operations under a hierarchical context:

        d/bar       (use `bar` from dictionary `d`)
        d/42        => d/[41 succ]
        d/[41 succ] => [d/41 d/succ]
        d/"hello"   => d/[104 "ello" cons]

In the dictionary representation, we simply define the extended symbols. For example, we can can write `:d/bar def` to update the definition for word `bar` in dictionary `d`. We can also use `/d/ secureHash` to logically embed or update an entire dictionary. 

Common functions and types will frequently be replicated between hierarchical dictionaries. The space overhead is mitigated by structure sharing. But writing out `d/42` is just ugly and inefficient if it has the same meaning as `42`. So we permit localization: an evaluator may rewrite a hierarchical qualifier whenever doing so does not affect behavior.

*Note:* It may be useful to encode a developer's primary dictionary under a prefix such as `d/word`. This enables embedding of metadata (such as timestamps or access control) via associated sibling dictionaries.

## Evaluation

Evaluation of an Awelon program simply rewrites it to an equivalent program. An external agent will presumably extract data from the evaluated result, then potentially modify the program and continue. Awelon is a pure language, but interactions with external agents provides a basis for effects.

Primitives rewrite by simple pattern matching:

            [B][A]a => A[B]         (apply)
            [B][A]b => [[B]A]       (bind)
               [A]c => [A][A]       (copy)
               [A]d =>              (drop)

Words rewrite into their evaluated definitions. If a word is undefined, it will not rewrite further. However, words will not rewrite unless doing so leads to further progress. There is no benefit in rewriting a word if it only leads to the inlined definition. This rule is called lazy linking. Lazy linking also ensures words denoting first-class values, such as `true = [a d]`, should be bound and moved directly, e.g. `true [] b => [true]`. 

Evaluation strategy is unspecified, and the default may be a heuristic mix of lazy, eager, and parallel. Awelon's primitives are confluent, therefore *valid* computations should reach the same result regardless of strategy. For *invalid* computations (such as `"2" 1 nat-add` or `3 0 nat-div`), or in case of quotas or breakpoints, partial evaluation is at discretion of the runtime and may expose implementation or optimization details.

### Arity Awaiting Annotations

Arity awaiting annotations are useful for Awelon, and have simple rewrite rules:

        [B][A](a2) == [B][A]
        [C][B][A](a3) == [C][B][A]
        ...

These annotations can be used to defer linking of words where a partial evaluation isn't useful. For example, consider a swap function `w = (a2) [] b a`. Ignoring the arity annotation, we'd rewrite `[A]w => [[A]]a`, which isn't useful progress. With the arity annotation, `[A]w` does not evaluate further, but `[B][A]w` evaluates directly to `[A][B]`. Arity annotations are also useful for modeling codata. For example, `[[A](a2)F]` has the observable behavior as `[[A]F]`, but the former defers computation until the result is required.

## Loops

Awelon definitions are acyclic, but we can express fixpoint combinators:

        [X][F]z == [X][[F]z]F
        z = [[(a3) c i] b (eq-z) [c] a b w i](a3) c i

        assuming:
            [def of foo](eq-foo) == [foo]
            [B][A]w == [A][B]       w = (a2) [] b a
               [A]i == A            i = [] w a d

This is the strict fixpoint combinator, which awaits one additional argument before evaluating. Using fixpoint combinators, we can express general recursive functions and loops. Unfortunately, fixpoint is difficult to use directly - even after writing dozens of fixpoint functions, I still find it awkward. This can be mitigated by use of *Named Local Variables* to represent function-local named recursion (see below). But in practice, it seems more convenient favor specialized loop combinators and collections-oriented programming styles.

## Memoization

Annotations can easily indicate [memoization](https://en.wikipedia.org/wiki/Memoization).

        [computation](memo) => [result]

Memoization involves searching for an existing record of the computation, or writing one if it does not exist. The exact mechanism may vary. Naively, we could use a table lookup. A more sophisticated mechanism might involve reusable partial evaluation traces. Regardless, the idea is to use memory - without explicitly introducing *state* - to avoid redundant computations.

For effective incremental computing, we must use memoization together with cache-friendly patterns: compositional views over persistent data structures, stowage for large but stable volumes of data.

## Error Reporting

We can represent errors by simply introducing an `(error)` annotation that acts as an undefined word, unable to be further rewritten. Then, we can define words such as `divide-by-zero = (error)` to create explicit, named errors that never rewrite further. Error values can be expressed as `[(error)]`. Errors in the top-level of an evaluated definition should be reported to programmers, except in the trivial case.

## Static Typing

Awelon doesn't depend on types. There is no type-driven dispatch or overloading. However, the language implies a simple static type model. If we can discover errors earlier by using static type analysis, that's a good thing. The stack-like environment can be typed as a tuple, and values as functions. Record constructors are typed using row polymorphism. Types for our primitive operations:

        a           ((s * x) * (s → s')) → (s' * x)
        b           ((s * x) * ((e * x) → e')) → (s * (e → e'))
        c           (s * x) → ((s * x) * x)
        d           (s * x) → s
        [F]         s → (s * type(F))

Type annotations can be expressed using Awelon annotations, we only need some conventions. Obviously, we can use specific annotations such as `(nat)` or `(bool)`. Lightweight annotations could describe function arity, such that `[F](t21)` indicates `F` receives two arguments and returns one result. For more sophisticated or precise types, we may eventually support `[Type Descriptor](type)d`, enabling flexible type descriptions. Debugging with structured types is usually a hassle because types can become very large, but annotations can also help here - enabling human-meaningful metadata to be lifted into the type analysis.

Unfortunately, simple static types are sometimes too simplistic and restrictive. For example, the `pick` function from Forth isn't amenable to static typing without sophisticated dependent types:

        [Vk]..[V1][V0] k pick == [Vk]..[V1][V0][Vk]

In this context, we could develop a series of functions like `pick2nd` and `pick3rd`, at cost of much boiler-plate. Or we could try to defer static typing until after we've specialized on the first parameter, treating `pick` as a macro. Intention to defer type checking can be indicated by annotation, e.g. adding a `(dyn)` comment to the subprogram with `[A](dyn) => [A]` behavior.

*Note:* Besides static types, termination analysis is also useful. As a purely functional language, non-termination or divergence is always an error for Awelon programs.

### Opaque Data Types

Modularity in functional programming is frequently based around opaque or abstract data types. Direct access to the data representation is confined to a predictable volume of code. Other code must use the provided interface. Using opaque data, we can enforce invariants, control coupling, partition programming tasks, and isolate bugs. 

For Awelon, we can support opaque data types via paired annotations:

        (seal-foo)  (s * x) → (s * foo:x)
        (open-foo)  (s * foo:x) → (s * x)

These annotations serve as symbolic type wrappers, resisting accidental access to data. Enforcement can be static or dynamic, and with compiler support the runtime overhead can feasibly be eliminated. For opacity, we further restrict access using a prefix matching constraint: `(seal-foo)` or `(open-foo)` may only be directly used in definitions of words that start with `foo-`. This would be enforced by a linter. Thus, hyphenated prefixes describe the predictable volumes of code confining direct access to data, and this would align with potential libraries.

## Structural Equivalence

Annotations can assert two functions are the same, structurally:

        [A][B](eq) => [A][B]     iff A,B, structurally equivalent

Structural equivalence assertions are certainly convenient for lightweight unit testing. But the motivating use case is sorted merge. Efficient merge requires assuming the two structures are sorted using the same comparison function. If we couple that function with the data, we can use `(eq)` to verify our assumption.

## Editable Views

Awelon's simple syntax must be augmented by [projectional editing](http://martinfowler.com/bliki/ProjectionalEditing.html) techniques to support richer programming interfaces, DSLs, namespaces, application models, and larger programs. As a simple example, we could support a numeric tower:

        #42         == (Awelon's 42)
        42          == [#42 #0 integer]
        -7          == [#0 #7 integer]
        3.141       == [3141 -3 decimal]
        -0.0070     == [-70 -4 decimal]
        2.998e8     == [2998 5 decimal]
        -4/6        == [-4 #6 rational]

This builds one view upon another, which is convenient for extending views. If our view left out rational numbers, we'd still render a sensible `[-4 #6 rational]`. Relative to built-in number support, there is some storage overhead - but it's relatively minor at larger scales (and compresses well). Besides numeric towers, editable views could feasibly support lists and matrices, continuation-passing style, Haskell-inspired do-notation, generators with yield, and other features. Problem specific languages can frequently be modeled as data-structures that we evaluate statically. Comments can easily be supported, e.g. `// comment == "comment"(a2)d`. Qualified namespaces are easy to support, e.g. such that `long-prefix-foo` can be abbreviated as `lp-foo`. It is feasible for projections to leverage color, such that `html-div` vs. `math-div` both render as `div` but in different colors, or other graphical expression of meaning.

We can also project edit sessions that view and edit multiple words together. In simplest form, we might have `my-session = [foo][bar][baz]` so we can 'open' the session then edit those three words together.

Although our initial emphasis is plain text views, the eventual goal is to support richly interactive graphical views involving tables, graphs, canvases, checkboxes, sliders, drop-down menus, copyable forms, and so on. A sophisticated projectional editor could support frames or a zoomable interface where a word's definition may be logically inlined/opened into the current view.

### Named Local Variables

We can leverage editable views to model named local variables, like lambdas or let expressions. For example, consider adapting Kitten programming language's syntax for local vars:

        7 -> X; EXPR            let-in equivalent
        [-> X; EXPR]            lambda equivalent

We can extract `X` from our expression by simple algorithm:

        EXPR == X T(X,EXPR) for value X

        T(X,E) | E does not contain X       => d E
        T(X,X)                              =>
        T(X,[E])                            => [T(X,E)] b
        T(X,F G)                            
            | only F contains X             => T(X,F) G
            | only G contains X             => [F] a T(X,G)
            | F and G contain X             => c [T(X,F)] a T(X,G)

For performance, we can optimize static conditionals to avoid copying:

        T(X,[F][T]if) => [T(X,F)][T(X,T)]if

It makes sense to record variable names as comments - that's how we use them.

        -> X; EXPR
            becomes
        "lambda X"(a2)d T(X,EXPR)

Named local variables offer a useful proof-of-concept for *Editable Views* as a viable alternative to built-in syntax extensions. But, in most cases, language extensions are more easily expressed as views of intermediate data structures, which may be statically processed.

## Arrays

Awelon doesn't have an array data type. But use annotations and accelerators could impose an array representation for some lists, such that we can access data in near-constant time. In context of a purely functional language, *modifying* an array is naively O(N) - copy the array with the small modification in place. However, if we hold the only reference to an array's representation, the runtime could simply modify the representation in-place without violating observable purity.

Awelon's explicit copy and drop on a stack makes it easy for a runtime to track dynamically whether it holds a unique reference to a representation, at least compared to to variable environment models used in lambda calculus. Copy-on-write could be performed as needed, so developers need only to ensure arrays are rarely copied between updates. Static analysis could often remove dynamic checks within tight update loops.

*Note:* Persistent data structures (finger-trees, int-maps, ropes, etc.) are still very useful - more flexible than arrays in their application, more scalable due to potential use of *Stowage* for deep structure, etc.. These data structures may benefit from use of small array fragments for tree fanout or leaf values.

## Labeled Data

Labeled data is weakly commutative, human meaningful, and extensible compared to spatially structured data such as `(A*B)` pairs and `(A+B)` sums. Most programming languages support for labeled products and sums (aka records and variants). Awelon does not have built-in support, but it's still feasible to leverage sorted association lists to model records, and we can encode variants as functions that select a labeled handler from a record.

This design benefits from appropriate annotations and accelerators. Records can be given specialized representation and operators in the runtime, specialized types for static analysis. Similarly, projectional editors can provide convenient views for construction and manipulation of labeled data. But the details haven't been worked out.

## Generic Programming in Awelon

A weakness of Awelon is lack of built-in support for generic programming. For example, we cannot implicitly overload an `add` word to use different functions for different types, such as natural numbers versus matrices. We can use explicit overloads, but such mechanisms are often syntactically awkward and difficult to integrate with type systems. Deferred typing and projectional editing should help, but we still require a model with concrete constructors and predictable behavior to project above.

My intuition is to generalize generic programming as a constraint or search problem. For example, the choice of which `add` function to use is based on constraints in future input and result types, which may be provided later. It seems feasible to develop a monad with an implicit environment of constraints, then evaluate a monad to a program result at compile-time, i.e. staged metaprogramming. But I have not verified this intuition in practice.

