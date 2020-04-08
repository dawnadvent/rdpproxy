%%
%% rdpproxy
%% remote desktop proxy
%%
%% Copyright 2020 Alex Wilson <alex@uq.edu.au>
%% The University of Queensland
%% All rights reserved.
%%
%% Redistribution and use in source and binary forms, with or without
%% modification, are permitted provided that the following conditions
%% are met:
%% 1. Redistributions of source code must retain the above copyright
%%    notice, this list of conditions and the following disclaimer.
%% 2. Redistributions in binary form must reproduce the above copyright
%%    notice, this list of conditions and the following disclaimer in the
%%    documentation and/or other materials provided with the distribution.
%%
%% THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
%% IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
%% OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
%% IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT,
%% INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
%% NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
%% DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
%% THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
%% (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
%% THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
%%

-module(session_ra).
-behaviour(ra_machine).

-include_lib("kerlberos/include/pac.hrl").

-export([init/1, apply/3, state_enter/2]).
-export([start/0]).
-export([tick/0]).
-export([gen_key/0]).
-export([get_all_pools/0, get_pool/1, create_pool/1, update_pool/1]).
-export([claim_handle/1, get_handle/1]).
-export([create_host/1, update_host/1, enable_host/1, disable_host/1]).
-export([reserve/2, reserve_ip/2, allocate/2]).
-export([alloc_error/2]).
-export([add_session/2, status_report/2]).
-export([get_prefs/2, get_pools_for/1]).
-export([get_all_hosts/0, get_user_handles/1, get_host/1, get_all_handles/0]).
-export([host_error/2]).

-define(ALPHA, {$0,$1,$2,$3,$4,$5,$6,$7,$8,$9,
                $a,$b,$c,$d,$e,$f,$g,$h,$i,$j,
                $k,$l,$m,$n,$o,$p,$q,$r,$s,$t,
                $u,$v,$w,$x,$y,$z,
                $A,$B,$C,$D,$E,$F,$G,$H,$I,$J,
                $K,$L,$M,$N,$O,$P,$Q,$R,$S,$T,
                $U,$V,$W,$X,$Y,$Z}).
-define(SORT_VSN, 1).
-define(HISTORY_LIMIT, 16).

-export_types([handle/0, handle_state_nopw/0, handle_state_plain/0]).
-export_types([host_state/0, error_record/0, alloc_record/0, session_record/0]).
-export_types([pool_config/0, user_info/0]).

gen_key(0) -> [];
gen_key(N) ->
    A = ?ALPHA,
    [element(crypto:rand_uniform(1, size(A)+1), A) | gen_key(N - 1)].
gen_key() -> list_to_binary(gen_key(16)).


start() ->
    Config = application:get_env(rdpproxy, ra, []),
    Nodes = proplists:get_value(nodes, Config, [node() | nodes()]),
    Servers = [{?MODULE, N} || N <- Nodes],
    ra:start_or_restart_cluster(?MODULE_STRING, {module, ?MODULE, #{}}, Servers).

-spec tick() -> ok.
tick() ->
    T = erlang:system_time(second),
    case ra:process_command(?MODULE, {tick, T}) of
        {ok, Res, _Leader} -> Res;
        Else -> Else
    end.

-spec get_all_pools() -> [pool_config()].
get_all_pools() ->
    case ra:process_command(?MODULE, get_all_pools) of
        {ok, Res, _Leader} -> Res;
        Else -> Else
    end.

-spec get_pool(pool()) -> {ok, pool_config()} | {error, not_found}.
get_pool(Pool) ->
    case ra:process_command(?MODULE, {get_pool, Pool}) of
        {ok, Res, _Leader} -> Res;
        Else -> Else
    end.

-type user_info() :: #{
    user => username(),
    groups => [#sid{}]
    }.

-spec get_pools_for(user_info()) -> {ok, [pool()]}.
get_pools_for(UserInfo) ->
    case ra:process_command(?MODULE, {get_pools_for, UserInfo}) of
        {ok, Res, _Leader} -> Res;
        Else -> Else
    end.

-spec create_pool(pool_config()) -> ok | {error, already_exists}.
create_pool(PoolMap) ->
    case ra:process_command(?MODULE, {create_pool, PoolMap}) of
        {ok, Res, _Leader} -> Res;
        Else -> Else
    end.

-spec update_pool(pool_config()) -> ok | {error, not_found}.
update_pool(PoolMap) ->
    case ra:process_command(?MODULE, {update_pool, PoolMap}) of
        {ok, Res, _Leader} -> Res;
        Else -> Else
    end.

-spec get_all_hosts() -> {ok, [host_state()]}.
get_all_hosts() ->
    case ra:process_command(?MODULE, get_all_hosts) of
        {ok, Res, _Leader} -> Res;
        Else -> Else
    end.

-spec get_all_handles() -> {ok, [handle()]}.
get_all_handles() ->
    case ra:process_command(?MODULE, get_all_handles) of
        {ok, Res, _Leader} -> Res;
        Else -> Else
    end.

-spec get_user_handles(username()) -> {ok, [handle()]} | {error, not_found}.
get_user_handles(User) ->
    case ra:process_command(?MODULE, {get_user_handles, User}) of
        {ok, Res, _Leader} -> Res;
        Else -> Else
    end.

-spec get_host(ipstr()) -> {ok, host_state()}.
get_host(Ip) ->
    case ra:process_command(?MODULE, {get_host, Ip}) of
        {ok, Res, _Leader} -> Res;
        Else -> Else
    end.

-spec claim_handle(handle()) -> {ok, handle_state_plain()} | {error, not_found} | {error, bad_hdl_state}.
claim_handle(Hdl) ->
    Pid = self(),
    T = erlang:system_time(second),
    case ra:process_command(?MODULE, {claim_handle, T, Hdl, Pid}) of
        {ok, {ok, Data}, _Leader} ->
            #{ip := Ip, user := User, password := PwCrypt} = Data,
            Pw = decrypt(PwCrypt, <<Hdl/binary, Ip/binary, User/binary>>),
            {ok, Data#{password => Pw}};
        {ok, {conflict, OtherPid}, _Leader} ->
            exit(OtherPid, kill),
            timer:sleep(10),
            claim_handle(Hdl);
        {ok, Res, _Leader} -> Res;
        Else -> Else
    end.

-spec get_handle(handle()) -> {ok, handle_state_nopw()} | {error, not_found}.
get_handle(Hdl) ->
    T = erlang:system_time(second),
    case ra:process_command(?MODULE, {get_handle, T, Hdl}) of
        {ok, {ok, Data}, _Leader} ->
            DataNoPw = maps:remove(password, Data),
            {ok, DataNoPw};
        {ok, Res, _Leader} -> Res;
        Else -> Else
    end.

-spec create_host(host_state()) -> ok | {error, invalid_pool} | {error, duplicate_ip}.
create_host(Data) ->
    T = erlang:system_time(second),
    case ra:process_command(?MODULE, {create_host, T, Data}) of
        {ok, Res, _Leader} -> Res;
        Else -> Else
    end.

-spec update_host(host_state()) -> ok | {error, not_found}.
update_host(Data) ->
    T = erlang:system_time(second),
    case ra:process_command(?MODULE, {update_host, T, Data}) of
        {ok, Res, _Leader} -> Res;
        Else -> Else
    end.

-spec enable_host(ipstr()) -> ok | {error, not_found} | {error, already_enabled}.
enable_host(Ip) ->
    T = erlang:system_time(second),
    case ra:process_command(?MODULE, {enable_host, T, Ip}) of
        {ok, Res, _Leader} -> Res;
        Else -> Else
    end.

-spec disable_host(ipstr()) -> ok | {error, not_found} | {error, already_disabled}.
disable_host(Ip) ->
    T = erlang:system_time(second),
    case ra:process_command(?MODULE, {disable_host, T, Ip}) of
        {ok, Res, _Leader} -> Res;
        Else -> Else
    end.

-spec reserve(pool(), username()) -> {ok, Hdl :: binary(), handle_state()} | {error, no_hosts}.
reserve(Pool, User) ->
    T = erlang:system_time(second),
    Pid = self(),
    SortVsn = ?SORT_VSN,
    Hdl = gen_key(),
    case ra:process_command(?MODULE, {reserve, T, Hdl, Pool, SortVsn, User, Pid}) of
        {ok, Res, _Leader} -> Res;
        Else -> Else
    end.

-spec reserve_ip(username(), ipstr()) -> {ok, Hdl :: binary(), handle_state()} | {error, not_found}.
reserve_ip(User, Ip) ->
    T = erlang:system_time(second),
    Pid = self(),
    Hdl = gen_key(),
    case ra:process_command(?MODULE, {reserve, T, Hdl, User, Ip, Pid}) of
        {ok, Res, _Leader} -> Res;
        Else -> Else
    end.

-spec get_prefs(pool(), username()) -> {ok, [ipstr()]}.
get_prefs(Pool, User) ->
    T = erlang:system_time(second),
    SortVsn = ?SORT_VSN,
    case ra:process_command(?MODULE, {get_prefs, T, Pool, User, SortVsn}) of
        {ok, Res, _Leader} -> Res;
        Else -> Else
    end.

-spec allocate(handle(), handle_state_plain()) -> {ok, handle_state()} | {error, not_found}.
allocate(Hdl, HD0) ->
    T = erlang:system_time(second),
    Id = crypto:rand_uniform(0, 1 bsl 31),
    #{ip := Ip, user := User, password := Pw} = HD0,
    PwCrypt = encrypt(Pw, <<Hdl/binary, Ip/binary, User/binary>>),
    HD1 = HD0#{password => PwCrypt, sessid => Id},
    case ra:process_command(?MODULE, {allocate, T, Hdl, HD1}) of
        {ok, Res, _Leader} -> Res;
        Else -> Else
    end.

-spec alloc_error(handle(), any()) -> ok | {error, not_found}.
alloc_error(Hdl, Err) ->
    T = erlang:system_time(second),
    case ra:process_command(?MODULE, {alloc_error, T, Hdl, Err}) of
        {ok, Res, _Leader} -> Res;
        Else -> Else
    end.

-spec host_error(ipstr(), any()) -> ok | {error, not_found}.
host_error(Ip, Err) ->
    T = erlang:system_time(second),
    case ra:process_command(?MODULE, {host_error, T, Ip, Err}) of
        {ok, Res, _Leader} -> Res;
        Else -> Else
    end.

-spec add_session(ipstr(), session_record()) -> ok | {error, not_found}.
add_session(Ip, SessMap) ->
    T = erlang:system_time(second),
    case ra:process_command(?MODULE, {add_session, T, Ip, SessMap}) of
        {ok, Res, _Leader} -> Res;
        Else -> Else
    end.

-spec status_report(ipstr(), available | busy) -> ok | {error, not_found}.
status_report(Ip, State) ->
    T = erlang:system_time(second),
    case ra:process_command(?MODULE, {status_report, T, Ip, State}) of
        {ok, Res, _Leader} -> Res;
        Else -> Else
    end.

-spec encrypt(binary(), binary()) -> encrypted().
encrypt(D, MacExtraData) ->
    #{keys := KeyList} = maps:from_list(application:get_env(rdpproxy, ra, [])),
    {KeyRef, KeyNum} = lists:last(KeyList),
    Iv = crypto:strong_rand_bytes(16),
    Key = <<KeyNum:128/big>>,
    DLen = byte_size(D),
    PadLen = 16 - (DLen rem 16),
    DPad = <<D/binary, PadLen:PadLen/big-unit:8>>,
    DEnc = crypto:block_encrypt(aes_cbc128, Key, Iv, DPad),
    DMac = crypto:hmac(sha256, Key,
        <<KeyRef:16/big, Iv/binary, MacExtraData/binary, DEnc/binary>>),
    <<KeyRef:16/big,
      (byte_size(Iv)):16/big, Iv/binary,
      (byte_size(DEnc)):16/big, DEnc/binary,
      (byte_size(DMac)):16/big, DMac/binary>>.

-spec decrypt(encrypted(), binary()) -> binary().
decrypt(Crypted, MacExtraData) ->
    <<KeyRef:16/big,
      IvLen:16/big, Iv:IvLen/binary,
      DEncLen:16/big, DEnc:DEncLen/binary,
      DMacLen:16/big, DMac:DMacLen/binary>> = Crypted,
    #{keys := KeyList} = maps:from_list(application:get_env(rdpproxy, ra, [])),
    KeyMap = maps:from_list(KeyList),
    #{KeyRef := KeyNum} = KeyMap,
    Key = <<KeyNum:128/big>>,
    OurMac = crypto:hmac(sha256, Key,
        <<KeyRef:16/big, Iv/binary, MacExtraData/binary, DEnc/binary>>),
    OurMac = DMac,
    DPad = crypto:block_decrypt(aes_cbc128, Key, Iv, DEnc),
    PadLen = binary:last(DPad),
    DLen = byte_size(DPad) - PadLen,
    <<D:DLen/binary, PadLen:PadLen/big-unit:8>> = DPad,
    D.

-type handle() :: binary().

-type encrypted() :: binary().

-type time() :: integer().
-type reltime() :: integer().
-type username() :: binary().

-type pool() :: atom().
-type ipstr() :: binary().

-type sessid() :: integer().

-type acl_verb() :: allow | require | deny.
-type acl_entry() ::
    {acl_verb(), everybody} |
    {acl_verb(), user, binary()} |
    {acl_verb(), group, #sid{}}.

-spec match_rule(user_info(), acl_entry()) -> match | no_match.
match_rule(_UInfo, {_, everybody}) -> match;
match_rule(#{user := U}, {_, user, U}) -> match;
match_rule(#{user := _U}, {_, user, _}) -> no_match;
match_rule(#{groups := Gs}, {_, group, G}) ->
    case lists:member(G, Gs) of
        true -> match;
        _ -> no_match
    end;
match_rule(_UInfo, {_, group, _}) -> no_match.

-spec process_rules(user_info(), [acl_entry()]) -> allow | deny.
process_rules(_UInfo, []) -> allow;
process_rules(UInfo, [Rule | Rest]) ->
    Match = match_rule(UInfo, Rule),
    case {Match, element(1, Rule)} of
        {match, allow} -> allow;
        {match, deny} -> deny;
        {no_match, require} -> deny;
        _ -> process_rules(UInfo, Rest)
    end.

-type pool_config() :: #{
    id => atom(),

    % info for the menu if we have to present one
    title => binary(),
    help_text => binary(),
    acl => [acl_entry()],

    % can machines in this pool host more than one RDP session?
    mode => single_user | multi_user,
    % do users get to choose which available machine to use?
    choice => boolean(),

    % when we create a new backend based on a status report, and it has a "role"
    % field, that can be used to automatically assign a pool
    report_roles => [binary()],

    %
    % timing settings for the pool
    %
    % never send someone different within
    min_rsvd_time => reltime(),
    % keep handle alive after disconnect for
    hdl_expiry_time => reltime()
    }.

-type error_record() :: #{
    time => time(),
    error => any()
    }.

-type alloc_record() :: #{
    time => time(),
    user => username(),
    hdl => handle()
    }.

-type session_record() :: #{
    time => time(),
    user => username(),
    type => binary(),
    id => integer()
    }.

-type host_state() :: #{
    ip => ipstr(),
    hostname => binary(),
    port => integer(),
    enabled => boolean(),
    last_update => time(),
    pool => atom(),
    desc => none | binary(),

    handles => [handle()],

    error_history => queue:queue(error_record()),
    alloc_history => queue:queue(alloc_record()),
    session_history => queue:queue(session_record()),

    idle_from => none | time(),
    report_state => {available | busy, time()},
    last_report => none | time(),

    image => none | binary(),
    role => none | binary(),
    hypervisor => unknown | ipstr()
    }.

-type handle_state() :: #{
    handle => handle(),

    start => time(),
    min => time(),
    expiry => connected | time(),

    pid => none | pid(),
    state => probe | error | ok,

    user => username(),
    ip => ipstr(),
    port => integer(),

    % not filled out during "probe" state
    password => none | encrypted(),
    domain => none | binary(),
    sessid => none | sessid()
    }.

-type handle_state_nopw() :: #{
    handle => handle(),

    start => time(),
    min => time(),
    expiry => connected | time(),

    pid => none | pid(),
    state => probe | error | ok,

    user => username(),
    ip => ipstr(),
    port => integer(),

    % not filled out during "probe" state
    domain => none | binary(),
    sessid => none | sessid()
    }.

-type handle_state_plain() :: #{
    handle => handle(),

    start => time(),
    min => time(),
    expiry => connected | time(),

    pid => none | pid(),
    state => probe | error | ok,

    user => username(),
    ip => ipstr(),
    port => integer(),

    % not filled out during "probe" state
    password => none | binary(),
    domain => none | binary(),
    sessid => none | sessid()
    }.

-record(?MODULE, {
    pools = #{} :: #{pool() => pool_config()},
    meta = #{} :: #{ipstr() => host_state()},
    users = #{} :: #{username() => queue:queue(handle())},
    hdls = #{} :: #{handle() => handle_state()},
    hdlexp = gb_trees:empty() :: gb_trees:tree(time(), [handle()]),
    watches = #{} :: #{pid() => handle()},
    last_time = 0 :: time()
    }).

init(_Config) ->
    DefaultPool = #{
        id => default,
        title => <<"default">>,
        help_text => <<>>,
        acl => [{deny, everybody}],
        mode => single_user,
        choice => false,
        report_roles => [],
        min_rsvd_time => 900,
        hdl_expiry_time => 900
    },
    #?MODULE{pools = #{default => DefaultPool}}.

apply(#{index := Idx}, {tick, T}, S0 = #?MODULE{}) ->
    S1 = expire_hdls(T, S0),
    S2 = S1#?MODULE{last_time = T},
    {S2, ok, [{release_cursor, Idx, S2}]};

apply(_Meta, get_all_pools, S0 = #?MODULE{pools = P0}) ->
    {S0, {ok, maps:values(P0)}, []};

apply(_Meta, get_all_handles, S0 = #?MODULE{hdls = H0}) ->
    {S0, {ok, maps:values(H0)}, []};

apply(_Meta, {get_pool, Pool}, S0 = #?MODULE{pools = P0}) ->
    case P0 of
        #{Pool := PD0} ->
            {S0, {ok, PD0}, []};
        _ ->
            {S0, {error, not_found}, []}
    end;

apply(_Meta, {get_pools_for, UInfo}, S0 = #?MODULE{pools = P0}) ->
    Pools = lists:filter(fun (PD) ->
        #{acl := ACL} = PD,
        case process_rules(UInfo, ACL) of
            allow -> true;
            deny -> false
        end
    end, maps:values(P0)),
    {S0, {ok, Pools}, []};

apply(_Meta, {create_pool, PD0}, S0 = #?MODULE{pools = P0}) ->
    #{id := Pool} = PD0,
    case P0 of
        #{Pool := _} ->
            {S0, {error, already_exists}, []};
        _ ->
            PD1 = #{
                id => Pool,
                title => maps:get(title, PD0, atom_to_binary(Pool, latin1)),
                help_text => maps:get(help_text, PD0, <<>>),
                acl => maps:get(acl, PD0, [{deny, everybody}]),
                mode => maps:get(mode, PD0, single_user),
                choice => maps:get(choice, PD0, false),
                report_roles => maps:get(report_roles, PD0, []),
                min_rsvd_time => maps:get(min_rsvd_time, PD0, 900),
                hdl_expiry_time => maps:get(hdl_expiry_time, PD0, 900)
            },
            P1 = P0#{Pool => PD1},
            S1 = S0#?MODULE{pools = P1},
            {S1, ok, []}
    end;

apply(_Meta, {update_pool, PCh}, S0 = #?MODULE{pools = P0}) ->
    #{id := Pool} = PCh,
    case P0 of
        #{Pool := PD0} ->
            PD1 = maps:map(fun (K, V0) ->
                case {K, PCh} of
                    {title, #{K := V1}} when is_binary(V1) -> V1;
                    {help_text, #{K := V1}} when is_binary(V1) -> V1;
                    {acl, #{K := V1}} when is_list(V1) -> V1;
                    {choice, #{K := V1}} when is_boolean(V1) -> V1;
                    {mode, #{K := V1}} when is_atom(V1) -> V1;
                    {report_roles, #{K := V1}} when is_list(V1) -> V1;
                    {min_rsvd_time, #{K := V1}} when is_integer(V1) -> V1;
                    {hdl_expiry_time, #{K := V1}} when is_integer(V1) -> V1;
                    _ -> V0
                end
            end, PD0),
            P1 = P0#{Pool => PD1},
            S1 = S0#?MODULE{pools = P1},
            {S1, ok, []};
        _ ->
            {S0, {error, not_found}, []}
    end;

apply(_Meta, get_all_hosts, S0 = #?MODULE{meta = M0}) ->
    {S0, {ok, maps:values(M0)}, []};

apply(_Meta, {get_user_handles, User}, S0 = #?MODULE{users = U0, hdls = H0}) ->
    case U0 of
        #{User := HdlQ} ->
            Hdls = lists:map(fun (Hdl) ->
                case H0 of
                    #{Hdl := HD} -> HD#{handle => Hdl};
                    _ -> #{handle => Hdl}
                end
            end, queue:to_list(HdlQ)),
            {S0, {ok, Hdls}, []};
        _ ->
            {S0, {error, not_found}, []}
    end;

apply(_Meta, {get_host, Ip}, S0 = #?MODULE{meta = M0}) ->
    case M0 of
        #{Ip := HM} -> {S0, {ok, HM}, []};
        _ -> {S0, {error, not_found}, []}
    end;

apply(_Meta, {claim_handle, _T, Hdl, Pid},
                    S0 = #?MODULE{hdls = H0, watches = W0, hdlexp = HT0}) ->
    case H0 of
        #{Hdl := HD0 = #{pid := none, state := ok, expiry := Exp}} ->
            % Remove from expiry tree
            Hdls0 = gb_trees:get(Exp, HT0),
            Hdls1 = Hdls0 -- [Hdl],
            HT1 = gb_trees:update(Exp, Hdls1, HT0),
            % Update actual handle state
            HD1 = HD0#{pid => Pid, expiry => connected},
            W1 = W0#{Pid => Hdl},
            H1 = H0#{Hdl => HD1},
            % Add monitor
            Effects = [{monitor, process, Pid}],
            S1 = S0#?MODULE{hdls = H1, watches = W1, hdlexp = HT1},
            {S1, {ok, HD1}, Effects};
        #{Hdl := #{pid := OtherPid, state := ok}} ->
            {S0, {conflict, OtherPid}, []};
        #{Hdl := _} ->
            {S0, {error, bad_hdl_state}, []};
        _ ->
            {S0, {error, not_found}, []}
    end;

apply(_Meta, {get_handle, _T, Hdl}, S0 = #?MODULE{hdls = H0}) ->
    case H0 of
        #{Hdl := HD} ->
            {S0, {ok, HD}, []};
        _ ->
            {S0, {error, not_found}, []}
    end;

apply(_Meta, {create_host, T, Map}, S0 = #?MODULE{meta = M0, pools = P0}) ->
    #{ip := Ip} = Map,
    case M0 of
        #{Ip := _} ->
            {S0, {error, duplicate_ip}, []};
        _ ->
            Pool = case Map of
                #{pool := P} -> P;
                #{role := Role} ->
                    Ps = maps:fold(fun (P, PConf, Acc) ->
                        case PConf of
                            #{report_roles := Roles} ->
                                case lists:member(Role, Roles) of
                                    true -> [P | Acc];
                                    false -> Acc
                                end;
                            _ -> Acc
                        end
                    end, [], P0),
                    case Ps of
                        [P | _] -> P;
                        _ -> undefined
                    end
            end,
            case P0 of
                #{Pool := _PConf} ->
                    HM0 = #{
                        ip => maps:get(ip, Map),
                        hostname => maps:get(hostname, Map),
                        port => maps:get(port, Map, 3389),
                        enabled => false,
                        last_update => T,
                        pool => Pool,
                        handles => [],
                        desc => maps:get(desc, Map, none),
                        error_history => queue:new(),
                        alloc_history => queue:new(),
                        session_history => queue:new(),
                        idle_from => none,
                        report_state => {available, T},
                        last_report => none,
                        image => maps:get(image, Map, none),
                        role => maps:get(role, Map, none),
                        hypervisor => maps:get(hypervisor, Map, unknown)
                    },
                    M1 = M0#{Ip => HM0},
                    S1 = S0#?MODULE{meta = M1},
                    {S1, ok, []};
                _ ->
                    {S0, {error, invalid_pool}, []}
            end
    end;

apply(_Meta, {update_host, T, CM}, S0 = #?MODULE{meta = M0}) when is_map(CM) ->
    #{ip := Ip} = CM,
    case M0 of
        #{Ip := HM0} ->
            HM1 = maps:map(fun (K, V0) ->
                case {K, CM} of
                    {hostname, #{K := V1}} when is_binary(V1) -> V1;
                    {port, #{K := V1}} when is_integer(V1) -> V1;
                    {pool, #{K := V1}} when is_atom(V1) -> V1;
                    {idle_from, #{K := V1}} when is_integer(V1) -> V1;
                    {image, #{K := V1}} when is_binary(V1) -> V1;
                    {role, #{K := V1}} when is_binary(V1) -> V1;
                    {hypervisor, #{K := V1}} when is_binary(V1) -> V1;
                    {desc, #{K := V1}} when is_binary(V1) -> V1;
                    _ -> V0
                end
            end, HM0),
            HM2 = HM1#{last_update => T},
            M1 = M0#{Ip => HM2},
            S1 = S0#?MODULE{meta = M1},
            {S1, ok, []};
        _ ->
            {S0, {error, not_found}, []}
    end;

apply(_Meta, {enable_host, T, Ip}, S0 = #?MODULE{meta = M0}) ->
    case M0 of
        #{Ip := #{enabled := true}} ->
            {S0, {error, already_enabled}, []};
        #{Ip := HM0 = #{enabled := false}} ->
            HM1 = HM0#{enabled => true, last_update => T},
            M1 = M0#{Ip => HM1},
            S1 = S0#?MODULE{meta = M1},
            {S1, ok, []};
        _ ->
            {S0, {error, not_found}, []}
    end;

apply(_Meta, {disable_host, T, Ip}, S0 = #?MODULE{meta = M0}) ->
    case M0 of
        #{Ip := #{enabled := false}} ->
            {S0, {error, already_disabled}, []};
        #{Ip := HM0 = #{enabled := true}} ->
            HM1 = HM0#{enabled => false, last_update => T},
            M1 = M0#{Ip => HM1},
            S1 = S0#?MODULE{meta = M1},
            {S1, ok, []};
        _ ->
            {S0, {error, not_found}, []}
    end;

apply(_Meta, {get_prefs, T, Pool, User, SortVsn}, S0 = #?MODULE{}) ->
    UserPrefs = user_existing_hosts(User, Pool, S0),
    Prefs0 = sort_prefs(SortVsn, Pool, S0),
    Prefs1 = filter_min_reserved(T, User, Prefs0, S0),
    Prefs2 = UserPrefs ++ (Prefs1 -- UserPrefs),
    {S0, {ok, Prefs2}, []};

apply(_Meta, {reserve, T, Hdl, Pool, SortVsn, User, Pid}, S0 = #?MODULE{hdls = H0}) ->
    case H0 of
        #{Hdl := _} ->
            {S0, {error, duplicate_handle}, []};
        _ ->
            case user_existing_hosts(User, Pool, S0) of
                [Ip | _] ->
                    {S1, H, Effects} = begin_handle(Hdl, T, User, Ip, Pid, S0),
                    {S1, {ok, Hdl, H}, Effects};
                _ ->
                    Prefs = sort_prefs(SortVsn, Pool, S0),
                    PrefsAv = filter_min_reserved(T, User, Prefs, S0),
                    case PrefsAv of
                        [Ip | _] ->
                            {S1, H, Effects} = begin_handle(Hdl, T, User, Ip,
                                Pid, S0),
                            {S1, {ok, Hdl, H}, Effects};
                        [] ->
                            {S0, {error, no_hosts}, []}
                    end
            end
    end;

apply(_Meta, {reserve, T, Hdl, User, Ip, Pid},
                                    S0 = #?MODULE{meta = M0, hdls = H0}) ->
    case H0 of
        #{Hdl := _} ->
            {S0, {error, duplicate_handle}, []};
        _ ->
            case M0 of
                #{Ip := _} ->
                    {S1, H, Effects} = begin_handle(Hdl, T, User, Ip, Pid, S0),
                    {S1, {ok, Hdl, H}, Effects};
                _ ->
                    {S0, {error, host_not_found}, []}
            end
    end;

apply(_Meta, {allocate, T, Hdl, Attrs}, S0 = #?MODULE{meta = M0, hdls = H0}) ->
    case H0 of
        #{Hdl := HD0 = #{ip := Ip, user := User}} ->
            case Attrs of
                #{ip := Ip} -> ok;
                #{ip := TheirIp} ->
                    lager:warning("allocate ip mismatch: fsm has ~p, "
                        "client has ~p", [Ip, TheirIp]);
                _ -> ok
            end,
            #{Ip := HM0} = M0,
            #{alloc_history := AHist0} = HM0,
            AHist1 = queue:in(#{time => T, user => User, hdl => Hdl}, AHist0),
            AHist2 = case queue:len(AHist1) of
                N when (N > ?HISTORY_LIMIT) ->
                    {{value, _}, Q} = queue:out(AHist1),
                    Q;
                _ -> AHist1
            end,
            HM1 = HM0#{alloc_history => AHist2},
            M1 = M0#{Ip => HM1},
            HD1 = HD0#{state => ok},
            HD2 = maps:map(fun (K, V0) ->
                case {K, Attrs} of
                    {password, #{K := V1}} when is_binary(V1) -> V1;
                    {domain, #{K := V1}} when is_binary(V1) -> V1;
                    {sessid, #{K := V1}} when is_integer(V1) -> V1;
                    _ -> V0
                end
            end, HD1),
            H1 = H0#{Hdl => HD2},
            S1 = S0#?MODULE{meta = M1, hdls = H1},
            {S1, {ok, HD2}, []};
        _ ->
            {S0, {error, not_found}, []}
    end;

apply(_Meta, {alloc_error, T, Hdl, Err}, S0 = #?MODULE{meta = M0, hdls = H0}) ->
    case H0 of
        #{Hdl := HD0 = #{ip := Ip}} ->
            #{Ip := HM0} = M0,
            #{error_history := EHist0} = HM0,
            EHist1 = queue:in(#{time => T, error => Err}, EHist0),
            EHist2 = case queue:len(EHist1) of
                N when (N > ?HISTORY_LIMIT) ->
                    {{value, _}, Q} = queue:out(EHist1),
                    Q;
                _ -> EHist1
            end,
            HM1 = HM0#{error_history => EHist2},
            M1 = M0#{Ip => HM1},
            HD1 = HD0#{state => error},
            H1 = H0#{Hdl => HD1},
            S1 = S0#?MODULE{meta = M1, hdls = H1},
            {S1, ok, []};
        _ ->
            {S0, {error, not_found}, []}
    end;

apply(_Meta, {host_error, T, Ip, Err}, S0 = #?MODULE{meta = M0}) ->
    case M0 of
        #{Ip := HM0} ->
            #{error_history := EHist0} = HM0,
            EHist1 = queue:in(#{time => T, error => Err}, EHist0),
            EHist2 = case queue:len(EHist1) of
                N when (N > ?HISTORY_LIMIT) ->
                    {{value, _}, Q} = queue:out(EHist1),
                    Q;
                _ -> EHist1
            end,
            HM1 = HM0#{error_history => EHist2},
            M1 = M0#{Ip => HM1},
            S1 = S0#?MODULE{meta = M1},
            {S1, ok, []};
        _ ->
            {S0, {error, not_found}, []}
    end;

apply(_Meta, {add_session, _T, Ip, SessMap}, S0 = #?MODULE{meta = M0}) ->
    case M0 of
        #{Ip := HM0 = #{session_history := SHist0}} ->
            SHist1 = queue:in(SessMap, SHist0),
            SHist2 = case queue:len(SHist1) of
                N when (N > ?HISTORY_LIMIT) ->
                    {{value, _}, Q} = queue:out(SHist1),
                    Q;
                _ -> SHist1
            end,
            HM1 = HM0#{session_history => SHist2},
            M1 = M0#{Ip => HM1},
            S1 = S0#?MODULE{meta = M1},
            {S1, ok, []};
        _ ->
            {S0, {error, not_found}, []}
    end;

apply(_Meta, {status_report, T, Ip, State}, S0 = #?MODULE{meta = M0}) ->
    case M0 of
        #{Ip := HM0 = #{report_state := {State, _}}} ->
            HM1 = HM0#{last_report => T},
            M1 = M0#{Ip => HM1},
            S1 = S0#?MODULE{meta = M1},
            {S1, ok, []};
        #{Ip := HM0} ->
            HM1 = HM0#{report_state => {State, T}, last_report => T},
            M1 = M0#{Ip => HM1},
            S1 = S0#?MODULE{meta = M1},
            {S1, ok, []};
        _ ->
            {S0, {error, not_found}, []}
    end;

apply(_Meta, {down, Pid, noconnection}, S0 = #?MODULE{}) ->
    {S0, ok, [{monitor, node, node(Pid)}]};

apply(_Meta, {down, Pid, _Reason}, S0 = #?MODULE{watches = W0, last_time = T}) ->
    % Find the handle state
    #{Pid := Hdl} = W0,
    S1 = detach_handle(Hdl, T, S0),
    {S1, ok, []};

apply(_Meta, {nodeup, Node}, S0 = #?MODULE{watches = W0}) ->
    Effects = maps:fold(fun
        (Pid, _Hdl, Acc) when (node(Pid) =:= Node) ->
            [{monitor, process, Pid} | Acc];
        (_Pid, _Hdl, Acc) -> Acc
    end, [], W0),
    {S0, ok, Effects};

apply(_Meta, {nodedown, _}, S0 = #?MODULE{}) ->
    {S0, ok, []}.

state_enter(leader, #?MODULE{watches = W0}) ->
    maps:fold(fun (Pid, _Hdl, Acc) ->
        [{monitor, process, Pid} | Acc]
    end, [], W0);
state_enter(_, #?MODULE{}) -> [].

expire_hdls(T, S0 = #?MODULE{hdlexp = HT0}) ->
    case gb_trees:is_empty(HT0) of
        true -> S0;
        false ->
            {TE, Hdls, HT1} = gb_trees:take_smallest(HT0),
            if
                (T > TE) ->
                    S1 = S0#?MODULE{hdlexp = HT1},
                    S2 = lists:foldl(fun kill_handle/2, S1, Hdls),
                    expire_hdls(T, S2);
                true ->
                    S0
            end
    end.

-spec kill_handle(handle(), #?MODULE{}) -> #?MODULE{}.
kill_handle(Hdl, S0 = #?MODULE{hdls = H0, meta = M0}) ->
    % No need to remove from the expiry tree (we're only called in expire_hdls)
    % Remove the record of the handle itself
    #{Hdl := #{ip := Ip}} = H0,
    H1 = maps:remove(Hdl, H0),
    % Also remove the handle from the hosts handles list
    #{Ip := HM0 = #{handles := HH0}} = M0,
    HH1 = HH0 -- [Hdl],
    HM1 = HM0#{handles => HH1},
    M1 = M0#{Ip => HM1},
    S0#?MODULE{hdls = H1, meta = M1}.

detach_handle(Hdl, T, S0 = #?MODULE{hdls = H0, meta = M0, pools = P0,
                                    hdlexp = HT0, watches = W0}) ->
    % Find handle state
    #{Hdl := HS0} = H0,
    #{pid := Pid} = HS0,
    % We're detaching, so it must be attached
    true = is_pid(Pid),

    % Get the expiry time for the pool
    #{ip := Ip} = HS0,
    #{Ip := #{pool := Pool}} = M0,
    #{Pool := #{hdl_expiry_time := TDelta}} = P0,

    % Since they've disconnected, we now set this handle to expire if they
    % don't reconnect
    NewExpiry = T + TDelta,

    % Update the expiry tree
    #{expiry := connected} = HS0,
    HT1 = case gb_trees:lookup(NewExpiry, HT0) of
        none -> gb_trees:insert(NewExpiry, [Hdl], HT0);
        {value, Hdls0} -> gb_trees:update(NewExpiry, [Hdl | Hdls0], HT0)
    end,

    % Update the handle state and remove the watch
    HS1 = HS0#{expiry => NewExpiry, pid => none},
    H1 = H0#{Hdl => HS1},
    W1 = maps:remove(Pid, W0),

    S0#?MODULE{watches = W1, hdls = H1, hdlexp = HT1}.

-spec begin_handle(handle(), time(), username(), ipstr(), pid(), #?MODULE{}) -> {#?MODULE{}, handle_state(), [any()]}.
begin_handle(Hdl, T, User, Ip, Pid, S0 = #?MODULE{}) ->
    % Check for and detach any existing handle for this pid
    S1 = case S0#?MODULE.watches of
        #{Pid := OldHdl} -> detach_handle(OldHdl, T, S0);
        _ -> S0
    end,
    #?MODULE{hdls = H0, meta = M0, users = U0, watches = W0} = S1,
    % Add the handle to the host list
    #{Ip := HM0 = #{handles := HH0, pool := P, port := Port}} = M0,
    HH1 = [Hdl | HH0],
    M1 = M0#{Ip => HM0#{handles => HH1}},
    % Add it to the recent handles queue for the user
    U1 = case U0 of
        #{User := UH0} ->
            UH1 = queue:in(Hdl, UH0),
            U0#{User => UH1};
        _ ->
            UH0 = queue:from_list([Hdl]),
            U0#{User => UH0}
    end,
    % Add the watch on the owner pid
    W1 = W0#{Pid => Hdl},
    Effects = [{monitor, process, Pid}],
    % Get pool info
    #?MODULE{pools = #{P := PConfig}} = S0,
    #{min_rsvd_time := MinDelta} = PConfig,
    % And finally add the actual handle state
    HD = #{
        handle => Hdl,
        start => T,
        min => T + MinDelta,
        expiry => connected,
        pid => Pid,
        state => probe,
        user => User,
        ip => Ip,
        port => Port,
        password => none,
        domain => none,
        sessid => none
    },
    H1 = H0#{Hdl => HD},
    S2 = S1#?MODULE{hdls = H1, meta = M1, users = U1, watches = W1},
    {S2, HD, Effects}.

-spec filter_min_reserved(time(), username(), [ipstr()], #?MODULE{}) -> [ipstr()].
filter_min_reserved(T, User, Ips, #?MODULE{meta = M0, hdls = H0}) ->
    lists:filter(fun (Ip) ->
        #{Ip := HM} = M0,
        case HM of
            #{enabled := false} -> false;
            #{handles := [Hdl | _]} ->
                case H0 of
                    #{Hdl := #{user := User}} -> true;
                    #{Hdl := #{state := error}} -> true;
                    #{Hdl := #{min := TE}} when (T > TE) -> true;
                    #{Hdl := _} -> false;
                    _ -> true
                end;
            _ -> true
        end
    end, Ips).

-spec user_existing_hosts(username(), pool(), #?MODULE{}) -> [ipstr()].
user_existing_hosts(User, Pool, #?MODULE{meta = M0, users = U0, hdls = H0}) ->
    % First, look at all recent reservations which belong to this user.
    % If we have any, keep track of the last handle we had each host (so
    % we can see if it was an error or a good alloc)
    LastHMs = case U0 of
        #{User := UH0} ->
            lists:foldl(fun (Hdl, Acc) ->
                case H0 of
                    #{Hdl := HD = #{ip := Ip}} ->
                        Acc#{Ip => {Hdl, HD}};
                    _ -> Acc
                end
            end, #{}, queue:to_list(UH0));
        _ ->
            #{}
    end,
    % Then look through all hosts which have their latest reported session
    % set to this user. If the session started after the last handle we have,
    % override it.
    %
    % Also if the machine reports a session for another user which started
    % >15min after the handle, don't use that machine.
    WithSess = maps:fold(fun (Ip, HM0, Acc) ->
        #{session_history := SHist0} = HM0,
        case queue:out_r(SHist0) of
            {{value, #{user := User, time := T0}}, _} ->
                case Acc of
                    #{Ip := {_Hdl, #{time := TH}}} when (TH >= T0) ->
                        Acc;
                    _ ->
                        Acc#{Ip => {none, #{time => T0, state => ok}}}
                end;
            {{value, #{time := T0}}, _} ->
                case Acc of
                    #{Ip := {_Hdl, #{time := TH, state := ok}}}
                            when ((TH + 900) < T0) ->
                        maps:remove(Ip, Acc);
                    _ ->
                        Acc
                end;
            _ -> Acc
        end
    end, LastHMs, M0),
    % Finally, check all of the hosts we found above for being enabled and not
    % carrying any other reservations.
    ToGive = maps:fold(fun
        (Ip, {none, #{state := ok}}, Acc) ->
            case M0 of
                #{Ip := #{pool := Pool, enabled := true, handles := [Hdl|_]}} ->
                    case H0 of
                        #{Hdl := #{user := User}} -> [Ip | Acc];
                        #{Hdl := #{}} -> Acc;
                        _ -> [Ip | Acc]
                    end;
                #{Ip := #{pool := Pool, enabled := true}} ->
                    [Ip | Acc];
                _ -> Acc
            end;
        (Ip, {Hdl, #{state := ok}}, Acc) ->
            case M0 of
                #{Ip := #{pool := Pool, enabled := true, handles := [Hdl|_]}} ->
                    [Ip | Acc];
                _ -> Acc
            end;
        (_Ip, _, Acc) -> Acc
    end, [], WithSess),
    lists:sort(fun (IpA, IpB) ->
        #{IpA := A, IpB := B} = M0,
        #{alloc_history := AHistA,
          session_history := SHistA} = A,
        ALatestA = case queue:out_r(AHistA) of
            {{value, #{time := ALAT}}, _} -> ALAT;
            _ -> 0
        end,
        SLatestA = case queue:out_r(SHistA) of
            {{value, #{time := SLAT}}, _} -> SLAT;
            _ -> 0
        end,
        SALatestA = lists:max([ALatestA, SLatestA]),

        #{alloc_history := AHistB,
          session_history := SHistB} = B,
        ALatestB = case queue:out_r(AHistB) of
            {{value, #{time := ALBT}}, _} -> ALBT;
            _ -> 0
        end,
        SLatestB = case queue:out_r(SHistB) of
            {{value, #{time := SLBT}}, _} -> SLBT;
            _ -> 0
        end,
        SALatestB = lists:max([ALatestB, SLatestB]),

        if
            % prefer the machine they used most recently
            (SALatestA > SALatestB) -> true;
            (SALatestA < SALatestB) -> false;
            % failing everything else, sort by IP
            (IpA < IpB) -> true;
            (IpA > IpB) -> false
        end
    end, ToGive).

-spec sort_prefs(Vsn :: integer(), Pool :: atom(), #?MODULE{}) -> [ipstr()].
sort_prefs(1, Pool, #?MODULE{meta = M, hdls = H}) ->
    SortFun = fun(IpA, IpB) ->
        #{IpA := A, IpB := B} = M,
        #{role := RoleA, image := ImageA, idle_from := IdleFromA} = A,
        #{role := RoleB, image := ImageB, idle_from := IdleFromB} = B,

        #{error_history := EHistA, alloc_history := AHistA,
          session_history := SHistA} = A,
        ELatestA = case queue:out_r(EHistA) of
            {{value, #{time := ELAT}}, _} -> ELAT;
            _ -> 0
        end,
        ALatestA = case queue:out_r(AHistA) of
            {{value, #{time := ALAT}}, _} -> ALAT;
            _ -> 0
        end,
        SLatestA = case queue:out_r(SHistA) of
            {{value, #{time := SLAT}}, _} -> SLAT;
            _ -> 0
        end,
        SALatestA = lists:max([ALatestA, SLatestA]),

        #{error_history := EHistB, alloc_history := AHistB,
          session_history := SHistB} = B,
        ELatestB = case queue:out_r(EHistB) of
            {{value, #{time := ELBT}}, _} -> ELBT;
            _ -> 0
        end,
        ALatestB = case queue:out_r(AHistB) of
            {{value, #{time := ALBT}}, _} -> ALBT;
            _ -> 0
        end,
        SLatestB = case queue:out_r(SHistB) of
            {{value, #{time := SLBT}}, _} -> SLBT;
            _ -> 0
        end,
        SALatestB = lists:max([ALatestB, SLatestB]),

        InErrorA = (ELatestA > ALatestA),
        InErrorB = (ELatestB > ALatestB),

        #{report_state := {RepStateA, RepStateChangedA}} = A,
        #{report_state := {RepStateB, RepStateChangedB}} = B,

        IsLabA = if
            is_binary(ImageA) ->
                (binary:longest_common_prefix([ImageA, <<"lab">>]) =/= 0);
            true -> false
        end,
        IsLabB = if
            is_binary(ImageB) ->
                (binary:longest_common_prefix([ImageB, <<"lab">>]) =/= 0);
            true -> false
        end,

        {ReservedA, ResvdTimeA} = case A of
            #{handles := [HdlA | _]} ->
                case H of
                    #{HdlA := #{state := error}} -> {false, 0};
                    #{HdlA := #{start := TRA}} -> {true, TRA};
                    _ -> {false, 0}
                end;
            _ -> {false, 0}
        end,
        {ReservedB, ResvdTimeB} = case B of
            #{handles := [HdlB | _]} ->
                case H of
                    #{HdlB := #{state := error}} -> {false, 0};
                    #{HdlB := #{start := TRB}} -> {true, TRB};
                    _ -> {false, 0}
                end;
            _ -> {false, 0}
        end,

        % A <= B  => true
        % else    => false
        %
        % lists:sort sorts ascending, and we are going to start at the front,
        % so more preferred => return true
        if
            % prefer machines where the latest event wasn't an error
            (not InErrorA) and InErrorB -> true;
            InErrorA and (not InErrorB) -> false;
            % prefer machines without a current reservation
            ReservedA and (not ReservedB) -> false;
            (not ReservedA) and ReservedB -> true;
            % prefer machines whose last status report was available, if
            % the report was after the last session/allocation
            (RepStateChangedA > SALatestA) and (RepStateA =:= available) and
                (RepStateB =:= busy) -> true;
            (RepStateA =:= busy) and (RepStateChangedB > SALatestB) and
                (RepStateB =:= available) -> false;
            % prefer machines with role == vlab
            (RoleA =:= <<"vlab">>) and (not (RoleB =:= <<"vlab">>)) -> true;
            (not (RoleA =:= <<"vlab">>)) and (RoleB =:= <<"vlab">>) -> false;
            % prefer lab images
            IsLabA and (not IsLabB) -> true;
            (not IsLabA) and IsLabB -> false;
            % prefer recent images
            (ImageA > ImageB) -> true;
            (ImageA < ImageB) -> false;
            % for machines which are reserved, pick longest idle first
            ReservedA and ReservedB and
                (not (IdleFromA =:= none)) and (not (IdleFromB =:= none)) and
                (IdleFromA < IdleFromB) -> true;
            ReservedA and ReservedB and
                (not (IdleFromA =:= none)) and (not (IdleFromB =:= none)) and
                (IdleFromA > IdleFromB) -> false;
            % if we don't have an idle time (it might not be reported) use
            % the time we reserved it
            ReservedA and ReservedB and (ResvdTimeA < ResvdTimeB) -> true;
            ReservedA and ReservedB and (ResvdTimeA > ResvdTimeB) -> false;
            % prefer machines where the last alloc or session start was further
            % in the past
            (SALatestA < SALatestB) -> true;
            (SALatestA > SALatestB) -> false;
            % last error further in the past
            (ELatestA < ELatestB) -> true;
            (ELatestA > ELatestB) -> false;
            % failing everything else, sort by IP
            (IpA < IpB) -> true;
            (IpA > IpB) -> false
        end
    end,
    Ips = maps:fold(fun (Ip, HM, Acc) ->
        case HM of
            #{pool := Pool, enabled := true} -> [Ip | Acc];
            _ -> Acc
        end
    end, [], M),
    lists:sort(SortFun, Ips).
