%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%% Copyright (c) 2007-2023 VMware, Inc. or its affiliates.  All rights reserved.
%%

-module(rabbit_exchange_type_consistent_hash_SUITE).

-compile(export_all).

-include("rabbitmq_consistent_hash_exchange.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("amqp_client/include/amqp_client.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("rabbitmq_ct_helpers/include/rabbit_assert.hrl").

-define(DEFAULT_WAIT, 1000).
-define(DEFAULT_INTERVAL, 100).

all() ->
    [
      {group, mnesia_store},
      {group, khepri_store},
      {group, khepri_migration}
    ].

groups() ->
    [
     {mnesia_store, [], [
                         {routing_tests, [], routing_tests()},
                         {hash_ring_management_tests, [], hash_ring_management_tests()},
                         {clustered, [], [node_restart]}
                        ]},
     {khepri_store, [], [
                         {routing_tests, [], routing_tests()},
                         {hash_ring_management_tests, [], hash_ring_management_tests()},
                         {clustered, [], [node_restart]}
                        ]},
     {khepri_migration, [], [
                             from_mnesia_to_khepri
                            ]}
    ].

routing_tests() ->
    [
     routing_key_hashing_test,
     custom_header_hashing_test,
     message_id_hashing_test,
     correlation_id_hashing_test,
     timestamp_hashing_test,
     other_routing_test
    ].

hash_ring_management_tests() ->
    [
     test_durable_exchange_hash_ring_recovery_between_node_restarts,
     test_hash_ring_updates_when_queue_is_deleted,
     test_hash_ring_updates_when_multiple_queues_are_deleted,
     test_hash_ring_updates_when_exclusive_queues_are_deleted_due_to_connection_closure,
     test_hash_ring_updates_when_exclusive_queues_are_deleted_due_to_connection_closure_case2,
     test_hash_ring_updates_when_exclusive_queues_are_deleted_due_to_connection_closure_case3,
     test_hash_ring_updates_when_exclusive_queues_are_deleted_due_to_connection_closure_case4,
     test_hash_ring_updates_when_exclusive_queues_are_deleted_due_to_connection_closure_case5,
     test_hash_ring_updates_when_exclusive_queues_are_deleted_due_to_connection_closure_case6,
     test_hash_ring_updates_when_exchange_is_deleted,
     test_hash_ring_updates_when_queue_is_unbound,
     test_hash_ring_updates_when_duplicate_binding_is_created_and_queue_is_deleted,
     test_hash_ring_updates_when_duplicate_binding_is_created_and_binding_is_deleted
    ].

%% -------------------------------------------------------------------
%% Test suite setup/teardown
%% -------------------------------------------------------------------

init_per_suite(Config) ->
    rabbit_ct_helpers:log_environment(),
    rabbit_ct_helpers:run_setup_steps(Config).

end_per_suite(Config) ->
    rabbit_ct_helpers:run_teardown_steps(Config).

init_per_group(mnesia_store, Config) ->
    rabbit_ct_helpers:set_config(Config, [{metadata_store, mnesia}]);
init_per_group(khepri_store, Config) ->
    FFs = [khepri_db],
    rabbit_ct_helpers:set_config(Config, [{metadata_store, {khepri, FFs}}]);
init_per_group(khepri_migration = Group, Config0) ->
    Config = rabbit_ct_helpers:set_config(Config0, [{metadata_store, mnesia}]),
    init_per_group(Group, Config, 1);
init_per_group(clustered = Group, Config) ->
    case rabbit_ct_helpers:is_mixed_versions() of
        false ->
            init_per_group(Group, Config, 3);
        true ->
            %% Consistent hash exchange plugin prior to
            %% https://github.com/rabbitmq/rabbitmq-server/pull/5121
            %% does not add bindings idempotently which makes test node_restart fail.
            {skip, "not mixed versions compatible"}
    end;
init_per_group(Group, Config) ->
    init_per_group(Group, Config, 1).

init_per_group(Group, Config, NodesCount) ->
    Config1 = rabbit_ct_helpers:set_config(
                Config,
                [{rmq_nodes_count, NodesCount},
                 {rmq_nodename_suffix, Group}
                ]),
    rabbit_ct_helpers:run_steps(Config1,
                                rabbit_ct_broker_helpers:setup_steps() ++
                                rabbit_ct_client_helpers:setup_steps()).

end_per_group(mnesia_store, Config) ->
    Config;
end_per_group(khepri_store, Config) ->
    Config;
end_per_group(khepri_migration, Config) ->
    Config;
end_per_group(_, Config) ->
    rabbit_ct_helpers:run_teardown_steps(Config,
                                         rabbit_ct_client_helpers:teardown_steps() ++
                                             rabbit_ct_broker_helpers:teardown_steps()).

init_per_testcase(Testcase, Config) ->
    clean_up_test_topology(Config),
    rabbit_ct_helpers:testcase_started(Config, Testcase).

end_per_testcase(Testcase, Config) ->
    rabbit_ct_helpers:testcase_finished(Config, Testcase).

%% -------------------------------------------------------------------
%% Test cases
%% -------------------------------------------------------------------

-define(AllQs, [<<"q0">>, <<"q1">>, <<"q2">>, <<"q3">>, <<"q4">>, <<"q5">>, <<"q6">>,
                <<"e-q0">>, <<"e-q1">>, <<"e-q2">>, <<"e-q3">>, <<"e-q4">>, <<"e-q5">>, <<"e-q6">>,
                <<"d-q0">>, <<"d-q1">>, <<"d-q2">>, <<"d-q3">>, <<"d-q4">>, <<"d-q5">>, <<"d-q6">>]).
-define(RoutingTestQs, [<<"q0">>, <<"q1">>, <<"q2">>, <<"q3">>]).

%% N.B. lowering this value below 100K increases the probability
%% of failing the Chi squared test in some environments
-define(DEFAULT_SAMPLE_COUNT, 150000).

routing_key_hashing_test(Config) ->
    ok = test_with_rk(Config, ?RoutingTestQs).

custom_header_hashing_test(Config) ->
    ok = test_with_header(Config, ?RoutingTestQs).

message_id_hashing_test(Config) ->
    ok = test_with_message_id(Config, ?RoutingTestQs).

correlation_id_hashing_test(Config) ->
    ok = test_with_correlation_id(Config, ?RoutingTestQs).

timestamp_hashing_test(Config) ->
    ok = test_with_timestamp(Config, ?RoutingTestQs).

other_routing_test(Config) ->
    ok = test_binding_with_negative_routing_key(Config),
    ok = test_binding_with_non_numeric_routing_key(Config),
    ok = test_non_supported_property(Config),
    ok = test_mutually_exclusive_arguments(Config),
    ok.


%% -------------------------------------------------------------------
%% Implementation
%% -------------------------------------------------------------------

test_with_rk(Config, Qs) ->
    test0(Config, fun (E) ->
                  #'basic.publish'{exchange = E, routing_key = rnd()}
          end,
          fun() ->
                  #amqp_msg{props = #'P_basic'{}, payload = <<>>}
          end, [], Qs).

test_with_header(Config, Qs) ->
    test0(Config, fun (E) ->
                  #'basic.publish'{exchange = E}
          end,
          fun() ->
                  H = [{<<"hashme">>, longstr, rnd()}],
                  #amqp_msg{props = #'P_basic'{headers = H}, payload = <<>>}
          end, [{<<"hash-header">>, longstr, <<"hashme">>}], Qs).

test_with_correlation_id(Config, Qs) ->
    test0(Config, fun(E) ->
                  #'basic.publish'{exchange = E}
          end,
          fun() ->
                  #amqp_msg{props = #'P_basic'{correlation_id = rnd()}, payload = <<>>}
          end, [{<<"hash-property">>, longstr, <<"correlation_id">>}], Qs).

test_with_message_id(Config, Qs) ->
    test0(Config, fun(E) ->
                  #'basic.publish'{exchange = E}
          end,
          fun() ->
                  #amqp_msg{props = #'P_basic'{message_id = rnd()}, payload = <<>>}
          end, [{<<"hash-property">>, longstr, <<"message_id">>}], Qs).

test_with_timestamp(Config, Qs) ->
    test0(Config, fun(E) ->
                  #'basic.publish'{exchange = E}
          end,
          fun() ->
                  #amqp_msg{props = #'P_basic'{timestamp = rnd_int()}, payload = <<>>}
          end, [{<<"hash-property">>, longstr, <<"timestamp">>}], Qs).

test_mutually_exclusive_arguments(Config) ->
    Chan = rabbit_ct_client_helpers:open_channel(Config, 0),

    process_flag(trap_exit, true),
    Cmd = #'exchange.declare'{
             exchange  = <<"fail">>,
             type      = <<"x-consistent-hash">>,
             arguments = [{<<"hash-header">>, longstr, <<"foo">>},
                          {<<"hash-property">>, longstr, <<"bar">>}]
            },
    ?assertExit(_, amqp_channel:call(Chan, Cmd)),

    rabbit_ct_client_helpers:close_channel(Chan),
    ok.

test_non_supported_property(Config) ->
    Chan = rabbit_ct_client_helpers:open_channel(Config, 0),

    process_flag(trap_exit, true),
    Cmd = #'exchange.declare'{
             exchange  = <<"fail">>,
             type      = <<"x-consistent-hash">>,
             arguments = [{<<"hash-property">>, longstr, <<"app_id">>}]
            },
    ?assertExit(_, amqp_channel:call(Chan, Cmd)),

    rabbit_ct_client_helpers:close_channel(Chan),
    ok.

rnd() ->
    list_to_binary(integer_to_list(rnd_int())).

rnd_int() ->
    rand:uniform(10000000).

test0(Config, MakeMethod, MakeMsg, DeclareArgs, Queues) ->
    test0(Config, MakeMethod, MakeMsg, DeclareArgs, Queues, ?DEFAULT_SAMPLE_COUNT).

test0(Config, MakeMethod, MakeMsg, DeclareArgs, [Q1, Q2, Q3, Q4] = Queues, IterationCount) ->
    Chan = rabbit_ct_client_helpers:open_channel(Config, 0),
    #'confirm.select_ok'{} = amqp_channel:call(Chan, #'confirm.select'{}),

    CHX = <<"e">>,

    clean_up_test_topology(Config, CHX, Queues),

    #'exchange.declare_ok'{} =
        amqp_channel:call(Chan,
                          #'exchange.declare' {
                            exchange = CHX,
                            type = <<"x-consistent-hash">>,
                            auto_delete = true,
                            arguments = DeclareArgs
                          }),
    [#'queue.declare_ok'{} =
         amqp_channel:call(Chan, #'queue.declare' {
                             queue = Q, exclusive = true }) || Q <- Queues],
    [#'queue.bind_ok'{} =
         amqp_channel:call(Chan, #'queue.bind' {queue = Q,
                                                exchange = CHX,
                                                routing_key = <<"1">>})
     || Q <- [Q1, Q2]],
    [#'queue.bind_ok'{} =
         amqp_channel:call(Chan, #'queue.bind' {queue = Q,
                                                exchange = CHX,
                                                routing_key = <<"2">>})
     || Q <- [Q3, Q4]],

    [amqp_channel:call(Chan,
                       MakeMethod(CHX),
                       MakeMsg()) || _ <- lists:duplicate(IterationCount, const)],
    amqp_channel:wait_for_confirms(Chan, 300),
    timer:sleep(1000),

    Counts =
        [begin
             #'queue.declare_ok'{message_count = M} =
                 amqp_channel:call(Chan, #'queue.declare' {queue     = Q,
                                                           exclusive = true}),
             M
         end || Q <- Queues],
    ?assertEqual(IterationCount, lists:sum(Counts)), %% All messages got routed

    %% Chi-square test
    %% H0: routing keys are not evenly distributed according to weight
    Expected = [IterationCount div 6, IterationCount div 6, (IterationCount div 6) * 2, (IterationCount div 6) * 2],
    Obs = lists:zip(Counts, Expected),
    Chi = lists:sum([((O - E) * (O - E)) / E || {O, E} <- Obs]),
    ct:pal("Chi-square test for 3 degrees of freedom is ~tp, p = 0.01 is 11.35, observations (counts, expected): ~tp",
           [Chi, Obs]),

    clean_up_test_topology(Config, CHX, Queues),
    rabbit_ct_client_helpers:close_channel(Chan),
    ok.

test_binding_with_negative_routing_key(Config) ->
    Chan = rabbit_ct_client_helpers:open_channel(Config, 0),
    X = <<"bind-fail">>,
    amqp_channel:call(Chan, #'exchange.delete' {exchange = X}),

    Declare1 = #'exchange.declare'{exchange = X,
                                   type = <<"x-consistent-hash">>},
    #'exchange.declare_ok'{} = amqp_channel:call(Chan, Declare1),
    Q = <<"test-queue">>,
    Declare2 = #'queue.declare'{queue = Q},
    #'queue.declare_ok'{} = amqp_channel:call(Chan, Declare2),
    process_flag(trap_exit, true),
    Cmd = #'queue.bind'{exchange = <<"bind-fail">>,
                        routing_key = <<"-1">>},
    ?assertExit(_, amqp_channel:call(Chan, Cmd)),
    Ch2 = rabbit_ct_client_helpers:open_channel(Config, 0),
    amqp_channel:call(Ch2, #'queue.delete'{queue = Q}),

    rabbit_ct_client_helpers:close_channel(Chan),
    rabbit_ct_client_helpers:close_channel(Ch2),
    ok.

test_binding_with_non_numeric_routing_key(Config) ->
    Chan = rabbit_ct_client_helpers:open_channel(Config, 0),
    X = <<"bind-fail">>,
    amqp_channel:call(Chan, #'exchange.delete' {exchange = X}),

    Declare1 = #'exchange.declare'{exchange = X,
                                   type = <<"x-consistent-hash">>},
    #'exchange.declare_ok'{} = amqp_channel:call(Chan, Declare1),
    Q = <<"test-queue">>,
    Declare2 = #'queue.declare'{queue = Q},
    #'queue.declare_ok'{} = amqp_channel:call(Chan, Declare2),
    process_flag(trap_exit, true),
    Cmd = #'queue.bind'{exchange = <<"bind-fail">>,
                        routing_key = <<"not-a-number">>},
    ?assertExit(_, amqp_channel:call(Chan, Cmd)),

    Ch2 = rabbit_ct_client_helpers:open_channel(Config, 0),
    amqp_channel:call(Ch2, #'queue.delete'{queue = Q}),

    rabbit_ct_client_helpers:close_channel(Chan),
    ok.

%%
%% Hash Ring management
%%

test_durable_exchange_hash_ring_recovery_between_node_restarts(Config) ->
    Chan = rabbit_ct_client_helpers:open_channel(Config, 0),

    X = <<"test_hash_ring_recovery_between_node_restarts">>,
    amqp_channel:call(Chan, #'exchange.delete' {exchange = X}),

    Declare = #'exchange.declare'{exchange = X,
                                  durable = true,
                                  type = <<"x-consistent-hash">>},
    #'exchange.declare_ok'{} = amqp_channel:call(Chan, Declare),

    Queues = [<<"d-q1">>, <<"d-q2">>, <<"d-q3">>],
    [#'queue.declare_ok'{} =
         amqp_channel:call(Chan, #'queue.declare'{
                                    queue = Q, durable = true, exclusive = false}) || Q <- Queues],
    [#'queue.bind_ok'{} =
         amqp_channel:call(Chan, #'queue.bind'{queue = Q,
                                               exchange = X,
                                               routing_key = <<"3">>})
     || Q <- Queues],

    ?assertEqual(9, count_buckets_of_exchange(Config, X)),
    assert_ring_consistency(Config, X),

    rabbit_ct_broker_helpers:restart_node(Config, 0),
    rabbit_ct_helpers:await_condition(
        fun () -> count_buckets_of_exchange(Config, X) > 0 end, 15000),

    ?assertEqual(9, count_buckets_of_exchange(Config, X)),
    assert_ring_consistency(Config, X),

    clean_up_test_topology(Config, X, Queues),
    rabbit_ct_client_helpers:close_channel(Chan),
    ok.

test_hash_ring_updates_when_queue_is_deleted(Config) ->
    Chan = rabbit_ct_client_helpers:open_channel(Config, 0),

    X = <<"test_hash_ring_updates_when_queue_is_deleted">>,
    amqp_channel:call(Chan, #'exchange.delete' {exchange = X}),

    Declare = #'exchange.declare'{exchange = X,
                                  type = <<"x-consistent-hash">>},
    #'exchange.declare_ok'{} = amqp_channel:call(Chan, Declare),

    Q = <<"d-q">>,
    #'queue.declare_ok'{} =
        amqp_channel:call(Chan, #'queue.declare'{
                                    queue = Q, durable = true, exclusive = false}),
    #'queue.bind_ok'{} =
        amqp_channel:call(Chan, #'queue.bind'{queue = Q,
                                               exchange = X,
                                               routing_key = <<"1">>}),

    ?assertEqual(1, count_buckets_of_exchange(Config, X)),
    assert_ring_consistency(Config, X),

    amqp_channel:call(Chan, #'queue.delete' {queue = Q}),
    ?assertEqual(0, count_buckets_of_exchange(Config, X)),

    clean_up_test_topology(Config, X, [Q]),
    rabbit_ct_client_helpers:close_channel(Chan),
    ok.

test_hash_ring_updates_when_multiple_queues_are_deleted(Config) ->
    Chan = rabbit_ct_client_helpers:open_channel(Config, 0),

    X = <<"test_hash_ring_updates_when_multiple_queues_are_deleted">>,
    amqp_channel:call(Chan, #'exchange.delete' {exchange = X}),

    Declare = #'exchange.declare'{exchange = X,
                                  type = <<"x-consistent-hash">>},
    #'exchange.declare_ok'{} = amqp_channel:call(Chan, Declare),

    Queues = [<<"d-q1">>, <<"d-q2">>, <<"d-q3">>],
    [#'queue.declare_ok'{} =
         amqp_channel:call(Chan, #'queue.declare'{
                                    queue = Q, durable = true, exclusive = false}) || Q <- Queues],
    [#'queue.bind_ok'{} =
         amqp_channel:call(Chan, #'queue.bind'{queue = Q,
                                               exchange = X,
                                               routing_key = <<"3">>})
     || Q <- Queues],

    ?assertEqual(9, count_buckets_of_exchange(Config, X)),
    assert_ring_consistency(Config, X),

    amqp_channel:call(Chan, #'queue.delete' {queue = <<"d-q1">>}),
    ?assertEqual(6, count_buckets_of_exchange(Config, X)),
    assert_ring_consistency(Config, X),

    amqp_channel:call(Chan, #'queue.delete' {queue = <<"d-q2">>}),
    amqp_channel:call(Chan, #'queue.delete' {queue = <<"d-q3">>}),
    ?assertEqual(0, count_buckets_of_exchange(Config, X)),

    clean_up_test_topology(Config, X, Queues),
    rabbit_ct_client_helpers:close_channel(Chan),
    ok.

test_hash_ring_updates_when_exclusive_queues_are_deleted_due_to_connection_closure(Config) ->
    Conn = rabbit_ct_client_helpers:open_unmanaged_connection(Config),
    {ok, Chan} = amqp_connection:open_channel(Conn),

    X = <<"test_hash_ring_updates_when_exclusive_queues_are_deleted_due_to_connection_closure">>,
    amqp_channel:call(Chan, #'exchange.delete' {exchange = X}),

    Declare = #'exchange.declare'{exchange = X,
                                  type = <<"x-consistent-hash">>},
    #'exchange.declare_ok'{} = amqp_channel:call(Chan, Declare),

    Queues = [<<"e-q1">>, <<"e-q2">>, <<"e-q3">>, <<"e-q4">>, <<"e-q5">>, <<"e-q6">>],
    [#'queue.declare_ok'{} =
         amqp_channel:call(Chan, #'queue.declare' {
                             queue = Q, exclusive = true }) || Q <- Queues],
    [#'queue.bind_ok'{} =
         amqp_channel:call(Chan, #'queue.bind' {queue = Q,
                                                exchange = X,
                                                routing_key = <<"3">>})
     || Q <- Queues],

    ct:pal("hash ring state: ~tp", [hash_ring_state(Config, X)]),

    ?assertEqual(18, count_buckets_of_exchange(Config, X)),
    assert_ring_consistency(Config, X),
    ok = amqp_connection:close(Conn),
    timer:sleep(500),

    ct:pal("hash ring state after connection closure: ~tp", [hash_ring_state(Config, X)]),

    ?awaitMatch(0, count_buckets_of_exchange(Config, X), ?DEFAULT_WAIT, ?DEFAULT_INTERVAL),
    clean_up_test_topology(Config, X, []),
    ok.

%% rabbitmq/rabbitmq-consistent-has-exchange#40, uses higher weights
test_hash_ring_updates_when_exclusive_queues_are_deleted_due_to_connection_closure_case2(Config) ->
    test_hash_ring_updates_when_exclusive_queues_are_deleted_due_to_connection_closure_case(Config, ?FUNCTION_NAME, 50).

%% rabbitmq/rabbitmq-consistent-has-exchange#40
test_hash_ring_updates_when_exclusive_queues_are_deleted_due_to_connection_closure_case3(Config) ->
    test_hash_ring_updates_when_exclusive_queues_are_deleted_due_to_connection_closure_case(Config, ?FUNCTION_NAME, 34).

%% rabbitmq/rabbitmq-consistent-has-exchange#40
test_hash_ring_updates_when_exclusive_queues_are_deleted_due_to_connection_closure_case4(Config) ->
    test_hash_ring_updates_when_exclusive_queues_are_deleted_due_to_connection_closure_case(Config, ?FUNCTION_NAME, 100).

%% rabbitmq/rabbitmq-consistent-has-exchange#40
test_hash_ring_updates_when_exclusive_queues_are_deleted_due_to_connection_closure_case5(Config) ->
    test_hash_ring_updates_when_exclusive_queues_are_deleted_due_to_connection_closure_case(Config, ?FUNCTION_NAME, 268).

%% rabbitmq/rabbitmq-consistent-has-exchange#40
test_hash_ring_updates_when_exclusive_queues_are_deleted_due_to_connection_closure_case6(Config) ->
    test_hash_ring_updates_when_exclusive_queues_are_deleted_due_to_connection_closure_case(Config, ?FUNCTION_NAME, 1937).

test_hash_ring_updates_when_exclusive_queues_are_deleted_due_to_connection_closure_case(Config, XAsList, Key) ->
    Conn = rabbit_ct_client_helpers:open_unmanaged_connection(Config),
    {ok, Chan} = amqp_connection:open_channel(Conn),

    X = atom_to_binary(XAsList, utf8),
    amqp_channel:call(Chan, #'exchange.delete' {exchange = X}),

    Declare = #'exchange.declare'{exchange = X,
                                  type = <<"x-consistent-hash">>},
    #'exchange.declare_ok'{} = amqp_channel:call(Chan, Declare),

    NumQueues = 6,
    Queues = [begin
                  #'queue.declare_ok'{queue = Q} =
                      amqp_channel:call(Chan, #'queue.declare' {exclusive = true }),
                  Q
              end || _ <- lists:seq(1, NumQueues)],
    [#'queue.bind_ok'{} =
         amqp_channel:call(Chan, #'queue.bind' {queue = Q,
                                                exchange = X,
                                                routing_key = integer_to_binary(Key)})
     || Q <- Queues],

    ct:pal("hash ring state: ~tp", [hash_ring_state(Config, X)]),

    %% NumQueues x 'Key' buckets per binding
    ?assertEqual(NumQueues * Key, count_buckets_of_exchange(Config, X)),
    assert_ring_consistency(Config, X),
    ok = amqp_connection:close(Conn),
    timer:sleep(1000),

    ct:pal("hash ring state after connection closure (~tp): ~tp", [XAsList, hash_ring_state(Config, X)]),

    ?awaitMatch(0, count_buckets_of_exchange(Config, X), ?DEFAULT_WAIT, ?DEFAULT_INTERVAL),
    clean_up_test_topology(Config, X, []),
    ok.

test_hash_ring_updates_when_exchange_is_deleted(Config) ->
    Chan = rabbit_ct_client_helpers:open_channel(Config, 0),

    X = <<"test_hash_ring_updates_when_exchange_is_deleted">>,
    amqp_channel:call(Chan, #'exchange.delete' {exchange = X}),

    Declare = #'exchange.declare'{exchange = X,
                                  type = <<"x-consistent-hash">>},
    #'exchange.declare_ok'{} = amqp_channel:call(Chan, Declare),

    Queues = [<<"e-q1">>, <<"e-q2">>, <<"e-q3">>, <<"e-q4">>, <<"e-q5">>, <<"e-q6">>],
    [#'queue.declare_ok'{} =
         amqp_channel:call(Chan, #'queue.declare' {
                             queue = Q, exclusive = true }) || Q <- Queues],
    [#'queue.bind_ok'{} =
         amqp_channel:call(Chan, #'queue.bind' {queue = Q,
                                                exchange = X,
                                                routing_key = <<"2">>})
     || Q <- Queues],

    ?assertEqual(12, count_buckets_of_exchange(Config, X)),
    amqp_channel:call(Chan, #'exchange.delete' {exchange = X}),

    ?assertEqual(0, count_buckets_of_exchange(Config, X)),

    amqp_channel:call(Chan, #'queue.delete' {queue = <<"e-q1">>}),
    ?assertEqual(0, count_buckets_of_exchange(Config, X)),

    clean_up_test_topology(Config, X, Queues),
    rabbit_ct_client_helpers:close_channel(Chan),
    ok.

test_hash_ring_updates_when_queue_is_unbound(Config) ->
    Chan = rabbit_ct_client_helpers:open_channel(Config, 0),

    X = <<"test_hash_ring_updates_when_queue_is_unbound">>,
    amqp_channel:call(Chan, #'exchange.delete' {exchange = X}),

    Declare = #'exchange.declare'{exchange = X,
                                  type = <<"x-consistent-hash">>},
    #'exchange.declare_ok'{} = amqp_channel:call(Chan, Declare),

    Queues = [<<"e-q1">>, <<"e-q2">>, <<"e-q3">>, <<"e-q4">>, <<"e-q5">>, <<"e-q6">>],
    [#'queue.declare_ok'{} =
         amqp_channel:call(Chan, #'queue.declare' {
                             queue = Q, exclusive = true }) || Q <- Queues],
    [#'queue.bind_ok'{} =
         amqp_channel:call(Chan, #'queue.bind' {queue = Q,
                                                exchange = X,
                                                routing_key = <<"2">>})
     || Q <- Queues],

    ?assertEqual(12, count_buckets_of_exchange(Config, X)),
    amqp_channel:call(Chan, #'queue.unbind'{exchange = X,
                                            queue = <<"e-q2">>,
                                            routing_key = <<"2">>}),

    ?assertEqual(10, count_buckets_of_exchange(Config, X)),
    amqp_channel:call(Chan, #'queue.unbind'{exchange = X,
                                            queue = <<"e-q6">>,
                                            routing_key = <<"2">>}),
    ?assertEqual(8, count_buckets_of_exchange(Config, X)),

    clean_up_test_topology(Config, X, Queues),
    rabbit_ct_client_helpers:close_channel(Chan),
    ok.

test_hash_ring_updates_when_duplicate_binding_is_created_and_queue_is_deleted(Config) ->
    Chan = rabbit_ct_client_helpers:open_channel(Config, 0),

    X = <<"test_hash_ring_updates_when_duplicate_binding_is_created_and_queue_is_deleted">>,
    amqp_channel:call(Chan, #'exchange.delete' {exchange = X}),

    Declare = #'exchange.declare'{exchange = X,
                                  type = <<"x-consistent-hash">>},
    #'exchange.declare_ok'{} = amqp_channel:call(Chan, Declare),

    Q1 = <<"f-q1">>,
    #'queue.declare_ok'{} =
        amqp_channel:call(Chan, #'queue.declare'{
                                    queue = Q1, durable = true, exclusive = false}),
    #'queue.bind_ok'{} =
        amqp_channel:call(Chan, #'queue.bind'{queue = Q1,
                                               exchange = X,
                                               routing_key = <<"2">>}),

    #'queue.bind_ok'{} =
        amqp_channel:call(Chan, #'queue.bind'{queue = Q1,
                                               exchange = X,
                                               routing_key = <<"3">>}),

    %% 1st binding wins. Duplicate bindings (i.e. bindings with same source and
    %% destination but possibly different routing key) should be ignored.
    ?assertEqual(2, count_buckets_of_exchange(Config, X)),
    assert_ring_consistency(Config, X),

    Q2 = <<"f-q2">>,
    #'queue.declare_ok'{} =
        amqp_channel:call(Chan, #'queue.declare'{
                                    queue = Q2, durable = true, exclusive = false}),
    #'queue.bind_ok'{} =
        amqp_channel:call(Chan, #'queue.bind'{queue = Q2,
                                               exchange = X,
                                               routing_key = <<"4">>}),

    ?assertEqual(6, count_buckets_of_exchange(Config, X)),
    assert_ring_consistency(Config, X),

    amqp_channel:call(Chan, #'queue.delete' {queue = Q1}),
    ?assertEqual(4, count_buckets_of_exchange(Config, X)),
    assert_ring_consistency(Config, X),

    clean_up_test_topology(Config, X, [Q1, Q2]),
    rabbit_ct_client_helpers:close_channel(Chan),
    ok.

test_hash_ring_updates_when_duplicate_binding_is_created_and_binding_is_deleted(Config) ->
    Chan = rabbit_ct_client_helpers:open_channel(Config, 0),

    X = <<"test_hash_ring_updates_when_duplicate_binding_is_created_and_binding_is_deleted">>,
    amqp_channel:call(Chan, #'exchange.delete' {exchange = X}),

    Declare = #'exchange.declare'{exchange = X,
                                  type = <<"x-consistent-hash">>},
    #'exchange.declare_ok'{} = amqp_channel:call(Chan, Declare),

    Q1 = <<"f-q1">>,
    #'queue.declare_ok'{} =
        amqp_channel:call(Chan, #'queue.declare'{
                                    queue = Q1, durable = true, exclusive = false}),
    #'queue.bind_ok'{} =
        amqp_channel:call(Chan, #'queue.bind'{queue = Q1,
                                               exchange = X,
                                               routing_key = <<"2">>}),

    %% Duplicate binding should be ignored when added.
    #'queue.bind_ok'{} =
        amqp_channel:call(Chan, #'queue.bind'{queue = Q1,
                                               exchange = X,
                                               routing_key = <<"3">>}),

    Q2 = <<"f-q2">>,
    #'queue.declare_ok'{} =
        amqp_channel:call(Chan, #'queue.declare'{
                                    queue = Q2, durable = true, exclusive = false}),
    #'queue.bind_ok'{} =
        amqp_channel:call(Chan, #'queue.bind'{queue = Q2,
                                               exchange = X,
                                               routing_key = <<"4">>}),

    ?assertEqual(6, count_buckets_of_exchange(Config, X)),
    assert_ring_consistency(Config, X),

    %% However, when duplicate binding gets removed,
    %% it should delete the (original binding's) buckets.
    amqp_channel:call(Chan, #'queue.unbind'{queue = Q1,
                                            exchange = X,
                                            routing_key = <<"3">>}),
    ?assertEqual(4, count_buckets_of_exchange(Config, X)),
    assert_ring_consistency(Config, X),

    amqp_channel:call(Chan, #'queue.unbind'{queue = Q2,
                                            exchange = X,
                                            routing_key = <<"4">>}),
    ?assertEqual(0, count_buckets_of_exchange(Config, X)),

    clean_up_test_topology(Config, X, [Q1, Q2]),
    rabbit_ct_client_helpers:close_channel(Chan),
    ok.

%% Follows the setup described in
%% https://github.com/rabbitmq/rabbitmq-server/issues/3386#issuecomment-1103929292
node_restart(Config) ->
    Chan1 = rabbit_ct_client_helpers:open_channel(Config, 1),
    Chan2 = rabbit_ct_client_helpers:open_channel(Config, 2),

    X = atom_to_binary(?FUNCTION_NAME),
    #'exchange.declare_ok'{} = amqp_channel:call(Chan1,
                                                 #'exchange.declare'{exchange = X,
                                                                     durable = true,
                                                                     type = <<"x-consistent-hash">>}),
    F = fun(Chan, Qs) ->
                lists:foreach(
                  fun(Q) ->
                          #'queue.declare_ok'{} =
                          amqp_channel:call(Chan, #'queue.declare'{queue = Q,
                                                                   durable = true}),
                          #'queue.bind_ok'{} =
                          amqp_channel:call(Chan, #'queue.bind' {exchange = X,
                                                                 queue = Q,
                                                                 routing_key = <<"1">>})
                  end, Qs)
        end,
    QsNode1 = [<<"q2">>, <<"q4">>],
    QsNode2 = [<<"q1">>, <<"q3">>],
    F(Chan1, QsNode1),
    F(Chan2, QsNode2),

    rabbit_ct_client_helpers:close_channel(Chan1),
    rabbit_ct_client_helpers:close_channel(Chan2),

    rabbit_ct_broker_helpers:restart_node(Config, 1),
    rabbit_ct_broker_helpers:restart_node(Config, 2),

    ?assertEqual(4, count_buckets_of_exchange(Config, X)),
    assert_ring_consistency(Config, X),

    clean_up_test_topology(Config, X, QsNode1 ++ QsNode2),
    ok.

%%
%% Helpers
%%

hash_ring_state(Config, X) ->
    rabbit_ct_broker_helpers:rpc(
      Config, 0, rabbit_exchange_type_consistent_hash, ring_state, [<<"/">>, X]).

assert_ring_consistency(Config, X) ->
    {ok, #chx_hash_ring{bucket_map = M}} = hash_ring_state(Config, X),
    Buckets = lists:usort(maps:keys(M)),
    Hi      = lists:last(Buckets),

    %% bucket numbers form a sequence without gaps or duplicates
    ?assertEqual(lists:seq(0, Hi), lists:usort(Buckets)).

count_buckets_of_exchange(Config, X) ->
    case hash_ring_state(Config, X) of
        {ok, #chx_hash_ring{bucket_map = M}} ->
            ct:pal("BUCKET MAP ~p", [M]),
            maps:size(M);
        {error, not_found}                   -> 0
    end.

from_mnesia_to_khepri(Config) ->
    Queues = [Q1, Q2, Q3, Q4] = ?RoutingTestQs,
    IterationCount = ?DEFAULT_SAMPLE_COUNT,
    Chan = rabbit_ct_client_helpers:open_channel(Config, 0),
    #'confirm.select_ok'{} = amqp_channel:call(Chan, #'confirm.select'{}),

    CHX = <<"e">>,

    clean_up_test_topology(Config, CHX, Queues),

    #'exchange.declare_ok'{} =
        amqp_channel:call(Chan,
                          #'exchange.declare' {
                            exchange = CHX,
                            type = <<"x-consistent-hash">>,
                            auto_delete = true,
                            arguments = []
                          }),
    [#'queue.declare_ok'{} =
         amqp_channel:call(Chan, #'queue.declare' {
                             queue = Q, exclusive = true }) || Q <- Queues],
    [#'queue.bind_ok'{} =
         amqp_channel:call(Chan, #'queue.bind' {queue = Q,
                                                exchange = CHX,
                                                routing_key = <<"1">>})
     || Q <- [Q1, Q2]],
    [#'queue.bind_ok'{} =
         amqp_channel:call(Chan, #'queue.bind' {queue = Q,
                                                exchange = CHX,
                                                routing_key = <<"2">>})
     || Q <- [Q3, Q4]],

    case rabbit_ct_broker_helpers:enable_feature_flag(Config, khepri_db) of
        ok ->
            case rabbit_ct_broker_helpers:enable_feature_flag(Config, rabbit_consistent_hash_exchange_raft_based_metadata_store) of
                ok ->
                    [amqp_channel:call(Chan,
                                       #'basic.publish'{exchange = CHX, routing_key = rnd()},
                                       #amqp_msg{props = #'P_basic'{}, payload = <<>>})
                     || _ <- lists:duplicate(IterationCount, const)],
                    amqp_channel:wait_for_confirms(Chan, 300),
                    timer:sleep(500),
                    Counts =
                        [begin
                             #'queue.declare_ok'{message_count = M} =
                                 amqp_channel:call(Chan, #'queue.declare' {queue     = Q,
                                                                           exclusive = true}),
                             M
                         end || Q <- Queues],
                    ?assertEqual(IterationCount, lists:sum(Counts)), %% All messages got routed
                    %% Chi-square test
                    %% H0: routing keys are not evenly distributed according to weight
                    Expected = [IterationCount div 6, IterationCount div 6, (IterationCount div 6) * 2, (IterationCount div 6) * 2],
                    Obs = lists:zip(Counts, Expected),
                    Chi = lists:sum([((O - E) * (O - E)) / E || {O, E} <- Obs]),
                    ct:pal("Chi-square test for 3 degrees of freedom is ~p, p = 0.01 is 11.35, observations (counts, expected): ~p",
                           [Chi, Obs]),
                    clean_up_test_topology(Config, CHX, Queues),
                    rabbit_ct_client_helpers:close_channel(Chan),
                    ok;
                Skip ->
                    Skip
            end;
        Skip ->
            Skip
    end.

clean_up_test_topology(Config) ->
    clean_up_test_topology(Config, none, ?AllQs).

clean_up_test_topology(Config, none, Qs) ->
    Ch = rabbit_ct_client_helpers:open_channel(Config, 0),
    [amqp_channel:call(Ch, #'queue.delete' {queue = Q}) || Q <- Qs],
    rabbit_ct_client_helpers:close_channel(Ch);

clean_up_test_topology(Config, X, Qs) ->
    Ch = rabbit_ct_client_helpers:open_channel(Config, 0),
    amqp_channel:call(Ch, #'exchange.delete' {exchange = X}),
    [amqp_channel:call(Ch, #'queue.delete' {queue = Q}) || Q <- Qs],
    rabbit_ct_client_helpers:close_channel(Ch).
