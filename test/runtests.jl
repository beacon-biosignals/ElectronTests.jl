using ElectronTests
using JSServe: @js_str, Slider, Button, TextField, linkjs, onjs
using JSServe.DOM
using Test
using Markdown

function test_handler(session, req)
    s1 = Slider(1:100)
    s2 = Slider(1:100)
    b = Button("hi")
    t = TextField("Write!")

    linkjs(session, s1.value, s2.value)


    dom = md"""
    # IS THIS REAL?

    My first slider: $(s1)

    My second slider: $(s2)

    Test: $(s1.value)

    The BUTTON: $(b)

    Type something for the list: $(t)

    some list $(t.value)
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
end
