defmodule Raft.ConsensusTest do
  use ExUnit.Case, async: true
  alias Raft.Consensus
  alias Raft.RPC

  test "random range" do
    all = for _ <- 1..1000, into: MapSet.new(), do: Consensus.random_range(2,13)
    assert all == MapSet.new(2..13)
  end

  test "init waits for nodes" do
    assert {:init, data, []} = Consensus.init(:a)
    assert %Consensus.Data{me: :a, current_term: 0, commit_index: 0, last_applied: 0, log: []} = data
  end

  test "config leads to follower" do
    {:init, data, []} = Consensus.init(:a)
    assert {:follower, new_data, actions} = Consensus.ev(:init, {:config, [:a, :b, :c]}, data)
    assert MapSet.new(new_data.nodes) == MapSet.new([:b, :c])
    assert [{:set_timer, :election, n}] = actions
    assert n >= 150 and n <= 300
  end

  test "follower election timeout" do
    {:init, data, []} = Consensus.init(:a)
    {:follower, data, _actions} = Consensus.ev(:init, {:config, [:a, :b, :c]}, data)
    assert {:candidate, data, actions}
    = Consensus.ev(:follower, {:timeout, :election}, data)

    %{nodes: nodes, me: me} = data
    assert [ {:set_timer, :election, _n},
      {:send, ^nodes, %RPC.RequestVoteReq{term: 1,from: ^me,last_log_index: 0,last_log_term: 0,}}
    ] = actions
  end

end
