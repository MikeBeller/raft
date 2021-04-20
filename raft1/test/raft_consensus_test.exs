defmodule Raft.ConsensusTest do
  use ExUnit.Case, async: true
  alias Raft.Consensus
  alias Raft.RPC
  alias Raft.Log

  defp newdata() do
    %Consensus.Data{me: :a, term: 0, commit_index: 0, last_applied: 0, log: []}
  end

  test "random range" do
    all = for _ <- 1..1000, into: MapSet.new(), do: Consensus.random_range(2,13)
    assert all == MapSet.new(2..13)
  end

  test "quorum?" do
    data = newdata()
    data = %{data | me: :a, nodes: [:b, :c]}
    assert Consensus.quorum?(data, %{:a => true, :b => true})
    assert Consensus.quorum?(data, %{:a => true, :c => true})
    refute Consensus.quorum?(data, %{:a => true})

    data = newdata()
    data = %{data | me: :a, nodes: [:b, :c, :d, :e]}
    assert Consensus.quorum?(data, %{:a => true, :b => true, :c => true})
    assert Consensus.quorum?(data, %{:a => true, :c => true, :e => true})
    refute Consensus.quorum?(data, %{:a => true, :b => true})
    refute Consensus.quorum?(data, %{:a => true, :d => true})
  end

  test "init waits for nodes" do
    assert {:init, data, []} = Consensus.init(:a)
    assert %Consensus.Data{me: :a, term: 0, commit_index: 0, last_applied: 0, log: []} = data
  end

  test "config leads to follower" do
    {:init, data, []} = Consensus.init(:a)
    assert {:follower, new_data, actions} = Consensus.ev(:init, {:config, [:a, :b, :c]}, data)
    assert MapSet.new(new_data.nodes) == MapSet.new([:b, :c])
    assert [{:set_timer, :election, n}] = actions
    assert n >= 150 and n <= 300
  end

  test "vote request as follower" do
    {:init, data, []} = Consensus.init(:a)
    {:follower, base_data, _actions} = Consensus.ev(:init, {:config, [:a, :b, :c]}, data)
    base_req = %RPC.RequestVoteReq{from: :b, term: 1, last_log_index: 0, last_log_term: 0}
    # test a set of voting scenarios in the follower state
    log_with_one_entry = Log.new() |> Log.append(1, :noop, nil)
    [
      # initial election, accept
      {[term: 0, voted_for: nil, log: []],
        [term: 1, from: :b, last_log_index: 0, last_log_term: 0],
        {1, true}},
      # requestor term is lower than mine, reject
      {[term: 7, voted_for: nil, log: []],
        [term: 6, from: :b, last_log_index: 0, last_log_term: 0],
        {7, false}},
      # I already voted, reject
      {[term: 0, voted_for: :c, log: []],
        [term: 1, from: :b, last_log_index: 0, last_log_term: 0],
        {0, false}},
      # Requestor's logs are up to date, accept
      {[term: 1, voted_for: nil, log: log_with_one_entry],
        [term: 2, from: :b, last_log_index: 1, last_log_term: 1],
        {2, true}},
      # Requestor's logs are not up to date, reject
      {[term: 1, voted_for: nil, log: log_with_one_entry],
        [term: 2, from: :b, last_log_index: 0, last_log_term: 1],
        {2, true}},
      {[term: 1, voted_for: nil, log: log_with_one_entry],
        [term: 2, from: :b, last_log_index: 1, last_log_term: 0],
        {2, true}},
    ]
    |> Enum.each(fn {data_overrides, request_overrides, {rsTerm, granted}} ->
      data = struct!(base_data, data_overrides)
      req = struct!(base_req, request_overrides)
      assert {:follower, new_data, actions} = Consensus.ev(:follower, {:recv, req}, data)
      assert [sendcmd | rest] = actions
      assert {:send, [:b], %RPC.RequestVoteResp{from: :a, term: ^rsTerm, granted: ^granted}} = sendcmd
      if granted do
        assert [{:set_timer, :election, _}] = rest
        assert new_data.term == req.term and new_data.voted_for == req.from
      else
        assert new_data == data
      end
    end)
  end

  test "follower become candidate and collect votes" do
    {:init, data, []} = Consensus.init(:a)
    {:follower, data, _actions} = Consensus.ev(:init, {:config, [:a, :b, :c]}, data)
    assert {:candidate, data, actions} = Consensus.ev(:follower, {:timeout, :election}, data)

    %{nodes: nodes, me: me} = data
    assert [ {:set_timer, :election, _n},
      {:send, ^nodes, %RPC.RequestVoteReq{term: 1,from: ^me,last_log_index: 0,last_log_term: 0,}}
    ] = actions

    {:leader, data, actions} = Consensus.ev(:candidate, {:recv, %RPC.RequestVoteResp{term: 0, from: :b, granted: true}}, data)
    IO.inspect data
    IO.inspect actions
    # &&& test all the fields
  end

end
