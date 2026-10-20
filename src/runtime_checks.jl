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
    registered_checking_enabled()

`false` while the registered DispatchDoctor is loaded and its own `allow_unstable`
runs, else `true`. Code written against the registered package, such as a
package's tests, pauses checks with its `allow_unstable`; as this fork is a
separate package, its checks would otherwise not notice.

The registered package is looked up in `Base.loaded_modules` at call time, which
the generated code only reaches once a return type was found to be unstable. This
never throws, and returns `true` (leaving it to this fork's own flag) when the
registered package is not loaded, when its internals differ from those of 0.4.x,
and when another task holds `Base.require_lock` (it does not wait for that task,
as the task may be loading a package whose `__init__` waits for this one).
"""
@noinline function registered_checking_enabled()
    try
        trylock(Base.require_lock) || return true
        registered = try
            get(Base.loaded_modules, REGISTERED_DISPATCHDOCTOR, nothing)
        finally
            unlock(Base.require_lock)
        end
        registered isa Module || return true
        # (In the latest world, as the package may have been loaded after the caller.)
        checks = Base.invokelatest(getglobal, registered, :_RuntimeChecks)
        flag = Base.invokelatest(getglobal, checks, :INSTABILITY_CHECK_ENABLED).value
        return flag isa Base.RefValue{Bool} ? flag[] : true
    catch
        return true
    end
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
