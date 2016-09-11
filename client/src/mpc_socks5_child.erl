-module(mpc_socks5_child).

-behaviour(gen_server).

%% API
-export([start_link/1]).

%% gen_server callbacks
-export([init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3]).

-record(state, {key, lsock, socket, remote}).

-include("../../include/socks_type.hrl").
-define(TIMEOUT, 1000 * 60 * 10).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link(LSock) ->
    gen_server:start_link(?MODULE, [LSock], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init([LSock]) ->
    {ok, Key} = application:get_env(make_proxy_client, key),
    {ok, #state{key = Key, lsock = LSock}, 0}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_cast(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------

handle_info(timeout, #state{key = Key, lsock = LSock, socket = undefined} = State) ->
    {ok, Socket} = gen_tcp:accept(LSock),
    mpc_socks5_sup:start_child(),

    case start_process(Socket, Key) of
        {ok, Remote} ->
            ok = inet:setopts(Socket, [{active, once}]),
            ok = inet:setopts(Remote, [{active, once}]),
            {noreply, State#state{socket = Socket, remote = Remote}, ?TIMEOUT};
        {error, Error} ->
            {stop, Error, State}
    end;


%% send by OPT timeout
handle_info(timeout, #state{socket = Socket} = State) when is_port(Socket) ->
    {stop, timeout, State};


%% recv from client, and send to remote
handle_info({tcp, Socket, Request}, #state{key = Key, socket = Socket, remote = Remote} = State) ->
    case gen_tcp:send(Remote, mp_crypto:encrypt(Key, Request)) of
        ok ->
            ok = inet:setopts(Socket, [{active, once}]),
            {noreply, State, ?TIMEOUT};
        {error, Error} ->
            {stop, Error, State}
    end;

%% recv from remote, and send back to client
handle_info({tcp, Socket, Response}, #state{key = Key, socket = Client, remote = Socket} = State) ->
    {ok, RealData} = mp_crypto:decrypt(Key, Response),
    case gen_tcp:send(Client, RealData) of
        ok ->
            ok = inet:setopts(Socket, [{active, once}]),
            {noreply, State, ?TIMEOUT};
        {error, Error} ->
            {stop, Error, State}
    end;

handle_info({tcp_closed, _}, State) ->
    {stop, normal, State};

handle_info({tcp_error, _, Reason}, State) ->
    {stop, Reason, State}.


%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, #state{socket = Socket, remote = Remote}) ->
    case is_port(Socket) of
        true -> gen_tcp:close(Socket);
        false -> ok
    end,

    case is_port(Remote) of
        true -> gen_tcp:close(Remote);
        false -> ok
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

-spec(start_process(port(), nonempty_string()) -> {ok, port()} |
{error, term()}).
start_process(Socket, Key) ->
    {ok, RemoteAddr} = application:get_env(make_proxy_client, remote_addr),
    {ok, RemotePort} = application:get_env(make_proxy_client, remote_port),
    {ok, Addr} = inet:getaddr(RemoteAddr, inet),

    {ok, Target, Response} = find_target(Socket),
    case find_target(Socket) of
        {ok, Target, Response} ->
            EncryptedTarget = mp_crypto:encrypt(Key, Target),
            case gen_tcp:connect(Addr, RemotePort, [binary, {active, false}, {packet, 4}]) of
                {ok, RemoteSocket} ->
                    ok = gen_tcp:send(Socket, Response),
                    ok = gen_tcp:send(RemoteSocket, EncryptedTarget),
                    {ok, RemoteSocket};
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

-spec find_target(port()) -> {ok, binary(), binary()} | {error, term()}.
find_target(Socket) ->
    case gen_tcp:recv(Socket, 1) of
        {ok, <<Ver:8>>} ->
            find_target(Socket, Ver);
        {error, closed} ->
            {error, closed}
    end.

-spec find_target(port(), integer()) ->
    {ok, binary(), binary()}
    | {error, term()}.
find_target(Socket, 4) ->
    %% http://www.openssh.com/txt/socks4.protocol
    {ok, <<CD:8>>} = gen_tcp:recv(Socket, 1),
    case CD =:= 1 orelse CD =:= 2 of
        true ->
            ok;
        false ->
            CD1 = integer_to_list(CD),
            erlang:throw(<<"Socket4 Bad CD: ", CD1>>)
    end,

    {ok, <<Port:16, Address:32>>} = gen_tcp:recv(Socket, 6),

    _UserID = read_socks4_userid(Socket),
    Target = <<?IPV4, Port:16, Address:32>>,
    Response = <<0:8, 90:8, Port:16, Address:32>>,
    {ok, Target, Response};

find_target(Socket, 5) ->
    %% https://www.ietf.org/rfc/rfc1928.txt
    {ok, <<NMethods:8>>} = gen_tcp:recv(Socket, 1),
    {ok, _Methods} = gen_tcp:recv(Socket, NMethods),

    gen_tcp:send(Socket, <<5:8/integer, 0:8/integer>>),
    {ok, <<5:8, 1:8, _Rsv:8, AType:8>>} = gen_tcp:recv(Socket, 4),

    Target =
    case AType of
        ?IPV4 ->
            {ok, <<Address:32>>} = gen_tcp:recv(Socket, 4),
            {ok, <<Port:16>>} = gen_tcp:recv(Socket, 2),
            <<?IPV4, Port:16, Address:32>>;
        ?IPV6 ->
            {ok, <<Address:128>>} = gen_tcp:recv(Socket, 16),
            {ok, <<Port:16>>} = gen_tcp:recv(Socket, 2),
            <<?IPV6, Port:16, Address:128>>;
        ?DOMAIN ->
            {ok, <<DomainLen:8>>} = gen_tcp:recv(Socket, 1),
            {ok, <<DomainBin/binary>>} = gen_tcp:recv(Socket, DomainLen),
            {ok, <<Port:16>>} = gen_tcp:recv(Socket, 2),
            <<?DOMAIN, Port:16, DomainLen:8, DomainBin/binary>>
    end,

    Response = <<5, 0, 0, 1, <<0, 0, 0, 0>>/binary, 0:16>>,
    {ok, Target, Response};

find_target(_, Num) ->
    {error, <<"Socks Invalid Ver: ", Num>>}.

-spec read_socks4_userid(port()) -> binary().
read_socks4_userid(Socket) ->
    {ok, <<Part:8>>} = gen_tcp:recv(Socket, 1),
    read_socks4_userid(Socket, [], Part).

-spec read_socks4_userid(port(), list(), integer()) -> binary().
read_socks4_userid(_Socket, UserID, 0) ->
    list_to_binary(lists:reverse(UserID));

read_socks4_userid(Socket, UserID, Part) ->
    UserID1 = [Part | UserID],
    {ok, <<Part1:8>>} = gen_tcp:recv(Socket, 1),
    read_socks4_userid(Socket, UserID1, Part1).
