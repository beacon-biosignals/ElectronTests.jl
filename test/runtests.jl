using ElectronTests
using JSServe
using JSServe: @js_str, Slider, Button, TextField, linkjs, onjs
using JSServe.DOM
using Test
using ElectronTests: TestSession
using Markdown

@testset "ElectronTests" begin

    function test_handler(session, req)
        s1 = Slider(1:100)
        s2 = Slider(1:100)
        b = Button("hi")
        t = TextField("Write!")
        bla = DOM.div("this is test!", dataTestId="test")
        linkjs(session, s1.value, s2.value)
        canvas = DOM.um("canvas", height="100", width="100")

        dom = md"""
        # IS THIS REAL?

        My first slider: $(s1)

        My second slider: $(s2)

        Test: $(s1.value)

        The BUTTON: $(b)

        Type something for the list: $(t)

        some list $(t.value)

        ## More test:

        $(bla)

        ## Canvas for mouse move

        $(canvas)
        """
        return DOM.div(dom, id="testapp")
    end

    testsession(test_handler) do app
        @test evaljs(app, js"document.getElementById('testapp').children.length") == 1
        @test evaljs(app, js"document.getElementById('testapp').children[0].children[0].innerText") == "IS THIS REAL?"
        @test evaljs(app, js"document.querySelectorAll('input[type=\"button\"]').length") == 1
        @test evaljs(app, js"document.querySelectorAll('input[type=\"range\"]').length") == 2
        trigger_keyboard_press(app, "KeyRight")
        trigger_mouse_move(app, (0, 0))
        @wait_for 1 == 1
        test = query_testid(app, "test")
        @test evaljs(app, js"$(test).innerText") == "this is test!"
    end

    # Start a second testsession to make sure we do the cleaning up correctly!
    testsession(test_handler) do app
        @test evaljs(app, js"document.getElementById('testapp').children.length") == 1
        @test evaljs(app, js"document.getElementById('testapp').children[0].children[0].innerText") == "IS THIS REAL?"
        @test evaljs(app, js"document.querySelectorAll('input[type=\"button\"]').length") == 1
        @test evaljs(app, js"document.querySelectorAll('input[type=\"range\"]').length") == 2
        trigger_keyboard_press(app, "KeyRight")
        trigger_mouse_move(app, (0, 0))
        @wait_for 1 == 1
        test = query_testid(app, "test")
        @test evaljs(app, js"$(test).innerText") == "this is test!"
    end
    @testset "errorrs" begin
        # Test direct construction!
        app = TestSession() do session, request
            return DOM.div("bla")
        end
        close(app)
        @test_throws ErrorException evaljs(app, js"console.log('pls error')")
        ElectronTests.start(app)
        response = JSServe.HTTP.get(string(app.url))
        @test response.status == 200
        close(app)

        @test_throws ErrorException("error in handler") TestSession() do session, request
            return error("error in handler")
        end
        testsession((a,b)-> DOM.div("lalal")) do app
        end

        global test_session = nothing
        global dom = nothing
        inline_display = JSServe.with_session() do session, req
            global test_session = session
            global dom = DOM.div("yay", dataTestId="yay")
            return DOM.div(ElectronTests.JSTest, dom)
        end;
        html_str = sprint(io-> Base.show(io, MIME"text/html"(), inline_display))
        eapp = ElectronTests.Electron.Application()
        url = ElectronTests.URI("http://localhost:8081/show")
        electron_disp = ElectronTests.Window(eapp, url)
        @wait_for isopen(test_session)
        app = TestSession(url, JSServe.global_application[], electron_disp, test_session)
        app.dom = dom
        elem = query_testid("yay")
        evaljs(app, js"$(elem).innerText") == "yay"
        ElectronTests.check_and_close_display()
        @test !JSServe.isrunning(JSServe.global_application[])
        close(app)
    end
end
