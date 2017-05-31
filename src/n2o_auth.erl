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

check(#mqtt_client{ws_initial_headers = undefined}, _Password, _) ->
    ignore;
check(#mqtt_client{client_id = <<>>,
                    username  = Username,
                    client_pid = ClientPid,
                    ws_initial_headers = Headers},
            <<"password">> = Password, _Listeners) ->
    ClientId = get_client_id(),
    Replace = fun(Topic) -> rep(<<"%u">>, Username,
        rep(<<"%c">>, ClientId, Topic)) end,
    Topics = [{<<"actions/%u/%c">>, 2}],
    TopicTable = [{Replace(Topic), Qos} || {Topic, Qos} <- Topics],
%    io:format("CHECK ~p~n",[Username]),
    ClientPid ! {subscribe, TopicTable},
    ok;
check(_Client, _Password, _Opts) ->
    ignore.

rep(<<"%c">>, ClientId, Topic)  -> emqttd_topic:feed_var(<<"%c">>, ClientId,   Topic);
rep(<<"%u">>, undefined, Topic) -> emqttd_topic:feed_var(<<"%u">>, <<"anon">>, Topic);
rep(<<"%u">>, Username, Topic)  -> emqttd_topic:feed_var(<<"%u">>, Username,   Topic).

description() ->
    "N2O Authentication Module".