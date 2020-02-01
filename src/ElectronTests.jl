module ElectronTests

using Electron, JSServe, URIParser
using JSServe.HTTP: Request
using JSServe: Session, JSObject, jsobject, Dependency, @js_str, JSCode
import JSServe: start, evaljs
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
    initialized::Bool
    error_in_handler::Any
    server::JSServe.Application
    window::Electron.Window
    session::Session
    dom::Node{HTMLSVG}
    request::Request
    # Library to run test commands
    js_library::JSObject

    function TestSession(url::URI)
        return new(url, false, nothing)
    end

    function TestSession(url::URI, server::JSServe.Application, window::Electron.Window, session::Session)
        testsession = new(url, true, nothing, server, window, session)
        testsession.js_library = jsobject(session, js"$JSTest")
        return testsession
    end
end

function check_and_close_display()
    # For some reason, when running code in Atom, it happens very easily,
    # That JSServe display server gets started!
    # Maybe better to PR an option in JSServe to prohibit starting it in the first place
    if isassigned(JSServe.global_application) && JSServe.isrunning(JSServe.global_application[])
        @warn "closing JSServe display server, which interfers with testing!"
        close(JSServe.global_application[])
    end
end

function TestSession(handler; url="0.0.0.0", port=8081, timeout=10)
    check_and_close_display()
    testsession = TestSession(URI(string("http://localhost:", port)))
    testsession.server = JSServe.Application(url, port) do session, request
        try
            dom = handler(session, request)
            testsession.dom = dom
            testsession.session = session
            testsession.request = request
            return DOM.div(JSTest, dom)
        catch e
            testsession.error_in_handler = (e, Base.catch_backtrace())
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
    while testsession.window.exists
        # We done!
        isopen(testsession.session) && break
        if testsession.error_in_handler !== nothing
            e, backtrace = testsession.error_in_handler
            Base.show_backtrace(stderr, backtrace)
            throw(e)
        end
        # Again, we need to sleep instead of just waiting on `take!`
        # But if we don't do this, on an error in serving, we'd wait indefinitely
        # even if the window gets closed...And since Julia can't deal with interrupting
        # Wait, that'd mean killing Julia completely
        sleep(0.01)
    end
    if !isopen(testsession.session)
        error("Window closed before getting a message from serving request")
    end
    tstart = time()
    on_timeout = "Timed out when waiting for JS to being loaded! Likely an error happend on the JS side, or your testsession is taking longer than $(timeout) seconds. If no error in console, try increasing timeout!"
    JSServe.wait_timeout(()->isready(testsession.session.js_fully_loaded), on_timeout, timeout)
    testsession.initialized = true
    return true
end

"""
    reload!(testsession::TestSession)

Reloads the served application and waits untill all state is initialized.
"""
function reload!(testsession::TestSession)
    check_and_close_display()
    testsession.initialized = true # we need to put it to true, otherwise handler will block!
    # Make 100% sure we're serving something,
    # since otherwise, well block forever
    @assert JSServe.isrunning(testsession.server)
    response = JSServe.HTTP.get(string(testsession.url), readtimeout=3, retries=1)
    @assert response.status == 200
    testsession.initialized = false
    testsession.error_in_handler = nothing
    Electron.load(testsession.window, testsession.url)
    wait(testsession)
    @assert testsession.initialized
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
    check_and_close_display()
    try
        if !JSServe.isrunning(testsession.server)
            start(testsession.server)
        end
        if !isdefined(testsession, :window) || !testsession.window.exists
            app = Electron.Application()
            testsession.window = Window(app)
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
        Base.showerror(stderr, e)
        # TODO why does this error on travis? Possibly linux in general
    end
    try
        # First request after close will still go through
        # see: https://github.com/JuliaWeb/HTTP.jl/pull/494
        JSServe.HTTP.get(string(testsession.url))
    catch e
        if e isa JSServe.HTTP.IOError && e.e isa Base.IOError
            # Huh, so this actually did close things correctly
        else
            rethrow(e)
        end
    finally
        if isdefined(testsession, :window)
            close(testsession.window.app)
            testsession.window.exists && close(testsession.window)
        end
    end
end

"""
    evaljs(testsession::TestSession, js::JSCode)
Runs javascript code `js` in testsession.
Will return the return value of `js`. Might return garbage data, if return value
isn't json serializable.

Example:
```julia
evaljs(testsession, js"document.getElementById('the-id')")
```
"""
function evaljs(testsession::TestSession, js::Union{JSCode, JSObject})
    JSServe.evaljs_value(testsession.session, js)
end

function evaljs(testsession::TestSession, js::JSCode)
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

function JSServe.jsobject(testsession::TestSession, js)
    return jsobject(testsession.session, js)
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
    testsession.js_library.trigger_mouse_move(position, element)
end

"""
    query_testid(id::String)
Returns a js string, that queries for `id`.
"""
function query_testid(id::String)
    js"document.querySelector('[data-test-id=$(id)]')"
end

"""
    query_testid(testsession::TestSession, id::String)
Returns a JSObject representing the object found for `id`.
"""
function query_testid(testsession::TestSession, id::String)
    return jsobject(testsession, query_testid(id))
end

export @wait_for, evaljs, testsession, trigger_keyboard_press, trigger_mouse_move, query_testid

end # module
