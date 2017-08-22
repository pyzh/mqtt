-module(n2o_auth).

-include("emqttd.hrl").

-behaviour(emqttd_auth_mod).
-compile(export_all).
-export([init/1, check/3, description/0]).

init([Listeners]) ->
    {ok, Listeners}.


get_client_id() ->
    {_, NPid, _} = emqttd_guid:new(),
    iolist_to_binary(["emqttd_", integer_to_list(NPid)]).

%%check(#mqtt_client{ws_initial_headers = undefined}, _Password, _) ->
%%    ignore;
check(#mqtt_client{client_id = ClientId,
                    username  = Username,
                    client_pid = ClientPid,
                    ws_initial_headers = _Headers},
            _Password, _Listeners) ->
    ClientId2 =
        case ClientId of
           <<>> -> get_client_id();
           _ ->  ClientId
        end,
    case ClientId2 of
        <<"emqttd_", _/binary>> ->
            Replace = fun(Topic) -> rep(<<"%u">>, Username,
                rep(<<"%c">>, ClientId2, Topic)) end,
            Topics = [{<<"actions/1/%u/%c">>, 2}],
            TopicTable = [{Replace(Topic), Qos} || {Topic, Qos} <- Topics],
            io:format("CHECK ~p, ~p~n",[Username, TopicTable]),
            emqttd_client:subscribe(ClientPid, TopicTable),
            Topics2 = [{<<"actions/2/%u/%c">>, 2}],
            TopicTable2 = [{Replace(Topic), Qos} || {Topic, Qos} <- Topics2],
            io:format("CHECK ~p, ~p~n",[Username, TopicTable2]),
            emqttd_client:subscribe(ClientPid, TopicTable2),
            ok;
        _ -> ok
    end;
check(_Client, _Password, _Opts) ->
    ignore.

rep(<<"%c">>, ClientId, Topic)  -> emqttd_topic:feed_var(<<"%c">>, ClientId,   Topic);
rep(<<"%u">>, undefined, Topic) -> emqttd_topic:feed_var(<<"%u">>, <<"anon">>, Topic);
rep(<<"%u">>, Username, Topic)  -> emqttd_topic:feed_var(<<"%u">>, Username,   Topic).

description() ->
    "N2O Authentication Module".