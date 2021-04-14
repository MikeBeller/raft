defmodule Raft.Consensus do
  #states: [:init, :follower, :leader, :candidate]
  alias Raft.RPC

  @election_timeout_min 150
  @election_timeout_max 300

  defmodule Data do
    defstruct [
      current_term: 0,
      voted_for: nil,
      log: [],
      me: nil,
      nodes: [],
      commit_index: 0,
      last_applied: 0,
      next_index: %{},
      match_index: %{},
      last_event_time: 0,
    ]
  end

  # Actions:
  # {:set_timer, atom(), non_neg_integer()}
  # {:cancel_timer, atom()}
  # {:send, pid(), term()}

  #@spec action_set_timer(name(),non_neg_integer()) :: action()
  defp action_set_timer(name, timeout), do: {:set_timer, name, timeout}
  defp action_cancel_timer(name), do: {:cancel_timer, name}
  defp action_send(who, msg), do: {:send, who, msg}

  def last_log_index(%Data{log: []}), do: 0
  def last_log_index(%Data{log: [{i,_t,_v} | _rest]}), do: i

  def last_log_term(%Data{log: []}), do: 0
  def last_log_term(%Data{log: [{_i,t,_v} | _rest]}), do: t

  def random_range(min, max) when is_integer(min) and is_integer(max) do
    min - 1 + :rand.uniform(max - min + 1)
  end

  def election_timeout(), do: random_range(@election_timeout_min, @election_timeout_max)

  def init(me) do
    data = %Data{me: me}
    {:init, data, []}
  end

  def ev(:init, {:config, nodes}, %Data{me: me} = data) do
    data = %{data | nodes: List.delete(nodes, me)}
    {:follower, data, [action_set_timer(:election, election_timeout())]}
  end

  def ev(:follower, {:timeout, :election}, %Data{current_term: current_term, me: me, nodes: nodes} = data) do
    term = current_term + 1
    {:candidate, %{data | current_term: term}, [
      action_set_timer(:election, election_timeout()),
      action_send(nodes, RPC.RequestVoteReq.new(term, me, last_log_index(data), last_log_term(data)))]}
  end
end
