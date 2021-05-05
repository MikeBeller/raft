defmodule Raft.ServerTest do
  use ExUnit.Case, async: false
  alias Raft.Consensus
  alias Raft.Server

  test "init" do
    nodes = [:a, :b, :c]
    conses = for n <- nodes, do: Consensus.new(n)
    servers = for c <- conses do
      {:ok, srv} = Server.start_link(cons: c, name: c.me, log: [:send, :recv, :timeout])
      srv
    end

    servers
    |> Enum.each(fn srv -> Server.ev(srv, {:config, nodes}) end)

    Process.sleep(3000)
  end
end
