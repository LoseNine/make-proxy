-module(server).

-export([start/0]).

-export([start_process/1,
        accept/1]).

-include("utils.hrl").
-include("config.hrl").



start() ->
    {ok, Socket} = gen_tcp:listen(?REMOTEPORT, ?OPTIONS({0,0,0,0})),
    io:format("Server listen on ~p~n", [?REMOTEPORT]),
    % accept(Socket).
    lists:foreach(
        fun(_) ->
            spawn(?MODULE, accept, [Socket])
        end,
        lists:seq(1,5)
    ).


accept(Socket) ->
    {ok, Client} = gen_tcp:accept(Socket),
    spawn(?MODULE, start_process, [Client]),
    accept(Socket).


start_process(Client) ->
    io:format("start process: ~p~n", [Client]),


    case gen_tcp:recv(Client, 2) of
        {ok, <<TargetLen:16>>} ->
            parse_target(TargetLen, Client);
        {error, Error} ->
            gen_tcp:close(Client)
    end.


parse_target(TargetLen, Client) ->
    {ok, <<Type:8, Port:16, Destination/binary>>} = gen_tcp:recv(Client, TargetLen),
    {ok, <<Request/binary>>} = gen_tcp:recv(Client, 0),


    Address = 
    case Type of
        ?IPV4 ->
            list_to_tuple( binary_to_list(Destination) );
        ?DOMAIN ->
            binary_to_list(Destination)
    end,


    io:format("Address: ~p, Port: ~p~n", [Address, Port]),


    case gen_tcp:connect(Address, Port, ?OPTIONS, 8000) of
        {ok, TargetSocket} ->
            ok = gen_tcp:send(TargetSocket, Request),
            transfer(Client, TargetSocket);
        {error, Error} ->
            io:format("connect error: ~p:~p ~p~n", [Address, Port, Error]),
            % gen_tcp:close(TargetSocket),
            gen_tcp:close(Client)
    end,


    io:format("process die!~n", []).




transfer(Client, Remote) ->
    case gen_tcp:recv(Remote, 0) of 
        {ok, Data} ->
            ok = gen_tcp:send(Client, Data),
            transfer(Client, Remote);
        {error, Error} ->
            % io:format("remote recv error: ~p~n", [Error]),
            gen_tcp:close(Client),
            gen_tcp:close(Remote)
    end.
