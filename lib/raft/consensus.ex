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

    defstruct [:state, :term, :voted_for, :responses, :log, :me, :nodes, :leader, :commit_index, :last_applied, :next_index, :match_index, :replies]

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
      replies: %{non_neg_integer() => {addr(), any()}},  # pending write replies
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
        replies: %{},
      }
    end
  end

  # Timers work as follows:
  #  * Each timer has a name
  #  * Only one timer with that name can be running
  #  * Setting a timer name also cancels any previous timer associated with that name
  #  * Cancelation is "perfect" (if you cancel, you will not receive a late message)
  #    (This is easily achievable if the timer system keeps the Erlang timer ref of the
  #    currently operating timer and filters out the old messages.)
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

  defp majority_greater_or_equal?(match_index, ind) do
    nn = map_size(match_index) + 1
    nc = ((for {_k,v} <- match_index, v >= ind, do: 1) |> Enum.sum()) + 1
    nc > (nn / 2)
  end

  defp calc_commit_index(term, commit_index, match_index, log) do
    lli = Log.last_index(log)

    # will always be true for commit_index so defaults to commit_index
    commit_index..lli
    |> Enum.reverse()
    |> Enum.find(fn
      0 -> true
      ind ->
        {:ok, entry} = Log.get_entry(log, ind) # must be there
        entry.term == term and majority_greater_or_equal?(match_index, ind)
    end)
  end

  @spec election_timeout() :: non_neg_integer()
  def election_timeout(), do: random_range(@election_timeout_min, @election_timeout_max)

  defp reset_election_timer(), do: action_set_timer(:election, election_timeout())

  @spec new(addr()) :: Data.t
  def new(me) do
    %{Data.new() | me: me}
  end

  @type config_event() :: {:config, list(addr())}
  @type timeout_event() :: {:timeout, atom()}
  @type message_event() :: {:recv, RPC.t}
  @type event() :: config_event() | timeout_event() | message_event()

  ## State transition functions

  @spec step_down_to_follower(Data.t, non_neg_integer(), addr()) :: Data.t
  def step_down_to_follower(%Data{} = data, term, leader \\ nil) do
    %{data | state: :follower, term: term, leader: leader, responses: %{}, voted_for: nil} # &&& voted_for needs reset?
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

  defp previous(_log, 1), do: {0, 0}
  defp previous(log, ind) do
    prev_index = ind - 1
    {:ok, entry} = Log.get_entry(log, prev_index)
    {prev_index, entry.term}
  end

  @spec send_entry(Data.t, Raft.addr(), non_neg_integer()) :: send_action()
  def send_entry(data, node, ind) do
    {prev_index, prev_term} = previous(data.log, ind)
    entries = case Log.get_entry(data.log, ind) do
      {:ok, entry} -> [entry]
      {:error, :not_found} -> []  # heartbeat
    end
    action_send([node],
      %RPC.AppendEntriesReq{
        from: data.me,
        term: data.term,
        prev_log_index: prev_index,
        prev_log_term: prev_term,
        leader_commit: data.commit_index,
        entries: entries,
      })
  end

  @spec send_next_entries(Data.t) :: list(send_action())
  # send next entry to each node per the next_index state variable
  def send_next_entries(data) do
    for node <- data.nodes do
      ind = data.next_index[node]
      send_entry(data, node, ind)
    end
  end

  @spec become_leader(Data.t) :: event_result()
  def become_leader(%Data{} = data) do
    lli = Log.last_index(data.log)
    next_index = for n <- data.nodes, into: %{}, do: {n, lli + 1}
    match_index = for n <- data.nodes, into: %{}, do: {n, 0}
    log = Log.append(data.log, data.term, :noop, nil)  #force a commit_index
    data = %{data | voted_for: nil, responses: %{}, next_index: next_index, log: log, match_index: match_index, replies: %{}}
    actions = send_next_entries(data)
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
      {%{data | term: req.term, state: :follower, leader: req.from, log: log, commit_index: commit},
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

  # received an AppendEntriesReq from (putative) new leader
  def ev(%Data{state: :candidate} = data, {:recv, %RPC.AppendEntriesReq{term: term} = req} = event) do
    if term >= data.term do
      # step down to follower and process it as a follower
      data = step_down_to_follower(data, term, req.from)
      ev(data, event)
    else
      {data, [action_send([req.from], %RPC.AppendEntriesResp{from: data.me, term: data.term, success: false})]}
    end
  end

  # election timeout
  def ev(%Data{state: :candidate} = data, {:timeout, :election}) do
    start_election(data)
  end

  ## LEADER

  def ev(%Data{state: :leader} = data, {:recv, %RPC.WriteReq{} = req}) do
    # add to log
    data = %{data | log: Log.append(data.log, data.term, :cmd, req.command)}
    # save sender in "replies" so you know who to send the write reply to when this entry is committed
    lli = Log.last_index(data.log)
    data = put_in(data.replies[lli], {req.from, req.id})
    actions = send_next_entries(data)
    actions = [action_set_timer(:heartbeat, @keep_alive_interval) | actions]
    {data, actions}
  end

  # positive AppendEntriesResp processing
  def ev(%Data{state: :leader} = data, {:recv, %RPC.AppendEntriesResp{success: true} = resp}) do
    index = data.next_index[resp.from]
    match_index = Map.put(data.match_index, resp.from, index)
    lli = Log.last_index(data.log)
    next_index = Map.put(data.next_index, resp.from, min(index + 1, lli))
    data = %{data | next_index: next_index, match_index: match_index}

    new_commit_index = calc_commit_index(data.term, data.commit_index, match_index, data.log)
    if new_commit_index > data.commit_index do
      # commit logs, send write replies
      # for now we don't actually have an external state machine to "apply" to so
      # committing logs just means updating commit_index.
      replies = (data.commit_index+1)..new_commit_index
                |> Enum.filter(fn ind ->
                  case Log.get_entry(data.log, ind) do
                    {:ok, e} -> e.type == :cmd
                    {:error, _} -> false
                  end
                end)
                |> Enum.map(fn ind ->
                  {from, id} = data.replies[ind]
                  {:send, [from], %RPC.WriteResp{from: data.me, id: id, result: :ok, leader: data.me}}
                end)
      {%{data | commit_index: new_commit_index}, replies}
    else
      {data, []}
    end
  end

  # Negative AppendEntriesResp processing
  def ev(%Data{state: :leader} = data, {:recv, %RPC.AppendEntriesResp{success: false} = req}) do
    cond do
      req.term > data.term ->
        {step_down_to_follower(data, req.term), [reset_election_timer()]}
      req.term < data.term ->
        {data, []}  # delayed message, ignore
      true ->
        # step back and try again
        case data.next_index[req.from] do
          0 ->
            # &&& really should log this!
            {data, []}
          ind ->
            data = put_in(data.next_index[req.from], ind-1)
            actions = [send_entry(data, req.from, ind-1)]
            {data, actions}
        end
    end
  end

  # Deal with heartbeats
  def ev(%Data{state: :leader} = data, {:timeout, :heartbeat}) do
    actions = send_next_entries(data)
    {data, [action_set_timer(:heartbeat, @keep_alive_interval) | actions]}
  end

  # Ignore vote responses after you already became leader:
  def ev(%Data{state: :leader} = data, {:recv, %RPC.RequestVoteResp{} = resp}) do
    {data, []}
  end

  # SPECIAL CASES
  
  # Deal with WriteReqs when you are not the leader
  def ev(%Data{state: state} = data, {:recv, %RPC.WriteReq{} = req}) when state != :leader do
    {data, [{:send, [req.from], %RPC.WriteResp{from: data.me, id: nil, result: :error, leader: data.leader}}]}
  end
end
