defmodule Raft.ServerTest do
  use ExUnit.Case, async: false
  alias Raft.Consensus
  alias Raft.Server
  alias Raft.RPC
  alias Raft.Log
  alias Consensus.Data

  test "init" do
    cons = Raft.Consensus.new()
    IO.inspect Raft.Server.start_link(cons)
  end
end
