defmodule Raft.Consensus do
  #states: [:init, :follower, :leader, :candidate]

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
  def action_set_timer(name, timeout), do: {:set_timer, name, timeout}
  def action_cancel_timer(name), do: {:cancel_timer, name}
  def action_send(who, msg), do: {:send, who, msg}

  def random_range(min, max) when is_integer(min) and is_integer(max) do
    min - 1 + :rand.uniform(max - min + 1)
  end

  def init(me) do
    data = %Data{me: me}
    {:init, data, []}
  end

  def ev(:init, {:config, nodes}, %Data{me: me} = data) do
    data = %{data | nodes: List.delete(nodes, me)}
    timeout = random_range(@election_timeout_min, @election_timeout_max)
    {:follower, data, [action_set_timer(:election, timeout)]}
  end
end
