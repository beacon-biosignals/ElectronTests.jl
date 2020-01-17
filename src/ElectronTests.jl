module ElectronTests

using Electron, JSServe, URIParser
using JSServe.HTTP: Request
using JSServe: Session, JSObject, jsobject, Dependency, @js_str
using JSServe.Hyperscript: Node, HTMLSVG
using Base: RefValue
using JSServe.DOM
using Test

const JSTest = Dependency(:Test, [joinpath(@__DIR__, "Test.js")])

mutable struct TestSession
    url::URI
    server::JSServe.Application
    application::Electron.Application
    window::Electron.Window
    dom::Node{HTMLSVG}
    session::Session
    request::Request
    # Library to run test commands
    testlib::JSObject
    function TestSession(url::URI)
        return new(url)
    end
end

function TestSession(handler; url="0.0.0.0", port=8081, timeout=10)
    testapp = TestSession(URI(string("http://localhost:", port)))
    serve_comm = Channel(1)
    testapp.server = JSServe.Application(url, port) do session, request
        try
            dom = handler(session, request)
            testapp.dom = dom
            testapp.session = session
            # testapp.request = request
            # Add our testing js library
            put!(serve_comm, :done)
            return DOM.div(JSTest, dom)
        catch e
            put!(serve_comm, e)
        end
    end

    try
        testapp.application = Electron.Application()
        testapp.window = Window(testapp.application, URI(testapp.url))
        answer = take!(serve_comm)
        if answer !== :done
            # we encountered an error while serving test app
            throw(answer)
        end
        tstart = time()
        while true
            if time() - tstart > timeout
                error("Timed out when waiting for JS to being loaded! Likely an error happend on the JS side, or your app is taking longer than $(timeout) seconds. If no error in console, try increasing timeout!")
            end
            # Session must be loaded because we wait in take! untill we got served!
            # We don't use wait(js_fully_loaded), since we can't interrupt that.
            # Instead we wait for event.set to become true!
            testapp.session.js_fully_loaded.set && break
            sleep(0.001) # welp, now, because we can't use wait, we need to use sleep-.-
        end
        # Now everything is loaded and setup! We can now get references to JS
        # Objects in the browser!
        testapp.testlib = jsobject(testapp.session, js"$JSTest")
        return testapp
    catch e
        close(testapp.server)
        rethrow(e)
    end
end


function testsession(f, handler; kw...)
    app = TestSession(handler; kw...)
    try
        f(app)
    catch e
        rethrow(e)
    finally
        close(app)
    end
end

function reload!(app::TestSession)
    Electron.load(app.window, app.url)
end

function Base.close(app::TestSession)
    try
        Electron.close(app.server)
    catch e
        # TODO why does this error on travis? Possibly linux in general
    end
    try
        # First request after close will still go through
        # see: https://github.com/JuliaWeb/HTTP.jl/pull/494
        JSServe.HTTP.get(string(app.url), readtimeout=3, retries=1)
    catch e
        if e isa JSServe.HTTP.IOError && e.e == Base.IOError("connect: connection refused (ECONNREFUSED)", -4078)
            # Huh, so this actually did close things correctly
        else
            rethrow(e)
        end
    finally
        close(app.window)
    end
end

function runjs(app, js)
    JSServe.evaljs_value(app.session, js)
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

trigger_keyboard_press(app, key) = app.testlib.trigger_keyboard_press(key)

end # module
