local luatest = require('luatest')
local helpers = require('test.luatest_helpers')
local cluster = require('test.luatest_helpers.cluster')
local g = luatest.group('gh-6033-box-promote-demote')

local make_leader = function(server)
    server:exec(function()
        box.ctl.promote()
    end)
    server:wait_election_state('leader')
    server:wait_synchro_queue_owner()
end

local get_wal_write_count = function(server)
    return server:exec(function()
        return box.error.injection.get('ERRINJ_WAL_WRITE_COUNT')
    end)
end

local get_raft_term = function(server)
    return server:exec(function()
        return box.info.election.term
    end)
end

-- @TODO should be changed to something like:
-- function(server, leader_id, raft_term)
--     server:wait_election_term(raft_term + 1)
--     server:wait_synchro_queue_owner(leader_id)
--  end
-- when https://github.com/tarantool/tarantool/issues/6754 will be fixed.
-- Current workaround is here because order of "term increment" and
-- "promote" messages is inconsistent. We wait for 2 WAL writes if
-- term increment arrives first, if promote arrives first we can continue.
local wait_promote = function(server, wal_write_count, raft_term)
    server:wait_wal_write_count(wal_write_count + 1)

    local new_raft_term = get_raft_term(server)

    if new_raft_term > raft_term then
        server:wait_wal_write_count(wal_write_count + 2)
    end
end

g.before_each(function(g)
    g.cluster = cluster:new({})

    g.box_cfg = {
        election_mode = 'off',
        read_only = false,
        replication_timeout = 0.1,
        replication_synchro_quorum = 1,
        replication = {
            helpers.instance_uri('server_', 1),
            helpers.instance_uri('server_', 2),
        },
    }

    g.server_1 = g.cluster:build_and_add_server(
        {alias = 'server_1', box_cfg = g.box_cfg})
    g.server_2 = g.cluster:build_and_add_server(
        {alias = 'server_2', box_cfg = g.box_cfg})
    g.cluster:start()
end)

g.after_each(function(g)
    g.cluster:stop()
end)

-- Test that box_promote and box_demote
-- will return 0 if server is not configured.
g.test_unconfigured = function()
    local ok = pcall(box.ctl.promote)
    luatest.assert(ok, 'error while promoting unconfigured server')

    local ok = pcall(box.ctl.demote)
    luatest.assert(ok, 'error while demoting unconfigured server')
end

-- Test that box_promote will return 0
-- if server is already raft leader and limbo owner.
g.test_leader_promote = function(g)
    g.server_1:box_config({election_mode = 'manual'})
    make_leader(g.server_1)

    local ok = g.server_1:exec(function()
        return pcall(box.ctl.promote)
    end)
    luatest.assert(ok, 'error while promoting leader')
end

-- Test that box_promote will return 0
-- if server is already raft leader but not current limbo owner.
g.test_raft_leader_promote = function(g)
    g.server_1:box_config({election_mode = 'manual'})

    g.server_1:exec(function()
        box.error.injection.set('ERRINJ_WAL_DELAY_COUNTDOWN', 2)
        box.ctl.promote()
        while box.error.injection.get("ERRINJ_WAL_DELAY") ~= true do
            require('fiber').sleep(0.01)
        end
    end)
    g.server_1:wait_election_state('leader')

    local ok = g.server_1:exec(function()
        local ok = pcall(box.ctl.promote)
        box.error.injection.set('ERRINJ_WAL_DELAY', false)
        return ok
    end)
    luatest.assert(ok, 'error while promoting raft leader')
end

-- Test that box_demote will return 0 if server is already follower.
g.test_follower_demote = function(g)
    g.server_1:box_config({election_mode = 'manual'})

    local ok = g.server_1:exec(function()
        return pcall(box.ctl.demote)
    end)
    luatest.assert(ok, 'error while demoting follower in manual mode')

    local ok = g.server_2:exec(function()
        return pcall(box.ctl.demote)
    end)
    luatest.assert(ok, 'error while demoting follower if off mode')
end

-- Test that box_demote will return 0 for leader
-- with election_mode = 'manual'.
g.test_manual_leader_demote = function(g)
    g.server_1:box_config({election_mode = 'manual'})
    make_leader(g.server_1)

    local ok = g.server_1:exec(function()
        return pcall(box.ctl.demote)
    end)
    luatest.assert(ok, 'error while demoting leader in manual mode')
end

-- Test that box_promote will return box.error.UNSUPPORTED
-- when called while in promote already
g.test_simultaneous_promote = function(g)
    local ok, err = g.server_1:exec(function()
        require('fiber').create(box.ctl.promote)
        return pcall(box.ctl.promote)
    end)
    luatest.assert(
        not ok and err.code == box.error.UNSUPPORTED,
        'error while promoting while in promote')
end

-- Test that box_demote will return box.error.UNSUPPORTED
-- when called while in promote already
g.test_simultaneous_demote = function(g)
    local ok, err = g.server_1:exec(function()
        require('fiber').create(box.ctl.promote)
        return pcall(box.ctl.demote)
    end)
    luatest.assert(
        not ok and err.code == box.error.UNSUPPORTED,
        'error while demoting while in promote')
end

-- Test that box_promote will return box.error.UNSUPPORTED
-- when trying to promote voter
g.test_voter_promote = function(g)
    g.server_1:box_config({election_mode = 'voter'})

    local ok, err = g.server_1:exec(function()
        return pcall(box.ctl.promote)
    end)
    luatest.assert(
        not ok and err.code == box.error.UNSUPPORTED,
        'error while promoting voter')
end

local start_wal_interfering_test = function(server_1, server_2)
    local wal_write_count = get_wal_write_count(server_1)
    local raft_term = get_raft_term(server_1)

    server_1:exec(function()
        box.error.injection.set('ERRINJ_WAL_DELAY', true)
    end)

    server_2:exec(function()
        box.ctl.promote()
    end)
    server_2:wait_synchro_queue_owner()
    wait_promote(server_1, wal_write_count, raft_term)
end

-- Test interfering promotion for election_mode = 'off'
-- while in WAL delay
g.test_wal_interfering_promote = function(g)
    start_wal_interfering_test(g.server_1, g.server_2)

    local ok, err = g.server_1:exec(function()
        local f = require('fiber').new(box.ctl.promote)
        f:set_joinable(true)
        box.error.injection.set('ERRINJ_WAL_DELAY', false)
        return f:join()
    end)
    luatest.assert(
        not ok and err.code == box.error.INTERFERING_PROMOTE,
        'interfering promote not handled')
end

-- Test interfering demotion for election_mode = 'off'
-- while in WAL delay
g.test_wal_interfering_demote = function(g)
    g.server_1:exec(function()
        box.ctl.promote()
    end)
    g.server_1:wait_synchro_queue_owner()
    g.server_2:wait_synchro_queue_owner(g.server_1:instance_id())

    start_wal_interfering_test(g.server_1, g.server_2)

    local ok, err = g.server_1:exec(function()
        local f = require('fiber').new(box.ctl.demote)
        f:set_joinable(true)
        box.error.injection.set('ERRINJ_WAL_DELAY', false)
        return f:join()
    end)
    luatest.assert(
        not ok and err.code == box.error.INTERFERING_PROMOTE,
        'interfering demote not handled')
end

local end_limbo_empty_test = function(server_1, server_2, blocked_fiber_id)
    local wal_write_count = get_wal_write_count(server_1)
    local raft_term = get_raft_term(server_1)
    server_2:exec(function()
        box.ctl.promote()
    end)
    server_2:wait_synchro_queue_owner()
    wait_promote(server_1, wal_write_count, raft_term)
    server_1:wait_election_term(raft_term + 1)
    server_1:wait_synchro_queue_owner(server_2:instance_id())

    return server_1:exec(function(f)
        box.error.injection.set('ERRINJ_TXN_LIMBO_EMPTY_DELAY', false)
        return require('fiber').find(f):join()
    end, {blocked_fiber_id})
end

-- Test interfering promotion for election_mode = 'off'
-- while in txn_limbo delay
g.test_limbo_empty_interfering_promote = function(g)
    local f = g.server_1:exec(function()
        box.error.injection.set('ERRINJ_TXN_LIMBO_EMPTY_DELAY', true)
        local f = require('fiber').new(box.ctl.promote)
        f:set_joinable(true)
        return f:id()
    end)

    local ok, err = end_limbo_empty_test(g.server_1, g.server_2, f)
    luatest.assert(
        not ok and err.code == box.error.INTERFERING_PROMOTE,
        'interfering promote not handled')
end

-- Test interfering demotion for election_mode = 'off'
-- while in txn_limbo delay
g.test_limbo_empty_interfering_demote = function(g)
    local wal_write_count = get_wal_write_count(g.server_2)
    local raft_term = get_raft_term(g.server_2)

    g.server_1:exec(function()
        box.ctl.promote()
    end)
    g.server_1:wait_synchro_queue_owner()
    wait_promote(g.server_2, wal_write_count, raft_term)

    wal_write_count = get_wal_write_count(g.server_2)
    local f = g.server_1:exec(function()
        box.error.injection.set('ERRINJ_TXN_LIMBO_EMPTY_DELAY', true)
        local f = require('fiber').new(box.ctl.demote)
        f:set_joinable(true)
        return f:id()
    end)
    g.server_2:wait_wal_write_count(wal_write_count + 1)

    local ok, err = end_limbo_empty_test(g.server_1, g.server_2, f)
    luatest.assert(
        not ok and err.code == box.error.INTERFERING_PROMOTE,
        'interfering demote not handled')
end

-- Test failing box_wait_limbo_acked in box_promote for election_mode = 'off'
g.test_fail_limbo_acked_promote = function(g)
    g.server_1:box_config({
        replication_synchro_quorum = 2,
    })
    g.server_2:box_config({
        read_only = true,
        replication_synchro_quorum = 2,
    })

    local cfg = {
        replication_synchro_quorum = 3,
        replication_timeout = 0.1,
        replication = {
            helpers.instance_uri('server_', 1),
            helpers.instance_uri('server_', 2),
        },
    }

    g.server_3 = g.cluster:build_and_add_server(
        {alias = 'server_3', box_cfg = cfg})
    g.server_3:start()

    g.server_2:exec(function()
        box.error.injection.set('ERRINJ_WAL_DELAY', true)
    end)

    g.server_1:box_config({
        replication = {
            helpers.instance_uri('server_', 3)
        }
    })

    local wal_write_count = get_wal_write_count(g.server_1)
    g.server_3:exec(function()
        box.ctl.promote()
        local s = box.schema.create_space('test', {is_sync = true})
        s:create_index('pk')
        require('fiber').create(s.replace, s, {1})
    end)

    g.server_1:wait_wal_write_count(wal_write_count + 6)
    g.server_3:drop()

    local ok, err = g.server_1:exec(function()
        box.cfg{replication_synchro_timeout = 0.1}
        return pcall(box.ctl.promote)
    end)

    g.server_2:exec(function()
        box.error.injection.set('ERRINJ_WAL_DELAY', false)
    end)
    luatest.assert(
        not ok and err.code == box.error.QUORUM_WAIT,
        'wait quorum failure not handled')
end

g.after_test('test_fail_limbo_acked_promote', function(g)
    g.server_3:drop()
    g.server_3 = nil
end)