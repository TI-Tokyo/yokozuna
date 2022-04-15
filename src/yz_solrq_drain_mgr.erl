%% -------------------------------------------------------------------
%%
%% Copyright (c) 2015 Basho Technologies, Inc.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------
-module(yz_solrq_drain_mgr).

-behaviour(gen_server).

%% API
-export([start_link/0, drain/0, drain/1, cancel/2]).

%% gen_server callbacks
-export([init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3]).

-include("yokozuna.hrl").
-include_lib("kernel/include/logger.hrl").

-define(SERVER, ?MODULE).

-record(state, {draining = [] :: [p()]}).

%%%===================================================================
%%% API
%%%===================================================================

-spec(start_link() ->
    {ok, Pid :: pid()} | ignore | {error, Reason :: term()}).
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @doc Drain all queues to Solr
-spec drain() -> ok | {error, Reason :: term()}.
drain() ->
    drain([]).

%% @doc Drain all queues to Solr
-spec drain(drain_params()) -> ok | {error, Reason :: term()}.
drain(Params) ->
    gen_server:call(?SERVER, {drain, Params}, infinity).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([]) ->
    schedule_tick(),
    {ok, #state{}}.

handle_call({drain, Params}, From, #state{draining=Draining} = State) ->
    ExchangeFSMPid = proplists:get_value(
        ?EXCHANGE_FSM_PID, Params, undefined
    ),
    PartitionToDrain = proplists:get_value(
        ?DRAIN_PARTITION, Params, undefined
    ),
    AlreadyDraining = lists:member(PartitionToDrain, Draining),
    case AlreadyDraining of
        true ->
            logger:debug("Drain in progress."),
            maybe_exchange_fsm_drain_error(ExchangeFSMPid, {error, in_progress}),
            {reply, {error, in_progress}, State};
        _ ->
            logger:debug("Solrq drain starting for partition ~p", [PartitionToDrain]),
            ExchangeFSMPid = proplists:get_value(
                ?EXCHANGE_FSM_PID, Params, undefined
            ),
            spawn_link(
                fun() ->
                    Result = try
                                 maybe_drain(enabled(), ExchangeFSMPid, Params)
                             catch
                                 _:E ->
                                     logger:info("An error occurred draining: ~p", [E]),
                                     maybe_exchange_fsm_drain_error(ExchangeFSMPid, E),
                                     {error, E}
                             end,
                    logger:debug("Solrq drain about to send compelte message for partition ~p.", [PartitionToDrain]),
                    gen_server:cast(?SERVER, {drain_complete, PartitionToDrain}),
                    gen_server:reply(From, Result)
                end
            ),
            {noreply, State#state{draining = Draining ++ [PartitionToDrain]}}
    end.

handle_cast({drain_complete, Partition}, #state{draining = Draining} = State) ->
    logger:debug("Solrq drain completed for partition ~p.", [Partition]),
    NewDraining = lists:delete(Partition, Draining),
    {noreply, State#state{draining = NewDraining}}.

%% Handle race conditions in monitor/receive timeout
handle_info({'DOWN', _Ref, _, _Obj, _Status}, State) ->
    {noreply, State};

handle_info(tick, State) ->
    yz_stat:queue_total_length(yz_solrq:queue_total_length()),
    schedule_tick(),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

maybe_drain(true, ExchangeFSMPid, Params) ->
    actual_drain(Params, ExchangeFSMPid);

maybe_drain(false, ExchangeFSMPid, Params) ->
    YZIndexHashtreeUpdateParams = proplists:get_value(
        ?YZ_INDEX_HASHTREE_PARAMS, Params
    ),
    maybe_update_yz_index_hashtree(
        ExchangeFSMPid, YZIndexHashtreeUpdateParams
    ),
    ok.

actual_drain(Params, ExchangeFSMPid) ->
    DrainTimeout = application:get_env(?YZ_APP_NAME,
                                       ?SOLRQ_DRAIN_TIMEOUT, ?SOLRQ_DRAIN_TIMEOUT_DEFAULT),
    Params1 = [{owner_pid, self()} | Params],
    {ok, Pid} = yz_solrq_sup:start_drain_fsm(Params1),
    Reference = erlang:monitor(process, Pid),
    yz_solrq_drain_fsm:start_prepare(Pid),
    try
        WorkersResumed = wait_for_workers_resumed_or_crash(DrainTimeout, Reference, Pid, ExchangeFSMPid),
        case WorkersResumed of
            ok ->
                wait_for_exit(Reference, Pid, ExchangeFSMPid);
            {error, Reason} ->
                {error, Reason}
        end
    after
        erlang:demonitor(Reference)
    end.

wait_for_workers_resumed_or_crash(DrainTimeout, Reference, Pid, ExchangeFSMPid) ->
    receive
        workers_resumed ->
            logger:debug("Workers resumed."),
            ok;
        {'DOWN', Reference, process, Pid, Reason} ->
            logger:error("Drain ~p exited prematurely.", [Pid]),
            handle_drain_fsm_pid_crash(Reason, ExchangeFSMPid)
    after DrainTimeout ->
        logger:debug("Drain ~p timed out.  Cancelling...", [Pid]),
        yz_stat:drain_timeout(),
        _ = cancel(Reference, Pid),
        maybe_exchange_fsm_drain_error(ExchangeFSMPid, timeout),
        {error, timeout}
    end.

wait_for_exit(Reference, Pid, ExchangeFSMPid) ->
    receive
        {'DOWN', Reference, process, Pid, normal} ->
            logger:debug("Drain ~p completed normally.", [Pid]),
            ok;
        {'DOWN', Reference, process, Pid, Reason} ->
            logger:error("Drain ~p crashed with reason ~p.", [Pid, Reason]),
            handle_drain_fsm_pid_crash(Reason, ExchangeFSMPid)
    end.

handle_drain_fsm_pid_crash(Reason, ExchangeFSMPid) ->
    yz_stat:drain_fail(),
    maybe_exchange_fsm_drain_error(ExchangeFSMPid, Reason),
    {error, Reason}.

enabled() ->
    application:get_env(?YZ_APP_NAME, ?SOLRQ_DRAIN_ENABLE, ?SOLRQ_DRAIN_ENABLE_DEFAULT).

cancel(Reference, Pid) ->
    CancelTimeout = application:get_env(
        ?YZ_APP_NAME, ?SOLRQ_DRAIN_CANCEL_TIMEOUT, ?SOLRQ_DRAIN_CANCEL_TIMEOUT_DEFAULT),
    case yz_solrq_drain_fsm:cancel(Pid, CancelTimeout) of
        timeout ->
            logger:warning("Drain cancel timed out.  Killing FSM pid ~p...", [Pid]),
            yz_stat:drain_cancel_timeout(),
            unlink_and_kill(Reference, Pid),
            {error, timeout};
        _ ->
            ok
    end.

unlink_and_kill(Reference, Pid) ->
    try
        demonitor(Reference),
        unlink(Pid),
        exit(Pid, kill)
    catch _:_ ->
        ok
    end.

-spec schedule_tick() -> reference().
schedule_tick() ->
    erlang:send_after(5000, ?SERVER, tick).

maybe_exchange_fsm_drain_error(undefined, _Reason) ->
    ok;
maybe_exchange_fsm_drain_error(Pid, Reason) ->
    yz_exchange_fsm:drain_error(Pid, Reason).

maybe_update_yz_index_hashtree(undefined, undefined) ->
    ok;
maybe_update_yz_index_hashtree(Pid, {YZTree, Index, IndexN}) ->
    yz_exchange_fsm:update_yz_index_hashtree(Pid, YZTree, Index, IndexN, undefined).
