
const Test = {
    trigger_keyboard_press: function trigger_keyboard_press(key, element){
        element = element || document
        var down = new KeyboardEvent('keydown', {key: key, code: key});
        var up = new KeyboardEvent('keyup', {key: key, code: key});
        element.dispatchEvent(down);
        element.dispatchEvent(up);
    },

    trigger_mouse_move: function trigger_mouse_move(position, element){
        element = element || document.querySelector('canvas');
        var event = new MouseEvent('mousemove', {
            clientX: position[0],
            clientY: position[1]
        });
        element.dispatchEvent(event);
    }
}
