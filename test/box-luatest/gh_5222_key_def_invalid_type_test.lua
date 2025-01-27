local t = require('luatest')
local g = t.group('gh-5222')

g.test_key_def_invalid_type = function()
    local key_def = require('key_def')

    t.assert_error_msg_content_equals("Wrong field type: expected string, got nil", function()
        key_def.new({{field = 1, type = nil}})
    end)
    t.assert_error_msg_content_equals("Wrong field type: expected string, got cdata", function()
        key_def.new({{field = 1, type = box.NULL}})
    end)
    t.assert_error_msg_content_equals("Wrong field type: expected string, got table", function()
        key_def.new({{field = 1, type = {}}})
    end)
    t.assert_error_msg_content_equals("Wrong field type: expected string, got boolean", function()
        key_def.new({{field = 1, type = true}})
    end)
    t.assert_error_msg_content_equals("Unknown field type: 2989", function()
        key_def.new({{field = 1, type = 2989}})
    end)
    t.assert_error_msg_content_equals("Unknown field type: bad", function()
        key_def.new({{field = 1, type = 'bad'}})
    end)
    t.assert_error_msg_content_equals("Unknown field type: ", function()
        key_def.new({{field = 1, type = ''}})
    end)
end
