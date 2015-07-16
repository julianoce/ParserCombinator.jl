

# this reproduces parsec's behaviour, by disallowing matched input to be
# used again.  to do this we need to:
# 1 - provide a source that allows input to be discarded
# 2 - discard input on success
# 3 - disable discarding input when inside Try()
# 4 - throw an exception when discarded input is accessed
# 5 - treat that exception as failure

# the source wraps an IO instance.  this is how julia manages files
# (which is presumably where this is needed most, since strings are
# already available in memory).  but strings can also be wrapped.


type ExpiredContent<:Exception end

type TrySource
    io::IO
    frozen::Int    # non-zero is frozen; count allows nested Try()
    zero::Int      # offset to lines (lines[x] contains line x+zero)
    right::Int     # rightmost expired column
    lines::Array{AbstractString,1}
    TrySource(io::IO) = new(io, 0, 0, 0, AbstractString[])
end
TrySource(s::AbstractString) = TrySource(IOBuffer(s))

@auto_hash_equals immutable TryIter
    line::Int
    col::Int
end

isless(a::TryIter, b::TryIter) = a.line < b.line || (a.line == b.line && a.col < b.col)

immutable TryRange
    start::TryIter
    stop::TryIter
end

END_COL = typemax(Int)
FLOAT_LINE = -1
FLOAT_END = TryIter(FLOAT_LINE, END_COL)


function expire(s::TrySource, i::TryIter)
#    println("expire $i $(s.zero) $(s.right)")
    if s.frozen == 0
        n = i.line - s.zero
        if n > 0
            s.lines = s.lines[n:end]
            s.zero += (n-1)
            if n > 1 || i.col > s.right
                s.right = i.col
            end
        end
    end
end

function line_at(f::TrySource, s::TryIter; check=true)
    if check
        if s.line <= f.zero || (s.line == f.zero+1 && s.col < f.right)
            throw(ExpiredContent())
        end
    end
    n = s.line - f.zero
    while length(f.lines) < n
        push!(f.lines, readline(f.io))
    end
    f.lines[n]
end

unify_line(a::TryIter, b::TryIter) = b.line == FLOAT_LINE ? TryIter(a.line, b.col) : b
unify_col(line::AbstractString, b::TryIter) = b.col == END_COL ? TryIter(b.line, endof(line)) : b

start(f::TrySource) = TryIter(1, 1)
endof(f::TrySource) = FLOAT_END

colon(a::TryIter, b::TryIter) = TryRange(a, b)

# very restricted - just enough to support iter[i:end] as current line
# for regexps.  step is ignored,
function getindex(f::TrySource, r::TryRange)
    start = r.start
    line = line_at(f, start)
    stop = unify_col(line, unify_line(start, r.stop))
    if start.line != stop.line
        error("Can only index a range within a line ($(start.line), $(stop.line))")
    else
        return line[start.col:stop.col]
    end
end

function next(f::TrySource, s::TryIter)
    # there's a subtlelty here.  the line is always correct for
    # reading more data (the check on done() comes *after* next).
    # this is so that getindex can access the line correctly if needed
    # (if we didn't have the line correct, getindex would take a slice
    # from the end of the previous line).
    line = line_at(f, s)
    c, col = next(line, s.col)
    if done(line, col)
        c, TryIter(s.line+1, 1)
    else
        c, TryIter(s.line, col)
    end
end

function done(f::TrySource, s::TryIter)
    line = line_at(f, s; check=false)
    done(line, s.col) && eof(f.io)
end


# and now the Config(s)

abstract TryConfig<:Config


# as NoCache, but treat ExpiredContent exceptions as failures

type TryNoCache<:TryConfig
    source::TrySource
    @compat stack::Array{Tuple{Matcher,State},1}
    @compat TryNoCache(source::TrySource) = new(source, Array(Tuple{Matcher,State}, 0))
end

function dispatch(k::TryNoCache, e::Execute)
    push!(k.stack, (e.parent, e.parent_state))
    try
        execute(k, e.child, e.child_state, e.iter)
    catch err
        if isa(err, ExpiredContent)
            FAILURE
        else
            rethrow()
        end
    end
end

function dispatch(k::TryNoCache, s::Success)
    parent, parent_state = pop!(k.stack)
    expire(k.source, s.iter)
    try
        success(k, parent, parent_state, s.child_state, s.iter, s.result)
    catch err
        if isa(err, ExpiredContent)
            FAILURE
        else
            rethrow()
        end
    end
end

function dispatch(k::TryNoCache, f::Failure)
    parent, parent_state = pop!(k.stack)
    try
        failure(k, parent, parent_state)
    catch err
        if isa(err, ExpiredContent)
            FAILURE
        else
            rethrow()
        end
    end
end


# ditto, but with cache too (Key from Cache in parsers.jl)
# (we really need mixins or multiple inheritance here...)

type TryCache<:TryConfig
    source::TrySource
    @compat stack::Array{Tuple{Matcher,State,Key},1}
    cache::Dict{Key,Message}
    @compat TryCache(source::TrySource) = new(source, Array(Tuple{Matcher,State,Key}, 0), Dict{Key,Message}())
end

function dispatch(k::TryCache, e::Execute)
    key = (e.child, e.child_state, e.iter)
    push!(k.stack, (e.parent, e.parent_state, key))
    if haskey(k.cache, key)
        k.cache[key]
    else
        try
            execute(k, e.child, e.child_state, e.iter)
        catch err
            if isa(err, ExpiredContent)
                FAILURE
            else
                rethrow()
            end
        end
    end
end

function dispatch(k::TryCache, s::Success)
    parent, parent_state, key = pop!(k.stack)
    expire(k.source, s.iter)
    k.cache[key] = s
    try
        success(k, parent, parent_state, s.child_state, s.iter, s.result)
    catch err
        if isa(err, ExpiredContent)
            FAILURE
        else
            rethrow()
        end
    end
end

function dispatch(k::TryCache, f::Failure)
    parent, parent_state, key = pop!(k.stack)
    k.cache[key] = f
    try
        failure(k, parent, parent_state)
    catch err
        if isa(err, ExpiredContent)
            FAILURE
        else
            rethrow()
        end
    end
end


# the Try() matcher that enables backtracking

@auto_hash_equals type Try<:Delegate
    name::Symbol
    matcher::Matcher
    Try(matcher) = new(:Try, matcher)
end

@auto_hash_equals immutable TryState<:DelegateState
    state::State
end

execute(k::Config, m::Try, s::Clean, i) = error("use Try only with TryNoCache / parse_try")

execute(k::TryConfig, m::Try, s::Clean, i) = execute(k, m, TryState(CLEAN), i)

function execute(k::TryConfig, m::Try, s::TryState, i)
    k.source.frozen += 1
    Execute(m, s, m.matcher, s.state, i)
end

function success(k::TryConfig, m::Try, s::TryState, t, i, r::Value)
    k.source.frozen -= 1
    Success(TryState(t), i, r)
end

function failure(k::TryConfig, m::Try, s::TryState)
    k.source.frozen -= 1
    FAILURE
end


parse_try = make_one(TryCache)
parse_try_dbg = make_one(Debug; delegate=TryCache)
parse_try_nocache = make_one(TryNoCache)
parse_try_nocache_dbg = make_one(Debug; delegate=TryNoCache)


# need to add some debug support for this iterator / source

function src(s::TrySource, i::TryIter; max=MAX_SRC)
    try
        pad(truncate(escape_string(s[i:end]), max), max)
    catch x
        if isa(x, ExpiredContent)
            pad(truncate("[expired]", max), max)
        else
            rethrow()
        end
    end
end
   
function debug{S<:TrySource}(k::Debug{S}, e::Execute)
    @printf("%3d,%-3d:%s %02d %s%s->%s\n",
            e.iter.line, e.iter.col, src(k.source, e.iter), k.depth[end], indent(k), e.parent.name, e.child.name)
end

function debug{S<:TrySource}(k::Debug{S}, s::Success)
    @printf("%3d,%-3d:%s %02d %s%s<-%s\n",
            s.iter.line, s.iter.col, src(k.source, s.iter), k.depth[end], indent(k), parent(k).name, short(s.result))
end

function debug{S<:TrySource}(k::Debug{S}, f::Failure)
    @printf("       :%s %02d %s%s<-!!!\n",
            pad(" ", MAX_SRC), k.depth[end], indent(k), parent(k).name)
end


# this is general, but usually not much use with backtracking

type ParserError{I}<:Exception
    msg::AbstractString
    iter::I
end

@auto_hash_equals immutable Error<:Matcher
    name::Symbol
    msg::AbstractString
    Error(msg::AbstractString) = new(:Error, msg)
end

execute{I}(k::Config, m::Error, s::Clean, i::I) = throw(ParserError{I}(m.msg, i))


