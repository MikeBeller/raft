defmodule Raft.ConsensusTest do
  use ExUnit.Case, async: false
  alias Raft.Consensus
  alias Raft.RPC
  alias Raft.Log
  alias Consensus.Data

  @spec event(Data.t, atom(), term()) :: {Data.t, list(Consensus.action())}
  def event(data, type, arg) do
    Consensus.ev(data, {type, arg})
  end

  @spec expect({Data.t, list(Consensus.action())}, atom(), list(function())) :: Data.t
  def expect({data, actions}, state, funs) do
    assert data.state == state
    assert length(funs) == length(actions)
    IO.puts "#{length(funs)} #{length(actions)} #{inspect actions}"
    assert Enum.all?(actions,
      fn a -> Enum.any?(funs, fn f -> f.(a) end) end)
    data
  end

  @spec base_consensus() :: Data.t
  def base_consensus() do
    Consensus.init(:a)
    |> expect(:init, [])
    |> event(:config, [:a, :b, :c])
    |> expect(:follower, [fn {:set_timer, :election, _} -> true end])
  end

  defp newdata() do
    %Consensus.Data{state: :init, me: :a, term: 0, commit_index: 0, last_applied: 0, log: []}
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
    assert {%Data{state: :init, me: :a, term: 0}, []} = Consensus.init(:a)
  end

  test "config leads to follower" do
    Consensus.init(:a)
    |> expect(:init, [])
    |> event(:config, [:a, :b, :c])
    |> expect(:follower, [fn {:set_timer, :election, _} -> true end])
  end

  test "vote request as follower" do
    base_data = base_consensus()
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

      {%Data{state: :follower} = new_data, actions} = data |> event(:recv, req)
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

  test "become candidate, test election process" do
    # Init
    base_data = base_consensus()
    me = base_data.me
    nodes = base_data.nodes

    # Timeout of election timer -> become candidate
    data = base_data
           |> event(:timeout, :election)
           |> expect(:candidate, [
             fn {:set_timer, :election, _} -> true end,
             fn {:send, ^nodes, %RPC.RequestVoteReq{term: 1, from: ^me, last_log_index: 0, last_log_term: 0}} -> true end])

    # successful election
    data
    |> event(:recv, %RPC.RequestVoteResp{term: 0, from: :b, granted: true})
    |> expect(:leader,
      [
        fn {:cancel_timer, :election} -> true end,
        fn {:set_timer, :heartbeat, _} -> true end,
        fn {:send, [:b], %RPC.AppendEntriesReq{term: 1, from: :a, prev_log_index: 0, prev_log_term: 0, entries: _entries}} -> true end,
        fn {:send, [:c], %RPC.AppendEntriesReq{term: 1, from: :a, prev_log_index: 0, prev_log_term: 0, entries: _entries}} -> true end,])

    # unsuccessful election -- recv AEReq from new leader with equal term
    data
    |> event(:recv, %RPC.AppendEntriesReq{term: 1, from: :b, prev_log_index: 0, prev_log_term: 0,
      entries: [%Log.Entry{index: 1, term: 1, type: :nop, data: nil}]})
      |> expect(:follower, [fn _ -> true end])

    # received an AppendEntriesReq from potential leader with lower term -- reject and continue
    data
    |> event(:recv, %RPC.AppendEntriesReq{term: 0, from: :b, prev_log_index: 0, prev_log_term: 0,
      entries: [%Log.Entry{index: 1, term: 1, type: :nop, data: nil}]})
    |> expect(:candidate, [fn {:send, [:b], %RPC.AppendEntriesResp{success: false}} -> true end])

    # unsuccessful election -- election timer timeout
    data
    |> event(:timeout, :election)
    |> expect(:candidate, [
      fn {:set_timer, :election, _v} -> true end,
      fn {:send, _, %RPC.RequestVoteReq{term: 1,from: ^me, last_log_index: 0,last_log_term: 0}} -> true end])

    # test receive requestvotereq with higher term?

  end


  test "appendentries processing as brand new follower" do
    base_consensus()
    |> event(:recv,
      %RPC.AppendEntriesReq{term: 1, from: :b, prev_log_index: 0, prev_log_term: 0,
      entries: [%Log.Entry{index: 1, term: 1, type: :nop, data: nil}]})
    |> expect(:follower, [
      fn {:set_timer, :election, _} -> true end,
      fn {:send, [:b], %RPC.AppendEntriesResp{success: true}} -> true end
    ])
  end

end
