defmodule Raft.ConsensusTest do
  use ExUnit.Case, async: false
  alias Raft.Consensus
  alias Raft.RPC
  alias Raft.Log
  alias Consensus.Data

  defmacro match(pat) do
    quote do
      (&match?(unquote(pat), &1))
    end
  end

  @spec event(Data.t, atom(), term()) :: {Data.t, list(Consensus.action())}
  def event(data, type, arg) do
    Consensus.ev(data, {type, arg})
  end

  @spec expect({Data.t, list(Consensus.action())}, atom(), list(function())) :: Data.t
  def expect({data, actions}, state, funs) do
    assert data.state == state
    assert length(funs) == length(actions)
    #IO.puts "#{length(funs)} #{length(actions)} #{inspect actions}"
    assert Enum.all?(actions,
      fn a -> Enum.any?(funs, fn f -> f.(a) end) end)
    data
  end

  @spec base_consensus() :: Data.t
  def base_consensus() do
    Consensus.init(:a)
    |> expect(:init, [])
    |> event(:config, [:a, :b, :c])
    |> expect(:follower, [match {:set_timer, :election, _}])
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
    |> expect(:follower, [match {:set_timer, :election, _}])
  end

  test "new vote request as follower" do
    # base data -- pattern matched so reader of this test can see key default values
    data = base_consensus() 
    %Data{state: :follower, term: 0, me: :a, nodes: [:b, :c]} = data  # for documentary purposes

    # base request -- tests will be based on receiving various modifications of this message
    req = %RPC.RequestVoteReq{from: :b, term: 1, last_log_index: 0, last_log_term: 0}

    log_with_one_entry = Log.new() |> Log.append(1, :noop, nil)

    # Initial election process -- accept
    %{data | term: 0}
    |> event(:recv, %{req | term: 1})
    |> expect(:follower, [
      match({:set_timer, :election, _}),
      match({:send, [:b], %RPC.RequestVoteResp{term: 1, granted: true}})
    ])

    # Requestor's term is lower than mine, reject
    %{data | term: 7}
    |> event(:recv, %{req | term: 6})
    |> expect(:follower, [
      match({:send, [:b], %RPC.RequestVoteResp{term: 7, granted: false}})
    ])

    # I already voted so reject
    %{data | term: 0, voted_for: :c}
    |> event(:recv, %{req | term: 1})
    |> expect(:follower, [
      match({:send, [:b], %RPC.RequestVoteResp{term: 0, granted: false}})
    ])

    # Requestors logs are up to date so accept
    %{data | term: 1, log: log_with_one_entry}
    |> event(:recv, %{req | term: 2, last_log_index: 1, last_log_term: 1})
    |> expect(:follower, [
      match({:set_timer, :election, _}),
      match({:send, [:b], %RPC.RequestVoteResp{term: 2, granted: true}})
    ])

    # Requestor's logs are not up to date, reject
    %{data | term: 1, log: log_with_one_entry}
    |> event(:recv, %{req | term: 1, last_log_index: 0, last_log_term: 1})
    |> expect(:follower, [
      match({:send, [:b], %RPC.RequestVoteResp{term: 1, granted: false}})
    ])
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
             match({:set_timer, :election, _}),
             match({:send, ^nodes, %RPC.RequestVoteReq{term: 1, from: ^me, last_log_index: 0, last_log_term: 0}})
           ])

    # successful election
    data
    |> event(:recv, %RPC.RequestVoteResp{term: 0, from: :b, granted: true})
    |> expect(:leader,
      [
        match({:cancel_timer, :election}),
        match({:set_timer, :heartbeat, _}),
        match({:send, [:b], %RPC.AppendEntriesReq{term: 1, from: :a, prev_log_index: 0, prev_log_term: 0, entries: _entries}}),
        match({:send, [:c], %RPC.AppendEntriesReq{term: 1, from: :a, prev_log_index: 0, prev_log_term: 0, entries: _entries}}),
      ])

    # unsuccessful election -- recv AEReq from new leader with equal term
    data
    |> event(:recv, %RPC.AppendEntriesReq{term: 1, from: :b, prev_log_index: 0, prev_log_term: 0,
      entries: [%Log.Entry{index: 1, term: 1, type: :nop, data: nil}]})
      |> expect(:follower, [
        match({:set_timer, :election, _}),
        match({:send, [:b], %RPC.AppendEntriesResp{success: true}}),
      ])

    # received an AppendEntriesReq from potential leader with lower term -- reject and continue
    data
    |> event(:recv, %RPC.AppendEntriesReq{term: 0, from: :b, prev_log_index: 0, prev_log_term: 0,
      entries: [%Log.Entry{index: 1, term: 1, type: :nop, data: nil}]})
    |> expect(:candidate, [
        match({:send, [:b], %RPC.AppendEntriesResp{success: false}})
      ])

    # unsuccessful election -- election timer timeout
    data
    |> event(:timeout, :election)
    |> expect(:candidate, [
      match({:set_timer, :election, _v}),
      match({:send, _, %RPC.RequestVoteReq{term: 1,from: ^me, last_log_index: 0,last_log_term: 0}})
    ])

    # test receive requestvotereq with higher term?

  end


  test "appendentries processing as brand new follower" do
    data = base_consensus()
    # document some expected initial fields
    %Data{state: :follower, term: 0, log: []} = data

    entry1 = %Log.Entry{index: 1, term: 1, type: :nop, data: nil}
    entry2 = %Log.Entry{index: 2, term: 1, type: :cmd, data: 123}
    entry3 = %Log.Entry{index: 3, term: 2, type: :cmd, data: 234}
    req = %RPC.AppendEntriesReq{term: 1, from: :b,
      prev_log_index: 0, prev_log_term: 0, entries: [entry1]}

    # Vanilla successful append entries
    new_data = data  # capture new_data for tests further down
    |> event(:recv, req)
    |> expect(:follower, [
      match({:set_timer, :election, _}),
      match({:send, [:b], %RPC.AppendEntriesResp{term: 1, success: true}})])
    |> event(:recv, %{req | prev_log_index: 1, prev_log_term: 1, entries: [entry2]})
    |> expect(:follower, [
      match({:set_timer, :election, _}),
      match({:send, [:b], %RPC.AppendEntriesResp{term: 1, success: true}})])
    assert Log.last_index(new_data.log) == 2

    # Failure -- received term less than current term  (5.1)
    %{data | term: 2}
    |> event(:recv, req)
    |> expect(:follower, [
      match({:send, [:b], %RPC.AppendEntriesResp{term: 2, success: false}})])

    # Failure -- log doesn't contain entry with term prev_log_term at index prev_log_index(5.3)
    new_data  # from above
    |> event(:recv, %{req | term: 2, prev_log_index: 2, prev_log_term: 2, entries: [entry3]})
    |> expect(:follower, [
      match({:send, [:b], %RPC.AppendEntriesResp{term: _, success: false}})])

  end
end
