# SimpleParser

This is a parser for Julia that tries to strike a balance between being both
(moderately) efficient and simple (for the end-user and the maintainer).  It
is similar to parser combinator libraries in other languages (eg Haskell's
Parsec).

**EXAMPLES HERE**

This is still under development, but to give some idea..

```
julia> using SimpleParser

julia> parse_one("abcd", (s"a" + (p"."[0:2] > string)) > tuple).value
("a","bc")
```

Maybe that seems a little unsexy, but it shows:

* a literal matcher, `s"a"`

* regexp matcher, `p"."`

* greedy repetition, `[0:2]`

* calling a function on results:

  * joining matched characters to a string `> string`

  * joining matches to a tuple `> tuple`

For large parsing tasks (eg parsing source code for a compiler) it would
probably be better to use a wrapper around an external parser generator, like
Anltr.

## Design

### Overview

Julia does not support tail call recursion, and is not lazy, so a naive
combinator library would be limited by recursion depth and poor efficiency.
Instead, the "combinators" in SimpleParser construct a tree that describes the
grammar, and which is "interpreted" during parsing, by dispatching functions
on the tree nodes.  The traversal over the tree (effectvely a depth first
search) is implemented via trampolining, with an optional (adjustable) cache
to avoid repeated evaluation (and, possibly, in the future, detect
left-recursive grammars).

The advantages of this approch are:

  * Recursion is avoided

  * Caching can be isolated to within the trampoline

  * Method dispatch on node types leads to idiomatic Julia code (well,
    as idiomatic as possble, for what is a glorified state machine).

It would also have been possible to use Julia tasks (coroutines).  I avoided
this approach because my understanding is (although I have no proof) that
tasks are significantly "heavier".

### Matcher Protocol

Consider the matchers `Parent` and `Child` which might be used in some way to
parse "hello world":

```
immutable Child<:Matcher
  text
end

immutable Parent<:Matcher
  child1::Child
  child2::Child  
end

# this is a very vague example, don't think too hard about what it means
hello = Child("hello")
world = Child("world")
hello_world_grammar = Parent(hello, world)
```

In addition, typically, each matcher has some associated types that store
state (the matchers themselves describe only the *static* grammar; the state
describes the associated state during matching and backtracking).  Two states,
`CLEAN` and `DIRTY`, are used globally to indicate that a matcher is uncalled,
or has exhausted all matches, respectively.

Methods are then associated with combinations of matchers and state.
Transitions between these methods implement a state machine.

These transitions are triggered via `Message` types.  A method associated with
a matcher (and state) can return one of the messages and the trampoline will
call the corresponding code for the target.

So, for example:

```
function execute(p::Parent, s::ParentState, iter, source)
  # the parent wants to match the source text at offset iter against child1
  Execute(p, s, p.child1, ChildStateStart(), iter)
end

function execute(c::Child, s::ChildStateStart, iter, source)
  # the above will call here, where we check if the text matches
  if compare(c.text, source[iter:])
    Response(c, ChildStateSucceeded(), iter, Value(c.text))
  else
    Response(c, ChildStateFailed(), iter, FAIL)
  end
end

function response(p::Parent, s::ParentState, c::Child, cs::ChildState, iter, source, result::Value)
  # the message containing a Value above triggers a call here, where we do 
  # something with the result (like save it in the ParentState)
  ...
  # and then perhaps evaluate child2...
  Execute(p, s, p.child2, ChildStateStart(), iter)
end
```

Finally, to simplify caching in the trampoline, it is important that the
different matchers appear as simple calls and responses.  So internal
transitions between states in the same matcher are *not* made by messages, but
by direct calls.  This explains why, for example, you see both `Execute(...)`
and `execute(...)` in the source - the latter is an internal transition to the
given method.

### Source (Input Text) Protocol

The source text is read using the [standard Julia iterator
protocol](http://julia.readthedocs.org/en/latest/stdlib/collections/?highlight=iterator).

This has the unfortunate result that Dot() returns characters, not strings.
But in practice that matcher is rarely used.

[![Build
Status](https://travis-ci.org/andrewcooke/SimpleParser.jl.png)](https://travis-ci.org/andrewcooke/SimpleParser.jl)
Julia 0.3 and 0.4 (trunk).
