defmodule Raft.Consensus do
  #states: [:init, :follower, :leader, :candidate]
  alias Raft.RPC
  alias Raft.Log

  @election_timeout_min 150
  @election_timeout_max 300
  @keep_alive_interval 50

  @type addr :: Raft.addr
  @type time :: Raft.time

  defmodule Data do
    @type addr :: Raft.addr
    @type time :: Raft.time

    defstruct [:state, :term, :voted_for, :responses, :log, :me, :nodes, :leader, :commit_index, :last_applied, :next_index, :match_index, :last_event_time]

    @type t :: %__MODULE__{
      state: :init | :follower | :candidate | :leader,
      term: non_neg_integer(),
      voted_for: nil | addr(),
      responses: %{addr() => boolean()},
      log: Log.t(),
      me: nil | addr(),
      nodes: list(addr),
      leader: nil | addr(),
      commit_index: non_neg_integer(),
      last_applied: non_neg_integer(),
      next_index: %{addr() => non_neg_integer()},
      match_index: %{addr() => non_neg_integer()},
      last_event_time: time(),
    }

    def new() do
      %__MODULE__{
        state: :init,
        term: 0,
        voted_for: nil,
        responses: %{},
        log: Log.new(),
        me: nil,
        nodes: [],
        leader: nil,
        commit_index: 0,
        last_applied: 0,
        next_index: %{},
        match_index: %{},
        last_event_time: 0
      }
    end
  end

  @type set_timer_action() :: {:set_timer, atom(), non_neg_integer()}
  @type cancel_timer_action() :: {:cancel_timer, atom()}
  @type send_action() :: {:send, list(addr()), RPC.t}
  @type action() :: set_timer_action() | cancel_timer_action() | send_action()

  @type event_result() :: {Data.t, list(action())}

  @spec action_set_timer(atom(), non_neg_integer()) :: set_timer_action()
  defp action_set_timer(name, timeout), do: {:set_timer, name, timeout}

  @spec action_cancel_timer(atom()) :: cancel_timer_action()
  defp action_cancel_timer(name), do: {:cancel_timer, name}

  @spec action_send(list(addr()), RPC.t) :: send_action()
  defp action_send(who, msg), do: {:send, who, msg}

  @spec random_range(integer(), integer()) :: integer()
  def random_range(min, max) when is_integer(min) and is_integer(max) do
    min - 1 + :rand.uniform(max - min + 1)
  end

  @spec quorum?(%Data{}, %{addr() => boolean()}) :: boolean()
  def quorum?(%Data{nodes: nodes}, responses) do
    nn = length(nodes) + 1
    nv = Enum.count(responses, fn {_k, v} -> v end)
    nv > nn / 2
  end

  defp candidate_log_up_to_date?(%Data{} = data, %RPC.RequestVoteReq{} = req) do
    lli = Log.last_index(data.log)
    llt = Log.last_term(data.log)
    cond do
      req.term > llt -> true
      req.term < llt -> false
      req.term == llt and req.last_log_index > lli -> true
      req.term == llt and req.last_log_index < lli -> false
      true -> true
    end
  end

  @spec election_timeout() :: non_neg_integer()
  def election_timeout(), do: random_range(@election_timeout_min, @election_timeout_max)

  defp reset_election_timer(), do: action_set_timer(:election, election_timeout())

  @spec init(addr()) :: event_result()
  def init(me) do
    data = %{Data.new() | me: me}
    {data, []}
  end

  @type config_event() :: {:config, list(addr())}
  @type timeout_event() :: {:timeout, atom()}
  @type message_event() :: {:recv, RPC.t}
  @type event() :: config_event() | timeout_event() | message_event()

  ## State transition functions

  @spec step_down_to_follower(Data.t, non_neg_integer()) :: Data.t
  def step_down_to_follower(%Data{} = data, term) do
    %{data | state: :follower, term: term, responses: %{}, voted_for: nil} # &&& voted_for needs reset?
  end

  @spec matching_entry?(Log.t, non_neg_integer(), non_neg_integer()) :: boolean()
  def matching_entry?(log, prev_ind, prev_term) do
    if prev_ind == 0 and prev_term == 0 do
      true
    else
      case Log.get_entry(log, prev_ind) do
        {:ok, entry} -> (entry.term == prev_term)
        _ -> false
      end
    end
  end

  @spec delete_conflicting_entries(Log.t, Log.Entry.t) :: Log.t
  def delete_conflicting_entries(log, entry) do
    case Log.get_entry(log, entry.index) do
      {:ok, e} ->
        if e.term == entry.term, do: log, else: Log.del_entry_and_following(log, entry.index)
      _ -> log
    end
  end

  @spec apply_entries(Log.t, list(Log.Entry.t)) :: Log.t
  def apply_entries(log, entries) do
    entries = Enum.sort_by(entries, fn e -> e.index end)
    log = Enum.reduce(entries, log, fn e,l -> delete_conflicting_entries(l, e) end)
    Enum.reduce(entries, log, fn e,l -> Log.append(l, e.term, e.type, e.data) end)
  end
  
  @spec start_election(Data.t) :: event_result()
  def start_election(%Data{} = data) do
    {%{data | state: :candidate, voted_for: data.me, responses: %{data.me => true}},
      [
        reset_election_timer(),
        action_send(data.nodes, %RPC.RequestVoteReq{term: data.term, from: data.me,
            last_log_index: Log.last_index(data.log), last_log_term: Log.last_term(data.log)}),
      ]
    }
  end

  defp previous(_data, 1), do: {0, 0}
  defp previous(data, ind) do
    prev_index = ind - 1
    {:ok, entry} = Log.get_entry(data, prev_index)
    {prev_index, entry.term}
  end

  @spec send_entry(Data.t, Raft.addr(), non_neg_integer()) :: send_action()
  def send_entry(data, node, ind) do
    {prev_index, prev_term} = previous(data, ind)
    {:ok, entry} = Log.get_entry(data.log, ind)

    action_send([node],
      %RPC.AppendEntriesReq{
        from: data.me,
        term: data.term,
        prev_log_index: prev_index,
        prev_log_term: prev_term,
        leader_commit: data.commit_index,
        entries: [entry],
      })
  end

  @spec become_leader(Data.t) :: event_result()
  def become_leader(%Data{} = data) do
    lli = Log.last_index(data.log)
    next_index = for n <- data.nodes, into: %{}, do: {n, lli + 1}
    log = Log.append(data.log, data.term, :noop, nil)  #force a commit_index
    data = %{data | voted_for: nil, responses: %{}, next_index: next_index, log: log, match_index: %{}}
    actions = 
      for node <- data.nodes do
        ind = next_index[node] # &&& ? thought it was different per node but it's lli+1 (see above)
        send_entry(data, node, ind)
      end
    actions = [action_cancel_timer(:election), action_set_timer(:heartbeat, @keep_alive_interval) | actions]
    {%{data | state: :leader}, actions}
  end

  ## INIT
  #
  # This state only exists from creation of a consenus module until it
  # has the configuration -- the addresses of the other nodes.

  @spec ev(Data.t, event()) :: event_result()

  def ev(%Data{state: :init} = data, {:config, nodes}) do
    data = %{data | nodes: List.delete(nodes, data.me)}
    {%{data | state: :follower}, [reset_election_timer()]}
  end

  ## FOLLOWER
  #

  # Election timeout
  def ev(%Data{state: :follower} = data, {:timeout, :election}) do
    start_election(%{data | term: data.term + 1})
  end

  def ev(%Data{state: :follower} = data, {:recv, %RPC.AppendEntriesReq{} = req}) do
    if req.term < data.term or ! matching_entry?(data.log, req.prev_log_index, req.prev_log_term) do
      {%{data | state: :follower},
        [action_send([req.from],
          %RPC.AppendEntriesResp{from: data.me, term: data.term, success: false})]}
    else
      log = apply_entries(data.log, req.entries)
      commit = if req.leader_commit > data.commit_index do
        min(req.leader_commit, Log.last_index(log))
      else
        data.commit_index
      end
      {%{data | state: :follower, log: log, commit_index: commit},
        [reset_election_timer(),
         action_send([req.from],
           %RPC.AppendEntriesResp{from: data.me, term: req.term, success: true})
        ]}
    end
  end

  # RequestVote received
  def ev(%Data{state: :follower} = data, {:recv, %RPC.RequestVoteReq{} = req}) do
    if req.term >= data.term
      and (data.voted_for == nil or req.from == data.voted_for)
      and candidate_log_up_to_date?(data, req) do
      data = %{data | term: req.term, voted_for: req.from}
      {data,
        [
          action_send([req.from], %RPC.RequestVoteResp{from: data.me, term: req.term, granted: true}),
          reset_election_timer(),
        ]}
    else
      {data,
        [action_send([req.from], %RPC.RequestVoteResp{from: data.me, term: data.term, granted: false})]}
    end
  end

  ## CANDIDATE
  #
  # RequestVote responses received:
  #
  # all negative vote responses received
  def ev(%Data{state: :candidate} = data, {:recv, %RPC.RequestVoteResp{granted: false} = resp}) do
    cond do 
      resp.term > data.term ->
        {step_down_to_follower(data, resp.term), [reset_election_timer()]}
      resp.term < data.term ->  #ignore
        {data, []}
      true ->
        {%{data | responses: Map.put(data.responses, resp.from, false)}, []}
    end
  end

  # all positive vote responses received
  def ev(%Data{state: :candidate} = data, {:recv, %RPC.RequestVoteResp{granted: true} = resp}) do
    data = put_in(data.responses[resp.from], true)
    case quorum?(data, data.responses) do
      true ->
        become_leader(data)
      false ->
        {data, []}
    end
  end

  # received and AppendEntriesReq from (putative) new leader
  def ev(%Data{state: :candidate} = data, {:recv, %RPC.AppendEntriesReq{term: term} = req} = event) do
    if term >= data.term do
      # step down to follower and process it as a follower
      data = step_down_to_follower(data, term)
      ev(data, event)
    else
      {data, [action_send([req.from], %RPC.AppendEntriesResp{from: data.me, term: data.term, success: false})]}
    end
  end

  # election timeout
  def ev(%Data{state: :candidate} = data, {:timeout, :election}) do
    start_election(data)
  end
end
