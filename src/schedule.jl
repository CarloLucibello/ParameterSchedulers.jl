"""
    AbstractSchedule

All schedules should inherit from this type or its subtypes.
Concrete subtypes are expected to conform to the
[iteration interface](https://docs.julialang.org/en/v1/manual/interfaces/#man-interface-iteration)
and implement [`Base.getindex`](https://docs.julialang.org/en/v1/manual/interfaces/#Indexing).
"""
abstract type AbstractSchedule end

Base.firstindex(schedule::AbstractSchedule) = 1

"""
    ScheduleIterator{T<:AbstractSchedule, S}
    ScheduleIterator(schedule::T)

Create a stateful iterator around `schedule`.
See also [`next!`](#)
"""
mutable struct ScheduleIterator{T<:AbstractSchedule, S}
    schedule::T
    state::Union{S, Nothing}
end
function ScheduleIterator(schedule::T) where T<:AbstractSchedule
    _, state = iterate(schedule)
    
    ScheduleIterator{T, typeof(state)}(schedule, nothing)
end

"""
    next!(iter::ScheduleIterator)

Advance `iter` by one iteration and return the next value.
See also [`ScheduleIterator`](#)
"""
function next!(iter::ScheduleIterator)
    val, iter.state = isnothing(iter.state) ? iterate(iter.schedule) : iterate(iter.schedule, iter.state)

    return val
end
    
"""
    DecaySchedule <: AbstractSchedule

An abstract type for all decay schedules.
Such schedules conform to a formula:
```
s(t) = λ * g(t)
```
where `s(t)` is the schedule output, `λ` is the base value, and `g(t)` is the decay function.
Concrete subtypes must implment [`basevalue`](#) and [`decay`](#).
"""
abstract type DecaySchedule <: AbstractSchedule end

# decay interface
"""
    basevalue(s::T) where T<:DecaySchedule

Concrete subtypes of [`DecaySchedule`](#) must implement this function for `T`.
Given `s`, the function should return the base value of `s`.
"""
function basevalue end
"""
    decay(s::T, t) where T<:DecaySchedule

Concrete subtypes of [`DecaySchedule`](#) must implement this function for `T`.
Given `s`, `decay(s, t)` should return the value of the decay function at iteration `t`.
"""
function decay end

Base.getindex(schedule::DecaySchedule, t::Integer) = basevalue(schedule) * decay(schedule, t)

Base.iterate(schedule::DecaySchedule, t = 1) = (schedule[t], t + 1)

"""
    CyclicSchedule <: AbstractSchedule

An abstract type for all cyclic schedules.
Such schedules conform to a formula:
```
s(t) = abs(λ0 - λ1) * g(t) + min(λ0, λ1)
```
where `s(t)` is the schedule output, `λ0` is the start value,
`λ1` is the end value, and `g(t)` is the cycle function.
Concrete subtypes must implment [`startvalue`](#), [`endvalue`](#) and [`cycle`](#).
"""
abstract type CyclicSchedule <: AbstractSchedule end

# cyclic interface
"""
    startvalue(s::T) where T<:CyclicSchedule

Concrete subtypes of [`CyclicSchedule`](#) must implement this function for `T`.
Given `s`, the function should return the start value of `s`.
"""
function startvalue end
"""
    endvalue(s::T) where T<:CyclicSchedule

Concrete subtypes of [`CyclicSchedule`](#) must implement this function for `T`.
Given `s`, the function should return the end value of `s`.
"""
function endvalue end
"""
    cycle(s::T, t) where T<:CyclicSchedule

Concrete subtypes of [`CyclicSchedule`](#) must implement this function for `T`.
Given `s`, `cycle(s, t)` should return the value of the cycle function at iteration `t`.
"""
function cycle end

function Base.getindex(schedule::CyclicSchedule, t::Integer)
    k0, k1 = startvalue(schedule), endvalue(schedule)
    
    return abs(k0 - k1) * cycle(schedule, t) + min(k0, k1)
end

Base.iterate(schedule::CyclicSchedule, t = 1) = (schedule[t], t + 1)

"""
    Lambda{T} <: AbstractSchedule
    Lambda(;f)

Wrap an arbitrary function `f` into a schedule.
The schedule output at iteration `t` is `f(t)`.
"""
struct Lambda{T} <: AbstractSchedule
    f::T
end
Lambda(;f) = Lambda(f)

Base.getindex(schedule::Lambda, t) = schedule.f(t)

Base.iterate(schedule::Lambda, t = 1) = (schedule[t], t + 1)
Base.IteratorEltype(::Type{<:Lambda}) = Base.EltypeUnknown()
Base.IteratorSize(::Type{<:Lambda}) = Base.SizeUnkown()

"""
    reverse(f, period)

Return a reverse function such that `reverse(f, period)(t) == f(period - t)`.
"""
reverse(f, period) = t -> f(period - t)
"""
    symmetric(f, period)

Return a symmetric function such that for `t ∈ [1, period / 2)`,
the symmetric function evaluates to `f(t)`, and when `t ∈ [period / 2, period)`,
the symmetric functions evaluates to `f(period - t)`.
"""
symmetric(f, period) = t -> (t < period / 2) ? f(t) : f(period - t)


at(x::Number, t) = x
at(x::AbstractSchedule, t) = x[t]

"""
    Sequence{T<:AbstractVector, S<:Integer} <: AbstractSchedule
    Sequence(;schedules, step_sizes)

A sequence of schedules.
The output of this schedule is the concatenation of `schedules` where each
schedule is evaluated for each step size in `step_sizes`.

Note that `schedules` can also be a vector of numbers (not just schedules).

# Arguments
- `schedules::AbstractVector`: a vector of schedules or numbers
- `step_sizes::Vector{<:Integer}`: a vector of iteration lengths for each schedule
"""
struct Sequence{T<:AbstractVector, S<:Integer} <: AbstractSchedule
    schedules::T
    step_sizes::Vector{S}
end
Sequence(;schedules, step_sizes) = Sequence(schedules, step_sizes)

function Base.getindex(schedule::Sequence, t::Integer)
    accum_steps = cumsum(schedule.step_sizes)
    i = findlast(x -> t > x, accum_steps)
    i = isnothing(i) ? 1 :
            (i >= length(schedule.schedules)) ? length(schedule.schedules) : i + 1
    toffset = (i > 1) ? t - accum_steps[i - 1] : t
    
    return at(schedule.schedules[i], toffset)
end
function Base.iterate(schedule::Sequence, state = (1, 1, 1))
    t, i, t0 = state
    if (i <= length(schedule.step_sizes)) && (t >= t0 + schedule.step_sizes[i])
        # move onto next step range
        i += 1
        t0 = t
    end

    return at(schedule.schedules[i], t - t0 + 1), (t + 1, i, t0)
end
Base.IteratorSize(::Type{<:Sequence}) = Base.SizeUnknown()


"""
    Loop{T<:AbstractSchedule, S<:Integer} <: AbstractSchedule
    Loop(;f, period)

Create a schedule that loops `f` every `period` iterations.
Note that `f` must be a subtype of [`AbstractSchedule`](#).
To loop arbitrary functions, wrap them in [`Lambda`](#).

# Arguments
- `f::AbstractSchedule`: the schedule to loop
- `period::Integer`: how often to loop
"""
struct Loop{T<:AbstractSchedule, S<:Integer} <: AbstractSchedule
    cycle_func::T
    period::S
end
Loop(;f, period) = Loop(f, period)

Base.getindex(schedule::Loop, t) = schedule.cycle_func[mod1(t, schedule.period)]

Base.iterate(schedule::Loop, t = 1) = (schedule[t], t + 1)

Base.eltype(::Type{<:Loop{T}}) where T<:Union{<:DecaySchedule, <:CyclicSchedule} = eltype(T)
Base.IteratorSize(::Type{<:Loop}) = Base.IsInfinite()