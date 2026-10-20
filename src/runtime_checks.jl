"""This module contains functions for modifying stabilized-functions at runtime"""
module _RuntimeChecks

using .._Errors: AllowUnstableDataRace

"""To avoid errors and warnings during precompilation."""
@inline is_precompiling() = ccall(:jl_generating_output, Cint, ()) == 1

"""
To locally enable/disable instability checks. Checks are also paused while the
`allow_unstable` of the registered DispatchDoctor runs (see
`registered_checking_enabled`).
"""
@inline function checking_enabled()
    return !is_precompiling() &&
           INSTABILITY_CHECK_ENABLED.value[] &&
           registered_checking_enabled()
end

const INSTABILITY_CHECK_ENABLED = (; value=Ref(true), lock=ReentrantLock())

"""The registered DispatchDoctor, which this fork (with its own UUID) is loaded next to."""
const REGISTERED_DISPATCHDOCTOR = Base.PkgId(
    Base.UUID("8d63f2c5-f18a-4cf2-ba9d-b3f60fc568c8"), "DispatchDoctor"
)

"""
The flag of the registered DispatchDoctor's `allow_unstable`, once that package is
loaded (see `registered_checking_enabled`), else `nothing`.
"""
const REGISTERED_FLAG = Ref{Union{Nothing,Base.RefValue{Bool}}}(nothing)

"""
    registered_checking_enabled()

`false` while the registered DispatchDoctor is loaded and its own `allow_unstable`
runs, else `true`. Code written against the registered package, such as a
package's tests, pauses checks with its `allow_unstable`; as this fork is a
separate package, its checks would otherwise not notice.

It reads the registered package's flag, which `capture_registered_flag` keeps in
`REGISTERED_FLAG` when that package loads, so it takes no lock and looks nothing
up: any number of threads can run checked code inside one `allow_unstable` of the
registered package. It never throws, and returns `true` (leaving it to this fork's
own flag) when no flag was captured.
"""
@noinline function registered_checking_enabled()
    flag = REGISTERED_FLAG[]
    return flag === nothing || flag[]
end

"""
    capture_registered_flag(pkg::Base.PkgId)

When `pkg` is the registered DispatchDoctor and it is loaded, keep the flag of its
`allow_unstable` in `REGISTERED_FLAG`. It runs from `__init__` (if that package was
loaded first) and from `Base.package_callbacks` (when it loads later). It never
throws, and leaves `REGISTERED_FLAG` as it was when the package is not loaded or
when its internals differ from those of 0.4.x.
"""
function capture_registered_flag(pkg::Base.PkgId)
    pkg == REGISTERED_DISPATCHDOCTOR || return nothing
    try
        registered = @lock Base.require_lock get(Base.loaded_modules, pkg, nothing)
        registered isa Module || return nothing
        # (In the latest world, as the package was loaded after this one's code.)
        checks = Base.invokelatest(getglobal, registered, :_RuntimeChecks)
        flag = Base.invokelatest(getglobal, checks, :INSTABILITY_CHECK_ENABLED).value
        flag isa Base.RefValue{Bool} && (REGISTERED_FLAG[] = flag)
    catch
    end
    return nothing
end

# Capture the registered DispatchDoctor's flag when it loads, or now if it is loaded.
function __init__()
    push!(Base.package_callbacks, capture_registered_flag)
    capture_registered_flag(REGISTERED_DISPATCHDOCTOR)
    return nothing
end

"""
Whether type inference runs for code in module `m`. It does not after
`Base.Experimental.@compiler_options infer=false` (as in JLL packages),
in which case every function in `m` would be inferred to be `Any`.
"""
@inline inference_enabled(m::Module) = ccall(:jl_get_module_infer, Cint, (Any,), m) != 0

"""
    allow_unstable(f::F) where {F<:Function}

Globally disable type DispatchDoctor instability checks within the provided function `f`.

This function allows you to execute a block of code where type instability
checks are disabled. It ensures that the checks are re-enabled after the block
is executed, even if an error occurs.

This function uses a `ReentrantLock` and will throw an error if used from
two tasks at once.

# Usage

```
allow_unstable() do
    # do unstable stuff
end
```

# Arguments

- `f::F`: A function to be executed with type instability checks disabled.

# Returns

- The result of the function `f`.

# Notes

You cannot call `allow_unstable` from two tasks at once. An error
will be thrown if you try to do so.
"""
@inline function allow_unstable(f::F) where {F<:Function}
    successful_lock = trylock(INSTABILITY_CHECK_ENABLED.lock)
    if !successful_lock
        throw(
            AllowUnstableDataRace(
                "You cannot call `allow_unstable` from two tasks at once. " *
                "This error is a result of `INSTABILITY_CHECK_ENABLED` " *
                "being locked by another task.",
            ),
        )
    end
    old_value = INSTABILITY_CHECK_ENABLED.value[]
    INSTABILITY_CHECK_ENABLED.value[] = false
    out = try
        f()
    finally
        INSTABILITY_CHECK_ENABLED.value[] = old_value
        unlock(INSTABILITY_CHECK_ENABLED.lock)
    end
    return out
end

end
