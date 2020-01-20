module ElectronTests

using Electron, JSServe, URIParser
using JSServe.HTTP: Request
using JSServe: Session, JSObject, jsobject, Dependency, @js_str, JSCode
import JSServe: start
using JSServe.Hyperscript: Node, HTMLSVG
using JSServe.DOM
using Base: RefValue
using Test

"""
Our Javascript library, defining a few JS helper functions!
"""
const JSTest = Dependency(:Test, [joinpath(@__DIR__, "Test.js")])

"""
    TestSession(handler)

Main construct, which will lunch an electron browser session, serving the application
created by `handler(testsession)::DOM.div`.
Can be used via the testsession function:
```julia
testsession(handler; url="0.0.0.0", port=8081, timeout=10)) do testsession
    # test code using testsession
end
```
This will ensure proper setup and teardown once done with the tests.
The testsession object allows to communicate with the browser session, run javascript
and get values from the html dom!
"""
mutable struct TestSession
    url::URI
    serve_comm::Channel{Any}
    initialized::Bool
    server::JSServe.Application
    application::Electron.Application
    window::Electron.Window
    dom::Node{HTMLSVG}
    session::Session
    request::Request
    # Library to run test commands
    js_library::JSObject
    function TestSession(url::URI)
        return new(url, Channel(1), false)
    end
end

function TestSession(handler; url="0.0.0.0", port=8081, timeout=10)
    testsession = TestSession(URI(string("http://localhost:", port)))
    testsession.server = JSServe.Application(url, port) do session, request
        try
            dom = handler(session, request)
            testsession.dom = dom
            testsession.session = session
            # testsession.request = request
            # Add our testing js library
            put!(testsession.serve_comm, :done)
            return DOM.div(JSTest, dom)
        catch e
            put!(testsession.serve_comm, e)
        end
    end
    try
        start(testsession)
        return testsession
    catch e
        close(testsession)
        rethrow(e)
    end
end

"""
```julia
    testsession(f, handler; url="0.0.0.0", port=8081, timeout=10)

testsession(handler; url="0.0.0.0", port=8081, timeout=10)) do testsession
    # test code using testsession
end
```
This function will ensure proper setup and teardown once done with the tests or whenever an error occurs.
The testsession object passed to `f` allows to communicate with the browser session, run javascript
and get values from the html dom!
"""
function testsession(f, handler; kw...)
    testsession = TestSession(handler; kw...)
    try
        f(testsession)
    catch e
        rethrow(e)
    finally
        close(testsession)
    end
end


"""
    wait(testsession::TestSession; timeout=10)

Wait for testsession to be fully loaded!
Note, if you call wait on a fully loaded test
"""
function wait(testsession::TestSession; timeout=10)
    testsession.initialized && return true
    if !testsession.window.exists
        error("Window isn't open, can't wait for testsession to be initialized")
    end
    answer = take!(testsession.serve_comm)
    if answer !== :done
        close(testsession)
        # we encountered an error while serving test testsession
        throw(answer)
    end
    tstart = time()
    while true
        if time() - tstart > timeout
            error("Timed out when waiting for JS to being loaded! Likely an error happend on the JS side, or your testsession is taking longer than $(timeout) seconds. If no error in console, try increasing timeout!")
        end
        # Session must be loaded because we wait in take! untill we got served!
        # We don't use wait(js_fully_loaded), since we can't interrupt that.
        # Instead we wait for event.set to become true!
        testsession.session.js_fully_loaded.set && break
        sleep(0.001) # welp, now, because we can't use wait, we need to use sleep-.-
    end
    testsession.initialized = true
    return true
end



"""
    reload!(testsession::TestSession)

Reloads the served application and waits untill all state is initialized.
"""
function reload!(testsession::TestSession)
    Electron.load(testsession.window, testsession.url)
    testsession.initialized = false
    wait(testsession)
    # Now everything is loaded and setup! At this point, we can get references to JS
    # Objects in the browser!
    testsession.js_library = jsobject(testsession.session, js"$JSTest")
    return true
end

"""
    start(testsession::TestSession)

Start the testsession and make sure everything is loaded correctly.
Will close all connections, if any error occurs!
"""
function JSServe.start(testsession::TestSession)
    try
        if !JSServe.isrunning(testsession.server)
            start(testsession.server)
        end
        if !isdefined(testsession, :application)
            testsession.application = Electron.Application()
        end
        if !isdefined(testsession, :window) || !testsession.window.exists
            testsession.window = Window(testsession.application)
        end
        reload!(testsession)
    catch e
        close(testsession)
        rethrow(e)
    end
    return true
end

"""
    close(testsession::TestSession)

Close the testsession and clean up the state!
"""
function Base.close(testsession::TestSession)
    try
        if isdefined(testsession, :server)
            Electron.close(testsession.server)
            testsession.initialized = false
        end
    catch e
        # TODO why does this error on travis? Possibly linux in general
    end
    try
        # First request after close will still go through
        # see: https://github.com/JuliaWeb/HTTP.jl/pull/494
        JSServe.HTTP.get(string(testsession.url), readtimeout=3, retries=1)
    catch e
        if e isa JSServe.HTTP.IOError && e.e == Base.IOError("connect: connection refused (ECONNREFUSED)", -4078)
            # Huh, so this actually did close things correctly
        else
            rethrow(e)
        end
    finally
        if isdefined(testsession, :window) && testsession.window.exists
            close(testsession.window)
        end
    end
end

"""
    runjs(testsession::TestSession, js::JSCode)
Runs javascript code `js` in testsession.
Will return the return value of `js`. Might return garbage data, if return value
isn't json serializable.

Example:
```julia
runjs(testsession, js"document.getElementById('the-id')")
```
"""
function runjs(testsession::TestSession, js::JSCode)
    JSServe.evaljs_value(testsession.session, js)
end

"""
    wait_test(condition)
Waits for condition expression to become true and then tests it!
"""
macro wait_for(condition)
    return quote
        while !$(esc(condition))
            sleep(0.001)
        end
        @test $(esc(condition))
    end
end

"""
    trigger_keyboard_press(testsession::TestSession, code::String, element=nothing)
Triggers a keyboard press on `element`! If element is `nothing`, the event will be
triggered for the whole `document`!
Find out the key code string to pass at `http://keycode.info/`
"""
function trigger_keyboard_press(testsession::TestSession, code::String, element=nothing)
    testsession.js_library.trigger_keyboard_press(code, element)
end

"""
    trigger_mouse_move(testsession::TestSession, code::String, position::Tuple{Int, Int}, element=nothing)
Triggers a MouseMove event! If element == nothing, it will try to trigger on any canvas element
found in the DOM.
"""
function trigger_mouse_move(testsession::TestSession, position::Tuple{Int, Int}, element=nothing)
    testsession.js_library.trigger_mouse_move(code, position, element)
end

end # module
