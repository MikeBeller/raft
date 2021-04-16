defmodule Raft.Consensus do
  #states: [:init, :follower, :leader, :candidate]
  alias Raft.RPC

  @election_timeout_min 150
  @election_timeout_max 300

  @type addr :: Raft.addr
  @type time :: Raft.time
  @type log_entry :: {non_neg_integer(), non_neg_integer(), term()}

  defmodule Data do
    @type addr :: Raft.addr
    @type time :: Raft.time
    @type log_entry :: {non_neg_integer(), non_neg_integer(), term()}

    defstruct [:term, :voted_for, :responses, :log, :me, :nodes, :commit_index, :last_applied, :next_index, :match_index, :last_event_time]

    @type t :: %__MODULE__{
      term: non_neg_integer(),
      voted_for: nil | addr(),
      responses: %{addr() => boolean()},
      log: list(log_entry()),
      me: nil | addr(),
      nodes: list(addr),
      commit_index: non_neg_integer(),
      last_applied: non_neg_integer(),
      next_index: %{addr() => non_neg_integer()},
      match_index: %{addr() => non_neg_integer()},
      last_event_time: time(),
    }

    def new() do
      %__MODULE__{term: 0, voted_for: nil, responses: 0, log: [], me: nil, nodes: [], commit_index: 0, last_applied: 0, next_index: %{}, match_index: %{}, last_event_time: 0}
    end
  end

  @type set_timer_action() :: {:set_timer, atom(), non_neg_integer()}
  @type cancel_timer_action() :: {:cancel_timer, atom()}
  @type send_action() :: {:send, list(addr()), RPC.t}
  @type action() :: set_timer_action() | cancel_timer_action() | send_action()

  @type result() :: {atom(), Data.t, list(action())}

  @spec action_set_timer(atom(), non_neg_integer()) :: set_timer_action()
  defp action_set_timer(name, timeout), do: {:set_timer, name, timeout}

  @spec action_cancel_timer(atom()) :: cancel_timer_action()
  defp action_cancel_timer(name), do: {:cancel_timer, name}

  @spec action_send(addr(), RPC.t) :: send_action()
  defp action_send(who, msg), do: {:send, who, msg}

  @spec last_log_index(Data.t) :: non_neg_integer()
  def last_log_index(%Data{log: []}), do: 0
  def last_log_index(%Data{log: [{i,_t,_v} | _rest]}), do: i

  @spec last_log_term(Data.t) :: non_neg_integer()
  def last_log_term(%Data{log: []}), do: 0
  def last_log_term(%Data{log: [{_i,t,_v} | _rest]}), do: t

  @spec random_range(integer(), integer()) :: integer()
  def random_range(min, max) when is_integer(min) and is_integer(max) do
    min - 1 + :rand.uniform(max - min + 1)
  end

  @spec quorum(%Data{}, %{addr() => boolean()}) :: boolean()
  def quorum(%Data{nodes: nodes}, responses) do
    nn = map_size(nodes) + 1
    nv = Enum.count(responses, fn {_k, v} -> v end)
    nv > nn / 2
  end

  @spec election_timeout() :: non_neg_integer()
  def election_timeout(), do: random_range(@election_timeout_min, @election_timeout_max)

  defp reset_election_timer(), do: action_set_timer(:election, election_timeout())
  defp become_leader() do
    raise "oops"
  end

  @spec init(addr()) :: {atom(), Data.t, list(action)}
  def init(me) do
    data = %{Data.new() | me: me}
    {:init, data, []}
  end

  @type config_event() :: {:config, list(addr())}
  @type timeout_event() :: {:timeout, atom()}
  @type message_event() :: {:recv, RPC.t}
  @type event() :: config_event() | timeout_event() | message_event()
  @spec ev(atom(), event(), Data.t) :: {atom(), Data.t, list(action())}

  ## INIT
  #
  # This state only exists from creation of a consenus module until it
  # has the configuration -- the addresses of the other nodes.

  def ev(:init, {:config, nodes}, %Data{me: me} = data) do
    data = %{data | nodes: List.delete(nodes, me)}
    {:follower, data, [reset_election_timer()]}
  end

  ## FOLLOWER
  #

  # Election timeout
  def ev(:follower, {:timeout, :election}, %Data{term: term, me: me, nodes: nodes} = data) do
    term = term + 1
    {:candidate, %{data | term: term, voted_for: me, responses: %{me => true}},
      [
        action_set_timer(:election, election_timeout()),
        action_send(nodes, %RPC.RequestVoteReq{term: term, from: me,
            last_log_index: last_log_index(data), last_log_term: last_log_term(data)}),
      ]
    }
  end

  # RequestVote received
  def ev(:follower, {:recv, %RPC.RequestVoteReq{}} = req, %Data{} = data) do
    raise "unimplemented"
  end

  ## CANDIDATE
  #
  # RequestVote responses:
  #
  # all negative vote responses
  def ev(:candidate, {:recv, %RPC.RequestVoteResp{} = resp}, %Data{} = data) do
    cond do 
      resp.term > data.term ->
        {:follower, %{data | term: resp.term, responses: %{}, leader: nil}, [reset_election_timer()]}
      resp.term < data.term ->  #ignore
        {:candidate, data, []}
      true ->
        {:follower, %{data | responses: Map.put(data.responses, resp.from, false)}, []}
    end
  end

  # all positive vote responses
  def ev(:candidate, {:recv, %RPC.RequestVoteResp{} = resp}, %Data{} = data) do
    responses = Map.put(data.responses, resp.from, true)
    case quorum(data, responses) do
      true ->
        #become_leader(data)
        raise "unimplemented"
      false ->
        {:candidate, %{data | responses: responses}, []}
    end
  end
end
